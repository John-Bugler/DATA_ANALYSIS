/* ================================================================
   VALUO — ZÁLOHA DEFINIC POHLEDŮ A PROCEDUR
   Stav databáze k 24. 10. 2026, po kroku 31.

   Export z sys.sql_modules (OBJECT_DEFINITION), text beze změny.
   Nahrazuje 29c_definice.sql jako aktuální stav; 29c zůstává
   jako historie.

   Obnova jednoho objektu: zkopíruj jeho blok, „CREATE" přepiš
   na „CREATE OR ALTER" a spusť v SSMS nad databází VALUO.

   Obsah (17 objektů):
     VIEW                   dbo.v_KN_parcely                     změněno 2026-10-22 15:58
     VIEW                   dbo.v_RUIAN_budovy                   změněno 2026-10-23 18:24
     VIEW                   dbo.v_RUIAN_jednotky                 změněno 2026-10-23 17:29
     VIEW                   dbo.v_RUIAN_vzorek                   změněno 2026-10-23 18:24
     VIEW                   dbo.v_Valuo                          změněno 2026-10-22 11:23
     VIEW                   dbo.v_Valuo_parcela_z_popisu         změněno 2026-10-22 21:45
     VIEW                   dbo.v_Valuo_vzorek                   změněno 2026-10-22 21:45
     VIEW                   dbo.v_Valuo_vzorek_q                 změněno 2026-10-24 13:55
     VIEW                   dbo.v_cenove_hladiny                 změněno 2026-10-23 10:00
     VIEW                   dbo.v_vklad_UP                       změněno 2026-10-23 15:40
     SQL_STORED_PROCEDURE   dbo.sp_detekce_hromadnych_prevodu    změněno 2026-10-23 18:59
     SQL_STORED_PROCEDURE   dbo.sp_detekce_prevodu_dle_ceny      změněno 2026-10-23 19:00
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_jednotkovych_cen     změněno 2026-10-24 13:55
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_men                  změněno 2026-10-22 19:19
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_prahu                změněno 2026-10-23 19:59
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_ruian_vzorku         změněno 2026-10-23 18:34
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_typu_prevodu         změněno 2026-10-22 21:23
   ================================================================ */

-- ----------------------------------------------------------------
-- VIEW: dbo.v_KN_parcely   (změněno 2026-10-22 15:58:31)
-- ----------------------------------------------------------------
/* ============================================================
   10.7  NÁZEV ÚZEMÍ SE NOVĚ BERE Z ČÍSELNÍKU
   ------------------------------------------------------------
   Kde jsi dřív psal k.kat_uzemi, napiš JOIN na číselník.
   Pohled níž to dělá za tebe.
   ============================================================ */

CREATE   VIEW dbo.v_KN_parcely
AS
SELECT  k.id,
        k.id_valuo,
        k.gml_id,
        k.kod_ku,
        c.ku_nazev                              AS kat_uzemi,
        c.obec_nazev                            AS obec,
        COALESCE(c.okres_nazev, c.kraj_nazev)   AS okres,
        c.kraj_nazev                            AS kraj,
        k.parcel_number,
        k.areaValue_m2,
        k.beginLifespanVersion                  AS zapsano_od,
        k.refPoint_x,
        k.refPoint_y,
        k.refPoint_lon,
        k.refPoint_lat,
        k.geo_bod,
        k.geo_plocha,
        k.id_UP_FVU_data,
        u.fvu_kod,
        u.mira_vyuziti,
        u.podil_pct                             AS podil_v_ploche_pct
FROM dbo.KN_parcel_data k
LEFT JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
LEFT JOIN dbo.KN_parcel_UP           u ON u.kn_id = k.id AND u.poradi = 1;
GO

-- ----------------------------------------------------------------
-- VIEW: dbo.v_RUIAN_budovy   (změněno 2026-10-23 18:24:18)
-- ----------------------------------------------------------------
/* ---------------------------------------------------------------------------
   1. v_RUIAN_budovy — zrušený příznak nahrazen poměrem

   ruian_pomer_pp_op = 3 x podlahová plocha / obestavěný prostor.
   Hodnota je data, mez je parametr v CIS_RUIAN_parametry — proto se
   příznak ruian_plocha_podezrela počítá až tady v pohledu.
   --------------------------------------------------------------------------- */
CREATE   VIEW dbo.v_RUIAN_budovy AS
SELECT
    v.id                        AS valuo_id,
    v.cislo_vkladu,
    v.nemovitost,
    v.typ,
    v.plocha                    AS plocha_valuo,
    v.typ_plochy                AS typ_plochy_valuo,
    r.kod_so,
    r.gml_id,
    r.dokonceni                 AS ruian_dokonceni,
    r.zastavena_plocha          AS ruian_zastavena_plocha,
    r.obestaveny_prostor        AS ruian_obestaveny_prostor,
    r.podlahova_plocha          AS ruian_podlahova_plocha,
    r.pomer_pp_op               AS ruian_pomer_pp_op,
    CAST(CASE WHEN r.pomer_pp_op IS NULL THEN NULL
              WHEN r.pomer_pp_op < p.pp_min OR r.pomer_pp_op > p.pp_max
              THEN 1 ELSE 0 END AS bit)  AS ruian_plocha_podezrela,
    r.pocet_podlazi             AS ruian_pocet_podlazi,
    r.pocet_bytu                AS ruian_pocet_bytu,
    r.druh_konstrukce_kod,
    ck.nazev                    AS druh_konstrukce,
    r.zpusob_vytapeni_kod,
    cv.nazev                    AS zpusob_vytapeni,
    r.vybaveni_vytahem_kod,
    cx.nazev                    AS vybaveni_vytahem,
    r.pripojeni_vodovod_kod,
    r.pripojeni_kanalizace_kod,
    r.pripojeni_plyn_kod,
    r.typ_so_kod,
    r.zpusob_vyuziti_kod,
    cu.nazev                    AS ruian_zpusob_vyuziti,
    r.soubor_datum              AS ruian_stav_k,
    r.plati_od                  AS ruian_plati_od
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data p2        ON p2.id_valuo = v.id
JOIN dbo.RUIAN_stavebni_objekty r ON r.gml_id = p2.gml_id
CROSS JOIN (
    SELECT MAX(CASE WHEN parametr = 'pomer_pp_op_min' THEN hodnota END) AS pp_min,
           MAX(CASE WHEN parametr = 'pomer_pp_op_max' THEN hodnota END) AS pp_max
    FROM dbo.CIS_RUIAN_parametry
) p
LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik = 'DruhKonstrukce'       AND ck.kod = r.druh_konstrukce_kod
LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik = 'ZpusobVytapeni'       AND cv.kod = r.zpusob_vytapeni_kod
LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik = 'VybaveniVytahem'      AND cx.kod = r.vybaveni_vytahem_kod
LEFT JOIN dbo.CIS_RUIAN cu ON cu.ciselnik = 'ZpusobVyuzitiObjektu' AND cu.kod = r.zpusob_vyuziti_kod
WHERE v.nemovitost = 'budova';
GO

-- ----------------------------------------------------------------
-- VIEW: dbo.v_RUIAN_jednotky   (změněno 2026-10-23 17:29:22)
-- ----------------------------------------------------------------
CREATE VIEW dbo.v_RUIAN_jednotky AS
SELECT
    v.id                        AS valuo_id,
    v.cislo_vkladu,
    v.typ,
    v.jednotka_oznaceni,
    v.jednotka_cp,
    r.kod_so,
    r.gml_id,

    /* kontrola napojení: nese ten objekt opravdu číslo popisné jednotky? */
    CAST(CASE WHEN EXISTS (
            SELECT 1 FROM dbo.RUIAN_so_cisla_domovni cd
            WHERE cd.kod_so = r.kod_so
              AND cd.cislo_domovni = TRY_CAST(v.jednotka_cp AS int))
         THEN 1 ELSE 0 END AS bit)          AS cp_souhlasi,

    r.dokonceni                 AS dum_dokonceni,
    r.pocet_bytu                AS dum_pocet_bytu,
    r.pocet_podlazi             AS dum_pocet_podlazi,
    r.zastavena_plocha          AS dum_zastavena_plocha,
    r.obestaveny_prostor        AS dum_obestaveny_prostor,
    r.druh_konstrukce_kod,
    ck.nazev                    AS dum_druh_konstrukce,
    r.vybaveni_vytahem_kod,
    cx.nazev                    AS dum_vytah,
    r.zpusob_vytapeni_kod,
    cv.nazev                    AS dum_vytapeni,
    r.pripojeni_vodovod_kod,
    r.pripojeni_kanalizace_kod,
    r.pripojeni_plyn_kod,
    r.zpusob_vyuziti_kod,
    cu.nazev                    AS dum_zpusob_vyuziti,
    r.soubor_datum              AS ruian_stav_k
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data p         ON p.id_valuo = v.id
JOIN dbo.RUIAN_stavebni_objekty r ON r.gml_id = p.gml_id
LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik = 'DruhKonstrukce'       AND ck.kod = r.druh_konstrukce_kod
LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik = 'ZpusobVytapeni'       AND cv.kod = r.zpusob_vytapeni_kod
LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik = 'VybaveniVytahem'      AND cx.kod = r.vybaveni_vytahem_kod
LEFT JOIN dbo.CIS_RUIAN cu ON cu.ciselnik = 'ZpusobVyuzitiObjektu' AND cu.kod = r.zpusob_vyuziti_kod
WHERE v.nemovitost = 'jednotka';
GO

-- ----------------------------------------------------------------
-- VIEW: dbo.v_RUIAN_vzorek   (změněno 2026-10-23 18:24:18)
-- ----------------------------------------------------------------
/* ---------------------------------------------------------------------------
   2. v_RUIAN_vzorek — jeden řádek na vklad, klíč cislo_vkladu

   Plochy se sčítají přes RŮZNÉ stavební objekty vkladu (DISTINCT kod_so),
   aby se u vkladu s několika jednotkami v témže domě nezapočítal dům
   vícekrát.

   U jednotek jsou plochy a objem plochami CELÉHO DOMU, ne bytu. Slouží
   k popisu domu (stáří, konstrukce, výtah), ne k výpočtu jednotkové ceny
   bytu — proto se Kč/m3 a Kč/m2 počítají jen u budov. Rozlišuje to
   sloupec ruian_zdroj.
   --------------------------------------------------------------------------- */
