WITH ValidValuo AS (
    SELECT *
    FROM dbo.Valuo_data
    WHERE cislo_vkladu IN (
        SELECT cislo_vkladu
        FROM dbo.Valuo_data
        GROUP BY cislo_vkladu
        HAVING 
            SUM(CASE WHEN nemovitost = 'budova' AND typ IN (
                'rodinný dùm', 'objekt k bydlení', 'zemìdìlská usedlost') THEN 1 ELSE 0 END) = 1
            AND SUM(CASE WHEN nemovitost = 'budova' AND typ NOT IN (
                'rodinný dùm', 'objekt k bydlení', 'zemìdìlská usedlost', 'garáž', 'jiná stavba') THEN 1 ELSE 0 END) = 0
            AND SUM(CASE WHEN nemovitost = 'parcela' THEN 1 ELSE 0 END) >= 1
            AND SUM(CASE WHEN GPS_API_info = 'ERR' THEN 1 ELSE 0 END) = 0
    )
),
NemovitostTypCounts AS (
    SELECT
        cislo_vkladu,
        COUNT(*) AS NemovitostCount,
        SUM(CASE WHEN nemovitost = 'budova' THEN 1 ELSE 0 END) AS BudovaCount,
        SUM(CASE WHEN nemovitost = 'parcela' THEN 1 ELSE 0 END) AS ParcelaCount
    FROM dbo.Valuo_data
    GROUP BY cislo_vkladu
),
FC_Identifikace AS (
    SELECT cislo_vkladu,
           DENSE_RANK() OVER (ORDER BY cislo_vkladu) AS id_fc
    FROM (SELECT DISTINCT cislo_vkladu FROM ValidValuo) AS sub
)
SELECT 
    FC.id_fc,
    V.*,
    K.kat_uzemi,
    K.upper_zoning_id,
    K.parcel_number,
    K.gml_id,
    K.areaValue_m2,
    K.beginLifespanVersion,
    K.endLifespanVersion,
    K.geometry,
    K.inspire_localId,
    K.inspire_namespace,
    K.label,
    K.nationalCadastralReference,
    K.refPoint_x,
    K.refPoint_y,
    K.refPoint_lon,
    K.refPoint_lat,
    K.validFrom,
    K.administrativeUnit_href,
    K.administrativeUnit_title,
    K.zoning_href,
    K.zoning_title,
    K.id_valuo,

    -- Výpoèet JC jen pro hlavní budovu
    CASE 
        WHEN V.nemovitost = 'budova' AND V.typ IN ('rodinný dùm', 'objekt k bydlení', 'zemìdìlská usedlost')
        THEN CAST(ROUND(V.cenovy_udaj / NULLIF(V.plocha, 0), 0) AS DECIMAL(38,0))
        ELSE NULL
    END AS JC,

    TC.NemovitostCount AS [#NEM],
    TC.BudovaCount AS [#BUDOVA],
    TC.ParcelaCount AS [#PARCELA]

FROM ValidValuo AS V
LEFT JOIN dbo.KN_parcel_data AS K ON K.id_valuo = V.id
LEFT JOIN NemovitostTypCounts AS TC ON TC.cislo_vkladu = V.cislo_vkladu
LEFT JOIN FC_Identifikace AS FC ON FC.cislo_vkladu = V.cislo_vkladu
ORDER BY id_fc ASC
