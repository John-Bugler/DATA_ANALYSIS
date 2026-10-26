/* ============================================================
   VALUO — KROK 18: DOKONČENÍ PO PŘETAŽENÍ PARCEL

   Spouštěj PO krocích 17, 17b a 09. Celé najednou.

   ------------------------------------------------------------
   PROČ JE TENTO KROK NUTNÝ
   ------------------------------------------------------------
   1) SOUŘADNICE VE Valuo_data SE NEPŘEPOČÍTÁVAJÍ SAMY

      Valuo_data.geo_bod je běžný sloupec, plněný v kroku 02c
      z referenčního bodu největší parcely vkladu. Záznam bez
      parcely neměl odkud bod vzít, takže mu zůstala souřadnice
      z geokodéru (u něhož byla ověřena odchylka až 344 km),
      nebo žádná.

      Ze 9 936 záznamů přetahovaných v kroku 17 mělo
          6 388   souřadnici jen z geokodéru (API_NEOVERENO)
          1 681   žádnou souřadnici
          1 867   bod z katastru

      Srovnávací vzorek se vybírá prostorově
      (geo_bod.STDistance), takže bez tohoto přepočtu by se
      osm tisíc opravených záznamů do vzorku nedostalo.

   2) PROCEDURY SE ZAKLÁDAJÍ ZNOVU PRO JISTOTU

      CREATE OR ALTER je u existující procedury neškodné —
      přepíše ji beze změny chování, protože definice jsou
      převzaté ze skriptů 05 a 11 bez úprav.

      Pozn.: dřívější verze této hlavičky tvrdila, že
      procedury v databázi chybí. Bylo to chybné zjištění.
      Účet claude_reader, jímž se Claude do databáze
      připojuje, nemá oprávnění VIEW ANY DEFINITION ani
      přístup k procedurám, a SQL Server proto objekty,
      k nimž účet nemá právo, v sys.procedures vůbec
      nezobrazí. Dotaz vracel nulu kvůli oprávnění, ne proto,
      že by procedury neexistovaly.

      Platí to obecně: přes tento účet nelze zkontrolovat
      existenci procedur ani přečíst definice pohledů. Taková
      kontrola se musí spustit v Management Studiu.

   Pozn.: Klasifikace vkladů ani vklad_plocha_parcel na
   parcelách z katastru nezávisí — počítají se z Valuo_data.
   Krok 17 je tedy nemění a přepočet je tu jen proto, aby
   procedury v databázi existovaly pro budoucí importy.
   ============================================================ */

USE VALUO;
GO

/* ---------- 18.1 ZÁLOHA SOUŘADNIC -------------------------- */

IF OBJECT_ID('dbo.zaloha_geo_18') IS NOT NULL
    DROP TABLE dbo.zaloha_geo_18;
GO

SELECT  id, geo_bod, geo_zdroj, GETDATE() AS datum_zalohy
INTO    dbo.zaloha_geo_18
FROM    dbo.Valuo_data
WHERE   geo_zdroj IS NULL
   OR   geo_zdroj <> 'KN_refPoint'
   OR   id IN (SELECT id_valuo FROM dbo.KN_k_pretazeni);
GO

CREATE CLUSTERED INDEX IX_zaloha_geo_18 ON dbo.zaloha_geo_18 (id);
GO

SELECT COUNT(*) AS zalohovano FROM dbo.zaloha_geo_18;
GO


/* ---------- 18.2 DOPLNĚNÍ SOUŘADNIC Z KATASTRU -------------
   Stejná logika jako v kroku 02c: bod největší parcely vkladu,
   jen pokud leží v rozsahu souřadnic České republiky.

   LAT a LON se NEnastavují — od kroku 11 jsou to počítané
   sloupce a dopočítají se z geo_bod samy.                    */

WITH nejvetsi_parcela AS (
    SELECT  k.id_valuo,
            k.refPoint_lat,
            k.refPoint_lon,
            ROW_NUMBER() OVER (PARTITION BY k.id_valuo
                               ORDER BY k.areaValue_m2 DESC, k.id) AS poradi
    FROM dbo.KN_parcel_data k
    WHERE k.refPoint_lat BETWEEN 48.5 AND 51.1
      AND k.refPoint_lon BETWEEN 12.0 AND 18.9
)
UPDATE v
SET v.geo_bod   = geography::Point(p.refPoint_lat, p.refPoint_lon, 4326),
    v.geo_zdroj = 'KN_refPoint'