CREATE   VIEW dbo.v_RUIAN_vzorek AS
WITH vaz AS (
    SELECT v.cislo_vkladu, b.kod_so,
           CAST(1 AS int) AS je_budova, CAST(0 AS int) AS je_jednotka
    FROM dbo.v_RUIAN_budovy b
    JOIN dbo.Valuo_data v ON v.id = b.valuo_id
    UNION ALL
    SELECT v.cislo_vkladu, j.kod_so, 0, 1
    FROM dbo.v_RUIAN_jednotky j
    JOIN dbo.Valuo_data v ON v.id = j.valuo_id
),
u AS (
    SELECT cislo_vkladu, kod_so,
           MAX(je_budova) AS je_budova, MAX(je_jednotka) AS je_jednotka
    FROM vaz
    GROUP BY cislo_vkladu, kod_so
),
a AS (
    SELECT
        u.cislo_vkladu,
        COUNT(*)                                     AS objektu,
        MAX(u.je_budova)                             AS ma_budovu,
        MAX(u.je_jednotka)                           AS ma_jednotku,
        MIN(YEAR(r.dokonceni))                       AS rok_od,
        MAX(YEAR(r.dokonceni))                       AS rok_do,
        MIN(CASE WHEN r.dokonceni IS NULL THEN NULL
                 WHEN (MONTH(r.dokonceni) = 12 AND DAY(r.dokonceni) = 31)
                   OR DAY(r.dokonceni) = 1 THEN 0 ELSE 1 END) AS rok_presny,
        SUM(r.zastavena_plocha)                      AS zastavena_plocha,
        SUM(r.podlahova_plocha)                      AS podlahova_plocha,
        SUM(r.obestaveny_prostor)                    AS obestaveny_prostor,
        SUM(r.pocet_bytu)                            AS pocet_bytu,
        MAX(r.pocet_podlazi)                         AS pocet_podlazi,
        MIN(r.pomer_pp_op)                           AS pomer_pp_op,
        MIN(r.druh_konstrukce_kod)                   AS druh_konstrukce_kod,
        MIN(r.zpusob_vytapeni_kod)                   AS zpusob_vytapeni_kod,
        MIN(r.vybaveni_vytahem_kod)                  AS vybaveni_vytahem_kod,
        MIN(r.pripojeni_vodovod_kod)                 AS pripojeni_vodovod_kod,
        MIN(r.pripojeni_kanalizace_kod)              AS pripojeni_kanalizace_kod,
        MIN(r.pripojeni_plyn_kod)                    AS pripojeni_plyn_kod,
        MAX(r.soubor_datum)                          AS stav_k
    FROM u
    JOIN dbo.RUIAN_stavebni_objekty r ON r.kod_so = u.kod_so
    GROUP BY u.cislo_vkladu
),
cena AS (
    SELECT cislo_vkladu, MAX(cena_Kc) AS cena_Kc
    FROM dbo.Valuo_data
    GROUP BY cislo_vkladu
),
p AS (
    SELECT MAX(CASE WHEN parametr = 'pomer_pp_op_min' THEN hodnota END) AS pp_min,
           MAX(CASE WHEN parametr = 'pomer_pp_op_max' THEN hodnota END) AS pp_max
    FROM dbo.CIS_RUIAN_parametry
)
SELECT
    a.cislo_vkladu,

    /* --- původ údajů --- */
    a.objektu                               AS ruian_objektu,
    CASE WHEN a.ma_budovu = 1 AND a.ma_jednotku = 1 THEN N'obojí'
         WHEN a.ma_budovu = 1 THEN N'budova'
         ELSE N'jednotka' END               AS ruian_zdroj,
    a.stav_k                                AS ruian_stav_k,

    /* --- rok dokončení --- */
    a.rok_od                                AS ruian_rok,
    CASE WHEN a.rok_do <> a.rok_od THEN a.rok_do END AS ruian_rok_nejnovejsi,
    CAST(a.rok_presny AS bit)               AS ruian_rok_presny,
    s.pasmo                                 AS ruian_pasmo,
    CASE WHEN a.rok_od IS NOT NULL
         THEN YEAR(GETDATE()) - a.rok_od END AS ruian_stari_let,

    /* --- plochy a objem --- */
    a.zastavena_plocha                      AS ruian_zastavena_plocha,
    a.podlahova_plocha                      AS ruian_podlahova_plocha,
    a.obestaveny_prostor                    AS ruian_obestaveny_prostor,
    a.pocet_podlazi                         AS ruian_pocet_podlazi,
    a.pocet_bytu                            AS ruian_pocet_bytu,

    /* --- věrohodnost podlahové plochy --- */
    a.pomer_pp_op                           AS ruian_pomer_pp_op,
    CAST(CASE WHEN a.pomer_pp_op IS NULL THEN NULL
              WHEN a.pomer_pp_op < p.pp_min OR a.pomer_pp_op > p.pp_max
              THEN 1 ELSE 0 END AS bit)     AS ruian_plocha_podezrela,

    /* --- jednotkové ceny z údajů RÚIAN, jen u budov --- */
    CASE WHEN a.ma_budovu = 1 AND a.obestaveny_prostor > 0
         THEN CAST(cena.cena_Kc / a.obestaveny_prostor AS decimal(18,2)) END
                                            AS ruian_jedn_cena_Kc_m3,
    CASE WHEN a.ma_budovu = 1 AND a.podlahova_plocha > 0
         THEN CAST(cena.cena_Kc / a.podlahova_plocha AS decimal(18,2)) END
                                            AS ruian_jedn_cena_Kc_m2,

    /* --- vlastnosti stavby --- */
    ck.nazev                                AS ruian_druh_konstrukce,
    cv.nazev                                AS ruian_vytapeni,
    cx.nazev                                AS ruian_vytah,
    a.pripojeni_vodovod_kod,
    a.pripojeni_kanalizace_kod,
    a.pripojeni_plyn_kod
FROM a
CROSS JOIN p
LEFT JOIN cena ON cena.cislo_vkladu = a.cislo_vkladu
LEFT JOIN dbo.CIS_stari_stavby s ON a.rok_od BETWEEN s.rok_od AND s.rok_do
LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik = 'DruhKonstrukce'  AND ck.kod = a.druh_konstrukce_kod
LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik = 'ZpusobVytapeni'  AND cv.kod = a.zpusob_vytapeni_kod
LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik = 'VybaveniVytahem' AND cx.kod = a.vybaveni_vytahem_kod;
GO

-- ----------------------------------------------------------------
-- VIEW: dbo.v_Valuo   (změněno 2026-10-22 11:23:27)
-- ----------------------------------------------------------------
CREATE   VIEW dbo.v_Valuo
AS
SELECT  v.id,
        v.cislo_vkladu,
        v.datum_podani,
        v.datum_zplatneni,
        v.rok,
        v.mesic,

        /* ověřená územní identifikace z číselníku ČÚZK */
        v.kod_ku,
        c.ku_nazev                              AS kat_uzemi,
        c.obec_nazev                            AS obec,
        COALESCE(c.okres_nazev, c.kraj_nazev)   AS okres,
        c.kraj_nazev                            AS kraj,

        /* předmět a cena */
        v.nemovitost,
        v.typ,
        v.typ_plochy,
        v.popis,
        v.adresa,
        v.plocha                                AS vymera_m2,
        v.cenovy_udaj                           AS cena_Kc,
        v.mena,
        CAST(v.cenovy_udaj / NULLIF(v.plocha, 0)
             AS decimal(14,2))                  AS jedn_cena_Kc_m2,

        /* prostorové údaje */
        v.geo_bod,
        v.LAT,
        v.LON,
        v.geo_zdroj,

        /* původní, neověřené hodnoty — pro dohledání */
        v.kat_uzemi                             AS kat_uzemi_puvodni,
        v.okres                                 AS okres_puvodni
FROM dbo.Valuo_data v
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku
WHERE v.geo_zdroj = 'KN_refPoint';
GO

-- ----------------------------------------------------------------
-- VIEW: dbo.v_Valuo_parcela_z_popisu   (změněno 2026-10-22 21:45:04)
-- ----------------------------------------------------------------
/* ---------- 22a.1 POMOCNÝ POHLED S PŘÍZNAKEM --------------- */

CREATE   VIEW dbo.v_Valuo_parcela_z_popisu
AS
SELECT  id,
        cislo_vkladu,
        nemovitost,
        vklad_klasifikace,
        je_stavebni,
        je_soucasti_pozemku,
        LTRIM(RTRIM(bez_zavorek)) AS parcela_s_uzemim
FROM (
    SELECT id, cislo_vkladu, nemovitost, vklad_klasifikace,
           je_stavebni, je_soucasti_pozemku,
           CASE WHEN CHARINDEX(N' (', za_prefixem) > 0
                THEN LEFT(za_prefixem, CHARINDEX(N' (', za_prefixem) - 1)
                ELSE za_prefixem END AS bez_zavorek
    FROM (
        SELECT id, cislo_vkladu, nemovitost, vklad_klasifikace,
               CASE WHEN popis LIKE N'stavební č. %' THEN 1 ELSE 0 END AS je_stavebni,
               CASE WHEN popis LIKE N'%součástí je stavba%' THEN 1 ELSE 0 END
                                                                AS je_soucasti_pozemku,
               CASE WHEN popis LIKE N'stavební č. %' THEN SUBSTRING(popis, 13, 400)
                    WHEN popis LIKE N'č. %'          THEN SUBSTRING(popis,  4, 400)
               END AS za_prefixem
        FROM dbo.Valuo_data
    ) a
    WHERE za_prefixem IS NOT NULL
) b;
GO

-- ----------------------------------------------------------------
-- VIEW: dbo.v_Valuo_vzorek   (změněno 2026-10-22 21:45:04)
-- ----------------------------------------------------------------
/* ---------- 22a.3 ZÁKLADNÍ POHLED -------------------------- */

