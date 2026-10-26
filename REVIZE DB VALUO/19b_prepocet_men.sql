/* ============================================================
   VALUO — KROK 19b: PŘEPOČET CIZÍCH MĚN NA KORUNY

   Spouštěj po 19_kurzy_CNB.py. Celé najednou.
   Nezávisí na krocích 17 a 18 — pracuje nad Valuo_data.

   ------------------------------------------------------------
   CO SE MĚNÍ
   ------------------------------------------------------------
   Valuo_data dostane tři sloupce: cena_Kc, kurz_pouzity
   a kurz_datum. U korunových vkladů je cena_Kc rovna
   cenovému údaji a kurz je NULL.

   Kurz se ukládá, nedopočítává se za běhu. Použitý kurz
   a den jeho vyhlášení musí být v posudku doložitelný —
   nestačí, aby ho uměl dopočítat pohled.

   ------------------------------------------------------------
   KE KTERÉMU DNI
   ------------------------------------------------------------
   K datu podání návrhu na vklad. Cena byla sjednána v kupní
   smlouvě, která je starší než vklad, a datum podání je k ní
   nejblíž — mezi podáním a zplatněním je u těchto vkladů
   průměrně 27 dní. Datum smlouvy data neobsahují.

   ČNB kurz o víkendech a svátcích nevyhlašuje, proto se bere
   poslední vyhlášený kurz ke dni podání nebo před ním.

   ------------------------------------------------------------
   ROZSAH
   ------------------------------------------------------------
       EUR  228 vkladů   2016–2026
       USD   12          2021–2025
       CHF    3          2020–2025
       GBP    2          2025
       AUD    1          2021
       ANG    1          2025   — ČNB nekotuje

   Nizozemskoantilský gulden v kurzovním lístku ČNB není. Ten
   jeden vklad zůstane bez přepočtu a v pohledu dostane
   hodnocení „cizí měna bez kurzu". Kurz se neodhaduje.

   ------------------------------------------------------------
   PROČ PŘEPOČTENÉ VKLADY NEVSTUPUJÍ DO CENOVÝCH HLADIN
   ------------------------------------------------------------
   Do vzorku vstupují, do mediánu ne. Hladina slouží jako
   etalon pro hodnocení ostatních záznamů a má stát na
   nejspolehlivějších datech. 236 vkladů ze 48 863 je 0,5 %,
   takže medián nezpřesní — zařazení by do etalonu jen vneslo
   kurzové riziko. Hodnoceny jsou pak stejnými prahy jako
   korunové.
   ============================================================ */

USE VALUO;
GO

/* ---------- 19b.1 KONTROLA PODKLADU ------------------------
   Než se cokoli změní, musí být kurzy stažené.              */

IF OBJECT_ID('dbo.CIS_kurzy_CNB') IS NULL
BEGIN
    RAISERROR('Tabulka CIS_kurzy_CNB neexistuje. Spusť nejprve 19_kurzy_CNB.py.', 16, 1);
    RETURN;
END
GO

SELECT mena, COUNT(*) AS dnu, MIN(datum) AS od, MAX(datum) AS do
FROM dbo.CIS_kurzy_CNB
GROUP BY mena ORDER BY mena;
GO


/* ---------- 19b.2 NOVÉ SLOUPCE ----------------------------- */

IF COL_LENGTH('dbo.Valuo_data', 'cena_Kc') IS NULL
    ALTER TABLE dbo.Valuo_data ADD cena_Kc decimal(18,2) NULL;
GO
IF COL_LENGTH('dbo.Valuo_data', 'kurz_pouzity') IS NULL
    ALTER TABLE dbo.Valuo_data ADD kurz_pouzity decimal(12,4) NULL;
GO
IF COL_LENGTH('dbo.Valuo_data', 'kurz_datum') IS NULL
    ALTER TABLE dbo.Valuo_data ADD kurz_datum date NULL;
GO


/* ============================================================
   19b.3  PROCEDURA PŘEPOČTU
   Spouštět po každém importu nových dat z Valua.
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.sp_prepocet_men
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

EXEC dbo.sp_prepocet_men;
GO


/* ---------- 19b.4 KONTROLA PŘEPOČTU ------------------------ */

SELECT  ISNULL(mena, 'CZK')                       AS mena,
        COUNT(DISTINCT cislo_vkladu)              AS vkladu,
        SUM(CASE WHEN cena_Kc IS NULL THEN 1 ELSE 0 END) AS radku_bez_ceny,
        CAST(MIN(kurz_pouzity) AS decimal(10,3))  AS kurz_min,
        CAST(MAX(kurz_pouzity) AS decimal(10,3))  AS kurz_max
