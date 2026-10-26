/* ============================================================
   VALUO — KROK 20a: OPRAVA DÉLKY SLOUPCE V ČÍSELNÍKU

   Blok 20.1 selhal chybou Msg 2628: sloupec
   CIS_metrika_ceny.metrika je varchar(10) a hodnota
   'JC_PODLAHOVA' má dvanáct znaků.

   Pohledy z kroku 20 se vytvořily v pořádku, takže stačí
   rozšířit sloupec a doplnit metriky. Rodinné domy jsou do té
   doby pořád na CELEK a jednotková cena se u nich nepočítá.

   Sloupec se rozšiřuje místo zkrácení názvu metriky, aby
   nebylo nutné pohledy přepisovat.

   Spusť celé najednou.
   ============================================================ */

USE VALUO;
GO

/* ---------- 20a.1 ROZŠÍŘENÍ SLOUPCE ------------------------ */

ALTER TABLE dbo.CIS_metrika_ceny
    ALTER COLUMN metrika varchar(20) NOT NULL;
GO


/* ---------- 20a.2 METRIKY STAVEB ---------------------------
   JC_PODLAHOVA znamená: jednotkovou cenu počítej z podlahové
   plochy, je-li v datech. Není-li, dostane vklad hodnocení
   „chybí podlahová plocha" a je kandidátem na doplnění
   z RÚIAN.

   Ověřeno, že u rodinných domů jde o skutečnou podlahovou
   plochu, ne o zastavěnou: z 848 řádků se jen jediný shoduje
   s výměrou stavební parcely pod domem, zatímco plocha je
   proti ní systematicky větší v poměru 1,07 až 1,67 — tedy
   v poměru typickém pro dvoupodlažní dům. U kategorie
   „Výměra parcely" se naproti tomu shoda se stavební parcelou
   objevuje u 547 z 2 006 řádků.                              */

UPDATE dbo.CIS_metrika_ceny
SET metrika  = 'JC_PODLAHOVA',
    poznamka = N'JC = cena vkladu / podlahová plocha. Není-li plocha '
             + N'v datech, vklad dostane „chybí podlahová plocha".'
WHERE nemovitost = N'budova'
  AND typ IN (N'rodinný dům', N'stavba pro rodinnou rekreaci');
GO

MERGE dbo.CIS_metrika_ceny AS c
USING (VALUES
    (N'budova', N'objekt k bydlení',         'JC_PODLAHOVA'),
    (N'budova', N'budova s číslem popisným', 'JC_PODLAHOVA')
) AS n (nemovitost, typ, metrika)
   ON c.nemovitost = n.nemovitost AND c.typ = n.typ
WHEN MATCHED THEN
    UPDATE SET metrika = n.metrika
WHEN NOT MATCHED THEN
    INSERT (nemovitost, typ, metrika, poznamka)
    VALUES (n.nemovitost, n.typ, n.metrika,
            N'JC = cena vkladu / podlahová plocha.');
GO


/* ---------- 20a.3 PROČ BYTOVÝ DŮM ZŮSTÁVÁ NA CELEK ---------
   Poznámka se zapisuje do číselníku, aby byl důvod po ruce
   při jeho ruční úpravě.                                     */

UPDATE dbo.CIS_metrika_ceny
SET poznamka = N'CELEK záměrně: u bytových domů je „podlahová plocha" '
             + N'plochou celé budovy, zatímco cena je za podíl v ní. '
             + N'Ověřeno na parcele 496/77 Střížkov — dvanáct vkladů, '
             + N'u všech plocha 28 000 m2, ceny 2,5 až 8,0 mil. Kč.'
WHERE nemovitost = N'budova' AND typ = N'bytový dům';
GO

UPDATE dbo.CIS_metrika_ceny
SET poznamka = N'KUS: garáž se porovnává jako jeden kus, ne na m2 — '
             + N'platí pro řadovou garáž i pro jednotku či stání.'
WHERE typ = N'garáž';
GO


/* ---------- 20a.4 KONTROLA --------------------------------- */

SELECT nemovitost, typ, metrika, LEFT(ISNULL(poznamka,''), 60) AS poznamka
FROM dbo.CIS_metrika_ceny
ORDER BY nemovitost, metrika, typ;
GO

/* Rodinné domy — nově s jednotkovou cenou */
SELECT  druh, metrika, hodnoceni_ceny, COUNT(*) AS vkladu,
        CAST(AVG(jedn_cena_Kc_m2) AS decimal(14,0))      AS prum_JC,
        CAST(AVG(plocha_podlahova_m2) AS decimal(10,1))  AS prum_podlahova,
        CAST(AVG(plocha_parcel_m2) AS decimal(10,1))     AS prum_pozemek
FROM dbo.v_Valuo_vzorek_q
WHERE druh IN (N'rodinný dům', N'stavba pro rodinnou rekreaci',
               N'objekt k bydlení', N'budova s číslem popisným')
GROUP BY druh, metrika, hodnoceni_ceny
ORDER BY druh, vkladu DESC;
GO

/* Kolik vkladů čeká na podlahovou plochu z RÚIAN */
SELECT druh, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
WHERE hodnoceni_ceny = N'chybí podlahová plocha'
GROUP BY druh ORDER BY COUNT(*) DESC;
GO

/* Celkový přehled vzorku */
SELECT klasifikace, metrika, hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY klasifikace, metrika, hodnoceni_ceny
ORDER BY klasifikace, vkladu DESC;
GO
