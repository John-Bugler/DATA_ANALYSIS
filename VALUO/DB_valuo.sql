/*
//////////////////////////   TABULKA   ///////////////////////////////
USE VALUO
--  struktura tabulky dle export filu tahanych z valua
Drop table Valuo_data;
Create table Valuo_data
	(
    id INT IDENTITY(1,1) PRIMARY KEY,
	timestamp datetime2(0) default (sysdatetime()), 
    cislo_vkladu VARCHAR(50) NOT NULL,
    datum_podani DATETIME NOT NULL,
    datum_zplatneni DATETIME NOT NULL,
    listina TEXT NOT NULL,
    nemovitost VARCHAR(50) NOT NULL,
    typ VARCHAR(100) NOT NULL,
    adresa VARCHAR(400) NOT NULL,
    cenovy_udaj DECIMAL(18,2) NOT NULL,
    mena VARCHAR(10) NOT NULL,
    plocha DECIMAL(10,2),
    typ_plochy VARCHAR(300),
    popis VARCHAR(800),
    okres VARCHAR(100) NOT NULL,
    kat_uzemi VARCHAR(100) NOT NULL,
    rok INT NOT NULL,
    mesic INT NOT NULL,
	LAT DECIMAL(9,7),
    LON DECIMAL(9,7)
    
	);
//////////////////////////   TABULKA   ///////////////////////////////
*/


/*

UPDATE [valuo].[dbo].[valuo_data] 
SET LAT = NULL, LON = NULL 
WHERE LAT IS not NULL AND LON IS not NULL;

UPDATE [valuo].[dbo].[valuo_data] 
SET GPS_API_info = 'OK' 
WHERE id BETWEEN 1 AND 1705;
*/






-- Deklarace promìnných pro dynamické SQL dotazy


DECLARE @cols NVARCHAR(MAX),       -- Dynamický seznam let pro PIVOT
        @dynSQL NVARCHAR(MAX),     -- Dynamický dotaz s PIVOTem
        @staticSQL NVARCHAR(MAX),  -- Statický dotaz s agregacemi
        @finalSQL NVARCHAR(MAX);   -- Finální dotaz kombinující statická a pivotovaná data

-------------------------------------------------------------
-- 1. Sestavení seznamu unikátních rokù jako názvù sloupcù
-------------------------------------------------------------
-- Použití STRING_AGG pro SQL Server 2017+ nebo starší metodu
IF (SELECT @@VERSION) LIKE '%2017%' OR (SELECT @@VERSION) LIKE '%2019%' OR (SELECT @@VERSION) LIKE '%2022%'
BEGIN
    SELECT @cols = STRING_AGG(QUOTENAME(CAST(rok AS VARCHAR(4))), ',') 
                   WITHIN GROUP (ORDER BY CAST(rok AS INT) DESC)
    FROM (
        SELECT DISTINCT rok 
        FROM [valuo].[dbo].[valuo_data]
        WHERE nemovitost IS NOT NULL   
          AND typ IS NOT NULL          
          AND cenovy_udaj IS NOT NULL  
          AND plocha IS NOT NULL       
          AND LAT IS NOT NULL          
          AND LON IS NOT NULL
    ) t;