FROM dbo.Valuo_data
GROUP BY mena ORDER BY vkladu DESC;
GO

/* Deset největších přepočtů — ověř, že ceny vycházejí rozumně */
SELECT TOP 10
        cislo_vkladu, mena, cenovy_udaj, kurz_pouzity, kurz_datum,
        CAST(datum_podani AS date)                AS datum_podani,
        cena_Kc,
        nemovitost, typ, plocha
FROM dbo.Valuo_data
WHERE mena IS NOT NULL AND mena <> 'CZK' AND cena_Kc IS NOT NULL
ORDER BY cena_Kc DESC;
GO

/* Kolik dní dělí vyhlášení kurzu od podání — mimo nulu jen
   víkendy a svátky, takže víc než 4 dny je podezřelé */
SELECT  DATEDIFF(day, kurz_datum, CAST(datum_podani AS date)) AS dnu_od_kurzu,
        COUNT(*) AS radku
FROM dbo.Valuo_data
WHERE kurz_pouzity IS NOT NULL
GROUP BY DATEDIFF(day, kurz_datum, CAST(datum_podani AS date))
ORDER BY dnu_od_kurzu;
GO


/* ============================================================
   19b.5  ZAPOJENÍ DO POHLEDŮ
   ------------------------------------------------------------
   Mění se tři věci:
     - základní pohled bere cena_Kc místo cenovy_udaj
       a jednotkovou cenu počítá i u přepočtených vkladů
     - cenové hladiny přepočtené vklady dál nezahrnují
     - pracovní pohled nese kurz a jeho datum, aby byl
       přepočet doložitelný, a hodnotí přepočtené vklady
       běžnými prahy
   ============================================================ */

