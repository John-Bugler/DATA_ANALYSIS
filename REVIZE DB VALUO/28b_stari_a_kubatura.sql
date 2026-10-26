/* ============================================================================
   28b_stari_a_kubatura.sql — stáří stavby do mezí, porovnání přes kubaturu

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.

   Většina tohoto skriptu je už v databázi nasazená (Claude ji spustil
   23. 10. 2026 večer). Zbývá poslední krok, oddíl 28b.5 — přepočet mezí.
   Ten se nevejde do časového limitu nástroje, kterým se Claude připojuje,
   a musí se pustit odtud.

   Skript je bezpečné pustit celý znovu; všechno je CREATE OR ALTER.

   ============================================================================
   CO SE MĚNÍ
   ============================================================================
   1. Meze se nově hledají i podle stáří stavby. Pořadí propadávání:
          k.ú.+stáří → k.ú. → okres+stáří → okres → kraj+stáří → kraj
      Dnešní stav je tím podlahou — kde na jemnější mez nejsou data,
      vezme se tatáž mez jako dosud. Nic se nemůže zhoršit.

      Měřeno předem: u pražských bytů se počet použitelných skupin na
      úrovni k.ú. zvedl ze 44 na 109 a ztráta pokrytí byla 3,4 %;
      u rodinných domů na úrovni kraje ze 7 na 15 při ztrátě 7,0 %.
      Ztracené vklady propadnou o úroveň výš, mez tedy neztratí.

   2. Přibyla metrika M3 — cena vkladu dělená obestavěným prostorem.
      Je PARALELNÍ: do hodnoceni_ceny nevstupuje, slouží k porovnání
      budov přes kubaturu. Sloupce jedn_cena_Kc_m3, median_Kc_m3,
      mez_m3_zdola, mez_m3_shora, bodu_v_mezi_m3, uroven_meze_m3.

   3. v_Valuo_vzorek_q dostal údaje z RÚIAN vedle vlastních, nikoli
      místo nich — rok dokončení, pásmo, konstrukci, výtah, vytápění,
      obestavěný prostor a poměr věrohodnosti podlahové plochy.

   ============================================================================
   DVĚ ROZHODNUTÍ, KTERÁ STOJÍ ZA ZAPSÁNÍ
   ============================================================================
   PÁSMO JEN U STAVEB. Klasifikace JC_PARCELY pásmo nedostane, i když
   na pozemku stavba stojí — stáří cizí stavby o ceně pozemku nevypovídá
   a jen by drobilo skupiny. Pohled i procedura to omezují shodně; kdyby
   se obě místa rozešla, nenašla by se žádná mez a všechno by spadlo
   do „bez srovnání".

   MATERIALIZACE. v_RUIAN_vzorek agreguje přes 557 tisíc stavebních
   objektů a v_Valuo_vzorek_q je sám na hranici 60 s. Připojit jeden
   k druhému by ho přes hranici přetlačilo, proto je RÚIAN vzorek
   materializovaný do tabulky RUIAN_vzorek, kterou plní procedura
   sp_prepocet_ruian_vzorku. Pohled v_RUIAN_vzorek zůstává jako
   referenční definice.

   POZOR NA TRUNCATE. V proceduře je záměrně DELETE, ne TRUNCATE.
   TRUNCATE potřebuje výhradní zámek tabulky a v krátkém spojení kvůli
   tomu celá procedura spadne na timeout.

   ============================================================================
   POŘADÍ SPOUŠTĚNÍ PO KAŽDÉM IMPORTU
   ============================================================================
       EXEC dbo.sp_prepocet_jednotkovych_cen;
       EXEC dbo.sp_prepocet_typu_prevodu;
       EXEC dbo.sp_prepocet_men;
       EXEC dbo.sp_detekce_hromadnych_prevodu;
       EXEC dbo.sp_prepocet_ruian_vzorku;    -- NOVÉ, před prahy
       EXEC dbo.sp_prepocet_prahu;
   ============================================================================ */

USE VALUO;
GO
SET NOCOUNT ON;
GO

/* ---------- 28b.5  PŘEPOČET — TOHLE JE TEN ZBÝVAJÍCÍ KROK ---------- */

EXEC dbo.sp_prepocet_ruian_vzorku;
GO

EXEC dbo.sp_prepocet_prahu;
GO


/* ---------- 28b.6  CO SE ZMĚNILO ---------------------------------- */