CREATE   VIEW dbo.v_Valuo_vzorek
AS
WITH opakovani AS (
    SELECT  popis, plocha,
            COUNT(DISTINCT cislo_vkladu) AS prodeju
    FROM dbo.Valuo_data
    WHERE nemovitost = N'budova' AND plocha > 0
    GROUP BY popis, plocha
),
parcely_ve_vkladu AS (
    SELECT DISTINCT cislo_vkladu
    FROM dbo.v_Valuo_parcela_z_popisu
    WHERE nemovitost = N'parcela'
),
stavba_vs_pozemek AS (
    /* 0 jen při obou podmínkách zároveň: stavba je samostatná
       věc A parcela pod ní se neprodává, přesto se ve vkladu
       jiné parcely prodávají.                                */
    SELECT  b.cislo_vkladu,
            MIN(CASE WHEN b.je_soucasti_pozemku = 1    THEN 1
                     WHEN pod.cislo_vkladu IS NOT NULL THEN 1
                     WHEN pv.cislo_vkladu IS NULL      THEN 1
                     ELSE 0 END) AS cena_patri_stavbe
    FROM dbo.v_Valuo_parcela_z_popisu b
    LEFT JOIN parcely_ve_vkladu pv
           ON pv.cislo_vkladu = b.cislo_vkladu
    LEFT JOIN dbo.v_Valuo_parcela_z_popisu pod
           ON pod.cislo_vkladu     = b.cislo_vkladu
          AND pod.nemovitost       = N'parcela'
          AND pod.parcela_s_uzemim = b.parcela_s_uzemim
    WHERE b.nemovitost = N'budova'
    GROUP BY b.cislo_vkladu
),
vklad AS (
    SELECT  v.cislo_vkladu,
            MIN(v.id)                      AS id_prvni,
            MIN(v.datum_zplatneni)         AS datum_zplatneni,
            MIN(v.rok)                     AS rok,
            MIN(v.mesic)                   AS mesic,
            MIN(v.kod_ku)                  AS kod_ku,
            MAX(v.cena_Kc)                 AS cena,
            MAX(v.cenovy_udaj)             AS cena_v_mene,
            MIN(v.mena)                    AS mena,
            MIN(v.kurz_pouzity)            AS kurz_pouzity,
            MIN(v.kurz_datum)              AS kurz_datum,
            MIN(v.typ_prevodu)             AS typ_prevodu,
            MIN(v.vklad_klasifikace)       AS klasifikace,
            MIN(v.vklad_duvod)             AS duvod,
            MIN(v.vklad_nemovitosti)       AS nemovitosti,
            MIN(v.vklad_duplicit)          AS duplicit,
            MIN(v.vklad_plocha_parcel)     AS plocha_parcel,
            MIN(v.vklad_plocha_jednotky)   AS plocha_jednotky,
            MIN(v.vklad_plocha_budovy)     AS plocha_budovy,

            MAX(CASE WHEN v.popis LIKE N'%součástí je stavba%'
                     THEN 1 ELSE 0 END)    AS na_pozemku_stavba,

            /* stavba zapsaná jako samostatná nemovitost */
            MAX(CASE WHEN v.nemovitost = N'budova'
                      AND v.popis NOT LIKE N'%součástí je stavba%'
                     THEN 1 ELSE 0 END)    AS stavba_samostatna,

            MIN(CASE WHEN v.nemovitost = N'budova'
                     THEN v.typ_plochy END) AS typ_plochy_stavby,

            MAX(CASE WHEN v.nemovitost = N'budova'
                     THEN o.prodeju END)    AS prodeju_tehoz_objektu,

            MIN(CASE WHEN v.vklad_klasifikace = 'JC_JEDNOTKA'
                      AND v.nemovitost = N'jednotka' THEN v.typ
                     WHEN v.vklad_klasifikace = 'CELEK_BUDOVA'
                      AND v.nemovitost = N'budova'   THEN v.typ
                     WHEN v.vklad_klasifikace = 'JC_PARCELY'
                      AND v.nemovitost = N'parcela'  THEN v.typ
                END)                       AS druh,
            COUNT(DISTINCT v.typ)          AS ruznych_druhu
    FROM dbo.Valuo_data v
    LEFT JOIN opakovani o ON o.popis = v.popis AND o.plocha = v.plocha
                         AND v.nemovitost = N'budova'
    WHERE v.geo_zdroj   = 'KN_refPoint'
      AND v.cenovy_udaj > 0
    GROUP BY v.cislo_vkladu
)
SELECT  k.cislo_vkladu,
        k.datum_zplatneni,
        k.rok,
        k.mesic,

        k.kod_ku,
        c.ku_nazev                              AS kat_uzemi,
        c.obec_nazev                            AS obec,
        COALESCE(c.okres_nazev, c.kraj_nazev)   AS okres,
        c.kraj_nazev                            AS kraj,

        k.klasifikace,
        k.duvod,
        k.typ_prevodu,
        k.druh,
        k.ruznych_druhu,
        k.nemovitosti                           AS nemovitosti_ve_vkladu,
        k.duplicit                              AS duplicitnich_radku,
        k.na_pozemku_stavba,
        k.stavba_samostatna,
        k.typ_plochy_stavby,
        k.prodeju_tehoz_objektu,
        ISNULL(sp.cena_patri_stavbe, 1)         AS cena_patri_stavbe,

        k.plocha_parcel                         AS plocha_parcel_m2,
        k.plocha_jednotky                       AS plocha_jednotky_m2,
        k.plocha_budovy                         AS plocha_budovy_m2,

        CASE WHEN k.typ_plochy_stavby = N'Podlahová plocha'
             THEN k.plocha_budovy END           AS plocha_podlahova_m2,

        k.cena                                  AS cena_Kc,
        k.mena,
        k.cena_v_mene,
        k.kurz_pouzity,
        k.kurz_datum,

        CASE
            WHEN k.klasifikace = 'JC_PARCELY' AND k.na_pozemku_stavba = 1
                 THEN NULL
            WHEN k.klasifikace = 'JC_PARCELY'
                 THEN CAST(k.cena / NULLIF(k.plocha_parcel, 0) AS decimal(14,2))
            WHEN k.klasifikace = 'JC_JEDNOTKA'
                 THEN CAST(k.cena / NULLIF(k.plocha_jednotky, 0) AS decimal(14,2))
            WHEN k.klasifikace = 'CELEK_BUDOVA'
             AND k.typ_plochy_stavby = N'Podlahová plocha'
             AND ISNULL(sp.cena_patri_stavbe, 1) = 1
                 THEN CAST(k.cena / NULLIF(k.plocha_budovy, 0) AS decimal(14,2))
            ELSE NULL
        END                                     AS jedn_cena_Kc_m2,

        p.geo_bod,
        p.LAT,
        p.LON
FROM vklad k
JOIN dbo.Valuo_data p            ON p.id     = k.id_prvni
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
LEFT JOIN stavba_vs_pozemek sp   ON sp.cislo_vkladu = k.cislo_vkladu;
GO

