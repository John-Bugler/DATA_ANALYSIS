/* =====================================================================
   netmon_schema.sql  –  MS SQL schéma pro monitoring domácí sítě
   E:\DATA_ANALYSIS\NETMON\netmon_schema.sql

   Spouští se buď:
       python netmon.py --init        (nejjednodušší, nevyžaduje SSMS)
   nebo ručně v SSMS / sqlcmd.

   Skript je IDEMPOTENTNÍ - opakované spuštění nesmaže nasbíraná data.
   ===================================================================== */

IF DB_ID('NetMon') IS NULL
    CREATE DATABASE NetMon;
GO
USE NetMon;
GO

/* ---------- 1) Jednotlivé sondy (dlouhý formát) ---------- */
IF OBJECT_ID('dbo.NetMon_Probe') IS NULL
CREATE TABLE dbo.NetMon_Probe (
    Id          BIGINT IDENTITY(1,1) PRIMARY KEY,
    RunTsUtc    DATETIME2(0)  NOT NULL,   -- začátek cyklu (společný klíč pro celý cyklus)
    ProbeTsUtc  DATETIME2(3)  NOT NULL,   -- přesný čas dokončení sondy
    SourceHost  NVARCHAR(64)  NOT NULL,   -- odkud se měřilo (RYZEN9 / MacBook / QNAP)
    Kind        VARCHAR(12)   NOT NULL,   -- dns | dns_nocache | tcp | ping
    Target      NVARCHAR(128) NOT NULL,   -- co se měřilo
    Ok          BIT           NOT NULL,
    LatencyMs   FLOAT         NULL,
    LossPct     FLOAT         NULL,       -- jen pro ping
    Detail      NVARCHAR(400) NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Probe_Run' AND object_id=OBJECT_ID('dbo.NetMon_Probe'))
    CREATE INDEX IX_Probe_Run ON dbo.NetMon_Probe (RunTsUtc) INCLUDE (Kind, Ok, LatencyMs);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Probe_Fail' AND object_id=OBJECT_ID('dbo.NetMon_Probe'))
    CREATE INDEX IX_Probe_Fail ON dbo.NetMon_Probe (Ok, RunTsUtc) WHERE Ok = 0;
GO

/* ---------- 2) Stav routeru RB5009 (jeden řádek na cyklus) ---------- */
IF OBJECT_ID('dbo.NetMon_Router') IS NULL
CREATE TABLE dbo.NetMon_Router (
    RunTsUtc        DATETIME2(0) NOT NULL PRIMARY KEY,
    Reachable       BIT          NOT NULL,
    ConnTotal       INT          NULL,   -- total-entries z connection tracking
    ConnMax         INT          NULL,   -- max-entries
    CpuLoad         INT          NULL,
    FreeMemory      BIGINT       NULL,
    Uptime          NVARCHAR(32) NULL,
    Ether1Running   BIT          NULL,
    Ether1LinkDowns INT          NULL,
    Ether1RxByte    BIGINT       NULL,
    Ether1TxByte    BIGINT       NULL,
    DhcpStatus      NVARCHAR(32) NULL,
    DhcpExpires     NVARCHAR(32) NULL,
    Error           NVARCHAR(300) NULL
);
GO

/* ---------- 3) Minutový přehled – hlavní analytický pohled ---------- */
IF OBJECT_ID('dbo.vNetMon_Minute') IS NOT NULL DROP VIEW dbo.vNetMon_Minute;
GO
CREATE VIEW dbo.vNetMon_Minute AS
SELECT
    DATEADD(minute, DATEDIFF(minute, 0, p.RunTsUtc), 0)                    AS MinuteUtc,
    p.SourceHost,
    SUM(CASE WHEN p.Kind LIKE 'dns%' AND p.Ok = 0 THEN 1 ELSE 0 END)       AS DnsFail,
    SUM(CASE WHEN p.Kind LIKE 'dns%' THEN 1 ELSE 0 END)                    AS DnsTotal,
    AVG(CASE WHEN p.Kind LIKE 'dns%' AND p.Ok = 1 THEN p.LatencyMs END)    AS DnsAvgMs,
    SUM(CASE WHEN p.Kind = 'tcp' AND p.Ok = 0 THEN 1 ELSE 0 END)           AS TcpFail,
    SUM(CASE WHEN p.Kind = 'tcp' THEN 1 ELSE 0 END)                        AS TcpTotal,
    AVG(CASE WHEN p.Kind = 'tcp' AND p.Ok = 1 THEN p.LatencyMs END)        AS TcpAvgMs,
    MAX(CASE WHEN p.Target = '192.168.88.1'  THEN p.LossPct END)           AS LossRouter,
    MAX(CASE WHEN p.Target = '192.168.11.1'  THEN p.LossPct END)           AS LossUpstream,
    MAX(CASE WHEN p.Target = '8.8.8.8'       THEN p.LossPct END)           AS LossInternet
FROM dbo.NetMon_Probe p
GROUP BY DATEADD(minute, DATEDIFF(minute, 0, p.RunTsUtc), 0), p.SourceHost;
GO

/* ---------- 4) Jen minuty, kdy něco selhalo ---------- */
IF OBJECT_ID('dbo.vNetMon_Outage') IS NOT NULL DROP VIEW dbo.vNetMon_Outage;
GO
CREATE VIEW dbo.vNetMon_Outage AS
SELECT m.*, r.ConnTotal, r.CpuLoad, r.DhcpStatus, r.Ether1LinkDowns
FROM dbo.vNetMon_Minute m
LEFT JOIN dbo.NetMon_Router r
       ON r.RunTsUtc >= m.MinuteUtc AND r.RunTsUtc < DATEADD(minute, 1, m.MinuteUtc)
WHERE m.DnsFail > 0 OR m.TcpFail > 0 OR m.LossInternet > 0 OR m.LossUpstream > 0;
GO

/* =====================================================================
   UŽITEČNÉ DOTAZY (kopírovat do SSMS)
   ===================================================================== */

-- a) Které minuty byly "špatné" a co v nich selhalo
-- SELECT TOP 200 * FROM dbo.vNetMon_Outage
-- WHERE MinuteUtc > DATEADD(hour,-24,SYSUTCDATETIME()) ORDER BY MinuteUtc;

