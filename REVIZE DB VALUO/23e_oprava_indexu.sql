/* ============================================================
   VALUO — KROK 23e, oprava indexu

   Jen index, do dat nezasahuje. Spusť celé najednou.

   ------------------------------------------------------------
   CO BYLO ŠPATNĚ
   ------------------------------------------------------------
       Msg 10609 — Filtered index 'IX_Valuo_data_jednotka'
       cannot be created on table 'dbo.Valuo_data' because the
       column 'jednotka_oznaceni' in the filter expression is
       a computed column.

   Filtr indexu nesmí odkazovat na počítaný sloupec, ani když je
   PERSISTED. Indexovat počítaný sloupec přitom jde — omezení
   platí jen na podmínku ve WHERE.

   Filtr se proto přesouvá na obyčejný sloupec nemovitost. Pokrývá
   tytéž řádky: jednotka_oznaceni je neprázdné právě u jednotek,
   což potvrzuje kontrola — 49 491 jednotek, 49 491 s označením.

   Samotné počítané sloupce z kroku 23e už v tabulce jsou a jsou
   v pořádku, ty se nijak nemění.
   ============================================================ */

USE VALUO;
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Valuo_data_jednotka')
    DROP INDEX IX_Valuo_data_jednotka ON dbo.Valuo_data;
GO

CREATE NONCLUSTERED INDEX IX_Valuo_data_jednotka
    ON dbo.Valuo_data (jednotka_oznaceni)
    INCLUDE (cislo_vkladu, kat_uzemi, typ)
    WHERE nemovitost = 'jednotka';
GO


/* ---------- KONTROLA ---------------------------------------- */

SELECT i.name AS index_name, i.type_desc, i.has_filter,
       i.filter_definition,
       SUM(p.rows) AS radku
FROM sys.indexes i
JOIN sys.partitions p ON p.object_id = i.object_id
                     AND p.index_id = i.index_id
WHERE i.object_id = OBJECT_ID('dbo.Valuo_data')
  AND i.name = 'IX_Valuo_data_jednotka'
GROUP BY i.name, i.type_desc, i.has_filter, i.filter_definition;
GO

/* Zkouška dohledání — tohle je ten dotaz, pro který index je */
SELECT cislo_vkladu, kat_uzemi, typ, jednotka_oznaceni
FROM dbo.Valuo_data
WHERE nemovitost = 'jednotka' AND jednotka_oznaceni = N'622/4';
GO