-- ----------------------------------------------------------------
-- VIEW: dbo.v_Valuo_vzorek_q   (změněno 2026-10-24 13:55:40)
-- ----------------------------------------------------------------
CREATE VIEW dbo.v_Valuo_vzorek_q
AS
WITH hlavni AS (
    SELECT  v.cislo_vkladu,
            MIN(v.nemovitost) AS nemovitost,
            MIN(v.typ)        AS typ,
            MIN(v.typ_plochy) AS typ_plochy,
            MIN(CASE WHEN CHARINDEX(N'domu a pozemku ', v.popis) > 0
                     THEN TRY_CONVERT(decimal(18,2),
                            SUBSTRING(v.popis,
                              CHARINDEX(N'domu a pozemku ', v.popis) + 15,
                              NULLIF(CHARINDEX(N'/', v.popis,
                                       CHARINDEX(N'domu a pozemku ',
                                                 v.popis) + 15), 0)
                              - CHARINDEX(N'domu a pozemku ', v.popis) - 15))
                END)          AS citatel_podilu
    FROM dbo.Valuo_data v
    WHERE (v.vklad_klasifikace = 'JC_JEDNOTKA'  AND v.nemovitost = N'jednotka')
       OR (v.vklad_klasifikace = 'CELEK_BUDOVA' AND v.nemovitost = N'budova')
       OR (v.vklad_klasifikace = 'JC_PARCELY'   AND v.nemovitost = N'parcela')
    GROUP BY v.cislo_vkladu
),
metrika AS (
    SELECT  v.cislo_vkladu,
            ISNULL(m.metrika,
                   CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                        ELSE 'CELEK' END)            AS metrika_dle_ciselniku,
            m.mez_vuci_kraji                         AS mez_druh,
            CASE
                WHEN v.klasifikace = 'JC_PARCELY'
                 AND v.na_pozemku_stavba = 1                 THEN 'CELEK'
                WHEN v.klasifikace = 'CELEK_BUDOVA'
                 AND v.cena_patri_stavbe = 0                 THEN 'CELEK'
                WHEN v.klasifikace = 'CELEK_BUDOVA'
                 AND ISNULL(v.prodeju_tehoz_objektu, 0) >= 5 THEN 'CELEK'
                WHEN ISNULL(m.metrika, '') = 'JC_PODLAHOVA'
                 AND v.plocha_podlahova_m2 > 0               THEN 'JC'
                WHEN ISNULL(m.metrika, '') = 'JC_PODLAHOVA'  THEN 'CELEK'
                ELSE ISNULL(m.metrika,
                       CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                            ELSE 'CELEK' END)
            END                                              AS metrika
    FROM dbo.v_Valuo_vzorek v
    LEFT JOIN hlavni p ON p.cislo_vkladu = v.cislo_vkladu
    LEFT JOIN dbo.CIS_metrika_ceny m
           ON m.nemovitost = p.nemovitost AND m.typ = p.typ
)
SELECT  v.cislo_vkladu, v.datum_zplatneni, v.rok, v.mesic, v.kod_ku,
        v.kat_uzemi, v.obec, v.okres, v.kraj, v.klasifikace, v.duvod,
        v.typ_prevodu, v.druh, v.ruznych_druhu, v.nemovitosti_ve_vkladu,
        v.duplicitnich_radku, v.plocha_parcel_m2, v.plocha_jednotky_m2,
        v.plocha_budovy_m2, v.plocha_podlahova_m2, v.typ_plochy_stavby,
        v.prodeju_tehoz_objektu, v.cena_patri_stavbe, v.stavba_samostatna,
        v.cena_Kc, v.mena, v.cena_v_mene, v.kurz_pouzity, v.kurz_datum,

        CASE WHEN hp.jedn_cena_Kc_m2 IS NOT NULL
               OR hc.cena_skupiny_Kc IS NOT NULL THEN 1 ELSE 0 END AS hromadny_prevod,
        COALESCE(hp.vkladu, hc.vkladu)              AS hromadne_vkladu,
        COALESCE(hp.typ_jevu, hc.typ_jevu)          AS typ_jevu,
        COALESCE(hp.poznamka, hc.poznamka)          AS hromadna_poznamka,
        CASE WHEN hp.jedn_cena_Kc_m2 IS NOT NULL THEN 'JC'
             WHEN hc.cena_skupiny_Kc IS NOT NULL THEN 'CENA' END AS hromadny_detektor,

        mt.metrika,
        CASE WHEN mt.metrika = 'JC' THEN v.jedn_cena_Kc_m2 END AS jedn_cena_Kc_m2,

        up.fvu_kod, up.mira_vyuziti, fs.skupina AS fvu_skupina,
        vp.pasmo AS velikostni_pasmo,

        h.hodnota AS porovnavana_hodnota,

        CAST(p.median     AS decimal(18,2)) AS median_Kc,
        CAST(p.prah_dolni AS decimal(18,2)) AS mez_zdola,
        CAST(p.prah_horni AS decimal(18,2)) AS mez_shora,
        p.n AS bodu_v_mezi,
        p.uroven AS uroven_meze,
        CASE WHEN p.median > 0
             THEN CAST(h.hodnota / p.median AS decimal(10,3)) END AS pomer_k_medianu,

        CAST(kr.median AS decimal(18,2))            AS median_kraj,
        CAST(kr.median * NULLIF(COALESCE(mt.mez_druh, t.mez_vuci_kraji), 0)
             AS decimal(18,2))                      AS mez_trzni_hladina,

        CASE
            WHEN ISNULL(v.mena, 'CZK') <> 'CZK'
             AND v.kurz_pouzity IS NULL              THEN N'cizí měna bez kurzu'
            WHEN v.typ_prevodu <> 'KUPNI_SMLOUVA'    THEN N'nestandardní převod'
            WHEN v.klasifikace = 'PRAVO_STAVBY'       THEN N'právo stavby'
            WHEN hp.jedn_cena_Kc_m2 IS NOT NULL
             AND ISNULL(y.do_medianu, 0) = 0         THEN N'hromadný převod'
            WHEN hc.cena_skupiny_Kc IS NOT NULL
             AND ISNULL(yc.do_medianu, 0) = 0        THEN N'hromadný převod'
            WHEN v.klasifikace = 'JC_PARCELY'
             AND v.cena_Kc < ISNULL(mzk.mez_Kc, mzg.mez_Kc)
                                                     THEN N'podíl nebo symbolický převod'
            WHEN v.klasifikace = 'CELEK_BUDOVA'
             AND v.cena_patri_stavbe = 0              THEN N'oddělené vlastnictví'
            WHEN v.klasifikace = 'CELEK_BUDOVA'
             AND ISNULL(v.prodeju_tehoz_objektu, 0) >= 5
                                                     THEN N'podíl na budově'
            WHEN mt.metrika_dle_ciselniku = 'JC_PODLAHOVA'
             AND ISNULL(v.plocha_podlahova_m2, 0) = 0
                                                     THEN N'chybí podlahová plocha'
            WHEN v.klasifikace = 'JC_PARCELY'
             AND v.na_pozemku_stavba = 1              THEN N'chybí podlahová plocha'
            WHEN mt.metrika = 'JC'
             AND ISNULL(v.jedn_cena_Kc_m2, 0) <= 0    THEN N'bez JC'
            WHEN ISNULL(h.hodnota, 0) <= 0            THEN N'bez ceny'

            /* Cena řádově pod krajskou hladinou není tržní, ať už jde
               o cokoli. Testuje se PŘED mezí z Valuo_prahy, protože ta
               je v kontaminovaném území stažená pod sebe.
               Podíl bere CIS_prahy_ceny podle klasifikace; konkrétní
               druh ho může přepsat v CIS_metrika_ceny, kde 0 znamená
               neuplatňovat (např. jiný nebytový prostor, kde se v jednom
               druhu míchají kanceláře se sklepy).                       */
            WHEN mt.metrika = 'JC'
             AND kr.median IS NOT NULL
             AND COALESCE(mt.mez_druh, t.mez_vuci_kraji) > 0
             AND v.jedn_cena_Kc_m2
                 < kr.median * COALESCE(mt.mez_druh, t.mez_vuci_kraji)
                                                     THEN N'pod tržní hladinou'

            WHEN v.klasifikace = 'NELZE'
             AND v.cena_Kc < ISNULL(NULLIF(t.cena_min, 0), mzg.mez_Kc)
                                                     THEN N'symbolická cena'
            WHEN v.klasifikace = 'NELZE'              THEN N'nelze porovnat'
            WHEN p.median IS NULL
             AND v.cena_Kc < ISNULL(NULLIF(t.cena_min, 0), mzg.mez_Kc)
                                                     THEN N'symbolická cena'
            WHEN p.median IS NULL                     THEN N'bez srovnání'
            WHEN h.hodnota < p.prah_dolni             THEN N'pod mezí'
            WHEN h.hodnota > p.prah_horni             THEN N'nad mezí'
            ELSE                                           N'bez výhrad'
        END                                         AS hodnoceni_ceny,

        CASE WHEN v.klasifikace = 'JC_PARCELY' AND v.na_pozemku_stavba = 1
             THEN N'stavba je součástí pozemku' ELSE N'—' END AS pozemek_se_stavbou,

        CASE WHEN ISNULL(v.mena, 'CZK') = 'CZK' THEN N'—'
             WHEN v.kurz_pouzity IS NULL        THEN N'bez kurzu'
             ELSE v.mena + N' kurzem ČNB k '
                  + CONVERT(varchar(10), v.kurz_datum, 104) END AS prepocet_meny,

        CASE
            WHEN r.nemovitost IS NULL                THEN N'bez pravidla'
            WHEN r.plocha_max = 0                    THEN N'nevhodný zdroj plochy'
            WHEN COALESCE(v.plocha_jednotky_m2, v.plocha_budovy_m2,
                          v.plocha_parcel_m2)
                 BETWEEN r.plocha_min AND r.plocha_max THEN N'v rozsahu'
            ELSE                                          N'mimo rozsah'
        END                                         AS hodnoceni_plochy,

        CASE
            WHEN v.klasifikace <> 'JC_JEDNOTKA'      THEN N'—'
            WHEN pd.citatel_podilu IS NULL           THEN N'nenačteno'
            WHEN pd.citatel_podilu < 100             THEN N'malý čitatel - podezřelý'
            ELSE                                          N'plošný zlomek'
        END                                         AS hodnoceni_podilu,

        CASE WHEN v.duplicitnich_radku > 0 THEN N'ano' ELSE N'ne' END
                                                    AS obsahuje_duplicity,

        v.geo_bod, v.LAT, v.LON,

        ru.ruian_rok, ru.ruian_pasmo, ru.ruian_rok_presny, ru.ruian_stari_let,
        ru.ruian_zastavena_plocha, ru.ruian_podlahova_plocha,
        ru.ruian_obestaveny_prostor, ru.ruian_pocet_podlazi,
        ru.ruian_pomer_pp_op, ru.ruian_plocha_podezrela,
        ru.ruian_druh_konstrukce, ru.ruian_vytapeni, ru.ruian_vytah,
        ru.ruian_zdroj, ru.ruian_stav_k,
        ISNULL(p.pasmo, N'') AS pasmo_meze,

        CASE WHEN v.klasifikace = 'CELEK_BUDOVA'
              AND ru.ruian_zdroj = N'budova'
              AND ru.ruian_obestaveny_prostor > 0
             THEN CAST(v.cena_Kc / ru.ruian_obestaveny_prostor AS decimal(18,2))
        END                                         AS jedn_cena_Kc_m3,
        CAST(m3.median     AS decimal(18,2))        AS median_Kc_m3,
        CAST(m3.prah_dolni AS decimal(18,2))        AS mez_m3_zdola,
        CAST(m3.prah_horni AS decimal(18,2))        AS mez_m3_shora,
        m3.n                                        AS bodu_v_mezi_m3,
        m3.uroven                                   AS uroven_meze_m3

FROM dbo.v_Valuo_vzorek v
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku
LEFT JOIN hlavni  pd ON pd.cislo_vkladu = v.cislo_vkladu
LEFT JOIN metrika mt ON mt.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.RUIAN_vzorek ru ON ru.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.Valuo_hromadne_prevody hp
       ON hp.klasifikace     = v.klasifikace
      AND hp.kat_uzemi       = v.kat_uzemi
      AND hp.druh            = ISNULL(v.druh, '?')
      AND hp.detektor        = 'JC'
      AND hp.jedn_cena_Kc_m2 = v.jedn_cena_Kc_m2
LEFT JOIN dbo.CIS_typy_hromadneho_prevodu y ON y.typ_jevu = hp.typ_jevu
LEFT JOIN dbo.Valuo_hromadne_prevody hc
       ON hc.klasifikace     = v.klasifikace
      AND hc.kat_uzemi       = v.kat_uzemi
      AND hc.druh            = ISNULL(v.druh, '?')
      AND hc.detektor        = 'CENA'
      AND hc.cena_skupiny_Kc = v.cena_Kc
      AND hc.rok             = v.rok
LEFT JOIN dbo.CIS_typy_hromadneho_prevodu yc ON yc.typ_jevu = hc.typ_jevu
LEFT JOIN dbo.v_vklad_UP      up ON up.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_FVU_skupiny fs ON fs.fvu_kod      = up.fvu_kod
LEFT JOIN dbo.CIS_velikost_pozemku vp
       ON v.plocha_parcel_m2 >= vp.od_m2 AND v.plocha_parcel_m2 < vp.do_m2
LEFT JOIN dbo.CIS_prahy_ceny   t  ON t.klasifikace = v.klasifikace
LEFT JOIN dbo.CIS_mez_podilu  mzk ON mzk.kraj      = c.kraj_nazev
LEFT JOIN dbo.CIS_mez_podilu  mzg ON mzg.kraj      = N'*'
LEFT JOIN dbo.CIS_rozsahy_ploch r
       ON r.nemovitost = pd.nemovitost
      AND r.typ        = pd.typ
      AND r.typ_plochy = pd.typ_plochy

CROSS APPLY (
    SELECT hodnota = CASE WHEN mt.metrika = 'JC' THEN v.jedn_cena_Kc_m2
                          ELSE v.cena_Kc END
) h

OUTER APPLY (
    SELECT TOP 1 pr.median, pr.prah_dolni, pr.prah_horni, pr.n, pr.uroven, pr.pasmo
    FROM dbo.Valuo_prahy pr
    WHERE pr.klasifikace = v.klasifikace
      AND v.klasifikace <> 'NELZE'
      AND pr.metrika = CASE WHEN mt.metrika = 'JC' THEN 'JC' ELSE 'CENA' END
      AND pr.klic = CASE
            WHEN v.klasifikace = 'JC_PARCELY'
             AND fs.skupina IS NOT NULL
             AND c.kraj_nazev = N'Hlavní město Praha'
            THEN N'FVU:' + CAST(fs.skupina AS nvarchar(20))
                 + N'|'  + CAST(vp.pasmo   AS nvarchar(12))
            ELSE N'DRUH:' + CAST(ISNULL(v.druh, '?') AS nvarchar(100)) END
      AND (pr.pasmo = ''
           OR (v.klasifikace IN ('JC_JEDNOTKA','CELEK_BUDOVA')
               AND pr.pasmo = ISNULL(ru.ruian_pasmo, '###')))
      AND (   (pr.uroven = N'k.ú.'  AND pr.uzemi = c.ku_nazev)
           OR (pr.uroven = N'okres' AND pr.uzemi =
                   COALESCE(c.okres_nazev, c.kraj_nazev))
           OR (pr.uroven = N'kraj'  AND pr.uzemi = c.kraj_nazev))
    ORDER BY CASE pr.uroven WHEN N'k.ú.'  THEN 1
                            WHEN N'okres' THEN 2 ELSE 3 END,
             CASE WHEN pr.pasmo <> '' THEN 0 ELSE 1 END
) p

