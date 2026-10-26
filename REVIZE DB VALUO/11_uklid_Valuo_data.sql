/* ============================================================
   VALUO — KROK 11: ÚKLID Valuo_data A TYP PŘEVODU

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.

   ------------------------------------------------------------
   CO SE PŘIDÁVÁ
   ------------------------------------------------------------
   typ_prevodu — rozlišení, zda šlo o běžný prodej. Odvozuje se
   ze sloupce listina, který jsme dosud nevyužili:

       KUPNI_SMLOUVA      48 530 vkladů
       DRAZBA                234     exekuce a veřejné dražby
       PREVOD_Z_DRUZSTVA      53     § 9 zák. 311/2013,
                                     průměrná cena 8 221 Kč
       DAROVANI               31
       SMENA                  15

   Dražba není volný trh a do porovnávací metody nepatří bez
   úpravy. Převod z družstva má symbolickou cenu.

   ------------------------------------------------------------
   CO SE RUŠÍ
   ------------------------------------------------------------
   GPS_API_info   příznak geokódování adres, které bylo
                  nahrazeno souřadnicemi z katastru
   KN_WFS_info    příznak dotažení z katastru; totéž se pozná
                  z existence vazby v KN_parcel_data

   ------------------------------------------------------------
   CO ZŮSTÁVÁ A PROČ
   ------------------------------------------------------------
   okres, kat_uzemi   jsou nespolehlivé a nahrazené číselníkem,
                      ALE kod_ku je vyplněn jen u 101 506 ze
                      110 710 záznamů (91,7 %). U zbylých 9 204
                      bez navázané parcely by po jejich zrušení
                      nezbyla žádná informace o lokalitě.
                      Zrušit je půjde, až budou mít všechny
                      záznamy parcelu.

   LAT, LON           mění se na počítané sloupce odvozené
                      z geo_bod — data se tím přestanou
                      duplikovat, ale export do Excelu
                      a do map zůstane snadný.

   rok, mesic         mění se na počítané z datum_zplatneni.

   timestamp          datum importu, potřebné pro audit.

   listina            zdroj pro typ_prevodu, ponechat.
   ============================================================ */

USE VALUO;
GO

/* ---------- 11.1 TYP PŘEVODU ------------------------------- */

IF COL_LENGTH('dbo.Valuo_data', 'typ_prevodu') IS NULL
    ALTER TABLE dbo.Valuo_data ADD typ_prevodu varchar(20) NULL;
GO

CREATE OR ALTER PROCEDURE dbo.sp_prepocet_typu_prevodu
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Valuo_data
    SET typ_prevodu =
        CASE
            WHEN CAST(listina AS varchar(500)) LIKE '%dražb%'
              OR CAST(listina AS varchar(500)) LIKE '%příklep%'
              OR CAST(listina AS varchar(500)) LIKE '%exekutor%'
                 THEN 'DRAZBA'
            WHEN CAST(listina AS varchar(500)) LIKE '%311/2013%'
                 THEN 'PREVOD_Z_DRUZSTVA'
            WHEN CAST(listina AS varchar(500)) LIKE '%směnná%'
                 THEN 'SMENA'
            WHEN CAST(listina AS varchar(500)) LIKE '%darovací%'
                 THEN 'DAROVANI'
            WHEN CAST(listina AS varchar(500)) LIKE '%vklad do základního kapitálu%'
              OR CAST(listina AS varchar(500)) LIKE '%nepeněžit%'
                 THEN 'VKLAD_DO_KAPITALU'
            WHEN CAST(listina AS varchar(500)) LIKE '%dědic%'
              OR CAST(listina AS varchar(500)) LIKE '%pozůstalost%'
                 THEN 'DEDICTVI'
            ELSE 'KUPNI_SMLOUVA'
        END;
END;
GO

EXEC dbo.sp_prepocet_typu_prevodu;
GO

CREATE NONCLUSTERED INDEX IX_Valuo_typ_prevodu
    ON dbo.Valuo_data (typ_prevodu, rok)
    INCLUDE (kod_ku, cenovy_udaj, geo_zdroj)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

SELECT typ_prevodu, COUNT(*) AS zaznamu,
       COUNT(DISTINCT cislo_vkladu) AS vkladu
FROM dbo.Valuo_data
GROUP BY typ_prevodu
ORDER BY zaznamu DESC;
GO


/* ---------- 11.2 ZRUŠENÍ PRACOVNÍCH PŘÍZNAKŮ --------------- */

