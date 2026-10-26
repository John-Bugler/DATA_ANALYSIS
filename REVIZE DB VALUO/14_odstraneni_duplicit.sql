/* ============================================================
   VALUO — KROK 14: ODSTRANĚNÍ DUPLICITNÍCH PARCEL

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Mazání řádků je nevratné; skript sice zálohuje mazané
   záznamy do samostatné tabulky, ale záloha databáze je
   jistější.

   ------------------------------------------------------------
   NÁLEZ
   ------------------------------------------------------------
   V KN_parcel_data je 5 551 skupin, kde je táž parcela
   (gml_id) navázaná na tutéž nemovitost (id_valuo) vícekrát.
   Celkem 11 962 nadbytečných řádků, tedy 8,1 % tabulky,
   nejvyšší násobnost 20.

   Ověřeno, že jde o identické kopie: ani jedna skupina se
   neliší výměrou (areaValue_m2) ani zatříděním do územního
   plánu (id_UP_FVU_data). Vznikly opakovaným během importu.

   ------------------------------------------------------------
   POSTUP
   ------------------------------------------------------------
   Z každé skupiny zůstává řádek s nejnižším id. Nejdřív se
   mažou navázané záznamy v KN_parcel_UP, teprve pak samotné
   parcely — opačné pořadí by zanechalo osiřelé vazby.

   Na závěr se zakládá unikátní index, který opakování téže
   chyby znemožní: příští import skončí chybou místo toho,
   aby tiše zdvojil data.
   ============================================================ */

USE VALUO;
GO

/* ---------- 14.1 OZNAČENÍ ŘÁDKŮ KE SMAZÁNÍ ----------------- */

IF OBJECT_ID('dbo.zaloha_duplicity_20261022') IS NOT NULL
    DROP TABLE dbo.zaloha_duplicity_20261022;
GO

SELECT  k.*,
        GETDATE() AS datum_zalohy
INTO dbo.zaloha_duplicity_20261022
FROM dbo.KN_parcel_data k
WHERE k.id NOT IN (
        SELECT MIN(id)
        FROM dbo.KN_parcel_data
        GROUP BY id_valuo, gml_id
);
GO

CREATE CLUSTERED INDEX IX_zaloha_dupl_id
    ON dbo.zaloha_duplicity_20261022 (id);
GO

SELECT COUNT(*) AS ke_smazani FROM dbo.zaloha_duplicity_20261022;
GO

/* Očekávání: 11 962. Pokud číslo výrazně nesedí, zastav se. */


/* ---------- 14.2 SMAZÁNÍ NAVÁZANÝCH VAZEB NA ÚP ------------ */

DELETE u
FROM dbo.KN_parcel_UP u
JOIN dbo.zaloha_duplicity_20261022 z ON z.id = u.kn_id;
GO

SELECT @@ROWCOUNT AS smazano_vazeb_na_UP;
GO


/* ---------- 14.3 SMAZÁNÍ DUPLICITNÍCH PARCEL --------------- */

DELETE k
FROM dbo.KN_parcel_data k
JOIN dbo.zaloha_duplicity_20261022 z ON z.id = k.id;
GO

SELECT @@ROWCOUNT AS smazano_parcel;
GO


/* ---------- 14.4 KONTROLA ---------------------------------- */

SELECT  COUNT(*)                        AS parcel_celkem,
        COUNT(DISTINCT gml_id)          AS ruznych_parcel,
        COUNT(DISTINCT id_valuo)        AS navazanych_nemovitosti
FROM dbo.KN_parcel_data;
GO

/* Zbyly ještě nějaké duplicity? Musí vyjít 0. */
SELECT COUNT(*) AS zbyvajicich_duplicit
FROM (
    SELECT id_valuo, gml_id
    FROM dbo.KN_parcel_data
    GROUP BY id_valuo, gml_id
    HAVING COUNT(*) > 1
) x;
GO

/* Osiřelé vazby na ÚP? Musí vyjít 0. */
SELECT COUNT(*) AS osirelych_vazeb
FROM dbo.KN_parcel_UP u
LEFT JOIN dbo.KN_parcel_data k ON k.id = u.kn_id
WHERE k.id IS NULL;
GO


/* ---------- 14.5 PREVENCE OPAKOVÁNÍ ------------------------
   Unikátní index zabrání tomu, aby příští import tiše zdvojil
   data. Místo toho skončí chybou, což je mnohem lepší.

   Pokud by založení selhalo, znamená to, že nějaké duplicity
   ještě zbyly — pak se vrať ke kontrole v bloku 14.4.        */

CREATE UNIQUE NONCLUSTERED INDEX UQ_KN_parcela_nemovitost
    ON dbo.KN_parcel_data (id_valuo, gml_id)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO


/* ---------- 14.6 REBUILD A STATISTIKY ---------------------- */

ALTER TABLE dbo.KN_parcel_data
    REBUILD WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

UPDATE STATISTICS dbo.KN_parcel_data WITH FULLSCAN;
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


/* ---------- 14.7 KDYBY BYLO TŘEBA SE VRÁTIT ----------------
   Vrátí smazané parcely. Vazby na ÚP se tím neobnoví —
   ty by se musely přepočítat skriptem 09.
   Spouštět jen vědomě a po zrušení unikátního indexu.        */

-- DROP INDEX UQ_KN_parcela_nemovitost ON dbo.KN_parcel_data;
-- GO
-- SET IDENTITY_INSERT dbo.KN_parcel_data ON;
-- INSERT INTO dbo.KN_parcel_data
--     (id, parcel_number, gml_id, areaValue_m2, beginLifespanVersion,
--      geometry, refPoint_x, refPoint_y, refPoint_lon, refPoint_lat,
--      id_valuo, id_UP_FVU_data, geo_bod, geo_plocha, kod_ku)
-- SELECT id, parcel_number, gml_id, areaValue_m2, beginLifespanVersion,
--        geometry, refPoint_x, refPoint_y, refPoint_lon, refPoint_lat,
--        id_valuo, id_UP_FVU_data, geo_bod, geo_plocha, kod_ku
-- FROM dbo.zaloha_duplicity_20261022;
-- SET IDENTITY_INSERT dbo.KN_parcel_data OFF;
-- GO