OUTER APPLY (
    SELECT TOP 1 pr.median
    FROM dbo.Valuo_prahy pr
    WHERE pr.klasifikace = v.klasifikace
      AND v.klasifikace IN ('JC_JEDNOTKA', 'CELEK_BUDOVA')
      AND pr.metrika = 'JC'
      AND pr.pasmo   = ''
      AND pr.uroven  = N'kraj'
      AND pr.uzemi   = c.kraj_nazev
      AND pr.klic    = N'DRUH:' + CAST(ISNULL(v.druh, '?') AS nvarchar(100))
) kr

OUTER APPLY (
    SELECT TOP 1 pr.median, pr.prah_dolni, pr.prah_horni, pr.n, pr.uroven
    FROM dbo.Valuo_prahy pr
    WHERE pr.klasifikace = v.klasifikace
      AND v.klasifikace = 'CELEK_BUDOVA'
      AND pr.metrika = 'M3'
      AND pr.klic = N'DRUH:' + CAST(ISNULL(v.druh, '?') AS nvarchar(100))
      AND (pr.pasmo = '' OR pr.pasmo = ISNULL(ru.ruian_pasmo, '###'))
      AND (   (pr.uroven = N'k.ú.'  AND pr.uzemi = c.ku_nazev)
           OR (pr.uroven = N'okres' AND pr.uzemi =
                   COALESCE(c.okres_nazev, c.kraj_nazev))
           OR (pr.uroven = N'kraj'  AND pr.uzemi = c.kraj_nazev))
    ORDER BY CASE pr.uroven WHEN N'k.ú.'  THEN 1
                            WHEN N'okres' THEN 2 ELSE 3 END,
             CASE WHEN pr.pasmo <> '' THEN 0 ELSE 1 END
) m3;
GO

-- ----------------------------------------------------------------
-- VIEW: dbo.v_cenove_hladiny   (změněno 2026-10-23 10:00:12)
-- ----------------------------------------------------------------
/* ---------- 23b.4 HLADINY S PRÁVEM VETA --------------------
   Proti kroku 23 se mění jen to, že skupina zatříděná jako TRH
   zůstává ve výpočtu mediánu.                                */

CREATE   VIEW dbo.v_cenove_hladiny
AS
WITH zaklad AS (
    SELECT  q.kod_ku,
            c.okres_nazev,
            c.kraj_nazev,
            q.klasifikace,
            t.prah_bodu,
            CASE WHEN q.klasifikace = 'JC_PARCELY'
                  AND up.fvu_kod IS NOT NULL THEN N'FVU:'  + up.fvu_kod
                 ELSE                              N'DRUH:' + ISNULL(q.druh, '?')
            END                 AS klic,
            q.jedn_cena_Kc_m2   AS jc
    FROM dbo.v_Valuo_vzorek q
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod      = q.kod_ku
    JOIN dbo.CIS_prahy_ceny        t ON t.klasifikace = q.klasifikace
    LEFT JOIN dbo.v_vklad_UP      up ON up.cislo_vkladu = q.cislo_vkladu
    WHERE q.jedn_cena_Kc_m2 > 0
      AND q.cena_Kc >= t.cena_min
      AND ISNULL(q.mena, 'CZK') = 'CZK'
      AND q.typ_prevodu         = 'KUPNI_SMLOUVA'
      AND ISNULL(q.prodeju_tehoz_objektu, 0) < 5
      AND q.rok >= YEAR(GETDATE()) - 5
      AND NOT EXISTS (
            SELECT 1
            FROM dbo.Valuo_hromadne_prevody h
            LEFT JOIN dbo.CIS_typy_hromadneho_prevodu y
                   ON y.typ_jevu = h.typ_jevu
            WHERE h.klasifikace     = q.klasifikace
              AND h.kat_uzemi       = q.kat_uzemi
              AND h.druh            = ISNULL(q.druh, '?')
              AND h.jedn_cena_Kc_m2 = q.jedn_cena_Kc_m2
              AND ISNULL(y.do_medianu, 0) = 0)   /* TRH se nevyřazuje */
),
u_ku AS (
    SELECT DISTINCT kod_ku, klasifikace, klic, prah_bodu,
           COUNT(*) OVER (PARTITION BY kod_ku, klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY kod_ku, klasifikace, klic) AS med
    FROM zaklad
),
u_okres AS (
    SELECT DISTINCT COALESCE(okres_nazev, kraj_nazev) AS okres,
           klasifikace, klic, prah_bodu,
           COUNT(*) OVER (PARTITION BY COALESCE(okres_nazev, kraj_nazev),
                                       klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY COALESCE(okres_nazev, kraj_nazev),
                                  klasifikace, klic) AS med
    FROM zaklad
),
u_kraj AS (
    SELECT DISTINCT kraj_nazev, klasifikace, klic, prah_bodu,
           COUNT(*) OVER (PARTITION BY kraj_nazev, klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY kraj_nazev, klasifikace, klic) AS med
    FROM zaklad
)
SELECT DISTINCT
        z.kod_ku,
        z.klasifikace,
        z.klic,
        CAST(COALESCE(a.med, b.med, c.med) AS decimal(14,2)) AS median,
        COALESCE(a.n, b.n, c.n)                              AS bodu,
        CASE WHEN a.med IS NOT NULL THEN N'k.ú.'
             WHEN b.med IS NOT NULL THEN N'okres'
             WHEN c.med IS NOT NULL THEN N'kraj'
             ELSE N'—' END                                   AS uroven
FROM zaklad z
LEFT JOIN u_ku    a ON a.kod_ku = z.kod_ku
                   AND a.klasifikace = z.klasifikace
                   AND a.klic = z.klic AND a.n >= z.prah_bodu
LEFT JOIN u_okres b ON b.okres = COALESCE(z.okres_nazev, z.kraj_nazev)
                   AND b.klasifikace = z.klasifikace
                   AND b.klic = z.klic AND b.n >= z.prah_bodu
LEFT JOIN u_kraj  c ON c.kraj_nazev = z.kraj_nazev
                   AND c.klasifikace = z.klasifikace
                   AND c.klic = z.klic AND c.n >= z.prah_bodu;
GO

-- ----------------------------------------------------------------
-- VIEW: dbo.v_vklad_UP   (změněno 2026-10-23 15:40:46)
-- ----------------------------------------------------------------
/* ---------- 24e.2 OPRAVENÝ POHLED --------------------------
   Logika beze změny, jen správný zdroj. KN_parcel_UP má vazbu
   M:N, proto se uvnitř parcely bere polygon s pořadím 1, tedy
   s největším podílem plochy.                                */

CREATE   VIEW dbo.v_vklad_UP
AS
WITH hlavni_parcela AS (
    SELECT  k.id_valuo,
            u.fvu_kod,
            u.mira_vyuziti,
            ROW_NUMBER() OVER (PARTITION BY k.id_valuo
                               ORDER BY k.areaValue_m2 DESC, k.id) AS poradi
    FROM dbo.KN_parcel_data k
    JOIN dbo.KN_parcel_UP  u ON u.kn_id = k.id AND u.poradi = 1
)
SELECT  v.cislo_vkladu,
        MIN(h.fvu_kod)      AS fvu_kod,
        MIN(h.mira_vyuziti) AS mira_vyuziti
FROM dbo.Valuo_data v
JOIN hlavni_parcela h ON h.id_valuo = v.id AND h.poradi = 1
GROUP BY v.cislo_vkladu;
GO

-- ----------------------------------------------------------------
-- SQL_STORED_PROCEDURE: dbo.sp_detekce_hromadnych_prevodu   (změněno 2026-10-23 18:59:03)
-- ----------------------------------------------------------------
CREATE   PROCEDURE dbo.sp_detekce_hromadnych_prevodu
    @min_vkladu int = 5,
    @min_ploch  int = 3
