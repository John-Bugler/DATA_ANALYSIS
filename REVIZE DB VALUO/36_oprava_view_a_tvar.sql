-- =============================================================================
-- 36_oprava_view_a_tvar.sql — oprava karty vkladu pro jednotky a doplnění tvaru
-- =============================================================================
-- Databáze: VALUO        Krok: 36        Datum: 24. 10. 2026
--
-- Proč to vzniklo
-- ---------------
-- Karta vkladu se dosud zkoušela jen na rodinných domech. Na jednotkách
-- a na souborech pozemků se ukázalo dvojí:
--
-- 1) Jednotky neměly jednotkovou cenu, nebo ji měly špatně.
--    View bralo podlahovou plochu ze sloupce plocha_podlahova_valuo, který je
--    u jednotek vyplněný ve 137 případech z 27 325. Skutečná plocha prodávané
--    jednotky je ve Valuo_data.vklad_plocha_jednotky — vyplněná v 25 902
--    případech, tedy u 94,8 %.
--    Horší byl záložní zdroj: když plocha_podlahova_valuo chyběla, sáhlo view
--    na ruian_podlahova_plocha. Jenže RÚIAN u jednotky popisuje CELÝ DŮM.
--    Byt 44,81 m2 za 168,6 mil. tak vyšel na 4 140 Kc/m2 místo 3 762 553,
--    a takto chybně počítalo 10 053 vkladů jednotek.
--    Oprava: u jednotek se bere plocha jednotky z Valuo a na RÚIAN se nesahá;
--    u budov zůstává RÚIAN jako záloha. Ze stejného důvodu se u jednotek
--    nepočítá Kc/m2 pozemku ani Kc/m3 — pozemek pod domem i obestavěný prostor
--    patří všem bytům, ne tomu prodávanému.
--    Nový sloupec plocha_podlahova_zdroj říká, odkud plocha je.
--
-- 2) PP index nebyl ve view vůbec.
--    Valuo_karta_vklad existovala, ale nic ji neplnilo ani na ni view
--    nesahalo. Doplněna procedura sp_prepocet_karty_tvar a join do view.
--
-- Pořadí při plnění
-- -----------------
--    EXEC dbo.sp_prepocet_karty_okoli ...   -- po katastrálních územích
--    EXEC dbo.sp_prepocet_karty @cislo_vkladu = ...
--    EXEC dbo.sp_prepocet_karty_tvar        -- bez parametru = vše, co má kartu
--
-- Ověřeno
-- -------
--    Písnice V-76414/2024-101: pp_index_celku 0,718, pp_index_vse 0,120
--    Libuš   V-9837/2023-101:  pp_index_celku 0,597
--    — tytéž hodnoty, jaké dával dřívější ruční výpočet.
-- =============================================================================