ALTER TABLE dbo.Valuo_data DROP COLUMN GPS_API_info, KN_WFS_info;
GO


/* ---------- 11.3 rok A mesic JAKO POČÍTANÉ ----------------- */

DROP INDEX IF EXISTS IX_Valuo_ku_typ_rok       ON dbo.Valuo_data;
DROP INDEX IF EXISTS IX_Valuo_okres_typ_rok    ON dbo.Valuo_data;
DROP INDEX IF EXISTS IX_Valuo_kod_ku_typ_rok   ON dbo.Valuo_data;
DROP INDEX IF EXISTS IX_Valuo_klasifikace      ON dbo.Valuo_data;
DROP INDEX IF EXISTS IX_Valuo_typ_prevodu      ON dbo.Valuo_data;
GO

/* Kontrola, že odvození z datum_zplatneni sedí se současnými
   hodnotami. Musí vyjít 0 neshod.                            */
SELECT SUM(CASE WHEN YEAR(datum_zplatneni)  <> rok   THEN 1 ELSE 0 END) AS rok_nesedi,
       SUM(CASE WHEN MONTH(datum_zplatneni) <> mesic THEN 1 ELSE 0 END) AS mesic_nesedi
FROM dbo.Valuo_data;
GO
/* Pokud nesedí, NEPOKRAČUJ dalším blokem a napiš mi to. */


/* ---------- 11.4 ZÁMĚNA rok A mesic ------------------------ */

ALTER TABLE dbo.Valuo_data DROP COLUMN rok, mesic;
GO

ALTER TABLE dbo.Valuo_data
    ADD rok   AS YEAR(datum_zplatneni)  PERSISTED,
        mesic AS MONTH(datum_zplatneni) PERSISTED;
GO


/* ---------- 11.5 LAT A LON JAKO POČÍTANÉ -------------------
   Přestanou se duplikovat s geo_bod, ale zůstanou použitelné
   pro export. Pokud by ALTER selhal (geography metody nemusí
   být přípustné v počítaném sloupci), použij blok 11.5b.     */

ALTER TABLE dbo.Valuo_data DROP COLUMN LAT, LON;
GO

ALTER TABLE dbo.Valuo_data
    ADD LAT AS geo_bod.Lat,
        LON AS geo_bod.Long;
GO


/* ---------- 11.5b ZÁLOŽNÍ VARIANTA -------------------------
   Spusť jen tehdy, když blok 11.5 selhal.                    */

-- ALTER TABLE dbo.Valuo_data ADD LAT decimal(9,7) NULL, LON decimal(9,7) NULL;
-- GO
-- UPDATE dbo.Valuo_data
-- SET LAT = CAST(geo_bod.Lat  AS decimal(9,7)),
--     LON = CAST(geo_bod.Long AS decimal(9,7))
-- WHERE geo_bod IS NOT NULL;
-- GO


/* ---------- 11.6 OBNOVENÍ INDEXŮ --------------------------- */

CREATE NONCLUSTERED INDEX IX_Valuo_kod_ku_typ_rok
    ON dbo.Valuo_data (kod_ku, typ, rok)
    INCLUDE (cenovy_udaj, plocha, geo_zdroj, typ_prevodu)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

CREATE NONCLUSTERED INDEX IX_Valuo_klasifikace
    ON dbo.Valuo_data (vklad_klasifikace, rok)
    INCLUDE (kod_ku, cenovy_udaj, vklad_plocha_parcel,
             vklad_plocha_jednotky, vklad_plocha_budovy, geo_zdroj)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

CREATE NONCLUSTERED INDEX IX_Valuo_typ_prevodu
    ON dbo.Valuo_data (typ_prevodu, rok)
    INCLUDE (kod_ku, cenovy_udaj, geo_zdroj)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO


/* ---------- 11.7 REBUILD A STATISTIKY ---------------------- */

ALTER TABLE dbo.Valuo_data
    REBUILD WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

UPDATE STATISTICS dbo.Valuo_data WITH FULLSCAN;
GO


/* ---------- 11.8 VÝSLEDNÁ STRUKTURA ------------------------ */

SELECT  c.ORDINAL_POSITION AS poradi,
        c.COLUMN_NAME      AS sloupec,
        c.DATA_TYPE        AS typ,
        c.IS_NULLABLE      AS nullable
FROM INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_NAME = 'Valuo_data'
ORDER BY c.ORDINAL_POSITION;
GO