AS
BEGIN
    SET NOCOUNT ON;
    /* Detektor podle JEDNOTKOVÉ ceny (krok 23).
       Od kroku 29 je v téže tabulce i detektor podle CELKOVÉ ceny,
       proto je všechno omezené na detektor = 'JC' — bez toho by
       NOT MATCHED BY SOURCE smazalo skupiny druhého detektoru. */

    WITH nove AS (
        SELECT  v.klasifikace, v.kat_uzemi, ISNULL(v.druh, '?') AS druh,
                v.jedn_cena_Kc_m2,
                COUNT(*) AS vkladu,
                COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                                        v.plocha_budovy_m2)) AS ruznych_ploch,
                MIN(v.cena_Kc) AS cena_min, MAX(v.cena_Kc) AS cena_max,
                MIN(v.rok) AS rok_min, MAX(v.rok) AS rok_max,
                MIN(COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                             v.plocha_budovy_m2)) AS plocha_min,
                MAX(COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                             v.plocha_budovy_m2)) AS plocha_max
        FROM dbo.v_Valuo_vzorek v
        WHERE v.jedn_cena_Kc_m2 > 0
        GROUP BY v.klasifikace, v.kat_uzemi, ISNULL(v.druh, '?'), v.jedn_cena_Kc_m2
        HAVING COUNT(*) >= @min_vkladu
           AND COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                                       v.plocha_budovy_m2)) >= @min_ploch
    )
    MERGE dbo.Valuo_hromadne_prevody AS t
    USING nove AS n
       ON  t.klasifikace     = n.klasifikace
       AND t.kat_uzemi       = n.kat_uzemi
       AND t.druh            = n.druh
       AND t.jedn_cena_Kc_m2 = n.jedn_cena_Kc_m2
       AND t.detektor        = 'JC'
    WHEN MATCHED THEN UPDATE SET
        t.vkladu = n.vkladu, t.ruznych_ploch = n.ruznych_ploch,
        t.cena_min = n.cena_min, t.cena_max = n.cena_max,
        t.rok_min = n.rok_min, t.rok_max = n.rok_max,
        t.plocha_min = n.plocha_min, t.plocha_max = n.plocha_max,
        t.datum_vypoctu = GETDATE()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (klasifikace, kat_uzemi, druh, detektor, jedn_cena_Kc_m2,
         cena_skupiny_Kc, rok, vkladu, ruznych_ploch, cena_min, cena_max,
         rok_min, rok_max, plocha_min, plocha_max, datum_vypoctu)
        VALUES
        (n.klasifikace, n.kat_uzemi, n.druh, 'JC', n.jedn_cena_Kc_m2,
         0, 0, n.vkladu, n.ruznych_ploch, n.cena_min, n.cena_max,
         n.rok_min, n.rok_max, n.plocha_min, n.plocha_max, GETDATE())
    WHEN NOT MATCHED BY SOURCE AND t.detektor = 'JC' AND t.typ_jevu IS NULL
        THEN DELETE
    WHEN NOT MATCHED BY SOURCE AND t.detektor = 'JC' AND t.typ_jevu IS NOT NULL
        THEN UPDATE SET t.vkladu = 0, t.datum_vypoctu = GETDATE();

    /* počet katastrů s touž jednotkovou cenou — jen pro detektor JC */
    UPDATE h SET h.katastru = k.katastru
    FROM dbo.Valuo_hromadne_prevody h
    JOIN (SELECT jedn_cena_Kc_m2, COUNT(DISTINCT kat_uzemi) AS katastru
          FROM dbo.Valuo_hromadne_prevody WHERE detektor = 'JC'
          GROUP BY jedn_cena_Kc_m2) k ON k.jedn_cena_Kc_m2 = h.jedn_cena_Kc_m2
    WHERE h.detektor = 'JC';

    /* medián lokality a poměr */
    UPDATE h
       SET h.median_lokality = x.median,
           h.pomer = CASE WHEN x.median > 0
                          THEN CAST(h.jedn_cena_Kc_m2 / x.median AS decimal(8,3)) END
    FROM dbo.Valuo_hromadne_prevody h
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_nazev = h.kat_uzemi
    OUTER APPLY (
        SELECT TOP 1 l.median FROM dbo.v_cenove_hladiny l
        WHERE l.kod_ku = c.ku_kod AND l.klasifikace = h.klasifikace
          AND l.klic = 'DRUH:' + h.druh
    ) x
    WHERE h.detektor = 'JC';
END;
GO

-- ----------------------------------------------------------------
-- SQL_STORED_PROCEDURE: dbo.sp_detekce_prevodu_dle_ceny   (změněno 2026-10-23 19:00:16)
-- ----------------------------------------------------------------
CREATE   PROCEDURE dbo.sp_detekce_prevodu_dle_ceny
    @min_vkladu int = 5,
    @kulatost   int = 1000
AS
BEGIN
    SET NOCOUNT ON;
    /* ========================================================================
       Detektor hromadných převodů podle CELKOVÉ ceny vkladu (krok 29).

       Doplňuje sp_detekce_hromadnych_prevodu, který klíčuje podle
       JEDNOTKOVÉ ceny a vyžaduje tři a více různých ploch. Družstevní
       privatizace, kde má každý byt vlastní cenu podle téhož vzorce,
       tou podmínkou propadne: každá jednotková cena má plochu jedinou.

       Doložený případ — Stodůlky, byty, 2023: 46 vkladů za shodných
       251 361 Kč, 42 za 493 433 Kč, 35 za 275 137 Kč. Medián území za
       ten rok vyšel 6 436 Kč/m² proti 125 376 Kč/m² o rok později,
       a všech 318 vkladů prošlo jako „bez výhrad". Mez je nezachytila,
       protože si ji ty převody samy stáhly pod sebe (mez_zdola
       645 Kč/m²).

       KRITÉRIUM. Shodná celková cena u @min_vkladu a více vkladů
       v témže území, druhu a roce, A ZÁROVEŇ aspoň jedno z:
         - plochy se opakují (různých ploch nejvýš polovina vkladů)
         - cena není kulatá na @kulatost Kč

       Druhá podmínka odděluje trh od transakce: pět bytů za kulatých
       pět milionů s pěti různými plochami je náhoda, ne jedna smlouva.

       Nic nemaže ani nevyřazuje — skupiny jen označí. Zatřídění dělá
       znalec a MERGE ho zachová, stejně jako u detektoru JC.

       Zdroj je nejdřív v #nove: MERGE přímo nad CTE nad pohledem
       nestíhal.
       ======================================================================== */

    IF OBJECT_ID('tempdb..#nove') IS NOT NULL DROP TABLE #nove;

    SELECT  v.klasifikace, v.kat_uzemi, ISNULL(v.druh, '?') AS druh,
            v.rok, v.cena_Kc,
            COUNT(*) AS vkladu,
            COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                                    v.plocha_budovy_m2)) AS ruznych_ploch,
            COUNT(DISTINCT v.jedn_cena_Kc_m2) AS ruznych_cen,
            MIN(COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                         v.plocha_budovy_m2)) AS plocha_min,
            MAX(COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                         v.plocha_budovy_m2)) AS plocha_max
    INTO #nove
    FROM dbo.v_Valuo_vzorek v
    WHERE v.cena_Kc > 0
    GROUP BY v.klasifikace, v.kat_uzemi, ISNULL(v.druh, '?'), v.rok, v.cena_Kc
    HAVING COUNT(*) >= @min_vkladu
       AND ( COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                                     v.plocha_budovy_m2)) * 2 <= COUNT(*)
          OR v.cena_Kc % @kulatost <> 0 );

    MERGE dbo.Valuo_hromadne_prevody AS t
    USING #nove AS n
       ON  t.klasifikace     = n.klasifikace
       AND t.kat_uzemi       = n.kat_uzemi
       AND t.druh            = n.druh
       AND t.detektor        = 'CENA'
       AND t.cena_skupiny_Kc = n.cena_Kc
       AND t.rok             = n.rok
    WHEN MATCHED THEN UPDATE SET
        t.vkladu = n.vkladu, t.ruznych_ploch = n.ruznych_ploch,
        t.ruznych_cen = n.ruznych_cen,
        t.cena_min = n.cena_Kc, t.cena_max = n.cena_Kc,
        t.rok_min = n.rok, t.rok_max = n.rok,
        t.plocha_min = n.plocha_min, t.plocha_max = n.plocha_max,
        t.datum_vypoctu = GETDATE()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (klasifikace, kat_uzemi, druh, detektor, jedn_cena_Kc_m2,
         cena_skupiny_Kc, rok, vkladu, ruznych_ploch, ruznych_cen,
         cena_min, cena_max, rok_min, rok_max, plocha_min, plocha_max,
         datum_vypoctu)
        VALUES
        (n.klasifikace, n.kat_uzemi, n.druh, 'CENA', 0,
         n.cena_Kc, n.rok, n.vkladu, n.ruznych_ploch, n.ruznych_cen,
         n.cena_Kc, n.cena_Kc, n.rok, n.rok, n.plocha_min, n.plocha_max,
         GETDATE())
    WHEN NOT MATCHED BY SOURCE AND t.detektor = 'CENA' AND t.typ_jevu IS NULL
        THEN DELETE
    WHEN NOT MATCHED BY SOURCE AND t.detektor = 'CENA' AND t.typ_jevu IS NOT NULL
        THEN UPDATE SET t.vkladu = 0, t.datum_vypoctu = GETDATE();

    DROP TABLE #nove;
END;
GO

-- ----------------------------------------------------------------
-- SQL_STORED_PROCEDURE: dbo.sp_prepocet_jednotkovych_cen   (změněno 2026-10-24 13:55:23)
-- ----------------------------------------------------------------
CREATE PROCEDURE dbo.sp_prepocet_jednotkovych_cen
AS
BEGIN
    SET NOCOUNT ON;

    /* různé nemovitosti ve vkladu — bez duplicitních zápisů */
    WITH dedup AS (
        SELECT DISTINCT cislo_vkladu, nemovitost, typ, adresa, plocha,
                        typ_plochy
        FROM dbo.Valuo_data
    ),
    pocty AS (
        SELECT  cislo_vkladu,
                COUNT(*) AS nemovitosti,
                SUM(CASE WHEN nemovitost = N'parcela'  THEN 1 ELSE 0 END) AS parcel,
                SUM(CASE WHEN nemovitost = N'jednotka' THEN 1 ELSE 0 END) AS jednotek,
                SUM(CASE WHEN nemovitost = N'budova'   THEN 1 ELSE 0 END) AS budov,

                /* krok 31: právo stavby — Valuo ho vede jako '---' */
                SUM(CASE WHEN nemovitost = N'---'      THEN 1 ELSE 0 END) AS prav_stavby,

                /* součet výměr parcel */
                SUM(CASE WHEN nemovitost = N'parcela' THEN plocha ELSE 0 END)
                    AS plocha_parcel,

                /* plocha jednotky — jen z podílu na budově.
                   "Výměra parcely" u jednotky je pozemek,
                   ne byt, a do jmenovatele nepatří. */
                SUM(CASE WHEN nemovitost = N'jednotka'
                          AND typ_plochy = N'Plocha spočítaná z podílu na budově'
                         THEN plocha ELSE 0 END) AS plocha_jednotky,

                /* plocha budovy — jen podlahová či zastavěná */
                SUM(CASE WHEN nemovitost = N'budova'
                          AND typ_plochy IN (N'Podlahová plocha',
                                             N'Zastavěná plocha budovy')
                         THEN plocha ELSE 0 END) AS plocha_budovy
        FROM dedup
        GROUP BY cislo_vkladu
    ),
    radky AS (
        SELECT cislo_vkladu, COUNT(*) AS radku
        FROM dbo.Valuo_data
        GROUP BY cislo_vkladu
    )
    UPDATE v
    SET v.vklad_nemovitosti     = p.nemovitosti,
        v.vklad_radku           = r.radku,
        v.vklad_duplicit        = r.radku - p.nemovitosti,
        v.vklad_plocha_parcel   = NULLIF(p.plocha_parcel,   0),
        v.vklad_plocha_jednotky = NULLIF(p.plocha_jednotky, 0),
        v.vklad_plocha_budovy   = NULLIF(p.plocha_budovy,   0),

        v.vklad_klasifikace =
            CASE WHEN p.prav_stavby > 0                THEN 'PRAVO_STAVBY'
                 WHEN p.budov    > 1                   THEN 'NELZE'
                 WHEN p.jednotek > 1                   THEN 'NELZE'
                 WHEN p.budov = 1 AND p.jednotek = 1   THEN 'NELZE'
                 WHEN p.budov    = 1                   THEN 'CELEK_BUDOVA'
                 WHEN p.jednotek = 1                   THEN 'JC_JEDNOTKA'
                 WHEN p.parcel   > 0                   THEN 'JC_PARCELY'
                 ELSE                                       'NELZE'
            END,

        v.vklad_duvod =
            CASE WHEN p.prav_stavby > 0              THEN 'právo stavby'
                 WHEN p.budov    > 1                 THEN 'více budov ve vkladu'
                 WHEN p.jednotek > 1                 THEN 'více jednotek ve vkladu'
                 WHEN p.budov = 1 AND p.jednotek = 1 THEN 'budova i jednotka zároveň'
                 WHEN p.budov = 0 AND p.jednotek = 0
                  AND p.parcel = 0                   THEN 'nezařazená nemovitost'
                 ELSE NULL
            END
    FROM dbo.Valuo_data v
    JOIN pocty p ON p.cislo_vkladu = v.cislo_vkladu
    JOIN radky r ON r.cislo_vkladu = v.cislo_vkladu;