/* Kolik mezí vzniklo a kolik z nich je se stářím */
SELECT metrika,
       CASE WHEN pasmo = '' THEN N'bez stáří' ELSE N'se stářím' END AS druh_meze,
       uroven, COUNT(*) AS kombinaci, SUM(n) AS bodu
FROM dbo.Valuo_prahy
GROUP BY metrika, CASE WHEN pasmo = '' THEN N'bez stáří' ELSE N'se stářím' END, uroven
ORDER BY metrika, druh_meze, uroven;
GO

/* Hodnocení před a po. Před krokem 28b (23. 10. 2026):
       bez výhrad 25 300, nelze porovnat 10 314, pod mezí 3 457,
       chybí podlahová plocha 2 081, podíl nebo symbolický převod 1 563,
       bez JC 1 256, bez srovnání 1 142, hromadný převod 866,
       podíl na budově 521, oddělené vlastnictví 509, nad mezí 482,
       nestandardní převod 320, symbolická cena 254, cizí měna 1      */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO

/* Odkud meze pocházejí — kolik vkladů dostalo jemnější mez se stářím */
SELECT uroven_meze,
       CASE WHEN pasmo_meze = N'' THEN N'bez stáří' ELSE N'se stářím' END AS druh_meze,
       COUNT(*) AS vkladu,
       MIN(bodu_v_mezi) AS nejmene_bodu,
       CAST(AVG(CAST(bodu_v_mezi AS float)) AS int) AS prumer_bodu
FROM dbo.v_Valuo_vzorek_q
WHERE uroven_meze IS NOT NULL
GROUP BY uroven_meze, CASE WHEN pasmo_meze = N'' THEN N'bez stáří' ELSE N'se stářím' END
ORDER BY uroven_meze, druh_meze;
GO

/* Porovnání se zálohou z kroku 28 — co se u starých kombinací posunulo */
SELECT  kontrola      = N'posun mezí proti stavu před krokem 28b',
        pred          = (SELECT COUNT(*) FROM dbo.zaloha_prahy_pred_28),
        po_bez_stari  = (SELECT COUNT(*) FROM dbo.Valuo_prahy WHERE pasmo = ''),
        po_se_starim  = (SELECT COUNT(*) FROM dbo.Valuo_prahy WHERE pasmo <> ''),
        zmenenych     = (SELECT COUNT(*) FROM dbo.zaloha_prahy_pred_28 a
                         JOIN dbo.Valuo_prahy b
                           ON b.klasifikace = a.klasifikace AND b.klic = a.klic
                          AND b.metrika = a.metrika AND b.uroven = a.uroven
                          AND b.uzemi = a.uzemi AND b.pasmo = ''
                         WHERE ABS(b.median - a.median) > 0.01),
        zmizelych     = (SELECT COUNT(*) FROM dbo.zaloha_prahy_pred_28 a
                         WHERE NOT EXISTS (SELECT 1 FROM dbo.Valuo_prahy b
                           WHERE b.klasifikace = a.klasifikace AND b.klic = a.klic
                             AND b.metrika = a.metrika AND b.uroven = a.uroven
                             AND b.uzemi = a.uzemi AND b.pasmo = ''));
GO

/* Stabilita — druhý přepočet musí dát totéž, jinak se meze stahují */
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
                        OR ABS(b.prah_dolni - a.prah_dolni) > 0.01
                        OR ABS(b.prah_horni - a.prah_horni) > 0.01);
DROP TABLE #pred;
GO

/* Pražské byty podle stáří — kontrolní vzorek, čísla musí dávat smysl */
SELECT uzemi, pasmo, n,
       CAST(median AS decimal(12,0))     AS median,
       CAST(prah_dolni AS decimal(12,0)) AS zdola,
       CAST(prah_horni AS decimal(12,0)) AS shora
FROM dbo.Valuo_prahy
WHERE klasifikace = 'JC_JEDNOTKA' AND klic = N'DRUH:byt'
  AND uroven = N'k.ú.' AND pasmo <> ''
ORDER BY uzemi, pasmo;
GO

/* Kubatura — nová metrika */
SELECT uroven, uzemi, pasmo, klic, n,
       CAST(median AS decimal(12,0))     AS median_Kc_m3,
       CAST(prah_dolni AS decimal(12,0)) AS zdola,
       CAST(prah_horni AS decimal(12,0)) AS shora
FROM dbo.Valuo_prahy WHERE metrika = 'M3'
ORDER BY n DESC;
GO
