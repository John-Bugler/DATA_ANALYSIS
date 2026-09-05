USE NetMon;
DECLARE @od DATETIME2 = '2026-08-28T16:00:00';

SELECT r.ConnExternal/50*50 AS BucketVen, COUNT(*) AS Mereni,
       SUM(CASE WHEN m.TcpFail>0 THEN 1 ELSE 0 END) AS SVypadkem,
       CAST(100.0*SUM(CASE WHEN m.TcpFail>0 THEN 1 ELSE 0 END)/COUNT(*) AS DECIMAL(5,1)) AS PctVypadku
FROM dbo.NetMon_Router r
JOIN dbo.vNetMon_Minute m ON r.RunTsUtc >= m.MinuteUtc AND r.RunTsUtc < DATEADD(minute,1,m.MinuteUtc)
WHERE r.ConnExternal IS NOT NULL AND r.RunTsUtc > @od
GROUP BY r.ConnExternal/50*50 ORDER BY BucketVen;