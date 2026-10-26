/* ============================================================
   VALUO — OPRAVA 3c: ORIENTACE POLYGONŮ PARCEL

   Reprojekce v 03b_kn_reprojekce.py uložila všech 148 404
   polygonů s obrácenou orientací ringu. Plocha proto vychází
   na 510 bilionů m2, což je povrch Země — typ geography takový
   polygon chápe jako "celý svět mimo tuto plochu".

   ------------------------------------------------------------
   PŘÍČINA
   ------------------------------------------------------------
   Skript vyhodnocoval směr obchůzky na souřadnicích v S-JTSK
   a teprve potom transformoval do WGS84. Osy obou systémů jsou
   orientované různě, takže se směr převodem obrátil.
   Orientace se musí posuzovat až po transformaci.

   ------------------------------------------------------------
   POSTUP
   ------------------------------------------------------------
   Otočení přímo v databázi je rychlejší než opakování celé
   reprojekce. Skript pracuje po dávkách, aby jedna vadná
   geometrie neshodila celou operaci.

   Spouštět po blocích.
   ============================================================ */

USE VALUO;
GO

/* ---------- 3c.1 TEST NA VZORKU ----------------------------
   Nic nemění. Ověří, že otočení dá smysluplné plochy
   srovnatelné s výměrou z katastru.                          */

SELECT TOP 10
        id,
        parcel_number,
        CAST(areaValue_m2 AS decimal(12,1))                   AS katastr_m2,
        CAST(geo_plocha.ReorientObject().STArea()
             AS decimal(18,1))                                AS po_otoceni_m2,
        CAST(ABS(geo_plocha.ReorientObject().STArea() - areaValue_m2)
             / NULLIF(areaValue_m2, 0) * 100
             AS decimal(8,2))                                 AS odchylka_pct
FROM dbo.KN_parcel_data
WHERE geo_plocha IS NOT NULL
  AND areaValue_m2 > 0
ORDER BY id;
GO

/* Očekávání: po_otoceni_m2 řádově odpovídá katastr_m2,
   odchylka v jednotkách procent. Pokud ano, pokračuj.        */


/* ---------- 3c.2 OTOČENÍ PO DÁVKÁCH ------------------------
   Opakovaně spouštěj tento blok, dokud nevypíše 0 řádků.
   Každý běh zpracuje 20 000 parcel.                          */

UPDATE TOP (20000) dbo.KN_parcel_data
SET geo_plocha = geo_plocha.ReorientObject()
WHERE geo_plocha IS NOT NULL
  AND geo_plocha.STArea() > 1e10;
GO


/* ---------- 3c.3 KONTROLA POSTUPU --------------------------
   Kolik ještě zbývá otočit.                                  */

SELECT COUNT(*) AS zbyva_otocit
FROM dbo.KN_parcel_data
WHERE geo_plocha IS NOT NULL
  AND geo_plocha.STArea() > 1e10;
GO


/* ---------- 3c.4 VÝSLEDNÁ KONTROLA -------------------------
   Spusť, až 3c.3 vypíše nulu.                                */

SELECT  COUNT(*)                                          AS parcel,
        CAST(MIN(geo_plocha.STArea()) AS decimal(18,1))   AS min_m2,
        CAST(AVG(geo_plocha.STArea()) AS decimal(18,1))   AS prumer_m2,
        CAST(MAX(geo_plocha.STArea()) AS decimal(18,1))   AS max_m2,
        SUM(CASE WHEN geo_plocha.STArea() > 1e10
                 THEN 1 ELSE 0 END)                       AS stale_obracenych
FROM dbo.KN_parcel_data
WHERE geo_plocha IS NOT NULL;
GO


/* ---------- 3c.5 POROVNÁNÍ S VÝMĚROU Z KATASTRU ------------
   Tohle je zároveň kontrola kvality reprojekce i vstup
   k otevřenému bodu s nesedícími výměrami.                   */

SELECT  CASE
            WHEN odchylka <  1 THEN N'a) do 1 %'
            WHEN odchylka <  5 THEN N'b) 1-5 %'
            WHEN odchylka < 20 THEN N'c) 5-20 %'
            ELSE                    N'd) nad 20 %'
        END                 AS pasmo,
        COUNT(*)            AS parcel
FROM (
    SELECT ABS(geo_plocha.STArea() - areaValue_m2)
           / NULLIF(areaValue_m2, 0) * 100 AS odchylka
    FROM dbo.KN_parcel_data
    WHERE geo_plocha IS NOT NULL
      AND areaValue_m2 > 0
      AND geo_plocha.STArea() <= 1e10
) x
GROUP BY CASE
            WHEN odchylka <  1 THEN N'a) do 1 %'
            WHEN odchylka <  5 THEN N'b) 1-5 %'
            WHEN odchylka < 20 THEN N'c) 5-20 %'
            ELSE                    N'd) nad 20 %'
         END
ORDER BY pasmo;
GO


/* ---------- 3c.6 PROSTOROVÝ INDEX --------------------------
   Až po otočení — index nad obrácenými polygony by byl
   k ničemu.                                                  */

CREATE SPATIAL INDEX SIX_KN_geo_plocha
    ON dbo.KN_parcel_data (geo_plocha)
    USING GEOGRAPHY_AUTO_GRID
    WITH (CELLS_PER_OBJECT = 64);
GO

UPDATE STATISTICS dbo.KN_parcel_data WITH FULLSCAN;
GO
