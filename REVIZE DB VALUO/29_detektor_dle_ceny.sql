/* ============================================================================
   29_detektor_dle_ceny.sql — druhý detektor hromadných převodů

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.

   Struktura, obě procedury i pohled jsou už v databázi nasazené
   (Claude je spustil 23. 10. 2026 večer). Zbývá oddíl 29.4 — spuštění
   detektoru. Nevejde se do časového limitu nástroje, kterým se Claude
   připojuje, a musí se pustit odtud.

   ============================================================================
   PROČ
   ============================================================================
   Detektor z kroku 23 klíčuje podle JEDNOTKOVÉ ceny a vyžaduje tři
   a více různých ploch. Družstevní privatizace, kde má každý byt vlastní
   cenu podle téhož vzorce, tou podmínkou propadne: každá jednotková cena
   má plochu jedinou.

   DOLOŽENÝ PŘÍPAD — Stodůlky, byty, 2023:

       JC Kč/m²   vkladů   cena od    cena do    různých ploch
       5 699,80       46   251 361    251 361        1
       6 442,53       42   493 433    493 433        1
       6 160,70       35   275 137    275 137        1

   Medián území za ten rok vyšel 6 436 Kč/m², proti 125 376 Kč/m² o rok
   později. Všech 318 vkladů prošlo jako „bez výhrad".

   Mez je nezachytila ani ona: mez_zdola v té skupině je 645 Kč/m²,
   protože těch 318 převodů tvoří většinu skupiny, ze které se mez
   počítá — stáhly si ji samy pod sebe. Je to táž kontaminace, kvůli
   které v kroku 24 padly MAD i IQR.

   ============================================================================
   KRITÉRIUM
   ============================================================================
   Shodná CELKOVÁ cena u 5 a více vkladů v témže území, druhu a roce,
   a zároveň aspoň jedno z:
     - plochy se opakují (různých ploch nejvýš polovina vkladů)
     - cena není kulatá na 1 000 Kč

   Druhá podmínka odděluje trh od transakce. Měřeno na datech:

       cena      plochy          skupin  vkladů  prochází „bez výhrad"
       kulatá    různé              121     713        654   <- trh, nechat
       nekulatá  opakují se          91   1 410        421   <- zachytit
       kulatá    opakují se          18     278        246   <- zachytit
       nekulatá  různé               11      99          9   <- zachytit

   Pět bytů za kulatých pět milionů s pěti různými plochami je náhoda,
   ne jedna smlouva. Kritérium proto první řádek vynechá.

   Najde 118 skupin a 1 757 vkladů, z toho 667 dnes prochází jako
   použitelné.

   ============================================================================
   CO SE ZMĚNILO VE STRUKTUŘE
   ============================================================================
   Valuo_hromadne_prevody dostala sloupce detektor ('JC' / 'CENA'),
   cena_skupiny_Kc, rok a ruznych_cen. Primární klíč je o ně rozšířený.
   Obě sady skupin jsou v jedné tabulce, aby se zatřiďovaly na jednom
   místě.

   POZOR — sp_detekce_hromadnych_prevodu bylo nutné upravit. Měla
   v MERGE klauzuli:

       WHEN NOT MATCHED BY SOURCE AND t.typ_jevu IS NULL THEN DELETE

   Bez omezení na detektor by při každém běhu smazala všechny skupiny
   druhého detektoru. Nově je všude `AND t.detektor = 'JC'`, včetně
   obou pomocných UPDATE na konci procedury.

   ============================================================================
   CO SE STANE PO SPUŠTĚNÍ
   ============================================================================
   Nalezené skupiny nemají zatřídění, takže všech 1 757 vkladů dostane
   hodnocení „hromadný převod" a vypadne z „bez výhrad". To je záměr —
   dokud nerozhodneš, jsou podezřelé. Očekávaný posun:

       bez výhrad   25 379  ->  zhruba 24 700
       hromadný p.     866  ->  zhruba 2 600

   Zatřídění se dělá jako u původních 66 skupin. Oddíl 29.6 má k tomu
   výpis a příklad příkazu.

   Zároveň se tím opraví meze: sp_prepocet_prahu filtruje
   hromadny_prevod = 0, takže Stodůlky už se do své vlastní meze
   nezapočítají. PO ZATŘÍDĚNÍ je proto nutné meze přepočítat.

   ============================================================================
   POŘADÍ SPOUŠTĚNÍ PO KAŽDÉM IMPORTU
   ============================================================================
       EXEC dbo.sp_prepocet_jednotkovych_cen;
       EXEC dbo.sp_prepocet_typu_prevodu;
       EXEC dbo.sp_prepocet_men;
       EXEC dbo.sp_detekce_hromadnych_prevodu;    -- detektor JC
       EXEC dbo.sp_detekce_prevodu_dle_ceny;      -- NOVÉ, detektor CENA
       EXEC dbo.sp_prepocet_ruian_vzorku;
       EXEC dbo.sp_prepocet_prahu;
   ============================================================================ */