FROM dbo.Valuo_data v
JOIN nejvetsi_parcela p ON p.id_valuo = v.id AND p.poradi = 1
WHERE v.geo_zdroj IS NULL
   OR v.geo_zdroj <> 'KN_refPoint'
   OR v.id IN (SELECT id_valuo FROM dbo.KN_k_pretazeni);
GO

SELECT @@ROWCOUNT AS souradnic_doplneno;
GO

/* Záznam, který parcelu nedostal ani teď, si ponechá souřadnici
   z geokodéru — musí ale zůstat poznat, že je neověřená.     */

UPDATE dbo.Valuo_data
SET geo_zdroj = 'API_NEOVERENO'
WHERE geo_bod IS NOT NULL
  AND (geo_zdroj IS NULL OR geo_zdroj = 'VALUO_API');
GO


/* ---------- 18.3 PROSTOROVÝ INDEX -------------------------- */

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'SIX_Valuo_geo_bod'
             AND object_id = OBJECT_ID('dbo.Valuo_data'))
    ALTER INDEX SIX_Valuo_geo_bod ON dbo.Valuo_data REBUILD;
GO

UPDATE STATISTICS dbo.Valuo_data WITH FULLSCAN;
GO


/* ============================================================
   18.4  ZNOVUVYTVOŘENÍ PROCEDUR
   ------------------------------------------------------------
   Spouštět po každém importu nových dat z Valua:
       EXEC dbo.sp_prepocet_jednotkovych_cen;
       EXEC dbo.sp_prepocet_typu_prevodu;
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.sp_prepocet_jednotkovych_cen
AS
BEGIN
    SET NOCOUNT ON;

    /* různé nemovitosti ve vkladu — bez duplicitních zápisů */
    WITH dedup AS (
        SELECT DISTINCT cislo_vkladu, nemovitost, typ, adresa, plocha,
                        typ_plochy
        FROM dbo.Valuo_data
    ),
    pocty AS (
        SELECT  cislo_vkladu,
                COUNT(*) AS nemovitosti,
                SUM(CASE WHEN nemovitost = N'parcela'  THEN 1 ELSE 0 END) AS parcel,
                SUM(CASE WHEN nemovitost = N'jednotka' THEN 1 ELSE 0 END) AS jednotek,
                SUM(CASE WHEN nemovitost = N'budova'   THEN 1 ELSE 0 END) AS budov,

                /* součet výměr parcel */
                SUM(CASE WHEN nemovitost = N'parcela' THEN plocha ELSE 0 END)
                    AS plocha_parcel,

                /* plocha jednotky — jen z podílu na budově.
                   "Výměra parcely" u jednotky je pozemek,
                   ne byt, a do jmenovatele nepatří. */
                SUM(CASE WHEN nemovitost = N'jednotka'
                          AND typ_plochy = N'Plocha spočítaná z podílu na budově'
                         THEN plocha ELSE 0 END) AS plocha_jednotky,

                /* plocha budovy — jen podlahová či zastavěná */
                SUM(CASE WHEN nemovitost = N'budova'
                          AND typ_plochy IN (N'Podlahová plocha',
                                             N'Zastavěná plocha budovy')
                         THEN plocha ELSE 0 END) AS plocha_budovy
        FROM dedup
        GROUP BY cislo_vkladu
    ),
    radky AS (
        SELECT cislo_vkladu, COUNT(*) AS radku
        FROM dbo.Valuo_data
        GROUP BY cislo_vkladu
    )
    UPDATE v
    SET v.vklad_nemovitosti     = p.nemovitosti,
        v.vklad_radku           = r.radku,
        v.vklad_duplicit        = r.radku - p.nemovitosti,
        v.vklad_plocha_parcel   = NULLIF(p.plocha_parcel,   0),
        v.vklad_plocha_jednotky = NULLIF(p.plocha_jednotky, 0),
        v.vklad_plocha_budovy   = NULLIF(p.plocha_budovy,   0),

        v.vklad_klasifikace =
            CASE WHEN p.budov    > 1                   THEN 'NELZE'
                 WHEN p.jednotek > 1                   THEN 'NELZE'
                 WHEN p.budov = 1 AND p.jednotek = 1   THEN 'NELZE'
                 WHEN p.budov    = 1                   THEN 'CELEK_BUDOVA'
                 WHEN p.jednotek = 1                   THEN 'JC_JEDNOTKA'
                 WHEN p.parcel   > 0                   THEN 'JC_PARCELY'
                 ELSE                                       'NELZE'
            END,

        v.vklad_duvod =
            CASE WHEN p.budov    > 1                 THEN 'více budov ve vkladu'
                 WHEN p.jednotek > 1                 THEN 'více jednotek ve vkladu'
                 WHEN p.budov = 1 AND p.jednotek = 1 THEN 'budova i jednotka zároveň'
                 WHEN p.budov = 0 AND p.jednotek = 0
                  AND p.parcel = 0                   THEN 'nezařazená nemovitost'
                 ELSE NULL
            END
    FROM dbo.Valuo_data v
    JOIN pocty p ON p.cislo_vkladu = v.cislo_vkladu
    JOIN radky r ON r.cislo_vkladu = v.cislo_vkladu;
