/* ============================================================
   VALUO — KROK 25: AUDIT DATABÁZE

   Jen čte, nic nemění. Příkazy k úklidu jsou na konci
   zakomentované — rozhodneš podle toho, co audit ukáže.

   ============================================================
   PROČ
   ============================================================
   Krok 24e odhalil, že v_vklad_UP četl ze starého sloupce
   KN_parcel_data.id_UP_FVU_data, který obsahoval pražské
   funkční využití i u 1 569 parcel mimo Prahu. Byl to pozůstatek
   dřívějších skriptů, o kterém se vědělo, že je uklizený.

   Tenhle audit hledá další takové věci: dvojí zdroje téhož
   údaje, osiřelé vazby, duplicity a data, na která už nic
   neukazuje.
   ============================================================ */

USE VALUO;
GO

/* ============================================================
   25.1 CO V DATABÁZI JE
   ============================================================ */

SELECT  tabulka = t.name,
        radku   = p.rows,
        vznik   = CONVERT(varchar(16), t.create_date, 120),
        zmena   = CONVERT(varchar(16), t.modify_date, 120),
        role    = CASE
            WHEN t.name LIKE 'zaloha%' OR t.name LIKE '%_zaloha%'
                 OR t.name LIKE 'oprava%'          THEN N'ZÁLOHA'
            WHEN t.name LIKE 'CIS[_]%'             THEN N'číselník'
            WHEN t.name IN ('Valuo_data','KN_parcel_data',
                            'UP_FVU_data','KN_parcel_UP')
                                                   THEN N'produkční'
            WHEN t.name LIKE 'Valuo[_]%'           THEN N'odvozená'
            ELSE N'pracovní' END
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
ORDER BY role, p.rows DESC;
GO

SELECT  pohled = v.name,
        sloupcu = (SELECT COUNT(*) FROM sys.columns c
                   WHERE c.object_id = v.object_id),
        zmena = CONVERT(varchar(16), v.modify_date, 120)
FROM sys.views v ORDER BY v.name;
GO

/* Procedury — claude_reader je nevidí, ty ano */
SELECT  procedura = p.name,
        zmena = CONVERT(varchar(16), p.modify_date, 120)
FROM sys.procedures p ORDER BY p.name;
GO


/* ============================================================
   25.2 DVOJÍ ZDROJE TÉHOŽ ÚDAJE
   ============================================================
   Tohle je typ chyby, který shodil v_vklad_UP: údaj je na dvou
   místech a každé říká něco jiného.
   ============================================================ */

/* Územní plán: starý sloupec proti tabulce z kroku 09.
   Po kroku 24e má být shoda úplná.                           */
SELECT  kontrola = N'územní plán: starý sloupec vs KN_parcel_UP',
        kraj = c.kraj_nazev,
        stary_sloupec = SUM(CASE WHEN p.id_UP_FVU_data IS NOT NULL
                                 THEN 1 ELSE 0 END),
        nova_tabulka  = SUM(CASE WHEN u.kn_id IS NOT NULL THEN 1 ELSE 0 END),
        rozdil = SUM(CASE WHEN p.id_UP_FVU_data IS NOT NULL
                           AND u.kn_id IS NULL THEN 1 ELSE 0 END)
FROM dbo.KN_parcel_data p
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = p.kod_ku
LEFT JOIN dbo.KN_parcel_UP u ON u.kn_id = p.id AND u.poradi = 1
GROUP BY c.kraj_nazev
HAVING SUM(CASE WHEN p.id_UP_FVU_data IS NOT NULL THEN 1 ELSE 0 END) > 0
    OR SUM(CASE WHEN u.kn_id IS NOT NULL THEN 1 ELSE 0 END) > 0
ORDER BY rozdil DESC;
GO

/* Souřadnice: Valuo_data.LAT/LON proti geo_bod.
   Mají být totožné, geo_bod je z nich počítaný.              */
