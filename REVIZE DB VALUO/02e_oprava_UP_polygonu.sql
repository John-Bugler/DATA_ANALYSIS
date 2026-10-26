/* ============================================================
   VALUO — OPRAVA 2e: POLYGONY ÚZEMNÍHO PLÁNU

   NAHRAZUJE blok 2.3 z 02_geografie.sql, který padal na chybě
   24144 (instance is not valid).

   ------------------------------------------------------------
   PROČ PŮVODNÍ VERZE PADALA
   ------------------------------------------------------------
   Orientace ringů v datech NENÍ jednotná:
       15 110 polygonů má ring obrácený
          432 polygonů má ring správně

   Původní skript volal ReorientObject() na všechny. U těch
   432 správných by otočením vznikl polygon pokrývající celou
   Zemi, a protože takový útvar je pro typ geography nevalidní,
   operace skončila výjimkou.

   V rovině (typ geometry) jsou přitom všechny polygony validní
   — geography má přísnější pravidla, útvar nesmí být větší
   než polokoule.

   ------------------------------------------------------------
   ŘEŠENÍ
   ------------------------------------------------------------
   1) MakeValid() na každý polygon — projde na všech 15 542
   2) otočit POUZE ty, jejichž plocha vyjde nesmyslně velká

   Práh 1e10 m2 (10 000 km2) je bezpečný: největší plocha
   územního plánu je řádově km2, obrácený polygon vychází
   na 510 milionů km2.
   ============================================================ */

USE VALUO;
GO

/* ---------- 2e.1 SLOUPEC ------------------------------------ */

IF COL_LENGTH('dbo.UP_FVU_data', 'geo_plocha') IS NULL
    ALTER TABLE dbo.UP_FVU_data ADD geo_plocha geography NULL;
GO


/* ---------- 2e.2 NAPLNĚNÍ S PODMÍNĚNÝM OTOČENÍM -------------
   CROSS APPLY zajistí, že se polygon parsuje jen jednou.     */

UPDATE u
SET geo_plocha = CASE WHEN x.geo.STArea() > 1e10
                      THEN x.geo.ReorientObject()
                      ELSE x.geo
                 END
FROM dbo.UP_FVU_data u
CROSS APPLY (
    SELECT geography::STGeomFromText(CAST(u.geometry AS varchar(max)), 4326)
               .MakeValid() AS geo
) x
WHERE u.geometry IS NOT NULL
  AND u.geo_plocha IS NULL;
GO


/* ---------- 2e.3 KONTROLA -----------------------------------
   Očekávání: žádná plocha nad 1e10, největší v řádu km2.     */

SELECT  COUNT(*)                                            AS naplneno,
        CAST(MIN(geo_plocha.STArea()) AS decimal(18,1))     AS nejmensi_m2,
        CAST(AVG(geo_plocha.STArea()) AS decimal(18,1))     AS prumer_m2,
        CAST(MAX(geo_plocha.STArea()) AS decimal(18,1))     AS nejvetsi_m2,
        SUM(CASE WHEN geo_plocha.STArea() > 1e10
                 THEN 1 ELSE 0 END)                         AS stale_obracenych
FROM dbo.UP_FVU_data
WHERE geo_plocha IS NOT NULL;
GO


/* ---------- 2e.4 PROSTOROVÝ INDEX --------------------------- */

CREATE SPATIAL INDEX SIX_UP_geo_plocha
    ON dbo.UP_FVU_data (geo_plocha)
    USING GEOGRAPHY_AUTO_GRID
    WITH (CELLS_PER_OBJECT = 64);
GO


/* ---------- 2e.5 ÚKLID TYPU TEXT ----------------------------
   Sloupec geometry je typ TEXT, který je zastaralý a neumí
   LEN(), porovnání ani REPLACE.                              */

ALTER TABLE dbo.UP_FVU_data ALTER COLUMN geometry varchar(max) NULL;
GO


/* ---------- 2e.6 SLOUPEC PRO POLYGONY PARCEL ----------------
   Naplní ho Python (03_kn_reprojekce.py), protože zdroj je
   v S-JTSK a SQL Server neumí transformaci mezi systémy.
   Prostorový index se zakládá až po naplnění.                */

IF COL_LENGTH('dbo.KN_parcel_data', 'geo_plocha') IS NULL
    ALTER TABLE dbo.KN_parcel_data ADD geo_plocha geography NULL;
GO


/* ---------- 2e.7 OVĚŘENÍ NAPOJENÍ NA ÚZEMNÍ PLÁN ------------
   Porovná uloženou vazbu id_UP_FVU_data s tím, co vyjde
   prostorově. Pouze ČTE.

   Vazba vznikla prostorovým průnikem v Pythonu; u parcel na
   rozhraní ploch byla přiřazena plocha s největším podílem,
   takže neshoda sama o sobě nemusí znamenat chybu.
   ============================================================ */

SELECT TOP 200
        k.kat_uzemi,
        k.parcel_number,
        k.id_UP_FVU_data                AS vazba_ulozena,
        u.id                            AS vazba_prostorova,
        u.KODFP1_A                      AS fvu_prostorove,
        CASE WHEN k.id_UP_FVU_data = u.id      THEN N'souhlasí'
             WHEN k.id_UP_FVU_data IS NULL     THEN N'vazba chybí'
             ELSE                                   N'NESOUHLASÍ'
        END                             AS kontrola
FROM dbo.KN_parcel_data k
JOIN dbo.UP_FVU_data u ON u.geo_plocha.STIntersects(k.geo_bod) = 1
WHERE k.kat_uzemi = N'Krč'
ORDER BY k.parcel_number;
GO
