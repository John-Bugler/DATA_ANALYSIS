/* ============================================================================
   29b_pamet_prahu.sql — sp_prepocet_prahu spadla na nedostatek paměti

   ============================================================================
   CO SE STALO
   ============================================================================
   Po kroku 28b procedura skončila chybou:

       Msg 701, Level 17 — There is insufficient system memory
       in resource pool 'default' to run this query.

   PŘÍČINA. Mediány se počítají přes PERCENTILE_CONT, což je OKENNÍ
   funkce — drží celý oddíl v paměti najednou. Krok 28b přidal pásmo
   stáří a metriku M3, takže vstupní sada se zdvojnásobila, a u krajské
   úrovně má oddíl pražských bytů přes sedmnáct tisíc řádků.

   Chyba v návrhu kroku 28: změřil se dopad na kvalitu mezí (počet
   skupin, ztráta pokrytí, posun hodnocení), ale ne na paměť.

   DRUHÁ PŘÍČINA, VNĚJŠÍ. Server měl max server memory na výchozí
   hodnotě 2147483647 MB (bez omezení) na stroji s 32 GB fyzické paměti.
   SQL Server si tedy bral, co mohl, a Windows spolu s VS Code,
   prohlížečem a Pythonem nad gigabajtovými XML se praly o zbytek.
   Msg 701 neznamená „došla paměť SQL Serveru", ale „Windows mu další
   nedá".

   ============================================================================
   OPRAVA
   ============================================================================
   1. Omezit serveru paměť (oddíl 29b.1) — vyžaduje sysadmin.
   2. Počítat v cyklu po klasifikacích (oddíl 29b.2). Čtyři průchody nad
      čtvrtinou dat místo jednoho nad celkem; špička paměti klesne zhruba
      na čtvrtinu a VÝSLEDEK JE BITOVĚ STEJNÝ.

   ZVAŽOVÁNO A ZAMÍTNUTO: APPROX_PERCENTILE_CONT ze SQL Serveru 2022 je
   agregační funkce a paměťově nenáročná, ale PŘIBLIŽNÁ s odchylkou
   do 1,3 %. Mediány z Valuo_prahy slouží i jako kontrolní čísla, takže
   je kvůli paměti rozhýbat nechceme.
   ============================================================================ */

USE VALUO;
GO

/* ---------- 29b.1  LIMIT PAMĚTI SERVERU ---------------------------
   16 GB z 32 GB. Druhá polovina zůstane Windows a ostatní práci.
   Projeví se postupně, restart služby není nutný.
   Vyžaduje sysadmin — claude_reader to nesmí.
   ------------------------------------------------------------------- */

EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'max server memory (MB)', 16384; RECONFIGURE;
EXEC sp_configure 'show advanced options', 0; RECONFIGURE;
GO

SELECT name, value_in_use FROM sys.configurations
WHERE name = 'max server memory (MB)';
GO

/* ---------- 29b.2  PROCEDURA ---------------------------------------
   sp_prepocet_prahu je nasazená v databázi. Definici si vyexportuj
   z SSMS do 29c_definice.sql, aby disk odpovídal databázi.

   Podstata změny: tři INSERT bloky (k.ú., okres, kraj) jsou obalené
   cyklem WHILE nad #k, což je seznam klasifikací, a každý blok má
   navíc podmínku `AND klasifikace = @kl`.
   ------------------------------------------------------------------- */


/* ---------- 29b.3  PŘEPOČET A KONTROLA ----------------------------- */

EXEC dbo.sp_prepocet_prahu;
GO

SELECT COUNT(*) AS kombinaci, MAX(datum_vypoctu) AS prepocteno,
       SUM(CASE WHEN pasmo <> '' THEN 1 ELSE 0 END) AS se_starim,
       SUM(CASE WHEN metrika = 'M3' THEN 1 ELSE 0 END) AS metrika_m3
FROM dbo.Valuo_prahy;
GO

/* Stabilita — druhý přepočet musí dát totéž */
IF OBJECT_ID('tempdb..#pred') IS NOT NULL DROP TABLE #pred;
SELECT * INTO #pred FROM dbo.Valuo_prahy;
EXEC dbo.sp_prepocet_prahu;
SELECT  kontrola  = N'stabilita při druhém přepočtu',
        pred      = (SELECT COUNT(*) FROM #pred),
        po        = (SELECT COUNT(*) FROM dbo.Valuo_prahy),
        zmenenych = (SELECT COUNT(*) FROM #pred a
                     JOIN dbo.Valuo_prahy b
                       ON b.klasifikace = a.klasifikace AND b.klic = a.klic
                      AND b.metrika = a.metrika AND b.pasmo = a.pasmo
                      AND b.uroven = a.uroven AND b.uzemi = a.uzemi
                     WHERE ABS(b.median - a.median) > 0.01
                        OR ABS(b.prah_dolni - a.prah_dolni) > 0.01);
DROP TABLE #pred;
GO