SELECT  kontrola = N'souřadnice: LAT/LON vs geo_bod',
        geo_zdroj,
        radku = COUNT(*),
        lisi_se = SUM(CASE WHEN geo_bod IS NOT NULL AND LAT IS NOT NULL
                            AND ABS(geo_bod.Lat - LAT) > 0.00001
                           THEN 1 ELSE 0 END),
        /* SQL Server neporovná dva logické výrazy mezi sebou,
           proto rozepsané do dvou větví */
        jen_jedno = SUM(CASE WHEN geo_bod IS NULL AND LAT IS NOT NULL THEN 1
                             WHEN geo_bod IS NOT NULL AND LAT IS NULL THEN 1
                             ELSE 0 END)
FROM dbo.Valuo_data GROUP BY geo_zdroj;
GO


/* ============================================================
   25.3 OSIŘELÉ VAZBY
   ============================================================ */

SELECT  kontrola = N'KN_parcel_UP ukazuje na neexistující parcelu',
        osirelych = COUNT(*)
FROM dbo.KN_parcel_UP u
WHERE NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data p WHERE p.id = u.kn_id);
GO

SELECT  kontrola = N'KN_parcel_UP ukazuje na neexistující polygon ÚP',
        osirelych = COUNT(*)
FROM dbo.KN_parcel_UP u
WHERE NOT EXISTS (SELECT 1 FROM dbo.UP_FVU_data f WHERE f.id = u.up_id);
GO

SELECT  kontrola = N'KN_parcel_data ukazuje na neexistující řádek Valuo_data',
        osirelych = COUNT(*)
FROM dbo.KN_parcel_data p
WHERE NOT EXISTS (SELECT 1 FROM dbo.Valuo_data v WHERE v.id = p.id_valuo);
GO

SELECT  kontrola = N'KN_k_pretazeni ukazuje na neexistující řádek Valuo_data',
        osirelych = COUNT(*)
FROM dbo.KN_k_pretazeni k
WHERE NOT EXISTS (SELECT 1 FROM dbo.Valuo_data v WHERE v.id = k.id_valuo);
GO

SELECT  kontrola = N'Valuo_hromadne_prevody na skupinu, která už neexistuje',
        skupin = COUNT(*)
FROM dbo.Valuo_hromadne_prevody WHERE vkladu = 0;
GO


/* ============================================================
   25.4 DUPLICITY
   ============================================================ */

SELECT  kontrola = N'KN_parcel_data: táž parcela dvakrát u téhož řádku',
        pripadu = COUNT(*)
FROM (SELECT id_valuo, gml_id FROM dbo.KN_parcel_data
      WHERE gml_id IS NOT NULL
      GROUP BY id_valuo, gml_id HAVING COUNT(*) > 1) a;
GO

SELECT  kontrola = N'KN_parcel_UP: tatáž dvojice parcela-polygon dvakrát',
        pripadu = COUNT(*)
FROM (SELECT kn_id, up_id FROM dbo.KN_parcel_UP
      GROUP BY kn_id, up_id HAVING COUNT(*) > 1) a;
GO

SELECT  kontrola = N'Valuo_data: týž vklad a popis dvakrát',
        pripadu = COUNT(*)
FROM (SELECT cislo_vkladu, popis FROM dbo.Valuo_data
      GROUP BY cislo_vkladu, popis HAVING COUNT(*) > 1) a;
GO


/* ============================================================
   25.5 ZÁLOŽNÍ TABULKY
   ============================================================
   Z revize 22. a 23. října. Jsou to kopie stavu před úpravami.
   ============================================================ */

SELECT  tabulka = t.name,
        radku   = p.rows,
        MB      = CAST(SUM(a.total_pages) * 8.0 / 1024 AS decimal(10,1)),
        vznik   = CONVERT(varchar(16), t.create_date, 120),
        stari_dnu = DATEDIFF(day, t.create_date, GETDATE())
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
JOIN sys.allocation_units a ON a.container_id = p.partition_id
WHERE t.name LIKE 'zaloha%' OR t.name LIKE '%_zaloha%'
   OR t.name LIKE 'oprava%'
GROUP BY t.name, p.rows, t.create_date
ORDER BY t.create_date;
GO


/* ============================================================
   25.6 SLOUPCE, KTERÉ MOŽNA UŽ NIKDO NEČTE
   ============================================================
   Vypsat je umí databáze, rozhodnout musíš ty — nástroj, který
   by spolehlivě zjistil, co čtou tvoje Python skripty a Excely,
   neexistuje.
   ============================================================ */