-- ČÁST 1: opravené view
-- --------------------------------------------------------------------------
GO
ALTER VIEW dbo.v_Valuo_karta_vkladu
AS
WITH vklad AS (
    SELECT d.cislo_vkladu,
        MIN(d.datum_zplatneni) AS datum_zplatneni, MIN(d.rok) AS rok,
        MAX(d.cena_Kc) AS cena_Kc, MIN(d.mena) AS mena, MIN(d.kod_ku) AS kod_ku,
        MIN(d.vklad_klasifikace) AS klasifikace, MIN(d.vklad_nemovitosti) AS nemovitosti_ve_vkladu,
        SUM(CASE WHEN d.nemovitost = 'budova'   THEN 1 ELSE 0 END) AS pocet_budov,
        SUM(CASE WHEN d.nemovitost = 'jednotka' THEN 1 ELSE 0 END) AS pocet_jednotek,
        SUM(CASE WHEN d.nemovitost = 'parcela'  THEN 1 ELSE 0 END) AS pocet_parcel_valuo,
        /* plocha prodávané jednotky; v rámci vkladu je stejná na všech řádcích */
        MAX(d.vklad_plocha_jednotky) AS plocha_jednotky_valuo
    FROM dbo.Valuo_data d GROUP BY d.cislo_vkladu
),
hlavni_agr AS (
    SELECT d.cislo_vkladu,
        MAX(CASE WHEN d.typ_plochy = N'Podlahová plocha' THEN d.plocha END) AS plocha_podlahova_valuo,
        COUNT(*) AS hlavnich_radku
    FROM dbo.Valuo_data d WHERE d.nemovitost IN ('budova', 'jednotka', '---')
    GROUP BY d.cislo_vkladu
),
hlavni AS (
    /* reprezentativní hlavní nemovitost: nejdřív obytné druhy, pak největší
       plocha. Abecední MIN by u vkladu "dům + garáž" vybral garáž. */
    SELECT cislo_vkladu, typ AS hlavni_druh, adresa AS hlavni_adresa,
           jednotka_oznaceni, popis AS hlavni_popis, plocha AS hlavni_plocha,
           typ_plochy AS hlavni_typ_plochy, nemovitost AS hlavni_nemovitost
    FROM (SELECT d.cislo_vkladu, d.typ, d.adresa, d.jednotka_oznaceni, d.popis,
                 d.plocha, d.typ_plochy, d.nemovitost,
                 ROW_NUMBER() OVER (PARTITION BY d.cislo_vkladu ORDER BY
                     CASE WHEN d.typ IN (N'rodinný dům', N'objekt k bydlení') THEN 1
                          WHEN d.typ IN (N'byt', N'bytový dům') THEN 2
                          WHEN d.typ IN (N'stavba pro rodinnou rekreaci') THEN 3
                          WHEN d.typ IN (N'ateliér', N'jiný nebytový prostor') THEN 4
                          WHEN d.typ IN (N'garáž') THEN 9
                          WHEN d.typ IN (N'jiná stavba') THEN 8
                          ELSE 5 END,
                     ISNULL(d.plocha, 0) DESC, d.id) AS rn
          FROM dbo.Valuo_data d
          WHERE d.nemovitost IN ('budova', 'jednotka', '---')) x
    WHERE rn = 1
),
druhy AS (
    SELECT cislo_vkladu, STRING_AGG(CAST(polozka AS nvarchar(max)), N', ') AS slozeni_vkladu
    FROM (SELECT DISTINCT d.cislo_vkladu,
                 CAST(d.nemovitost AS nvarchar(50)) + N' ' + CAST(ISNULL(d.typ, N'?') AS nvarchar(100)) AS polozka
          FROM dbo.Valuo_data d) x
    GROUP BY cislo_vkladu
),
karta AS (
    SELECT kp.cislo_vkladu,
        COUNT(*) AS parcel_celkem,
        SUM(kp.vymera_m2) AS vymera_pozemku_vse,
        SUM(CASE WHEN kp.vlastnictvi = N'výhradní' AND kp.prostorova_role IN (N'kotva', N'celek')
                 THEN kp.vymera_m2 END) AS vymera_vyhradni_celek,
        SUM(CASE WHEN kp.vlastnictvi = N'výhradní' AND kp.prostorova_role = N'oddělená'
                 THEN kp.vymera_m2 END) AS vymera_vyhradni_mimo,
        SUM(CASE WHEN kp.vlastnictvi = N'podílová' THEN kp.vymera_m2 END) AS vymera_podilova,
        SUM(kp.vymera_dle_podilu) AS vymera_podilova_dle_podilu,
        SUM(CASE WHEN kp.vlastnictvi = N'neověřeno' THEN kp.vymera_m2 END) AS vymera_neoverena,
        SUM(CASE WHEN kp.prostorova_role = N'bez kotvy' THEN kp.vymera_m2 END) AS vymera_bez_kotvy,
        SUM(CASE WHEN kp.je_kotva = 1 THEN 1 ELSE 0 END) AS parcel_kotva,
        SUM(CASE WHEN kp.vlastnictvi = N'výhradní' AND kp.prostorova_role IN (N'kotva', N'celek') THEN 1 ELSE 0 END) AS parcel_vyhradni_celek,
        SUM(CASE WHEN kp.vlastnictvi = N'výhradní' AND kp.prostorova_role = N'oddělená' THEN 1 ELSE 0 END) AS parcel_vyhradni_mimo,
        SUM(CASE WHEN kp.vlastnictvi = N'podílová'  THEN 1 ELSE 0 END) AS parcel_podilovych,
        SUM(CASE WHEN kp.vlastnictvi = N'neověřeno' THEN 1 ELSE 0 END) AS parcel_neoverenych,
        SUM(CASE WHEN kp.sporna = 1 THEN 1 ELSE 0 END) AS parcel_spornych,
        MAX(kp.komponenta) AS komponent_celkem,
        MIN(kp.podil_odhad) AS podil_odhad_min
    FROM dbo.Valuo_karta_parcely kp GROUP BY kp.cislo_vkladu
),
plochy AS (
    /* Z které plochy se počítá Kč/m2 podlahové plochy.

       U jednotky popisuje RÚIAN CELÝ DŮM, ne prodávaný byt. Dělit cenou bytu
       podlahovou plochu domu dává nesmysl (byt 45 m2 za 168 mil. vyšel na
       4 140 Kc/m2 misto 3 762 553), proto se u jednotek na RÚIAN nesahá a
       bere se plocha jednotky z Valuo. U budovy je RÚIAN naopak správný zdroj. */
    SELECT v.cislo_vkladu,
        CASE WHEN v.pocet_jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA'
             THEN COALESCE(v.plocha_jednotky_valuo, ha.plocha_podlahova_valuo)
             ELSE COALESCE(ha.plocha_podlahova_valuo, rv.ruian_podlahova_plocha)
        END AS plocha_podlahova_karty,
        CASE WHEN v.pocet_jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA'
             THEN CASE WHEN v.plocha_jednotky_valuo IS NOT NULL THEN N'plocha jednotky dle Valuo'
                       WHEN ha.plocha_podlahova_valuo IS NOT NULL THEN N'podlahová plocha dle Valuo'
                  END
             ELSE CASE WHEN ha.plocha_podlahova_valuo IS NOT NULL THEN N'podlahová plocha dle Valuo'
                       WHEN rv.ruian_podlahova_plocha IS NOT NULL THEN N'podlahová plocha dle RÚIAN'
                  END
        END AS plocha_podlahova_zdroj,
        CASE WHEN v.pocet_jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA' THEN 1 ELSE 0 END AS je_jednotka
    FROM vklad v
    LEFT JOIN hlavni_agr ha ON ha.cislo_vkladu = v.cislo_vkladu
    LEFT JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = v.cislo_vkladu
)
SELECT
    v.cislo_vkladu, v.datum_zplatneni, v.rok, v.kod_ku,
    CAST(c.ku_nazev AS nvarchar(200)) AS kat_uzemi,
    CAST(c.obec_nazev AS nvarchar(200)) AS obec,
    v.cena_Kc, v.mena, v.klasifikace,
    h.hlavni_nemovitost, h.hlavni_druh, h.hlavni_adresa, h.jednotka_oznaceni,
    h.hlavni_popis, h.hlavni_plocha, h.hlavni_typ_plochy, ha.hlavnich_radku,
    v.nemovitosti_ve_vkladu, v.pocet_budov, v.pocet_jednotek, v.pocet_parcel_valuo,
    d.slozeni_vkladu,
    k.parcel_celkem, k.vymera_pozemku_vse, k.vymera_vyhradni_celek, k.vymera_vyhradni_mimo,
    k.vymera_podilova, k.vymera_podilova_dle_podilu, k.vymera_neoverena, k.vymera_bez_kotvy,
    k.parcel_kotva, k.parcel_vyhradni_celek, k.parcel_vyhradni_mimo,
    k.parcel_podilovych, k.parcel_neoverenych, k.parcel_spornych,
    k.komponent_celkem, k.podil_odhad_min,
    ha.plocha_podlahova_valuo,
    v.plocha_jednotky_valuo,
    pl.plocha_podlahova_karty, pl.plocha_podlahova_zdroj,
    rv.ruian_podlahova_plocha, rv.ruian_zastavena_plocha, rv.ruian_obestaveny_prostor,
    rv.ruian_pocet_podlazi, rv.ruian_pocet_bytu, rv.ruian_rok, rv.ruian_rok_presny,
    rv.ruian_pasmo, rv.ruian_druh_konstrukce, rv.ruian_vytapeni, rv.ruian_vytah,
    rv.pripojeni_vodovod_kod, rv.pripojeni_kanalizace_kod, rv.pripojeni_plyn_kod,
    rv.ruian_pomer_pp_op, rv.ruian_plocha_podezrela,
    kv.pp_index_celku, kv.plocha_celku_m2, kv.obvod_celku_m, kv.casti_celku,
    kv.pp_index_vse, kv.plocha_vse_m2, kv.obvod_vse_m, kv.casti_vse,
    CASE WHEN pl.plocha_podlahova_karty > 0
         THEN CAST(v.cena_Kc / pl.plocha_podlahova_karty AS decimal(14,2)) END AS jc_Kc_m2_podlahova,
    /* U jednotky je pozemek pod domem společný všem bytům; cenu bytu jím
       dělit nelze. Totéž platí pro obestavěný prostor celého domu. */
    CASE WHEN pl.je_jednotka = 0 AND k.vymera_vyhradni_celek > 0
         THEN CAST(v.cena_Kc / k.vymera_vyhradni_celek AS decimal(14,2)) END AS jc_Kc_m2_vyhradni_celek,
    CASE WHEN pl.je_jednotka = 0 AND k.vymera_pozemku_vse > 0
         THEN CAST(v.cena_Kc / k.vymera_pozemku_vse AS decimal(14,2)) END AS jc_Kc_m2_vsech_pozemku,
    CASE WHEN pl.je_jednotka = 0 AND rv.ruian_obestaveny_prostor > 0
         THEN CAST(v.cena_Kc / rv.ruian_obestaveny_prostor AS decimal(14,2)) END AS jc_Kc_m3
