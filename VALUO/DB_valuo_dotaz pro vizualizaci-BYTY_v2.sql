

WITH ValidValuo AS (
    SELECT *
    FROM dbo.Valuo_data
    WHERE cislo_vkladu IN (
        SELECT cislo_vkladu
        FROM dbo.Valuo_data
        GROUP BY cislo_vkladu
        HAVING COUNT(*) = 1
           AND MAX(typ) = 'byt'
    )
)
SELECT 
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
    CAST(
         ROUND(V.cenovy_udaj / NULLIF(SUM(V.plocha) OVER (PARTITION BY V.cislo_vkladu), 0), 0)
         AS DECIMAL(38,0)
    ) AS JC
FROM ValidValuo AS V
LEFT JOIN dbo.KN_parcel_data AS K
    ON K.id_valuo = V.id
WHERE 1 = 1
  AND V.plocha <> 0
  AND V.cenovy_udaj <> 0
  --AND cislo_vkladu = 'V-11359/2024-101'
  AND V.kat_uzemi = 'Dejvice'