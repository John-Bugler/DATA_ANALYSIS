/* =====================================================================
   netmon_alter_v2.sql
   Rozšíří tabulku NetMon_Router o rozbor spojení.
   Spustit JEDNOU v SSMS. Existující data zůstávají, nové sloupce
   budou u starých řádků NULL.
   ===================================================================== */
USE NetMon;
GO

IF COL_LENGTH('dbo.NetMon_Router','ConnExternal') IS NULL
    ALTER TABLE dbo.NetMon_Router ADD
        ConnExternal INT NULL,           -- spojení mířící VEN = spotřeba portů u operátora
        ConnLocal    INT NULL,           -- spojení uvnitř lokálních sítí
        TopSrc       NVARCHAR(48) NULL,  -- IP zařízení s nejvíce spojeními ven
        TopSrcCount  INT NULL;           -- kolik jich drží
GO

PRINT 'Sloupce přidány. Nyní restartovat netmon.py.';
GO
