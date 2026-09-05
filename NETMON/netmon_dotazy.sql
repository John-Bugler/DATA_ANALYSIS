/* =====================================================================
   netmon_dotazy.sql  -  analytické dotazy
   Spouštět v SSMS. Každý blok samostatně (označit a F5).
   ===================================================================== */
USE NetMon;
GO

/* ---------------------------------------------------------------------
   DOTAZ A - KDE PŘESNĚ JE PRÁH (spojení mířící VEN)
   Tohle je hlavní výstup. Hledáme hodnotu, od které skokově roste
   podíl minut s výpadkem. Blízkost k 512 = blok portů u CGNAT.
   --------------------------------------------------------------------- */
SELECT r.ConnExternal/50*50 AS BucketVen,
       COUNT(*) AS Mereni,
       SUM(CASE WHEN m.TcpFail > 0 THEN 1 ELSE 0 END) AS SVypadkem,
       CAST(100.0*SUM(CASE WHEN m.TcpFail > 0 THEN 1 ELSE 0 END)/COUNT(*) AS DECIMAL(5,1)) AS PctVypadku
FROM dbo.NetMon_Router r
JOIN dbo.vNetMon_Minute m
     ON r.RunTsUtc >= m.MinuteUtc AND r.RunTsUtc < DATEADD(minute,1,m.MinuteUtc)
WHERE r.ConnExternal IS NOT NULL
GROUP BY r.ConnExternal/50*50
ORDER BY BucketVen;
GO

/* ---------------------------------------------------------------------
   DOTAZ B - KDO DRŽÍ NEJVÍC SPOJENÍ VEN
   --------------------------------------------------------------------- */
SELECT TopSrc,
       COUNT(*) AS Mereni,
       AVG(TopSrcCount) AS PrumerSpojeni,
       MAX(TopSrcCount) AS MaxSpojeni
FROM dbo.NetMon_Router
WHERE TopSrc IS NOT NULL
GROUP BY TopSrc
ORDER BY MaxSpojeni DESC;
GO

/* ---------------------------------------------------------------------
   DOTAZ C - POMĚR VEN vs. LOKÁLNÍ (ověření, o kolik byl práh nadhodnocen)
   --------------------------------------------------------------------- */
SELECT MIN(ConnExternal) AS VenMin, AVG(ConnExternal) AS VenPrumer, MAX(ConnExternal) AS VenMax,
       MIN(ConnLocal)    AS LokMin, AVG(ConnLocal)    AS LokPrumer, MAX(ConnLocal)    AS LokMax,
       AVG(ConnTotal)    AS CelkemPrumer
FROM dbo.NetMon_Router
WHERE ConnExternal IS NOT NULL;
GO

/* ---------------------------------------------------------------------
   DOTAZ D - PŘEHLED SELHÁNÍ PODLE CÍLE (celé měření)
   --------------------------------------------------------------------- */
SELECT Kind, Target,
       COUNT(*) AS Pokusu,
       SUM(CASE WHEN Ok=0 THEN 1 ELSE 0 END) AS Selhani,
       CAST(100.0*SUM(CASE WHEN Ok=0 THEN 1 ELSE 0 END)/COUNT(*) AS DECIMAL(5,2)) AS PctSelhani,
       CAST(AVG(CASE WHEN Ok=1 THEN LatencyMs END) AS DECIMAL(8,1)) AS PrumerMs
FROM dbo.NetMon_Probe
WHERE Kind <> 'dns_nocache'
GROUP BY Kind, Target
ORDER BY PctSelhani DESC;
GO

/* ---------------------------------------------------------------------
   DOTAZ E - MINUTY S VÝPADKEM, v místním čase, s novými sloupci
   --------------------------------------------------------------------- */
SELECT m.MinuteUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Central European Standard Time' AS CasCZ,
       m.TcpFail, m.TcpTotal, m.DnsFail,
       r.ConnTotal, r.ConnExternal, r.TopSrc, r.TopSrcCount, r.CpuLoad
FROM dbo.vNetMon_Minute m
LEFT JOIN dbo.NetMon_Router r
     ON r.RunTsUtc >= m.MinuteUtc AND r.RunTsUtc < DATEADD(minute,1,m.MinuteUtc)
WHERE m.TcpFail > 0
ORDER BY m.MinuteUtc;
GO



USE NetMon;
SELECT DATEPART(hour, RunTsUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Central European Standard Time') AS HodinaCZ,
       AVG(CASE WHEN ConnExternal IS NULL     THEN ConnTotal END) AS PredZmenou,
       AVG(CASE WHEN ConnExternal IS NOT NULL THEN ConnTotal END) AS PoZmene
FROM dbo.NetMon_Router
GROUP BY DATEPART(hour, RunTsUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Central European Standard Time')
ORDER BY HodinaCZ;