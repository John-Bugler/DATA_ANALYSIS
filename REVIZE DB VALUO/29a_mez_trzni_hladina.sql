/* ============================================================================
   29a_mez_trzni_hladina.sql — záchytná mez vztažená ke kraji

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Všechno v tomto skriptu je už v databázi nasazené (23. 10. 2026 večer).
   Skript je záznam a dá se pustit znovu — je idempotentní.

   ============================================================================
   PROČ
   ============================================================================
   Detektory hromadných převodů (kroky 23 a 29) hledají STRUKTURU
   transakce: opakovanou cenu u více vkladů. Zachytí tím hodně, ale ne
   všechno — privatizace roztříštěná do skupin po dvou až čtyřech
   vkladech jim propadne.

   Znalec na to řekl podstatnou věc: že byt v Praze za 5 000 Kč/m² není
   tržní prodej, je ZJIŠTĚNÍ, ne hypotéza. K vyřazení z mediánu to stačí
   samo o sobě; druh převodu je až popis do posudku.

   Z toho plyne přímé pravidlo na ceně. Lokální mez z Valuo_prahy ho
   udělat nemůže — v zamořeném území si ji převody stáhnou pod sebe
   (Stodůlky měly mez_zdola 645 Kč/m²). Krajský medián ale kontaminace
   neunese: pražské byty mají 17 409 vkladů a medián 127 013 Kč/m²,
   pár tisíc privatizací s ním nehne.

   ============================================================================
   KDE SE VZALA HRANICE 30 %
   ============================================================================
   Z dat, ne z odhadu. Pražské byty od 2022, tehdy „bez výhrad":

       do 10 tis.      91
       10-20 tis.      20
       20-30 tis.       8
       30-40 tis.       5     <- prázdná zóna
       40-50 tis.      40
       50-60 tis.      59
       60-80 tis.     304
       nad 80 tis.  13 904

   Mezi 20 a 40 tisíci je prakticky prázdno: třináct vkladů z téměř
   čtrnácti tisíc. Pod ní privatizace a podíly, nad ní souvislý trh.
   30 % krajského mediánu dává 38 104 Kč/m², tedy doprostřed mezery.

   Kontrola proti trhu (CenaOdhad.cz, realizované ceny z katastru,
   duben-září 2026): medián Prahy 152 000 Kč/m², nejlevnější městská
   část Praha 10 se 131 000, nejlevnější čtvrť Hostivař 123 000.
   Hranice 38 104 je tedy hluboko pod čímkoli reálným.

   VÝHODA PROTI PEVNÉ ČÁSTCE: krajský medián se každým přepočtem posouvá
   s trhem, takže se hranice drží sama. V Liberci vychází 13 660, v Praze
   38 104 — škáluje se podle kraje i druhu.

   ============================================================================
   DVOUSTUPŇOVÝ PARAMETR
   ============================================================================
   CIS_prahy_ceny.mez_vuci_kraji     výchozí podle KLASIFIKACE
   CIS_metrika_ceny.mez_vuci_kraji   přepis podle DRUHU; 0 = neuplatňovat

   POZEMKY JSOU VYNECHANÉ (NULL). Cena pozemku téhož druhu se uvnitř
   kraje legitimně liší i desetinásobně — 30 % by tam vyřadilo 13 %
   vzorku. Pro pozemky slouží CIS_mez_podilu na celkové ceně vkladu.

   JINÝ NEBYTOVÝ PROSTOR MÁ NULU. Podle znalce jsou v Praze komerční
   prostory podle lokality a stavu za 50-120 tis. Kč/m², zatímco sklepy,
   sklady a garážová stání zapsaná pod týmž druhem jdou pod 50 tis.
   Jedna mez to rozlišit neumí; mez 23 900 by vyřadila 596 legitimních
   sklepů. Je to táž heterogenita, kvůli které je ten druh v oddílu 8
   dokumentu veden jako k zamyšlení nad CIS_metrika_ceny.

   ============================================================================
   POŘADÍ TESTŮ V HODNOCENÍ
   ============================================================================
   „pod tržní hladinou" se testuje PŘED mezí z Valuo_prahy. Jinak by
   v kontaminovaném území rozhodla stažená lokální mez a vklad by prošel
   jako „bez výhrad" — přesně to se dělo ve Stodůlkách.
   ============================================================================ */

USE VALUO;
GO
SET NOCOUNT ON;
GO

/* ---------- 29a.1  PARAMETR PODLE KLASIFIKACE --------------------- */

IF COL_LENGTH('dbo.CIS_prahy_ceny','mez_vuci_kraji') IS NULL
    ALTER TABLE dbo.CIS_prahy_ceny ADD mez_vuci_kraji decimal(5,3) NULL;