FROM vklad v
LEFT JOIN hlavni h ON h.cislo_vkladu = v.cislo_vkladu
LEFT JOIN hlavni_agr ha ON ha.cislo_vkladu = v.cislo_vkladu
LEFT JOIN druhy d ON d.cislo_vkladu = v.cislo_vkladu
LEFT JOIN karta k ON k.cislo_vkladu = v.cislo_vkladu
LEFT JOIN plochy pl ON pl.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.Valuo_karta_vklad kv ON kv.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku;

GO

-- ČÁST 2: tvar celku a všech pozemků (PP index)
-- ------------------------------------------------------------------------
GO
CREATE OR ALTER PROCEDURE dbo.sp_prepocet_karty_tvar
    @cislo_vkladu varchar(50) = NULL,   -- NULL = všechny vklady, které mají kartu
    @jen_nove bit = 0                   -- 1 = přeskočit už spočítané
AS
BEGIN
    SET NOCOUNT ON;

    /* Tvar celku a tvar všech pozemků vkladu.

       Počítá se ze sloučené geometrie parcel, ne po parcelách — funkční celek
       složený ze tří parcel má jeden obvod, ne tři. Výsledkem je Polsby-Popperův
       index 4*pi*A/O^2 jako holé číslo; koeficient si ze souboru dělá znalec sám.

       "Celek" = parcely ve výhradním vlastnictví v roli kotva nebo celek.
       "Vše"   = všechny parcely vkladu včetně podílových a oddělených.

       Samostatná procedura, aby se sp_prepocet_karty nemusela přepisovat;
       volá se hned po ní. */

    DECLARE @vklady TABLE (cislo_vkladu varchar(50) PRIMARY KEY);
    INSERT INTO @vklady (cislo_vkladu)
    SELECT DISTINCT kp.cislo_vkladu
    FROM dbo.Valuo_karta_parcely kp
    WHERE (@cislo_vkladu IS NULL OR kp.cislo_vkladu = @cislo_vkladu)
      AND (@jen_nove = 0 OR NOT EXISTS (SELECT 1 FROM dbo.Valuo_karta_vklad kv
                                        WHERE kv.cislo_vkladu = kp.cislo_vkladu));

    ;WITH g AS (
        SELECT kp.cislo_vkladu,
               CASE WHEN kp.vlastnictvi = N'výhradní'
                     AND kp.prostorova_role IN (N'kotva', N'celek') THEN 1 ELSE 0 END AS je_celek,
               k.geo_plocha
        FROM dbo.Valuo_karta_parcely kp
        JOIN @vklady v ON v.cislo_vkladu = kp.cislo_vkladu
        JOIN dbo.KN_parcel_data k ON k.gml_id = kp.gml_id
        WHERE k.geo_plocha IS NOT NULL
    ),
    celek AS (
        SELECT cislo_vkladu, geography::UnionAggregate(geo_plocha) AS geo
        FROM g WHERE je_celek = 1 GROUP BY cislo_vkladu
    ),
    vse AS (
        SELECT cislo_vkladu, geography::UnionAggregate(geo_plocha) AS geo
        FROM g GROUP BY cislo_vkladu
    ),
    spoctene AS (
        SELECT v.cislo_vkladu,
            CAST(c.geo.STArea()   AS decimal(18,2)) AS plocha_celku_m2,
            CAST(c.geo.STLength() AS decimal(18,2)) AS obvod_celku_m,
            c.geo.STNumGeometries() AS casti_celku,
            CAST(a.geo.STArea()   AS decimal(18,2)) AS plocha_vse_m2,
            CAST(a.geo.STLength() AS decimal(18,2)) AS obvod_vse_m,
            a.geo.STNumGeometries() AS casti_vse
        FROM @vklady v
        LEFT JOIN celek c ON c.cislo_vkladu = v.cislo_vkladu
        LEFT JOIN vse   a ON a.cislo_vkladu = v.cislo_vkladu
    )
    MERGE dbo.Valuo_karta_vklad AS cil
    USING (SELECT cislo_vkladu, plocha_celku_m2, obvod_celku_m, casti_celku,
                  plocha_vse_m2, obvod_vse_m, casti_vse,
                  CASE WHEN obvod_celku_m > 0 THEN
                       CAST(4 * PI() * plocha_celku_m2 / (obvod_celku_m * obvod_celku_m) AS decimal(9,4)) END AS pp_celku,
                  CASE WHEN obvod_vse_m > 0 THEN
                       CAST(4 * PI() * plocha_vse_m2 / (obvod_vse_m * obvod_vse_m) AS decimal(9,4)) END AS pp_vse
           FROM spoctene) AS zdroj
    ON cil.cislo_vkladu = zdroj.cislo_vkladu
    WHEN MATCHED THEN UPDATE SET
        cil.plocha_celku_m2 = zdroj.plocha_celku_m2, cil.obvod_celku_m = zdroj.obvod_celku_m,
        cil.pp_index_celku = zdroj.pp_celku, cil.casti_celku = zdroj.casti_celku,
        cil.plocha_vse_m2 = zdroj.plocha_vse_m2, cil.obvod_vse_m = zdroj.obvod_vse_m,
        cil.pp_index_vse = zdroj.pp_vse, cil.casti_vse = zdroj.casti_vse,
        cil.prepocteno = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (cislo_vkladu, plocha_celku_m2, obvod_celku_m, pp_index_celku, casti_celku,
         plocha_vse_m2, obvod_vse_m, pp_index_vse, casti_vse, prepocteno)
        VALUES (zdroj.cislo_vkladu, zdroj.plocha_celku_m2, zdroj.obvod_celku_m,
                zdroj.pp_celku, zdroj.casti_celku, zdroj.plocha_vse_m2,
                zdroj.obvod_vse_m, zdroj.pp_vse, zdroj.casti_vse, SYSDATETIME());

    SELECT @@ROWCOUNT AS radku_tvaru;
END
GO