END;
GO

-- ----------------------------------------------------------------
-- SQL_STORED_PROCEDURE: dbo.sp_prepocet_men   (změněno 2026-10-22 19:19:17)
-- ----------------------------------------------------------------
/* ============================================================
   19b.3  PROCEDURA PŘEPOČTU
   Spouštět po každém importu nových dat z Valua.
   ============================================================ */

CREATE   PROCEDURE dbo.sp_prepocet_men
AS
BEGIN
    SET NOCOUNT ON;

    /* a) korunové vklady — cena beze změny */
    UPDATE dbo.Valuo_data
    SET cena_Kc      = cenovy_udaj,
        kurz_pouzity = NULL,
        kurz_datum   = NULL
    WHERE mena IS NULL OR mena = 'CZK';

    /* b) cizí měny — poslední kurz ke dni podání nebo dříve.
          Kurz za jednotku je kurz / mnozstvi; ČNB vyhlašuje
          některé měny za sto či tisíc jednotek. */
    WITH kurz AS (
        SELECT  v.id,
                k.kurz / k.mnozstvi AS kurz_za_jednotku,
                k.datum,
                ROW_NUMBER() OVER (PARTITION BY v.id
                                   ORDER BY k.datum DESC) AS poradi
        FROM dbo.Valuo_data   v
        JOIN dbo.CIS_kurzy_CNB k
          ON k.mena  = v.mena
         AND k.datum <= CAST(v.datum_podani AS date)
        WHERE v.mena IS NOT NULL AND v.mena <> 'CZK'
    )
    UPDATE v
    SET v.cena_Kc      = CAST(v.cenovy_udaj * q.kurz_za_jednotku AS decimal(18,2)),
        v.kurz_pouzity = CAST(q.kurz_za_jednotku AS decimal(12,4)),
        v.kurz_datum   = q.datum
    FROM dbo.Valuo_data v
    JOIN kurz q ON q.id = v.id AND q.poradi = 1;

    /* c) měna bez kurzu — cena v Kč zůstává nevyplněná */
    UPDATE dbo.Valuo_data
    SET cena_Kc      = NULL,
        kurz_pouzity = NULL,
        kurz_datum   = NULL
    WHERE mena IS NOT NULL AND mena <> 'CZK'
      AND NOT EXISTS (SELECT 1 FROM dbo.CIS_kurzy_CNB k
                      WHERE k.mena  = dbo.Valuo_data.mena
                        AND k.datum <= CAST(dbo.Valuo_data.datum_podani AS date));
END;
GO

-- ----------------------------------------------------------------
-- SQL_STORED_PROCEDURE: dbo.sp_prepocet_prahu   (změněno 2026-10-23 19:59:07)
-- ----------------------------------------------------------------
CREATE   PROCEDURE dbo.sp_prepocet_prahu
AS
BEGIN
    SET NOCOUNT ON;

    /* ========================================================================
       Meze spočítané z dat. Od kroku 28b i podle pásma stáří a pro
       metriku M3 (Kč/m3).

       PAMĚŤ (krok 29b). PERCENTILE_CONT je okenní funkce a drží celý
       oddíl v paměti. Po zavedení pásem a metriky M3 se vstupní sada
       zdvojnásobila a u krajské úrovně má oddíl pražských bytů přes
       sedmnáct tisíc řádků — procedura pak spadla na Msg 701
       (insufficient system memory). Proto se počítá v cyklu po
       klasifikacích: výsledek je BITOVĚ STEJNÝ, jen špička paměti
       je zhruba čtvrtinová.

       Nepoužívej APPROX_PERCENTILE_CONT — je levnější, ale přibližná,
       a mediány z této tabulky slouží i jako kontrolní čísla.
       ======================================================================== */

    DECLARE @mez_default decimal(14,0) =
        (SELECT mez_Kc FROM dbo.CIS_mez_podilu WHERE kraj = N'*');

    IF OBJECT_ID('tempdb..#d0') IS NOT NULL DROP TABLE #d0;
    IF OBJECT_ID('tempdb..#d')  IS NOT NULL DROP TABLE #d;
    IF OBJECT_ID('tempdb..#k')  IS NOT NULL DROP TABLE #k;

    SELECT  q.kod_ku, c.ku_nazev,
            COALESCE(c.okres_nazev, c.kraj_nazev) AS okres,
            c.kraj_nazev, q.klasifikace,
            CASE WHEN q.metrika = 'JC' THEN 'JC' ELSE 'CENA' END AS metrika_zakl,
            CASE WHEN q.klasifikace = 'JC_PARCELY'
                  AND f.skupina IS NOT NULL
                  AND c.kraj_nazev = N'Hlavní město Praha'
                 THEN N'FVU:' + f.skupina + N'|' + v.pasmo
                 ELSE N'DRUH:' + ISNULL(q.druh, '?') END AS klic,
            CASE WHEN q.klasifikace = 'JC_PARCELY'
                  AND f.skupina IS NOT NULL
                  AND c.kraj_nazev = N'Hlavní město Praha'
                 THEN 1 ELSE 0 END AS jen_kraj,
            t.k_faktor, t.min_bodu_prah, t.max_nasobek,
            CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                 ELSE q.cena_Kc END AS hodnota_zakl,
            CASE WHEN q.klasifikace = 'CELEK_BUDOVA'
                  AND ru.ruian_zdroj = N'budova'
                  AND ru.ruian_obestaveny_prostor > 0
                 THEN q.cena_Kc / ru.ruian_obestaveny_prostor END AS hodnota_m3,
            CASE WHEN q.klasifikace IN ('JC_JEDNOTKA','CELEK_BUDOVA')
                 THEN ru.ruian_pasmo END AS pasmo_vkladu
    INTO #d0
    FROM dbo.v_Valuo_vzorek_q q
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod      = q.kod_ku
    JOIN dbo.CIS_prahy_ceny        t ON t.klasifikace = q.klasifikace
    LEFT JOIN dbo.CIS_FVU_skupiny  f ON f.fvu_kod     = q.fvu_kod
    LEFT JOIN dbo.CIS_velikost_pozemku v
           ON q.plocha_parcel_m2 >= v.od_m2 AND q.plocha_parcel_m2 < v.do_m2
    LEFT JOIN dbo.CIS_mez_podilu   mz ON mz.kraj      = c.kraj_nazev
    LEFT JOIN dbo.RUIAN_vzorek     ru ON ru.cislo_vkladu = q.cislo_vkladu
    WHERE ISNULL(q.mena, 'CZK') = 'CZK'
      AND q.typ_prevodu = 'KUPNI_SMLOUVA'
      AND q.hromadny_prevod = 0
      AND ISNULL(q.prodeju_tehoz_objektu, 0) < 5
      AND q.rok >= YEAR(GETDATE()) - 5
      AND (CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                ELSE q.cena_Kc END) > 0
      AND (q.klasifikace <> 'JC_PARCELY'
           OR q.cena_Kc >= ISNULL(mz.mez_Kc, @mez_default));

    SELECT  d.kod_ku, d.ku_nazev, d.okres, d.kraj_nazev, d.klasifikace,
            d.klic, d.jen_kraj, d.k_faktor, d.min_bodu_prah, d.max_nasobek,
            m.metrika, pz.pasmo, LOG(m.hodnota) AS lg
    INTO #d
    FROM #d0 d
    CROSS APPLY (VALUES (d.metrika_zakl, d.hodnota_zakl),
                        ('M3',           d.hodnota_m3)) m(metrika, hodnota)
    CROSS APPLY (VALUES (CAST('' AS varchar(20))),
                        (CAST(d.pasmo_vkladu AS varchar(20)))) pz(pasmo)
    WHERE m.hodnota > 0 AND pz.pasmo IS NOT NULL;

    DROP TABLE #d0;
    CREATE INDEX IX_d ON #d (klasifikace, klic, metrika, pasmo, kod_ku);

    DELETE FROM dbo.Valuo_prahy;

    /* ---- cyklus po klasifikacích: drží špičku paměti nízko ---- */
    SELECT DISTINCT klasifikace INTO #k FROM #d;
    DECLARE @kl varchar(15);

    WHILE EXISTS (SELECT 1 FROM #k)
    BEGIN
        SELECT TOP 1 @kl = klasifikace FROM #k;

        INSERT INTO dbo.Valuo_prahy
            (klasifikace, klic, metrika, pasmo, uroven, uzemi, n, median, p75,
             sigma, prah_dolni, prah_horni, datum_vypoctu)
        SELECT DISTINCT klasifikace, klic, metrika, pasmo, N'k.ú.', ku_nazev, n,
               CAST(EXP(p50) AS decimal(18,2)), CAST(EXP(p75) AS decimal(18,2)),
               CAST(sig AS decimal(8,4)),
               CAST(GREATEST(EXP(p50 - k_faktor*sig), EXP(p50)/max_nasobek) AS decimal(18,2)),
               CAST(LEAST   (EXP(p50 + k_faktor*sig), EXP(p50)*max_nasobek) AS decimal(18,2)),
               GETDATE()
        FROM (
            SELECT DISTINCT klasifikace, klic, metrika, pasmo, ku_nazev, k_faktor,
                   max_nasobek,
                   COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kod_ku) AS n,
                   p50, p75, (p75 - p50)/0.6745 AS sig, min_bodu_prah
            FROM (
                SELECT klasifikace, klic, metrika, pasmo, ku_nazev, kod_ku,
                       k_faktor, min_bodu_prah, max_nasobek,
                       PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kod_ku) AS p50,
                       PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kod_ku) AS p75
                FROM #d WHERE jen_kraj = 0 AND klasifikace = @kl
            ) a
        ) b
        WHERE n >= min_bodu_prah AND p75 > p50;

        INSERT INTO dbo.Valuo_prahy
            (klasifikace, klic, metrika, pasmo, uroven, uzemi, n, median, p75,
             sigma, prah_dolni, prah_horni, datum_vypoctu)
        SELECT DISTINCT klasifikace, klic, metrika, pasmo, N'okres', okres, n,
               CAST(EXP(p50) AS decimal(18,2)), CAST(EXP(p75) AS decimal(18,2)),
               CAST(sig AS decimal(8,4)),
               CAST(GREATEST(EXP(p50 - k_faktor*sig), EXP(p50)/max_nasobek) AS decimal(18,2)),
               CAST(LEAST   (EXP(p50 + k_faktor*sig), EXP(p50)*max_nasobek) AS decimal(18,2)),
               GETDATE()
        FROM (
            SELECT DISTINCT klasifikace, klic, metrika, pasmo, okres, k_faktor,
                   max_nasobek,
                   COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika, pasmo, okres) AS n,
                   p50, p75, (p75 - p50)/0.6745 AS sig, min_bodu_prah
            FROM (
                SELECT klasifikace, klic, metrika, pasmo, okres, k_faktor,
                       min_bodu_prah, max_nasobek,
                       PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, okres) AS p50,
                       PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, okres) AS p75
                FROM #d WHERE jen_kraj = 0 AND klasifikace = @kl
            ) a
        ) b
        WHERE n >= min_bodu_prah AND p75 > p50;

        INSERT INTO dbo.Valuo_prahy
            (klasifikace, klic, metrika, pasmo, uroven, uzemi, n, median, p75,
             sigma, prah_dolni, prah_horni, datum_vypoctu)
        SELECT DISTINCT klasifikace, klic, metrika, pasmo, N'kraj', kraj_nazev, n,
               CAST(EXP(p50) AS decimal(18,2)), CAST(EXP(p75) AS decimal(18,2)),
               CAST(sig AS decimal(8,4)),
               CAST(GREATEST(EXP(p50 - k_faktor*sig), EXP(p50)/max_nasobek) AS decimal(18,2)),
               CAST(LEAST   (EXP(p50 + k_faktor*sig), EXP(p50)*max_nasobek) AS decimal(18,2)),
               GETDATE()
        FROM (
            SELECT DISTINCT klasifikace, klic, metrika, pasmo, kraj_nazev, k_faktor,
                   max_nasobek,
                   COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kraj_nazev) AS n,
                   p50, p75, (p75 - p50)/0.6745 AS sig, min_bodu_prah
            FROM (
                SELECT klasifikace, klic, metrika, pasmo, kraj_nazev, k_faktor,
                       min_bodu_prah, max_nasobek,
                       PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kraj_nazev) AS p50,
                       PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kraj_nazev) AS p75
                FROM #d WHERE klasifikace = @kl
            ) a
        ) b
        WHERE n >= min_bodu_prah AND p75 > p50;

        DELETE FROM #k WHERE klasifikace = @kl;
    END

    DROP TABLE #d;
    DROP TABLE #k;