CREATE OR ALTER VIEW dbo.v_Valuo_vzorek
AS
WITH vklad AS (
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

            MIN(CASE WHEN v.vklad_klasifikace = 'JC_JEDNOTKA'
                      AND v.nemovitost = N'jednotka' THEN v.typ
                     WHEN v.vklad_klasifikace = 'CELEK_BUDOVA'
                      AND v.nemovitost = N'budova'   THEN v.typ
                     WHEN v.vklad_klasifikace = 'JC_PARCELY'
                      AND v.nemovitost = N'parcela'  THEN v.typ
                END)                       AS druh,
            COUNT(DISTINCT v.typ)          AS ruznych_druhu
    FROM dbo.Valuo_data v
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

        k.plocha_parcel                         AS plocha_parcel_m2,
        k.plocha_jednotky                       AS plocha_jednotky_m2,
        k.plocha_budovy                         AS plocha_budovy_m2,

        k.cena                                  AS cena_Kc,
        k.mena,
        k.cena_v_mene,
        k.kurz_pouzity,
        k.kurz_datum,

        /* jednotková cena se počítá z ceny v korunách, tedy
           i u přepočtených vkladů; chybí-li cena_Kc (měna bez
           kurzu), vyjde NULL sama */
        CASE k.klasifikace
            WHEN 'JC_PARCELY'  THEN CAST(k.cena / NULLIF(k.plocha_parcel, 0)
                                         AS decimal(14,2))
            WHEN 'JC_JEDNOTKA' THEN CAST(k.cena / NULLIF(k.plocha_jednotky, 0)
                                         AS decimal(14,2))
            ELSE NULL
        END                                     AS jedn_cena_Kc_m2,

        p.geo_bod,
        p.LAT,
        p.LON
FROM vklad k
JOIN dbo.Valuo_data p            ON p.id     = k.id_prvni
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku;
GO


/* Cenové hladiny — podmínka mena = 'CZK' zůstává záměrně.
   Viz zdůvodnění v hlavičce skriptu.                        */

CREATE OR ALTER VIEW dbo.v_cenove_hladiny
AS
WITH zaklad AS (
    SELECT  q.kod_ku,
            c.okres_nazev,
            c.kraj_nazev,
            q.klasifikace,
            CASE WHEN q.klasifikace = 'JC_PARCELY'
                  AND up.fvu_kod IS NOT NULL THEN N'FVU:'  + up.fvu_kod
                 ELSE                              N'DRUH:' + ISNULL(q.druh, N'?')
            END                 AS klic,
            q.jedn_cena_Kc_m2   AS jc
    FROM dbo.v_Valuo_vzorek q
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod      = q.kod_ku
    JOIN dbo.CIS_prahy_ceny        t ON t.klasifikace = q.klasifikace
    LEFT JOIN dbo.v_vklad_UP      up ON up.cislo_vkladu = q.cislo_vkladu
    WHERE q.jedn_cena_Kc_m2 > 0
      AND q.cena_Kc >= t.cena_min
      AND ISNULL(q.mena, 'CZK') = 'CZK'
      AND q.typ_prevodu = 'KUPNI_SMLOUVA'
      AND q.rok >= YEAR(GETDATE()) - 5
),
u_ku AS (
    SELECT DISTINCT kod_ku, klasifikace, klic,
           COUNT(*) OVER (PARTITION BY kod_ku, klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY kod_ku, klasifikace, klic) AS med
    FROM zaklad
),
u_okres AS (
    SELECT DISTINCT COALESCE(okres_nazev, kraj_nazev) AS okres,
           klasifikace, klic,
           COUNT(*) OVER (PARTITION BY COALESCE(okres_nazev, kraj_nazev),
                                       klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY COALESCE(okres_nazev, kraj_nazev),
                                  klasifikace, klic) AS med
    FROM zaklad
),
u_kraj AS (
    SELECT DISTINCT kraj_nazev, klasifikace, klic,
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
                   AND a.klic = z.klic AND a.n >= 20
LEFT JOIN u_okres b ON b.okres = COALESCE(z.okres_nazev, z.kraj_nazev)
                   AND b.klasifikace = z.klasifikace
                   AND b.klic = z.klic AND b.n >= 20
LEFT JOIN u_kraj  c ON c.kraj_nazev = z.kraj_nazev
                   AND c.klasifikace = z.klasifikace
                   AND c.klic = z.klic AND c.n >= 20;
GO


CREATE OR ALTER VIEW dbo.v_Valuo_vzorek_q
AS
WITH hlavni AS (
    SELECT  v.cislo_vkladu,
            MIN(v.nemovitost) AS nemovitost,
            MIN(v.typ)        AS typ,
            MIN(v.typ_plochy) AS typ_plochy,
            MIN(TRY_CONVERT(decimal(18,2),
                SUBSTRING(v.popis,
                          CHARINDEX(N'domu a pozemku ', v.popis) + 15,
                          CHARINDEX(N'/', v.popis + N'/',
                                    CHARINDEX(N'domu a pozemku ', v.popis))
                          - CHARINDEX(N'domu a pozemku ', v.popis) - 15)))
                              AS citatel_podilu
    FROM dbo.Valuo_data v
    WHERE (v.vklad_klasifikace = 'JC_JEDNOTKA'  AND v.nemovitost = N'jednotka')
       OR (v.vklad_klasifikace = 'CELEK_BUDOVA' AND v.nemovitost = N'budova')
       OR (v.vklad_klasifikace = 'JC_PARCELY'   AND v.nemovitost = N'parcela')
    GROUP BY v.cislo_vkladu
)
SELECT  v.cislo_vkladu,
        v.datum_zplatneni,
        v.rok,
        v.mesic,
        v.kod_ku,
        v.kat_uzemi,
        v.obec,
        v.okres,
        v.kraj,
        v.klasifikace,
        v.duvod,
        v.typ_prevodu,
        v.druh,
        v.ruznych_druhu,
        v.nemovitosti_ve_vkladu,
        v.duplicitnich_radku,
        v.plocha_parcel_m2,
        v.plocha_jednotky_m2,
        v.plocha_budovy_m2,
        v.cena_Kc,
        v.mena,
        v.cena_v_mene,
        v.kurz_pouzity,
        v.kurz_datum,

        ISNULL(m.metrika,
               CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                    ELSE 'CELEK' END)                AS metrika,

        CASE WHEN ISNULL(m.metrika,
                 CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                      ELSE 'CELEK' END) = 'JC'
             THEN v.jedn_cena_Kc_m2 END              AS jedn_cena_Kc_m2,

        up.fvu_kod,
        up.mira_vyuziti,

        h.median                                    AS median_Kc_m2,
        h.bodu                                      AS bodu_v_hladine,
        h.uroven                                    AS uroven_hladiny,
        CASE WHEN ISNULL(m.metrika,
                 CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                      ELSE 'CELEK' END) = 'JC'
             THEN CAST(v.jedn_cena_Kc_m2 / NULLIF(h.median, 0)
                       AS decimal(10,3)) END        AS pomer_k_medianu,

        CASE
            WHEN ISNULL(v.mena, 'CZK') <> 'CZK'
             AND v.kurz_pouzity IS NULL              THEN N'cizí měna bez kurzu'
            WHEN v.typ_prevodu <> 'KUPNI_SMLOUVA'    THEN N'nestandardní převod'
            WHEN v.cena_Kc < t.cena_min              THEN N'symbolická cena'
            WHEN ISNULL(m.metrika,
                 CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                      ELSE 'CELEK' END) <> 'JC'      THEN N'porovnává se cena'
            WHEN v.jedn_cena_Kc_m2 IS NULL           THEN N'bez JC'
            WHEN h.median IS NULL                    THEN N'bez srovnání'
            WHEN v.jedn_cena_Kc_m2 / h.median < 0.1  THEN N'řádově nízká'
            WHEN v.jedn_cena_Kc_m2 / h.median > 10.0 THEN N'řádově vysoká'
            ELSE                                          N'bez výhrad'
        END                                         AS hodnoceni_ceny,

        /* přepočtený vklad se hodnotí běžnými prahy, ale musí
           být poznat — v posudku se k němu připojuje kurz */
        CASE WHEN ISNULL(v.mena, 'CZK') = 'CZK' THEN N'—'
             WHEN v.kurz_pouzity IS NULL        THEN N'bez kurzu'
             ELSE v.mena + N' kurzem ČNB k '
                  + CONVERT(varchar(10), v.kurz_datum, 104)
        END                                         AS prepocet_meny,

        CASE
            WHEN r.nemovitost IS NULL                THEN N'bez pravidla'
            WHEN r.plocha_max = 0                    THEN N'nevhodný zdroj plochy'
            WHEN COALESCE(v.plocha_jednotky_m2,
                          v.plocha_budovy_m2,
                          v.plocha_parcel_m2)
                 BETWEEN r.plocha_min AND r.plocha_max
                                                     THEN N'v rozsahu'
            ELSE                                          N'mimo rozsah'
        END                                         AS hodnoceni_plochy,

        CASE
            WHEN v.klasifikace <> 'JC_JEDNOTKA'      THEN N'—'
            WHEN p.citatel_podilu IS NULL            THEN N'nenačteno'
            WHEN p.citatel_podilu < 100              THEN N'malý čitatel - podezřelý'
            ELSE                                          N'plošný zlomek'
        END                                         AS hodnoceni_podilu,

        CASE WHEN v.duplicitnich_radku > 0 THEN N'ano' ELSE N'ne' END
                                                    AS obsahuje_duplicity,

        v.geo_bod,
        v.LAT,
        v.LON
FROM dbo.v_Valuo_vzorek v
LEFT JOIN hlavni p ON p.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_metrika_ceny m
       ON m.nemovitost = p.nemovitost AND m.typ = p.typ
LEFT JOIN dbo.CIS_prahy_ceny t ON t.klasifikace   = v.klasifikace
LEFT JOIN dbo.v_vklad_UP    up ON up.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.v_cenove_hladiny h
       ON h.kod_ku      = v.kod_ku
      AND h.klasifikace = v.klasifikace
      AND h.klic        = CASE WHEN v.klasifikace = 'JC_PARCELY'
                                AND up.fvu_kod IS NOT NULL
                               THEN N'FVU:'  + up.fvu_kod
                               ELSE N'DRUH:' + ISNULL(v.druh, N'?') END
LEFT JOIN dbo.CIS_rozsahy_ploch r
       ON r.nemovitost = p.nemovitost
      AND r.typ        = p.typ
      AND r.typ_plochy = p.typ_plochy;
GO


/* ---------- 19b.6 KONTROLA VE VZORKU -----------------------
   Pozor: přepočtené vklady se ve vzorku objeví jen tehdy,
   mají-li geo_zdroj = 'KN_refPoint'. Část jich na to čeká
   až po kroku 18.                                            */

SELECT  prepocet_meny, hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
WHERE prepocet_meny <> N'—'
GROUP BY prepocet_meny, hodnoceni_ceny
ORDER BY vkladu DESC;
GO

SELECT  COUNT(*) AS vkladu_v_cizi_mene_ve_vzorku
FROM dbo.v_Valuo_vzorek_q
WHERE ISNULL(mena, 'CZK') <> 'CZK';
GO

/* Srovnání jednotkových cen přepočtených vkladů s hladinou */
SELECT TOP 20
        cislo_vkladu, mena, cena_v_mene, kurz_pouzity, cena_Kc,
        kat_uzemi, druh, plocha_parcel_m2, plocha_jednotky_m2,
        jedn_cena_Kc_m2, median_Kc_m2, pomer_k_medianu, hodnoceni_ceny
FROM dbo.v_Valuo_vzorek_q
WHERE ISNULL(mena, 'CZK') <> 'CZK' AND jedn_cena_Kc_m2 IS NOT NULL
ORDER BY pomer_k_medianu DESC;
GO