-- b) Detail konkrétní minuty
-- SELECT ProbeTsUtc, Kind, Target, Ok, LatencyMs, LossPct, Detail
-- FROM dbo.NetMon_Probe
-- WHERE RunTsUtc BETWEEN '2026-08-26T18:00:00' AND '2026-08-26T18:12:00'
-- ORDER BY ProbeTsUtc, Kind, Target;

-- c) KLÍČOVÝ TEST: koreluje selhání TCP s počtem spojení na routeru?
-- SELECT r.ConnTotal/100*100 AS ConnBucket, COUNT(*) AS Minut,
--        SUM(CASE WHEN m.TcpFail>0 THEN 1 ELSE 0 END) AS MinutSVypadkem
-- FROM dbo.vNetMon_Minute m
-- JOIN dbo.NetMon_Router r ON r.RunTsUtc >= m.MinuteUtc AND r.RunTsUtc < DATEADD(minute,1,m.MinuteUtc)
-- GROUP BY r.ConnTotal/100*100 ORDER BY ConnBucket;

-- d) Selhává jen port 443, nebo i port 80?
-- SELECT Target, COUNT(*) AS Pokusu, SUM(CASE WHEN Ok=0 THEN 1 ELSE 0 END) AS Selhani,
--        CAST(100.0*SUM(CASE WHEN Ok=0 THEN 1 ELSE 0 END)/COUNT(*) AS DECIMAL(5,2)) AS PctSelhani
-- FROM dbo.NetMon_Probe WHERE Kind='tcp' GROUP BY Target ORDER BY PctSelhani DESC;

-- e) Rozdělení výpadků podle hodiny dne
-- SELECT DATEPART(hour, MinuteUtc) AS Hodina, COUNT(*) AS Minut,
--        SUM(CASE WHEN TcpFail>0 THEN 1 ELSE 0 END) AS MinutSVypadkem
-- FROM dbo.vNetMon_Minute GROUP BY DATEPART(hour, MinuteUtc) ORDER BY Hodina;