END;
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

EXEC dbo.sp_prepocet_jednotkovych_cen;
GO
EXEC dbo.sp_prepocet_typu_prevodu;
GO

SELECT COUNT(*) AS procedur_v_databazi FROM sys.procedures;
GO


/* ============================================================
   18.5  STAV PO PŘETAŽENÍ — SROVNÁNÍ SE VSTUPNÍM STAVEM
   ============================================================ */

/* a) záznamy bez parcely — před krokem 17 jich bylo 8 067 */
SELECT COUNT(*) AS bez_parcely
FROM dbo.Valuo_data v
WHERE NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data k WHERE k.id_valuo = v.id);
GO

/* b) parcely z cizího území — před krokem 17 jich bylo 385 */
SELECT COUNT(*) AS parcel_z_ciziho_uzemi
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data        k ON k.id_valuo = v.id
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod   = k.kod_ku
WHERE v.popis IS NOT NULL
  AND CHARINDEX(c.ku_nazev, v.popis) = 0;
GO

/* c) stavební parcela u pozemkové — před krokem 17 jich bylo 329 */
SELECT COUNT(DISTINCT v.id) AS stavebni_nesoulad
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data k ON k.id_valuo = v.id
WHERE v.popis LIKE N'č. %' AND k.parcel_number LIKE 'st.%';
GO

/* d) shoda výměry u parcel */
SELECT  CASE WHEN ABS(v.plocha - k.areaValue_m2) < 1 THEN N'sedí'
             ELSE N'nesedí' END   AS vymera,
        COUNT(*)                  AS parcel
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data k ON k.id_valuo = v.id
WHERE v.nemovitost = N'parcela' AND v.plocha > 0 AND k.areaValue_m2 > 0
GROUP BY CASE WHEN ABS(v.plocha - k.areaValue_m2) < 1 THEN N'sedí' ELSE N'nesedí' END;
GO

/* e) zdroj souřadnic — před krokem 18: KN 99 320, API 6 402, bez 1 681 */
SELECT  ISNULL(geo_zdroj, N'(bez souřadnic)') AS zdroj_souradnic,
        COUNT(*)                              AS zaznamu,
        CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(5,2)) AS podil_pct
FROM dbo.Valuo_data
GROUP BY geo_zdroj
ORDER BY zaznamu DESC;
GO

/* f) geometrie parcel — po 17b musí být bez_plochy nula */
SELECT  COUNT(*)                                            AS parcel,
        SUM(CASE WHEN geo_bod    IS NULL THEN 1 ELSE 0 END) AS bez_bodu,
        SUM(CASE WHEN geo_plocha IS NULL THEN 1 ELSE 0 END) AS bez_plochy
FROM dbo.KN_parcel_data;
GO

/* g) zatřídění do ÚP — po kroku 09 nesmí být osiřelé vazby */
SELECT  (SELECT COUNT(*) FROM dbo.KN_parcel_UP)                      AS vazeb_na_UP,
        (SELECT COUNT(*) FROM dbo.KN_parcel_UP u
         LEFT JOIN dbo.KN_parcel_data k ON k.id = u.kn_id
         WHERE k.id IS NULL)                                         AS osirelych;
GO

/* h) výsledný vzorek */
SELECT  klasifikace, hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY klasifikace, hodnoceni_ceny
ORDER BY klasifikace, vkladu DESC;
GO