GO

UPDATE dbo.CIS_prahy_ceny
   SET mez_vuci_kraji = 0.300
 WHERE klasifikace IN ('JC_JEDNOTKA','CELEK_BUDOVA')
   AND mez_vuci_kraji IS NULL;
GO

/* ---------- 29a.2  PŘEPIS PODLE DRUHU ----------------------------- */

IF COL_LENGTH('dbo.CIS_metrika_ceny','mez_vuci_kraji') IS NULL
    ALTER TABLE dbo.CIS_metrika_ceny ADD mez_vuci_kraji decimal(5,3) NULL;
GO

UPDATE dbo.CIS_metrika_ceny
   SET mez_vuci_kraji = 0,
       poznamka = N'Míchá komerční prostory (Praha 50-120 tis./m2) se sklepy, sklady a stáními pod 50 tis. Jedna mez to nerozliší, záchyt na kraji vypnut (0).'
 WHERE nemovitost = 'jednotka' AND typ = 'jiný nebytový prostor';
GO

SELECT klasifikace, cena_min, k_faktor, min_bodu_prah, max_nasobek, mez_vuci_kraji
FROM dbo.CIS_prahy_ceny ORDER BY klasifikace;
GO
SELECT nemovitost, typ, metrika, mez_vuci_kraji
FROM dbo.CIS_metrika_ceny WHERE mez_vuci_kraji IS NOT NULL;
GO

/* ---------- 29a.3  POHLED ------------------------------------------
   v_Valuo_vzorek_q je nasazený v databázi. Definici si vyexportuj
   z SSMS (pravý klik na pohled -> Script View as -> CREATE To) do
   29c_definice.sql, aby disk odpovídal databázi.

   Co v něm přibylo:
     - metrika CTE vrací navíc mez_druh z CIS_metrika_ceny
     - OUTER APPLY kr: krajský medián pro daný druh, pasmo = ''
     - sloupce median_kraj a mez_trzni_hladina
     - větev N'pod tržní hladinou' před testem na Valuo_prahy
   ------------------------------------------------------------------- */


/* ---------- 29a.4  KONTROLA --------------------------------------- */

/* Stav vzorku. Před krokem 29 a 29a (23. 10. 2026, 18:45):
       bez výhrad 25 379, nelze porovnat 10 314, pod mezí 3 141,
       chybí podlahová plocha 2 081, podíl nebo symb. převod 1 563,
       bez JC 1 256, bez srovnání 1 142, hromadný převod 866,
       nad mezí 719, podíl na budově 521, oddělené vlastnictví 509,
       nestandardní převod 320, symbolická cena 254, cizí měna 1     */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO

/* Kde pravidlo zabralo a jaká je tam mez */
SELECT TOP 20 druh, kraj, COUNT(*) AS vkladu,
       CAST(MIN(jedn_cena_Kc_m2) AS decimal(10,0)) AS jc_od,
       CAST(MAX(jedn_cena_Kc_m2) AS decimal(10,0)) AS jc_do,
       CAST(MIN(mez_trzni_hladina) AS decimal(10,0)) AS mez,
       CAST(MIN(median_kraj) AS decimal(10,0)) AS median_kraje
FROM dbo.v_Valuo_vzorek_q
WHERE hodnoceni_ceny = N'pod tržní hladinou'
GROUP BY druh, kraj ORDER BY COUNT(*) DESC;
GO

/* Stodůlky 2023 — případ, kvůli kterému to vzniklo.
   Nejlevnější vklad s hodnocením „bez výhrad" tu musí být nad mezí.  */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu,
       CAST(MIN(jedn_cena_Kc_m2) AS decimal(10,0)) AS jc_od,
       CAST(MAX(jedn_cena_Kc_m2) AS decimal(10,0)) AS jc_do,
       CAST(MIN(mez_trzni_hladina) AS decimal(10,0)) AS mez_trzni
FROM dbo.v_Valuo_vzorek_q
WHERE kat_uzemi = 'Stodůlky' AND druh = 'byt' AND rok = 2023
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO

/* Mez ve Stodůlkách po přepočtu. Před vyčištěním byla mez_zdola
   645 Kč/m² a medián 6 436; po něm 46 112 a 108 313.                */
SELECT uzemi, pasmo, n,
       CAST(median AS decimal(12,0))     AS median,
       CAST(prah_dolni AS decimal(12,0)) AS mez_zdola,
       CAST(prah_horni AS decimal(12,0)) AS mez_shora
FROM dbo.Valuo_prahy
WHERE klasifikace = 'JC_JEDNOTKA' AND klic = N'DRUH:byt'
  AND uroven = N'k.ú.' AND uzemi = N'Stodůlky'
ORDER BY pasmo;
GO