END;
GO

-- ----------------------------------------------------------------
-- SQL_STORED_PROCEDURE: dbo.sp_prepocet_ruian_vzorku   (změněno 2026-10-23 18:34:28)
-- ----------------------------------------------------------------
CREATE   PROCEDURE dbo.sp_prepocet_ruian_vzorku
AS
BEGIN
    SET NOCOUNT ON;
    /* DELETE, ne TRUNCATE — TRUNCATE potřebuje výhradní zámek tabulky
       a v krátkém spojení kvůli tomu celá procedura padá na timeout. */
    DELETE FROM dbo.RUIAN_vzorek;

    DECLARE @pp_min decimal(10,4) = (SELECT hodnota FROM dbo.CIS_RUIAN_parametry WHERE parametr='pomer_pp_op_min');
    DECLARE @pp_max decimal(10,4) = (SELECT hodnota FROM dbo.CIS_RUIAN_parametry WHERE parametr='pomer_pp_op_max');

    ;WITH vaz AS (
        SELECT v.cislo_vkladu, r.kod_so,
               MAX(CASE WHEN v.nemovitost='budova' THEN 1 ELSE 0 END) AS je_budova,
               MAX(CASE WHEN v.nemovitost='jednotka' THEN 1 ELSE 0 END) AS je_jednotka
        FROM dbo.Valuo_data v
        JOIN dbo.KN_parcel_data p ON p.id_valuo = v.id
        JOIN dbo.RUIAN_stavebni_objekty r ON r.gml_id = p.gml_id
        WHERE v.nemovitost IN ('budova','jednotka')
        GROUP BY v.cislo_vkladu, r.kod_so
    ),
    a AS (
        SELECT u.cislo_vkladu, COUNT(*) AS objektu,
               MAX(u.je_budova) AS ma_budovu, MAX(u.je_jednotka) AS ma_jednotku,
               MIN(YEAR(r.dokonceni)) AS rok_od, MAX(YEAR(r.dokonceni)) AS rok_do,
               MIN(CASE WHEN r.dokonceni IS NULL THEN NULL
                        WHEN (MONTH(r.dokonceni)=12 AND DAY(r.dokonceni)=31)
                          OR DAY(r.dokonceni)=1 THEN 0 ELSE 1 END) AS rok_presny,
               SUM(r.zastavena_plocha) AS zp, SUM(r.podlahova_plocha) AS pp,
               SUM(r.obestaveny_prostor) AS op, SUM(r.pocet_bytu) AS bytu,
               MAX(r.pocet_podlazi) AS podlazi, MIN(r.pomer_pp_op) AS pomer,
               MIN(r.druh_konstrukce_kod) AS kon, MIN(r.zpusob_vytapeni_kod) AS vyt,
               MIN(r.vybaveni_vytahem_kod) AS vth, MIN(r.pripojeni_vodovod_kod) AS vod,
               MIN(r.pripojeni_kanalizace_kod) AS kan, MIN(r.pripojeni_plyn_kod) AS plyn,
               MAX(r.soubor_datum) AS stav_k
        FROM vaz u JOIN dbo.RUIAN_stavebni_objekty r ON r.kod_so = u.kod_so
        GROUP BY u.cislo_vkladu
    )
    INSERT INTO dbo.RUIAN_vzorek (cislo_vkladu, ruian_objektu, ruian_zdroj, ruian_stav_k,
        ruian_rok, ruian_rok_nejnovejsi, ruian_rok_presny, ruian_pasmo, ruian_stari_let,
        ruian_zastavena_plocha, ruian_podlahova_plocha, ruian_obestaveny_prostor,
        ruian_pocet_podlazi, ruian_pocet_bytu, ruian_pomer_pp_op, ruian_plocha_podezrela,
        ruian_jedn_cena_Kc_m3, ruian_jedn_cena_Kc_m2, ruian_druh_konstrukce,
        ruian_vytapeni, ruian_vytah, pripojeni_vodovod_kod, pripojeni_kanalizace_kod,
        pripojeni_plyn_kod, prepocteno)
    SELECT a.cislo_vkladu, a.objektu,
           CASE WHEN a.ma_budovu=1 AND a.ma_jednotku=1 THEN N'obojí'
                WHEN a.ma_budovu=1 THEN N'budova' ELSE N'jednotka' END,
           a.stav_k, a.rok_od, CASE WHEN a.rok_do<>a.rok_od THEN a.rok_do END,
           CAST(a.rok_presny AS bit), s.pasmo,
           CASE WHEN a.rok_od IS NOT NULL THEN YEAR(GETDATE())-a.rok_od END,
           a.zp, a.pp, a.op, a.podlazi, a.bytu, a.pomer,
           CAST(CASE WHEN a.pomer IS NULL THEN NULL
                     WHEN a.pomer < @pp_min OR a.pomer > @pp_max THEN 1 ELSE 0 END AS bit),
           CASE WHEN a.ma_budovu=1 AND a.op>0 THEN CAST(c.cena_Kc/a.op AS decimal(18,2)) END,
           CASE WHEN a.ma_budovu=1 AND a.pp>0 THEN CAST(c.cena_Kc/a.pp AS decimal(18,2)) END,
           ck.nazev, cv.nazev, cx.nazev, a.vod, a.kan, a.plyn, SYSDATETIME()
    FROM a
    LEFT JOIN (SELECT cislo_vkladu, MAX(cena_Kc) AS cena_Kc FROM dbo.Valuo_data GROUP BY cislo_vkladu) c
           ON c.cislo_vkladu = a.cislo_vkladu
    LEFT JOIN dbo.CIS_stari_stavby s ON a.rok_od BETWEEN s.rok_od AND s.rok_do
    LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik='DruhKonstrukce'  AND ck.kod=a.kon
    LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik='ZpusobVytapeni'  AND cv.kod=a.vyt
    LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik='VybaveniVytahem' AND cx.kod=a.vth;
END;
GO

-- ----------------------------------------------------------------
-- SQL_STORED_PROCEDURE: dbo.sp_prepocet_typu_prevodu   (změněno 2026-10-22 21:23:31)
-- ----------------------------------------------------------------
CREATE   PROCEDURE dbo.sp_prepocet_typu_prevodu
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Valuo_data
    SET typ_prevodu =
        CASE
            WHEN CAST(listina AS varchar(500)) LIKE '%dražb%'
              OR CAST(listina AS varchar(500)) LIKE '%příklep%'
              OR CAST(listina AS varchar(500)) LIKE '%exekutor%'
                 THEN 'DRAZBA'
            WHEN CAST(listina AS varchar(500)) LIKE '%311/2013%'
                 THEN 'PREVOD_Z_DRUZSTVA'
            WHEN CAST(listina AS varchar(500)) LIKE '%směnná%'
                 THEN 'SMENA'
            WHEN CAST(listina AS varchar(500)) LIKE '%darovací%'
                 THEN 'DAROVANI'
            WHEN CAST(listina AS varchar(500)) LIKE '%vklad do základního kapitálu%'
              OR CAST(listina AS varchar(500)) LIKE '%nepeněžit%'
                 THEN 'VKLAD_DO_KAPITALU'
            WHEN CAST(listina AS varchar(500)) LIKE '%dědic%'
              OR CAST(listina AS varchar(500)) LIKE '%pozůstalost%'
                 THEN 'DEDICTVI'
            ELSE 'KUPNI_SMLOUVA'
        END;
END;
GO