SELECT  tabulka = t.name, sloupec = c.name,
        typ = ty.name
             + CASE WHEN ty.name LIKE '%char%'
                    THEN '(' + CASE WHEN c.max_length = -1 THEN 'max'
                               ELSE CAST(c.max_length AS varchar) END + ')'
                    ELSE '' END,
        naplneno = N'spusť dotaz v 25.7'
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.name IN ('Valuo_data', 'KN_parcel_data')
  AND c.name IN ('timestamp', 'listina', 'typ_plochy', 'adresa',
                 'geo_zdroj', 'LAT', 'LON', 'id_UP_FVU_data',
                 'refPoint_x', 'refPoint_y', 'beginLifespanVersion',
                 'geometry')
ORDER BY t.name, c.column_id;
GO

/* Kolik místa zabírá surová geometrie z katastru. Je to text
   ve formátu WFS, ze kterého krok 03b spočítal geo_plocha.
   Po reprojekci už ji nic nečte.                             */
SELECT  kontrola = N'surová geometrie z WFS',
        radku = COUNT(*),
        naplneno = SUM(CASE WHEN geometry IS NOT NULL THEN 1 ELSE 0 END),
        MB_textu = CAST(SUM(DATALENGTH(geometry)) / 1048576.0
                        AS decimal(10,1))
FROM dbo.KN_parcel_data;
GO


/* ============================================================
   25.7 JAK JSOU TY SLOUPCE NAPLNĚNÉ
   ============================================================ */

SELECT  tabulka = N'Valuo_data', radku = COUNT(*),
        listina    = SUM(CASE WHEN listina IS NOT NULL
                               AND listina <> '' THEN 1 ELSE 0 END),
        typ_plochy = SUM(CASE WHEN typ_plochy IS NOT NULL
                               AND typ_plochy <> '' THEN 1 ELSE 0 END),
        adresa     = SUM(CASE WHEN adresa IS NOT NULL
                               AND adresa <> '' THEN 1 ELSE 0 END),
        LAT        = SUM(CASE WHEN LAT IS NOT NULL THEN 1 ELSE 0 END)
FROM dbo.Valuo_data;
GO

SELECT  tabulka = N'KN_parcel_data', radku = COUNT(*),
        id_UP_FVU  = SUM(CASE WHEN id_UP_FVU_data IS NOT NULL
                              THEN 1 ELSE 0 END),
        refPoint_x = SUM(CASE WHEN refPoint_x IS NOT NULL THEN 1 ELSE 0 END),
        zapsano_od = SUM(CASE WHEN beginLifespanVersion IS NOT NULL
                              THEN 1 ELSE 0 END),
        geometry   = SUM(CASE WHEN geometry IS NOT NULL THEN 1 ELSE 0 END),
        geo_plocha = SUM(CASE WHEN geo_plocha IS NOT NULL THEN 1 ELSE 0 END)
FROM dbo.KN_parcel_data;
GO


/* ============================================================
   25.8 ÚKLID — ODKOMENTUJ, CO CHCEŠ PROVÉST
   ============================================================
   Zálohy z 22. října pokrývají kroky, které jsou hotové a
   ověřené. Záloha z 23g je dnešní, tu bych nechal ještě pár dní.

   DROP TABLE dbo.zaloha_gps_api_20261022;
   DROP TABLE dbo.zaloha_datumy_20261022;
   DROP TABLE dbo.zaloha_duplicity_20261022;
   DROP TABLE dbo.zaloha_valuo_duplicity_20261022;
   DROP TABLE dbo.zaloha_geo_18;
   DROP TABLE dbo.oprava_gps_20261022;

   -- až si budeš jistý krokem 23g:
   -- DROP TABLE dbo.KN_parcel_data_zaloha_23g;

   Starý sloupec územního plánu po kroku 24e už nikdo nečte —
   v_vklad_UP bere data z KN_parcel_UP. Zrušit se dá takto,
   ale počkej, až si ověříš, že na něm nevisí žádný tvůj
   Python skript ani Excel:

   -- ALTER TABLE dbo.KN_parcel_data DROP COLUMN id_UP_FVU_data;
   ============================================================ */
