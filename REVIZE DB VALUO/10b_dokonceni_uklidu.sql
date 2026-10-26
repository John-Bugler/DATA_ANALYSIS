/* ============================================================
   VALUO — KROK 10b: DOKONČENÍ ÚKLIDU KN_parcel_data

   Blok 10.3 selhal, protože index IX_KN_id_valuo má sloupec
   kat_uzemi v INCLUDE. Ověřeno, že je to jediná závislost
   na rušených sloupcích.

   Co už proběhlo: kod_ku přepojen na upper_zoning_id,
   IX_KN_ku_parcela přepsán na (kod_ku, parcel_number),
   pohled v_KN_parcely vytvořen.

   Zbývá: zrušit sloupce a obnovit index bez kat_uzemi.
   ============================================================ */

USE VALUO;
GO

/* ---------- 10b.1 ZRUŠENÍ ZÁVISLÉHO INDEXU ----------------- */

DROP INDEX IF EXISTS IX_KN_id_valuo ON dbo.KN_parcel_data;
GO


/* ---------- 10b.2 ZRUŠENÍ SLOUPCŮ -------------------------- */

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


/* ---------- 10b.3 OBNOVENÍ INDEXU --------------------------
   Místo kat_uzemi nese INCLUDE nově kod_ku — stejný účel,
   spolehlivý údaj, a k názvu se dojde přes číselník.        */

CREATE NONCLUSTERED INDEX IX_KN_id_valuo
    ON dbo.KN_parcel_data (id_valuo)
    INCLUDE (kod_ku, parcel_number, areaValue_m2, gml_id)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO


/* ---------- 10b.4 REBUILD A STATISTIKY --------------------- */

ALTER TABLE dbo.KN_parcel_data
    REBUILD WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

UPDATE STATISTICS dbo.KN_parcel_data WITH FULLSCAN;
GO


/* ---------- 10b.5 VÝSLEDNÁ STRUKTURA ----------------------- */

SELECT  c.ORDINAL_POSITION          AS poradi,
        c.COLUMN_NAME               AS sloupec,
        c.DATA_TYPE                 AS typ,
        c.CHARACTER_MAXIMUM_LENGTH  AS delka
FROM INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_NAME = 'KN_parcel_data'
ORDER BY c.ORDINAL_POSITION;
GO

SELECT  i.name      AS index_nazev,
        i.type_desc AS typ,
        CAST(SUM(a.used_pages) * 8.0 / 1024 AS decimal(10,1)) AS MB
FROM sys.indexes i
JOIN sys.tables      t ON t.object_id = i.object_id
JOIN sys.partitions  p ON p.object_id = i.object_id AND p.index_id = i.index_id
JOIN sys.allocation_units a ON a.container_id = p.partition_id
WHERE t.name = 'KN_parcel_data' AND i.type > 0
GROUP BY i.name, i.type_desc
ORDER BY i.name;
GO


/* ---------- 10b.6 OVĚŘENÍ POHLEDU -------------------------- */

SELECT TOP 5 id, gml_id, kat_uzemi, obec, okres, parcel_number,
             areaValue_m2, fvu_kod, podil_v_ploche_pct
FROM dbo.v_KN_parcely
WHERE fvu_kod IS NOT NULL;
GO
