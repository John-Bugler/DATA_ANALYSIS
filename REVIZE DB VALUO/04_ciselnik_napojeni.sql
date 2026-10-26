/* ============================================================
   VALUO — KROK 4b: NAPOJENÍ ČÍSELNÍKU A OVĚŘENÍ NÁZVŮ
   Spouštět po 04_import_ciselniku.py, po blocích.

   Číselník zůstává samostatnou tabulkou, názvy se do dat
   nekopírují. Důvod: při příští aktualizaci číselníku se
   změna projeví všude, bez přepisování dat.
   Pro pohodlí dotazů slouží pohled v_Valuo v bloku 4b.4.
   ============================================================ */

USE VALUO;
GO

/* ---------- 4b.1 ROZSAH CHYBNÝCH NÁZVŮ ---------------------
   Porovnání uloženého textu proti oficiálnímu názvu území.  */

SELECT  COUNT(*)                                           AS zaznamu_s_kodem,
        SUM(CASE WHEN v.kat_uzemi = c.ku_nazev
                 THEN 1 ELSE 0 END)                        AS nazev_souhlasi,
        SUM(CASE WHEN v.kat_uzemi <> c.ku_nazev
                 THEN 1 ELSE 0 END)                        AS nazev_CHYBNY,
        CAST(100.0 * SUM(CASE WHEN v.kat_uzemi <> c.ku_nazev
                              THEN 1 ELSE 0 END) / COUNT(*)
             AS decimal(5,2))                              AS podil_chybnych_pct
FROM dbo.Valuo_data v
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku;
GO


/* ---------- 4b.2 NEJČASTĚJŠÍ ZÁMĚNY ------------------------- */

SELECT TOP 25
        v.kat_uzemi      AS nazev_ulozeny,
        c.ku_nazev       AS nazev_spravny,
        c.ku_kod         AS kod_uzemi,
        COUNT(*)         AS zaznamu
FROM dbo.Valuo_data v
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku
WHERE v.kat_uzemi <> c.ku_nazev
GROUP BY v.kat_uzemi, c.ku_nazev, c.ku_kod
ORDER BY COUNT(*) DESC;
GO


/* ---------- 4b.3 OVĚŘENÍ OKRESU -----------------------------
   Sloupec okres ve Valuo_data pochází ze stejného zdroje
   jako kat_uzemi, takže bude mít stejný problém.
   Praha nemá okres, proto COALESCE na kraj.                  */

SELECT  COUNT(*)                                     AS zaznamu,
        SUM(CASE WHEN v.okres = COALESCE(c.okres_nazev, c.kraj_nazev)
                 THEN 1 ELSE 0 END)                  AS okres_souhlasi,
        SUM(CASE WHEN v.okres <> COALESCE(c.okres_nazev, c.kraj_nazev)
                 THEN 1 ELSE 0 END)                  AS okres_CHYBNY
FROM dbo.Valuo_data v
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku;
GO


/* ============================================================
   4b.4  POHLED PRO BĚŽNOU PRÁCI
   ------------------------------------------------------------
   Sjednocuje ověřené údaje na jednom místě. Od teď dotazuj
   tento pohled, ne Valuo_data přímo.

   Obsahuje jen záznamy se souřadnicí z katastru — tedy ty,
   které jsou použitelné pro porovnávací metodu.
   ============================================================ */

CREATE OR ALTER VIEW dbo.v_Valuo
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


/* ---------- 4b.5 KONTROLA POHLEDU --------------------------- */

SELECT COUNT(*) AS zaznamu_v_pohledu FROM dbo.v_Valuo;
GO

/* Ukázka: srovnávací vzorek v okruhu 1 km */

DECLARE @stred  geography = geography::Point(50.034433, 14.450230, 4326);
DECLARE @radius int = 1000;

SELECT  cislo_vkladu,
        datum_zplatneni,
        kat_uzemi,
        obec,
        okres,
        typ,
        vymera_m2,
        cena_Kc,
        jedn_cena_Kc_m2,
        CAST(geo_bod.STDistance(@stred) AS decimal(10,1)) AS vzdalenost_m
FROM dbo.v_Valuo
WHERE geo_bod.STDistance(@stred) <= @radius
  AND rok >= YEAR(GETDATE()) - 3
  AND vymera_m2 > 0
  AND cena_Kc > 0
ORDER BY vzdalenost_m;
GO


/* ---------- 4b.6 PŘEHLED ÚZEMÍ V DATECH --------------------- */

SELECT  okres,
        COUNT(DISTINCT kod_ku)  AS uzemi,
        COUNT(*)                AS zaznamu,
        MIN(rok)                AS od_roku,
        MAX(rok)                AS do_roku
FROM dbo.v_Valuo
GROUP BY okres
ORDER BY COUNT(*) DESC;
GO