END
ELSE -- Pro starší verze SQL Serveru (2016 a níže)
BEGIN
    SELECT @cols = STUFF((
        SELECT ',' + QUOTENAME(CAST(rok AS VARCHAR(4))) 
        FROM (
            SELECT DISTINCT CAST(rok AS INT) AS rok
            FROM [valuo].[dbo].[valuo_data]
            WHERE nemovitost IS NOT NULL   
              AND typ IS NOT NULL          
              AND cenovy_udaj IS NOT NULL  
              AND plocha IS NOT NULL       
              AND LAT IS NOT NULL          
              AND LON IS NOT NULL
        ) t
        ORDER BY rok DESC
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '');
END

-- Kontrola výstupu seznamu sloupcù
PRINT 'Seznam rokù pro PIVOT: ' + @cols;

-------------------------------------------------------------
-- 2. Sestavení dynamického dotazu s PIVOTem
-------------------------------------------------------------
SET @dynSQL = '
SELECT ' + @cols + '
FROM (
    -- Poddotaz: vybíráme rok a cislo_vkladu z tabulky, kde jsou splnìny podmínky
    SELECT CAST(rok AS VARCHAR(4)) AS rok, cislo_vkladu
    FROM [valuo].[dbo].[valuo_data]
    WHERE nemovitost IS NOT NULL    
      AND typ IS NOT NULL           
      AND cenovy_udaj IS NOT NULL   
      AND plocha IS NOT NULL        
      AND LAT IS NOT NULL           
      AND LON IS NOT NULL
) AS src
PIVOT (
    COUNT(cislo_vkladu)
    FOR rok IN (' + @cols + ')
) AS pvt
';

-------------------------------------------------------------
-- 3. Sestavení statického dotazu s pevnými agregacemi
-------------------------------------------------------------
SET @staticSQL = '
SELECT 
  COUNT(DISTINCT CONCAT(kat_uzemi, ''-'', rok, ''-'', mesic)) AS [#souboru],  
  COUNT(cislo_vkladu) AS [#V],  
  COUNT(DISTINCT cislo_vkladu) AS [#V_unique],  
  COUNT(CASE WHEN LAT IS NOT NULL AND LON IS NOT NULL THEN 1 END) AS [#v_YES_GPS],  
  COUNT(CASE WHEN LAT IS NULL AND LON IS NULL THEN 1 END) AS [#v_NO_GPS],  
  COUNT(DISTINCT CONCAT(LAT, ''-'', LON)) AS [#V_GPS_unique],  
  COUNT(CASE WHEN GPS_API_info = ''ERR'' THEN 1 END) AS [#GPS_API_ERR],  
  COUNT(CASE WHEN adresa <> ''Neznámá adresa'' THEN 1 END) AS [#adresa],  
  COUNT(DISTINCT CASE WHEN adresa <> ''Neznámá adresa'' THEN adresa END) AS [#adresa_unique],  
  COUNT(CASE WHEN adresa = ''Neznámá adresa'' THEN 1 END) AS [#adresa_neznama],  
  COUNT(DISTINCT okres) AS [#okresu],  
  COUNT(DISTINCT CONCAT(okres, ''-'', kat_uzemi)) AS [#kat_uzemi],  
  COUNT(CASE WHEN nemovitost = ''budova'' THEN 1 END) AS [#BUDOVA],  
  COUNT(CASE WHEN nemovitost = ''jednotka'' THEN 1 END) AS [#JEDNOTKA],  
  COUNT(CASE WHEN nemovitost = ''parcela'' THEN 1 END) AS [#PARCELA],  

  COUNT(CASE WHEN KN_WFS_info = 1 THEN 1 END) AS [#WFS_1],
  COUNT(CASE WHEN KN_WFS_info = 0 THEN 1 END) AS [#WFS_0],

  COUNT(CASE WHEN typ = ''rodinný dùm'' THEN 1 END) AS [#RD],  
  COUNT(CASE WHEN typ = ''byt'' THEN 1 END) AS [#byt],  
  COUNT(CASE WHEN typ = ''ateliér'' THEN 1 END) AS [#atelier],  
  COUNT(CASE WHEN typ = ''garáž'' THEN 1 END) AS [#garáž]
FROM [valuo].[dbo].[valuo_data]
';

-------------------------------------------------------------
-- 4. Sestavení finálního dotazu, který spojuje statická data a pivot data
-------------------------------------------------------------
SET @finalSQL = '
WITH StaticData AS (
' + @staticSQL + '
),
PivotData AS (
' + @dynSQL + '
)
SELECT s.*, p.*
FROM StaticData s
CROSS JOIN PivotData p;
';

-------------------------------------------------------------
-- 5. Spuštìní finálního dotazu
-------------------------------------------------------------
EXEC sp_executesql @finalSQL;



select 
-- ////////////////////////////////////////      prehled po okresech, kat_uzemi, letech, mesicich
     okres,
     kat_uzemi,
     rok,
     mesic,
     count(cislo_vkladu) as [#v],  -- celkový poèet záznamù
     count(case when lat is not null and lon is not null then 1 end) as [#v_gps],  -- poèet záznamù s gps
     (select count(*) 
      from (
          select distinct lat, lon  
          from valuo_data v
          where v.kat_uzemi = vd.kat_uzemi 
            and v.rok = vd.rok 
            and v.mesic = vd.mesic
            and v.lat is not null 
            and v.lon is not null
      ) as gps_unique
     ) as [#v_gps_unique],  -- poèet unikátních gps souøadnic pro danou skupinu

     count(case when nemovitost = 'budova' then 1 end) as [budova],  -- poèet budov
     count(case when nemovitost = 'jednotka' then 1 end) as [jednotka],  -- poèet jednotek
     count(case when nemovitost = 'parcela' then 1 end) as [parcela]  -- poèet parcel
from [valuo].[dbo].[valuo_data] vd
where 1=1
      and kat_uzemi = 'Modøany'
group by
     okres,
     kat_uzemi,
     rok,
     mesic
order by okres, kat_uzemi, rok, mesic desc;
-- ////////////////////////////////////////      prehled po okresech, kat_uzemi, letech, mesicich





--  ///////////////////////////////////////      POZEMKY / JC        ///////////////////////////////////////


DECLARE @KU NVARCHAR(MAX) = 'Kunratice,Písnice,Krè,Michle,Nusle';
DECLARE @UP NVARCHAR(MAX) = 'DH,DU,ZMK,IZ,S1,S2,S3,S4';
DECLARE @JC_MIN float = 999;
DECLARE @JC_MAX float = 15000;

WITH AgregovanaData AS (
  SELECT 
    cislo_vkladu,
    COUNT(*) AS [#PARCEL],
    SUM(plocha) AS [#CELKOVA_VYMERA],
    MIN(cenovy_udaj) AS cenovy_udaj  -- pøedpokládáme, že cenovy_udaj je u všech stejný
  FROM [valuo].[dbo].[Valuo_data]
  WHERE 
    kat_uzemi IN (
      SELECT LTRIM(RTRIM(value))
      FROM STRING_SPLIT(@KU, ',')
    )
    AND cislo_vkladu IN (
      SELECT cislo_vkladu
      FROM [valuo].[dbo].[Valuo_data]
      WHERE 
        kat_uzemi IN (
          SELECT LTRIM(RTRIM(value))
          FROM STRING_SPLIT(@KU, ',')
        )
      GROUP BY cislo_vkladu
      HAVING COUNT(*) = SUM(CASE WHEN nemovitost = 'parcela' THEN 1 ELSE 0 END)
    )
  GROUP BY cislo_vkladu
)

SELECT 
  vd.*,
  kn.parcel_number,
  kn.kat_uzemi AS kn_kat_uzemi,
  kn.zoning_title,
  ad.[#PARCEL],
  ad.[#CELKOVA_VYMERA],
  CONVERT(DECIMAL(10,1), ROUND((ad.cenovy_udaj / NULLIF(ad.[#CELKOVA_VYMERA], 0)), 1, 1)) AS [#JC],
  up.POPIS_Z
FROM [valuo].[dbo].[Valuo_data] vd
JOIN AgregovanaData ad ON vd.cislo_vkladu = ad.cislo_vkladu
LEFT JOIN [valuo].[dbo].[KN_parcel_data] kn ON vd.id = kn.id_valuo
LEFT JOIN [valuo].[dbo].[UP_FVU_data] up ON kn.id_UP_FVU_data = up.id

WHERE 
  CONVERT(DECIMAL(10,1), ROUND((ad.cenovy_udaj / NULLIF(ad.[#CELKOVA_VYMERA], 0)), 1, 1)) > @JC_MIN 
  AND CONVERT(DECIMAL(10,1), ROUND((ad.cenovy_udaj / NULLIF(ad.[#CELKOVA_VYMERA], 0)), 1, 1)) < @JC_MAX 

  AND vd.kat_uzemi IN (
    SELECT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(@KU, ',')
  )
  AND (
    up.POPIS_Z IS NOT NULL AND EXISTS (
      SELECT 1
      FROM STRING_SPLIT(@UP, ',') s
      WHERE up.POPIS_Z LIKE '%' + LTRIM(RTRIM(s.value)) + '%'
    )
  )
ORDER BY [#JC] DESC;


--  ///////////////////////////////////////      POZEMKY / JC        ///////////////////////////////////////




select distinct typ from [dbo].[Valuo_data]
where nemovitost = 'budova'



--select * from [dbo].[KN_parcel_data]

/*
select * from [valuo].[dbo].[Valuo_data] 
where 1=1
      and id = 1077
	  and LAT is NULL and LON is NULL
	  and adresa <> 'Neznámá adresa'

*/

/*
 SELECT id AS id_valuo, typ, LAT, LON, adresa, popis
    FROM [valuo].[dbo].[Valuo_data] 
    WHERE 1=1 
	  AND nemovitost = 'parcela'
      AND adresa <> 'Neznámá adresa'
      AND KN_WFS_info IS NULL

*/

                    

SELECT id AS id_valuo, KN_WFS_info, nemovitost, okres, v.kat_uzemi, adresa, popis, kn.* 
FROM Valuo_data v
left join KN_parcel_data kn on v.id = kn.id_valuo
WHERE 1=1
      --and KN_WFS_info = 0
	  and id in (23, 37, 45, 117, 160, 165, 173, 188, 204, 208, 5998, 7763, 12676)
                ORDER BY V.id ASC



/*
DELETE from dbo.KN_parcel_data
where id_valuo  in (23, 37, 45, 117, 160, 165, 173, 188, 204, 208, 5998, 7763, 12676)

UPDATE [valuo].[dbo].[Valuo_data]
SET
	KN_WFS_info = NULL
WHERE
    Id in (23, 37, 45, 117, 160, 165, 173, 188, 204, 208, 5998, 7763, 12676)

*/

select distinct popis from [valuo].[dbo].[Valuo_data] 
where 1=1
        and nemovitost = 'budova'



select * from [valuo].[dbo].[Valuo_data] 
where 1=1
	  and KN_WFS_info = 0
      and nemovitost = 'budova'
      --and nemovitost = 'parcela'
      --and popis like '%parcele%'
	  --and typ = 'byt'
	  --and kat_uzemi = 'Modøany'
	  --and plocha = 357
	  --and cislo_vkladu = 'V-10050/2025-101'


select * from [valuo].[dbo].[KN_parcel_data]
where 1=1
      and id_valuo = 20783

select * from [dbo].[UP_FVU_data]

/*
UPDATE [valuo].[dbo].[Valuo_data]
SET
    --LAT = 50.0460758,         -- nová hodnota LAT
    --LON = 14.3296703,          -- nová hodnota LON
	--adresa = 'Bronzová 2018/17'
	-- plocha = 74.0
	--cenovy_udaj = 7750000
	KN_WFS_info = NULL
WHERE
    Id in (47687);             -- identifikátor øádku, který chcete upravit




*/