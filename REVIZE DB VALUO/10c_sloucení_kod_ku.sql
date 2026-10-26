/* ============================================================
   VALUO — KROK 10c: SLOUČENÍ upper_zoning_id A kod_ku

   Oba sloupce nesou kód katastrálního území a shodují se ve
   všech 148 422 řádcích. Zůstane jediný: kod_ku jako int.

   ------------------------------------------------------------
   DŮSLEDEK PRO IMPORT — ČTI
   ------------------------------------------------------------
   kod_ku byl dosud POČÍTANÝ sloupec, plnil se sám.
   Po této změně je to běžný sloupec a importní skript ho musí
   plnit výslovně — jinak budou nové řádky mít kod_ku prázdný
   a vypadnou ze všech JOINů na číselník.

   Ve zdrojových datech z katastru odpovídá údaji, který se
   dosud ukládal do upper_zoning_id.

   Alternativa, pokud chceš zachovat automatické plnění:
   nespouštěj tento skript a ponech oba sloupce. Duplicita
   stojí 148 422 × 20 bajtů, tedy necelé 3 MB.
   ============================================================ */

USE VALUO;
GO

/* ---------- 10c.1 KONTROLA PŘED ZMĚNOU ---------------------
   Musí vyjout 148 422 a 0 neshod.                            */

SELECT  COUNT(*)                                        AS radku,
        SUM(CASE WHEN TRY_CONVERT(int, upper_zoning_id) = kod_ku
                 THEN 1 ELSE 0 END)                     AS shoduje_se,
        SUM(CASE WHEN TRY_CONVERT(int, upper_zoning_id) IS NULL
                 THEN 1 ELSE 0 END)                     AS neprevoditelnych
FROM dbo.KN_parcel_data;
GO


/* ---------- 10c.2 ZRUŠENÍ INDEXŮ S kod_ku ------------------ */

DROP INDEX IF EXISTS IX_KN_kod_ku     ON dbo.KN_parcel_data;
DROP INDEX IF EXISTS IX_KN_ku_parcela ON dbo.KN_parcel_data;
DROP INDEX IF EXISTS IX_KN_id_valuo   ON dbo.KN_parcel_data;
GO


/* ---------- 10c.3 ZÁMĚNA POČÍTANÉHO SLOUPCE ZA BĚŽNÝ ------- */

ALTER TABLE dbo.KN_parcel_data DROP COLUMN kod_ku;
GO

ALTER TABLE dbo.KN_parcel_data ADD kod_ku int NULL;
GO

UPDATE dbo.KN_parcel_data
SET kod_ku = TRY_CONVERT(int, upper_zoning_id);
GO

/* Kontrola naplnění — musí být 148 422 a 435 */
SELECT COUNT(kod_ku) AS vyplneno, COUNT(DISTINCT kod_ku) AS ruznych_uzemi
FROM dbo.KN_parcel_data;
GO

/* Teprve když kontrola sedí, pokračuj dalším blokem. */


/* ---------- 10c.4 ZRUŠENÍ upper_zoning_id ------------------ */

ALTER TABLE dbo.KN_parcel_data ALTER COLUMN kod_ku int NOT NULL;
GO

ALTER TABLE dbo.KN_parcel_data DROP COLUMN upper_zoning_id;
GO


/* ---------- 10c.5 OBNOVENÍ INDEXŮ -------------------------- */

CREATE NONCLUSTERED INDEX IX_KN_kod_ku
    ON dbo.KN_parcel_data (kod_ku)
    INCLUDE (id_valuo, parcel_number, areaValue_m2)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

CREATE NONCLUSTERED INDEX IX_KN_ku_parcela
    ON dbo.KN_parcel_data (kod_ku, parcel_number)
    INCLUDE (id_valuo, areaValue_m2, gml_id)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

CREATE NONCLUSTERED INDEX IX_KN_id_valuo
    ON dbo.KN_parcel_data (id_valuo)
    INCLUDE (kod_ku, parcel_number, areaValue_m2, gml_id)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO


/* ---------- 10c.6 REBUILD A STATISTIKY --------------------- */

ALTER TABLE dbo.KN_parcel_data
    REBUILD WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

UPDATE STATISTICS dbo.KN_parcel_data WITH FULLSCAN;
GO


/* ---------- 10c.7 VÝSLEDNÁ STRUKTURA ----------------------- */

SELECT  c.ORDINAL_POSITION          AS poradi,
        c.COLUMN_NAME               AS sloupec,
        c.DATA_TYPE                 AS typ,
        c.CHARACTER_MAXIMUM_LENGTH  AS delka,
        c.IS_NULLABLE               AS nullable
FROM INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_NAME = 'KN_parcel_data'
ORDER BY c.ORDINAL_POSITION;
GO

SELECT TOP 3 id, gml_id, kod_ku, kat_uzemi, obec, parcel_number, fvu_kod
FROM dbo.v_KN_parcely
WHERE fvu_kod IS NOT NULL;
GO