USE VALUO;
GO
SET NOCOUNT ON;
GO

/* ---------- 29.4  SPUŠTĚNÍ DETEKTORU — ZBÝVAJÍCÍ KROK ------------- */

EXEC dbo.sp_detekce_prevodu_dle_ceny;
GO

/* Kontrola, že starý detektor nové skupiny nesmazal */
EXEC dbo.sp_detekce_hromadnych_prevodu;
GO

SELECT detektor, COUNT(*) AS skupin, SUM(vkladu) AS vkladu,
       SUM(CASE WHEN typ_jevu IS NULL THEN 1 ELSE 0 END) AS nezatridenych
FROM dbo.Valuo_hromadne_prevody GROUP BY detektor;
GO


/* ---------- 29.5  CO TO UDĚLALO S HODNOCENÍM ---------------------- */

/* Před krokem 29: bez výhrad 25 379, nelze porovnat 10 314,
   pod mezí 3 141, chybí podlahová plocha 2 081, podíl nebo symbolický
   převod 1 563, bez JC 1 256, bez srovnání 1 142, hromadný převod 866,
   nad mezí 719, podíl na budově 521, oddělené vlastnictví 509,
   nestandardní převod 320, symbolická cena 254, cizí měna 1          */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO

/* Stodůlky 2023 — případ, kvůli kterému to vzniklo.
   Po detekci tu nesmí zůstat nic s hodnocením „bez výhrad"
   kolem 6 000 Kč/m².                                                 */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu,
       CAST(MIN(jedn_cena_Kc_m2) AS decimal(12,0)) AS jc_od,
       CAST(MAX(jedn_cena_Kc_m2) AS decimal(12,0)) AS jc_do
FROM dbo.v_Valuo_vzorek_q
WHERE kat_uzemi = 'Stodůlky' AND druh = 'byt' AND rok = 2023
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO


/* ---------- 29.6  ZATŘÍDĚNÍ NOVÝCH SKUPIN ------------------------- */

/* Co je k rozhodnutí — největší skupiny nahoře.
   pomer_jc je podíl průměrné jednotkové ceny skupiny k ceně, kterou
   by měl mít běžný prodej; hodně nízké číslo znamená privatizaci.    */
SELECT TOP 40
       h.kat_uzemi, h.druh, h.rok,
       CAST(h.cena_skupiny_Kc AS decimal(12,0)) AS cena_vkladu,
       h.vkladu, h.ruznych_ploch, h.ruznych_cen,
       CAST(h.plocha_min AS decimal(10,1)) AS plocha_od,
       CAST(h.plocha_max AS decimal(10,1)) AS plocha_do,
       CAST(h.cena_skupiny_Kc / NULLIF(h.plocha_max,0) AS decimal(12,0)) AS jc_pri_max_plose
FROM dbo.Valuo_hromadne_prevody h
WHERE h.detektor = 'CENA' AND h.typ_jevu IS NULL
ORDER BY h.vkladu DESC;
GO

/* Zatřídění. Typy jsou v CIS_typy_hromadneho_prevodu:
   PRIVATIZACE, VYKUP_LINIOVY, TRH, PREVOD_PODILU, JINE.
   Jen TRH vstupuje do mediánu.

UPDATE dbo.Valuo_hromadne_prevody
   SET typ_jevu = 'PRIVATIZACE',
       poznamka = N'Družstevní privatizace, cena dle stanov.'
 WHERE detektor = 'CENA' AND kat_uzemi = 'Stodůlky'
   AND druh = 'byt' AND rok = 2023;
*/

/* PO ZATŘÍDĚNÍ přepočítej meze — Stodůlky si dosud stahovaly
   vlastní mez pod sebe.                                              */
-- EXEC dbo.sp_prepocet_prahu;
GO
