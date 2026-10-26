/* ============================================================
   VALUO — OPRAVA: DOPLNĚNÍ MĚNY DO POHLEDU v_Valuo_vzorek

   Pohled z kroku 5 neobsahoval sloupec mena, takže se na něj
   krok 7 nemohl odkázat.

   POŘADÍ SPUŠTĚNÍ:
       1) tento skript  (přepíše v_Valuo_vzorek)
       2) bloky 7.3 a 7.4 z 07_finalni_priznaky.sql
   ============================================================ */

USE VALUO;
GO

CREATE OR ALTER VIEW dbo.v_Valuo_vzorek
AS
WITH vklad AS (
    SELECT  v.cislo_vkladu,
            MIN(v.id)                      AS id_prvni,
            MIN(v.datum_zplatneni)         AS datum_zplatneni,
            MIN(v.rok)                     AS rok,
            MIN(v.mesic)                   AS mesic,
            MIN(v.kod_ku)                  AS kod_ku,
            MAX(v.cenovy_udaj)             AS cena,
            MIN(v.mena)                    AS mena,          -- DOPLNĚNO
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

        /* územní identifikace z číselníku ČÚZK */
        k.kod_ku,
        c.ku_nazev                              AS kat_uzemi,
        c.obec_nazev                            AS obec,
        COALESCE(c.okres_nazev, c.kraj_nazev)   AS okres,
        c.kraj_nazev                            AS kraj,

        /* co vklad obsahoval */
        k.klasifikace,
        k.duvod,
        k.druh,
        k.ruznych_druhu,
        k.nemovitosti                           AS nemovitosti_ve_vkladu,
        k.duplicit                              AS duplicitnich_radku,

        /* výměry */
        k.plocha_parcel                         AS plocha_parcel_m2,
        k.plocha_jednotky                       AS plocha_jednotky_m2,
        k.plocha_budovy                         AS plocha_budovy_m2,

        /* cena */
        k.cena                                  AS cena_Kc,
        k.mena,                                                 -- DOPLNĚNO
        CASE WHEN k.mena <> 'CZK' THEN NULL                     -- DOPLNĚNO
             ELSE
                CASE k.klasifikace
                    WHEN 'JC_PARCELY'  THEN CAST(k.cena / NULLIF(k.plocha_parcel, 0)
                                                 AS decimal(14,2))
                    WHEN 'JC_JEDNOTKA' THEN CAST(k.cena / NULLIF(k.plocha_jednotky, 0)
                                                 AS decimal(14,2))
                    ELSE NULL
                END
        END                                     AS jedn_cena_Kc_m2,

        /* poloha */
        p.geo_bod,
        p.LAT,
        p.LON
FROM vklad k
JOIN dbo.Valuo_data p            ON p.id     = k.id_prvni
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku;
GO


/* ---------- KONTROLA ---------------------------------------- */

SELECT  mena,
        COUNT(*) AS datovych_bodu,
        SUM(CASE WHEN jedn_cena_Kc_m2 IS NOT NULL THEN 1 ELSE 0 END) AS s_JC
FROM dbo.v_Valuo_vzorek
GROUP BY mena
ORDER BY datovych_bodu DESC;
GO
