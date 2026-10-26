/* ============================================================
   VALUO — KROK 10: ÚKLID STRUKTURY KN_parcel_data

   Odstraňuje sloupce, které nenesou informaci, duplikují jiné
   nebo vedly k chybám. Spouštět po blocích.

   PŘED SPUŠTĚNÍM UDĚLEJ ZÁLOHU DATABÁZE.
   Rušení sloupců je nevratné.

   ------------------------------------------------------------
   CO SE RUŠÍ A PROČ
   ------------------------------------------------------------
   kat_uzemi                  u 16,6 % řádků obsahuje adresu
                              místo názvu území; spolehlivý
                              název je v číselníku ČÚZK
   nationalCadastralReference složitelné z kod_ku + parcel_number
   inspire_localId            duplicita gml_id
   inspire_namespace          jediná hodnota pro všech 148 422 řádků
   label                      duplicita parcel_number
   endLifespanVersion         zcela prázdný
   validFrom                  zcela prázdný
   administrativeUnit_href    URL, nikde se nepoužívá
   zoning_href                URL, nikde se nepoužívá
   administrativeUnit_title   název obce — z číselníku
   zoning_title               název území — z číselníku

   ------------------------------------------------------------
   CO ZŮSTÁVÁ A PROČ
   ------------------------------------------------------------
   gml_id              identifikátor parcely používaný ČÚZK,
                       vystupuje v URL dálkového přístupu
   upper_zoning_id     původní kód katastrálního území z katastru;
                       ověřeno, že se shoduje s kod_ku ve všech
                       148 422 řádcích
   kod_ku              typovaná (int) odvozenina pro JOINy
                       a indexy — PŘEPOJÍ SE na upper_zoning_id
   refPoint_x, _y      souřadnice v S-JTSK, jiná informace
                       než refPoint_lon/_lat
   ============================================================ */

USE VALUO;
GO

/* ---------- 10.1 PŘEPOJENÍ kod_ku --------------------------
   kod_ku je dnes počítaný z nationalCadastralReference. Dokud
   na něm závisí, nelze ten sloupec zrušit. Přepojíme ho na
   upper_zoning_id, který nese totéž a je původní údaj.       */

DROP INDEX IF EXISTS IX_KN_kod_ku ON dbo.KN_parcel_data;
GO

IF COL_LENGTH('dbo.KN_parcel_data', 'kod_ku') IS NOT NULL
    ALTER TABLE dbo.KN_parcel_data DROP COLUMN kod_ku;
GO

ALTER TABLE dbo.KN_parcel_data
    ADD kod_ku AS TRY_CONVERT(int, upper_zoning_id) PERSISTED;
GO

CREATE NONCLUSTERED INDEX IX_KN_kod_ku
    ON dbo.KN_parcel_data (kod_ku)
    INCLUDE (id_valuo, parcel_number, areaValue_m2)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

/* Kontrola: musí vyjít 148 422 a žádné NULL */
SELECT COUNT(*) AS radku,
       COUNT(kod_ku) AS kod_vyplnen,
       COUNT(DISTINCT kod_ku) AS ruznych_uzemi
FROM dbo.KN_parcel_data;
GO


/* ---------- 10.2 ZRUŠENÍ ZÁVISLÝCH INDEXŮ ------------------
   IX_KN_ku_parcela má kat_uzemi jako klíčový sloupec.        */

DROP INDEX IF EXISTS IX_KN_ku_parcela ON dbo.KN_parcel_data;
GO


/* ---------- 10.3 ZRUŠENÍ SLOUPCŮ --------------------------- */

ALTER TABLE dbo.KN_parcel_data DROP COLUMN
    kat_uzemi,
    nationalCadastralReference,
    inspire_localId,
    inspire_namespace,
    label,
    endLifespanVersion,
    validFrom,
    administrativeUnit_href,
    zoning_href,
    administrativeUnit_title,
    zoning_title;
GO


/* ---------- 10.4 NÁHRADNÍ INDEX ----------------------------
   Místo (kat_uzemi, parcel_number) nově (kod_ku, parcel_number)
   — stejný účel, spolehlivý klíč.                            */

CREATE NONCLUSTERED INDEX IX_KN_ku_parcela
    ON dbo.KN_parcel_data (kod_ku, parcel_number)
    INCLUDE (id_valuo, areaValue_m2, gml_id)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO


/* ---------- 10.5 REBUILD A STATISTIKY ---------------------- */

ALTER TABLE dbo.KN_parcel_data
    REBUILD WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

UPDATE STATISTICS dbo.KN_parcel_data WITH FULLSCAN;
GO


/* ---------- 10.6 VÝSLEDNÁ STRUKTURA ------------------------ */

SELECT  c.ORDINAL_POSITION          AS poradi,
        c.COLUMN_NAME               AS sloupec,
        c.DATA_TYPE                 AS typ,
        c.CHARACTER_MAXIMUM_LENGTH  AS delka
FROM INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_NAME = 'KN_parcel_data'
ORDER BY c.ORDINAL_POSITION;
GO

SELECT  t.name      AS tabulka,
        i.name      AS index_nazev,
        i.type_desc AS typ,
        CAST(SUM(a.used_pages) * 8.0 / 1024 AS decimal(10,1)) AS MB
FROM sys.indexes i
JOIN sys.tables      t ON t.object_id = i.object_id
JOIN sys.partitions  p ON p.object_id = i.object_id AND p.index_id = i.index_id
JOIN sys.allocation_units a ON a.container_id = p.partition_id
WHERE t.name = 'KN_parcel_data' AND i.type > 0
GROUP BY t.name, i.name, i.type_desc
ORDER BY i.name;
GO


/* ============================================================
   10.7  NÁZEV ÚZEMÍ SE NOVĚ BERE Z ČÍSELNÍKU
   ------------------------------------------------------------
   Kde jsi dřív psal k.kat_uzemi, napiš JOIN na číselník.
   Pohled níž to dělá za tebe.
   ============================================================ */

CREATE OR ALTER VIEW dbo.v_KN_parcely
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

SELECT TOP 5 id, gml_id, kat_uzemi, obec, parcel_number,
             areaValue_m2, fvu_kod, podil_v_ploche_pct
FROM dbo.v_KN_parcely
WHERE fvu_kod IS NOT NULL;
GO
