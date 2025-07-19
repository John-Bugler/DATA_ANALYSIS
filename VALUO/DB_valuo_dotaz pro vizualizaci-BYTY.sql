-- Definice vstupních parametrù
DECLARE @byt_price_lower INT = 2500000;
DECLARE @byt_price_upper INT = 30000000;
DECLARE @byt_area_lower DECIMAL(10,2) = 15;
DECLARE @byt_area_upper DECIMAL(10,2) = 300;

-- Parametry pro jednotkovou cenu (JC)
DECLARE @byt_jc_lower DECIMAL(18,2) = 50000;    -- minimální JC
DECLARE @byt_jc_upper DECIMAL(18,2) = 250000;   -- maximální JC

-- Parametr pro okres
DECLARE @byt_okres NVARCHAR(50) = '%';
-- DECLARE @byt_okres NVARCHAR(50) = 'Hlavní mìsto Praha';

---------------------------------------------------------------------------
-- Krok 1: Vytvoøení podmnožiny dat dle ceny a plochy
---------------------------------------------------------------------------
WITH initial AS (
    SELECT
        cislo_vkladu,
        MAX(CAST(listina AS VARCHAR(MAX)))          AS listina,
        MAX(datum_podani)                           AS datum_podani,
        MAX(rok)                                    AS rok,
        MAX(mesic)                                  AS mesic,
        MAX(okres)                                  AS okres,
        MAX(kat_uzemi)                              AS kat_uzemi,
        MAX(CAST(adresa AS VARCHAR(MAX)))           AS adresa,
        MAX(LAT)                                    AS LAT,
        MAX(LON)                                    AS LON,
        MAX(mena)                                   AS mena,
        FLOOR(MAX(cenovy_udaj))                     AS cenovy_udaj,
        COUNT(*)                                    AS [#_NEMOVITOSTI],
        SUM(CASE WHEN typ = 'byt' THEN 1 ELSE 0 END) AS [#_byt],
        ROUND(SUM(CASE WHEN typ = 'byt' THEN plocha ELSE 0 END), 2) AS A_byt,
        'byt'                                       AS TYP,
        '[m2]'                                      AS MJ,
        ROUND(SUM(CASE WHEN typ = 'byt' THEN plocha ELSE 0 END), 2) AS POCET_MJ,
        -- Výpoèet jednotkové ceny jako desetinná hodnota
        MAX(cenovy_udaj)*1.0 / NULLIF(SUM(CASE WHEN typ = 'byt' THEN plocha ELSE 0 END), 0) AS JC_val
    FROM [valuo].[dbo].[valuo_data]
    WHERE typ = 'byt'
      AND okres like @byt_okres
      AND LAT IS NOT NULL
      AND LON IS NOT NULL
    GROUP BY cislo_vkladu
    HAVING 
         COUNT(*) = 1
      AND MIN(cenovy_udaj) >= @byt_price_lower
      AND MAX(cenovy_udaj) <= @byt_price_upper
      AND MIN(plocha)      >= @byt_area_lower
      AND MAX(plocha)      <= @byt_area_upper
)

---------------------------------------------------------------------------
-- Krok 2: Filtrace dle JC a øazení výsledkù sestupnì podle JC
---------------------------------------------------------------------------
SELECT 
    
    m.cislo_vkladu,
    m.listina,
    m.datum_podani,
    m.rok,
    m.mesic,
    m.okres,
    m.kat_uzemi,
    m.adresa,
    m.LAT,
    m.LON,
    m.mena,
    m.cenovy_udaj,
    m.[#_NEMOVITOSTI],
    m.[#_byt],
    m.A_byt,
    m.TYP,
    m.MJ,
    m.POCET_MJ,
    -- Zaokrouhlená JC pro výstup
    CAST(ROUND(m.JC_val, 0) AS INT) AS JC,
    -- Concatenované sloupce
    STUFF(
        (SELECT ' || ' + ISNULL(t.typ_plochy, '')
         FROM [valuo].[dbo].[valuo_data] t
         WHERE t.cislo_vkladu = m.cislo_vkladu
         FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 4, ''
    ) AS typ_plochy,
    STUFF(
        (SELECT ' || ' + ISNULL(t.popis, '')
         FROM [valuo].[dbo].[valuo_data] t
         WHERE t.cislo_vkladu = m.cislo_vkladu
         FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 4, ''
    ) AS popis
FROM initial m
-- Filtrace dle JC na základì vypoètené hodnoty bez zaokrouhlení
WHERE m.JC_val BETWEEN @byt_jc_lower AND @byt_jc_upper
ORDER BY m.JC_val DESC;






