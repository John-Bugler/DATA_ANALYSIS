/* ============================================================
   VALUO — OPRAVA 3d: ORIENTACE POLYGONŮ PARCEL

   Nahrazuje 03c_oprava_orientace.sql — ten vyžadoval ruční
   opakování jednoho bloku. Tahle verze má cyklus a dá se
   pustit celá najednou.

   ------------------------------------------------------------
   PROBLÉM
   ------------------------------------------------------------
   Reprojekce uložila všech 148 404 polygonů s obrácenou
   orientací ringu. Plocha vychází na 510 bilionů m2, což je
   povrch Země — typ geography takový polygon chápe jako
   "celý svět mimo tuto plochu".

   Příčina: skript vyhodnocoval směr obchůzky na souřadnicích
   v S-JTSK a teprve potom transformoval do WGS84. Osy obou
   systémů jsou orientované různě, takže se směr převodem
   obrátil. Orientace se musí posuzovat až po transformaci.

   Prostorový index, který vypsal Python na konci běhu,
   NESPOUŠTĚJ — je součástí tohoto skriptu, až na konci.
   ============================================================ */

USE VALUO;
GO

/* ---------- 3d.1 TEST NA VZORKU ----------------------------
   Nic nemění. Ověří, že otočení dá plochy srovnatelné
   s výměrou z katastru.                                      */

SELECT TOP 10
        id,
        parcel_number,
        CAST(areaValue_m2 AS decimal(12,1))                   AS katastr_m2,
        CAST(geo_plocha.ReorientObject().STArea()
             AS decimal(18,1))                                AS po_otoceni_m2
FROM dbo.KN_parcel_data
WHERE geo_plocha IS NOT NULL
  AND areaValue_m2 > 0
ORDER BY id;
GO


/* ---------- 3d.2 OTOČENÍ — CYKLUS --------------------------
   Běží, dokud zbývá co otáčet. Po dávkách po 20 000, aby
   transakce nerostly do nemožna. Průběh se vypisuje
   do záložky Messages.                                       */

SET NOCOUNT ON;

DECLARE @otoceno int = 1;
DECLARE @celkem  int = 0;
DECLARE @zprava  varchar(100);

WHILE @otoceno > 0
BEGIN
    UPDATE TOP (20000) dbo.KN_parcel_data
    SET geo_plocha = geo_plocha.ReorientObject()
    WHERE geo_plocha IS NOT NULL
      AND geo_plocha.STArea() > 1e10;

    SET @otoceno = @@ROWCOUNT;
    SET @celkem  = @celkem + @otoceno;

    SET @zprava = 'otoceno celkem: ' + CAST(@celkem AS varchar(20));
    RAISERROR(@zprava, 0, 1) WITH NOWAIT;
END

SET NOCOUNT OFF;
GO


/* ---------- 3d.3 KONTROLA ---------------------------------
   stale_obracenych musí být 0, plochy v rozumných řádech.    */

SELECT  COUNT(*)                                          AS parcel,
        CAST(MIN(geo_plocha.STArea()) AS decimal(18,1))   AS min_m2,
        CAST(AVG(geo_plocha.STArea()) AS decimal(18,1))   AS prumer_m2,
        CAST(MAX(geo_plocha.STArea()) AS decimal(18,1))   AS max_m2,
        SUM(CASE WHEN geo_plocha.STArea() > 1e10
                 THEN 1 ELSE 0 END)                       AS stale_obracenych
FROM dbo.KN_parcel_data
WHERE geo_plocha IS NOT NULL;
GO


/* ---------- 3d.4 POROVNÁNÍ S VÝMĚROU Z KATASTRU ------------
   Kontrola kvality reprojekce a zároveň vstup k otevřenému
   bodu s nesedícími výměrami.                                */

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


/* ---------- 3d.5 PROSTOROVÝ INDEX -------------------------- */

DROP INDEX IF EXISTS SIX_KN_geo_plocha ON dbo.KN_parcel_data;
GO

CREATE SPATIAL INDEX SIX_KN_geo_plocha
    ON dbo.KN_parcel_data (geo_plocha)
    USING GEOGRAPHY_AUTO_GRID
    WITH (CELLS_PER_OBJECT = 64);
GO

UPDATE STATISTICS dbo.KN_parcel_data WITH FULLSCAN;
GO
