/* ============================================================
   VALUO — KROK 24a: PRAHY POZEMKŮ PODLE SKUPIN FVU A VÝMĚRY

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Zakládá dva číselníky a přepisuje proceduru z kroku 24.
   Do hodnocení se pořád nic nezapojuje.

   ============================================================
   PROČ SE POZEMKY POČÍTAJÍ JINAK
   ============================================================
   Práh z kroku 24 u pražských pozemků selhal. Důvod ukazují
   kvantily jednotkové ceny v jednotlivých územích u funkčního
   využití OB, tedy pro bydlení:

   | k. ú.      |  n |   P50 |   P75 |   P90 |   P95 |
   |------------|----|-------|-------|-------|-------|
   | Točná      | 37 | 8 793 | 9 717 |10 877 |11 491 |
   | Kunratice  | 54 | 7 045 |17 910 |26 046 |28 670 |
   | Stodůlky   | 32 | 1 761 | 4 503 |12 711 |15 903 |
   | Smíchov    | 70 |   658 | 4 762 |15 131 |16 670 |
   | Košíře     | 83 |   357 | 2 280 | 6 034 |15 257 |

   V Točné je rozpětí mezi mediánem a P95 jen 1,3 násobek,
   v Košířích 43 násobek. Metoda z kroku 24 odhaduje rozptyl
   z horní poloviny, takže snese kontaminaci do 50 % — tady je
   ale v Košířích odhadem 70 až 80 %.

   ------------------------------------------------------------
   ČÍM TO JE
   ------------------------------------------------------------
   U pozemků se běžně prodávají SPOLUVLASTNICKÉ PODÍLY: zlomek
   cesty, zeleně, společného dvora. Cena je za podíl, výměra za
   celou parcelu, takže jednotková cena vyjde zlomkem skutečné.
   Podíl v datech nikde není, takže se z nich nedá vyčíst.

   Doklad z Košíř — vklady s nejnižší jednotkovou cenou:

       parcela 1837/19,  189 m2,   1 000 Kč  ->    5 Kč/m2
       parcela 1560/2,  1342 m2,  10 000 Kč  ->    7 Kč/m2
       parcela  156/1,   173 m2,   2 000 Kč  ->   12 Kč/m2

   Každý takový vklad má jinou cenu, takže je detektor hromadných
   převodů nezachytil — ten hledá shodu.

   ------------------------------------------------------------
   VÝMĚRA ROZLIŠUJE, ALE OBRÁCENĚ
   ------------------------------------------------------------
   Funkční využití OB, celá Praha:

   | výměra       |   n | medián |    P75 |
   |--------------|-----|--------|--------|
   | do 100 m2    | 203 |  4 070 | 11 478 |
   | 100-300 m2   | 162 |    947 |  5 069 |
   | 300-600 m2   | 166 |  2 222 |  8 962 |
   | 600-1500 m2  | 211 |  6 475 | 15 278 |
   | nad 1500 m2  | 249 |     89 |  2 258 |

   Nejhorší nejsou malé parcely, ale velké. Medián 89 Kč/m2
   u pozemků nad 1 500 m2 určených k bydlení jsou podíly na
   velkých pozemcích. Pásmo 600 až 1 500 m2 je naopak nejčistší
   — to jsou stavební parcely.

   ------------------------------------------------------------
   SKUPINY FUNKČNÍHO VYUŽITÍ
   ------------------------------------------------------------
   Kódy se seskupují podle toho, jak se chovají ceny, ne podle
   významu v územním plánu — ten v datech není, je jen v jeho
   metodice.

   Seskupeno podle P90, ne podle mediánu. Medián je u silně
   kontaminovaných kódů stažený dolů: SV má medián 169 Kč/m2,
   ale P90 14 100, takže podle mediánu by spadlo mezi zeleň,
   i když patří k obytným.

   TOHLE ZKONTROLUJ PROTI ÚZEMNÍMU PLÁNU. Zařazení je odvozené
   z cen a číselník se dá upravit bez zásahu do kódu.

   ------------------------------------------------------------
   ÚROVEŇ VÝPOČTU
   ------------------------------------------------------------
   Pro pozemky s funkčním využitím se práh počítá za CELOU PRAHU,
   ne za katastrální území. Po rozdělení na skupinu a velikostní
   pásmo by na území nezbylo dost bodů — 991 vkladů s OB dělených
   pěti pásmy dá dvě stě na pásmo za celou Prahu.

   Je to hrubší než u bytů, ale pro práh to stačí: má odhalit
   nesmysl, ne popsat trh. Hlavní přínos je, že konečně oddělí
   stavební parcelu od podílu na cestě.

   Počet bodů zůstává u každého prahu v sloupci n, aby bylo vidět,
   na čem stojí.
   ============================================================ */

USE VALUO;
GO

/* ---------- 24a.1 SKUPINY FUNKČNÍHO VYUŽITÍ ---------------- */

IF OBJECT_ID('dbo.CIS_FVU_skupiny') IS NULL
CREATE TABLE dbo.CIS_FVU_skupiny (
    fvu_kod  varchar(10)   NOT NULL PRIMARY KEY,
    skupina  varchar(20)   NOT NULL,
    p90_Kc   decimal(12,0) NULL,      /* podle čeho se zařadilo */
    poznamka nvarchar(200) NULL
);
GO

MERGE dbo.CIS_FVU_skupiny AS c
USING (VALUES
 /* jádro města — řádově nad ostatními */
 ('SMJ', 'JADRO',     69404),
 /* obytné a smíšené, P90 od 12 do 21 tisíc */
 ('VV',  'OBYTNE',    20933), ('OV',  'OBYTNE',    19084),
 ('OB',  'OBYTNE',    19000), ('S4',  'OBYTNE',    17447),
 ('VOP', 'OBYTNE',    15177), ('SV',  'OBYTNE',    14100),
 ('DGP', 'OBYTNE',    13159), ('ZVO', 'OBYTNE',    12180),
 ('VN',  'OBYTNE',    12054),
 /* smíšené nižší intenzity a sport, P90 od 6 do 10 tisíc */
 ('S2',  'SMISENE',    9686), ('DU',  'SMISENE',    9507),
 ('PZO', 'SMISENE',    8405), ('DL',  'SMISENE',    7658),
 ('VS',  'SMISENE',    7268), ('DH',  'SMISENE',    6966),
 ('ZMK', 'SMISENE',    6553), ('PZA', 'SMISENE',    6214),
 ('SP',  'SMISENE',    6094),
 /* zeleň, doprava, ostatní plochy, P90 od 3 do 6 tisíc */
 ('PS',  'ZELEN',      5834), ('OP',  'ZELEN',      5255),
 ('DZ',  'ZELEN',      4937), ('S1',  'ZELEN',      4613),
 ('TVE', 'ZELEN',      4346), ('ZP',  'ZELEN',      3915),
 ('IZ',  'ZELEN',      3509), ('SO',  'ZELEN',      3334),
 ('DP',  'ZELEN',      3293),
 /* les, louky a plochy bez využitelnosti */
 ('SD',  'LES_LOUKY',  2722), ('LR',  'LES_LOUKY',  2159),
 ('NL',  'LES_LOUKY',  2059), ('SUP', 'LES_LOUKY',  1949),
 ('VVA', 'LES_LOUKY',    72), ('TEP', 'LES_LOUKY',    25),
 /* jednotlivé vklady, zařazeno podle výše ceny */
 ('ZKC', 'SMISENE',   10000), ('ZOB', 'ZELEN',       3496),
 ('TVV', 'ZELEN',       NULL), ('TI',  'ZELEN',      NULL),
 ('TVO', 'ZELEN',       NULL)
) AS n (fvu_kod, skupina, p90)
ON c.fvu_kod = n.fvu_kod
WHEN MATCHED THEN UPDATE SET skupina = n.skupina, p90_Kc = n.p90
WHEN NOT MATCHED THEN INSERT (fvu_kod, skupina, p90_Kc)
     VALUES (n.fvu_kod, n.skupina, n.p90);
GO

SELECT skupina, COUNT(*) AS kodu,
       MIN(p90_Kc) AS p90_od, MAX(p90_Kc) AS p90_do,
       STRING_AGG(fvu_kod, ', ') WITHIN GROUP (ORDER BY p90_Kc DESC) AS kody
FROM dbo.CIS_FVU_skupiny GROUP BY skupina ORDER BY MAX(p90_Kc) DESC;
GO


/* ---------- 24a.2 VELIKOSTNÍ PÁSMA ------------------------- */

IF OBJECT_ID('dbo.CIS_velikost_pozemku') IS NULL
CREATE TABLE dbo.CIS_velikost_pozemku (
    pasmo    varchar(12)   NOT NULL PRIMARY KEY,
    od_m2    decimal(12,2) NOT NULL,
    do_m2    decimal(12,2) NOT NULL,
    poradi   tinyint       NOT NULL,
    poznamka nvarchar(200) NULL
);
GO

MERGE dbo.CIS_velikost_pozemku AS c
USING (VALUES
 ('do100',     0,     100, 1, N'Zbytkové plochy, díly chodníků a vjezdů.'),
 ('100-300',   100,   300, 2, N'Doplňky k sousedním pozemkům.'),
 ('300-600',   300,   600, 3, N'Menší parcely, často už zastavěné.'),
 ('600-1500',  600,  1500, 4, N'Stavební parcely pro rodinný dům. Nejčistší pásmo.'),
 ('nad1500',  1500, 999999999, 5, N'Velké pozemky. Nejvíc zasažené podíly — medián 89 Kč/m2 u OB.')
) AS n (pasmo, od_m2, do_m2, poradi, pozn)
ON c.pasmo = n.pasmo
WHEN MATCHED THEN UPDATE SET od_m2 = n.od_m2, do_m2 = n.do_m2,
                             poradi = n.poradi, poznamka = n.pozn
WHEN NOT MATCHED THEN INSERT (pasmo, od_m2, do_m2, poradi, poznamka)
     VALUES (n.pasmo, n.od_m2, n.do_m2, n.poradi, n.pozn);
GO

SELECT pasmo, od_m2, do_m2, poznamka
FROM dbo.CIS_velikost_pozemku ORDER BY poradi;
GO


/* ---------- 24a.3 PROCEDURA -------------------------------
   Proti kroku 24 se mění jen klíč u pražských pozemků a to, že
   se u nich počítá rovnou na úrovni kraje.                   */

CREATE OR ALTER PROCEDURE dbo.sp_prepocet_prahu
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;

    SELECT  q.kod_ku,
            c.ku_nazev,
            COALESCE(c.okres_nazev, c.kraj_nazev) AS okres,
            c.kraj_nazev,
            q.klasifikace,
            CASE WHEN q.metrika = 'JC' THEN 'JC' ELSE 'CENA' END AS metrika,
            /* pozemek s funkčním využitím: skupina a velikostní
               pásmo; ostatní jako dosud podle druhu */
            CASE WHEN q.klasifikace = 'JC_PARCELY' AND f.skupina IS NOT NULL
                 THEN N'FVU:' + f.skupina + N'|' + v.pasmo
                 ELSE N'DRUH:' + ISNULL(q.druh, '?') END AS klic,
            CASE WHEN q.klasifikace = 'JC_PARCELY' AND f.skupina IS NOT NULL
                 THEN 1 ELSE 0 END AS jen_kraj,
            t.k_faktor,
            t.min_bodu_prah,
            LOG(CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                     ELSE q.cena_Kc END) AS lg
    INTO #d
    FROM dbo.v_Valuo_vzorek_q q
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod      = q.kod_ku
    JOIN dbo.CIS_prahy_ceny        t ON t.klasifikace = q.klasifikace
    LEFT JOIN dbo.CIS_FVU_skupiny  f ON f.fvu_kod     = q.fvu_kod
    LEFT JOIN dbo.CIS_velikost_pozemku v
           ON q.plocha_parcel_m2 >= v.od_m2 AND q.plocha_parcel_m2 < v.do_m2
    WHERE ISNULL(q.mena, 'CZK') = 'CZK'
      AND q.typ_prevodu = 'KUPNI_SMLOUVA'
      AND q.hromadny_prevod = 0
      AND ISNULL(q.prodeju_tehoz_objektu, 0) < 5
      AND q.rok >= YEAR(GETDATE()) - 5
      AND (CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                ELSE q.cena_Kc END) > 0;

    CREATE INDEX IX_d ON #d (klasifikace, klic, metrika, kod_ku);

    TRUNCATE TABLE dbo.Valuo_prahy;

    /* --- katastrální území; pozemky s FVU sem nepatří --- */
    INSERT INTO dbo.Valuo_prahy
        (klasifikace, klic, metrika, uroven, uzemi, n, median, p75,
         sigma, prah_dolni, prah_horni, datum_vypoctu)
    SELECT DISTINCT klasifikace, klic, metrika, N'k.ú.', ku_nazev, n,
           CAST(EXP(p50) AS decimal(18,2)),
           CAST(EXP(p75) AS decimal(18,2)),
           CAST(sig AS decimal(8,4)),
           CAST(EXP(p50 - k_faktor * sig) AS decimal(18,2)),
           CAST(EXP(p50 + k_faktor * sig) AS decimal(18,2)),
           GETDATE()
    FROM (
        SELECT DISTINCT klasifikace, klic, metrika, ku_nazev, k_faktor,
               COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika,
                                           kod_ku) AS n,
               p50, p75, (p75 - p50) / 0.6745 AS sig, min_bodu_prah
        FROM (
            SELECT klasifikace, klic, metrika, ku_nazev, kod_ku,
                   k_faktor, min_bodu_prah,
                   PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika,
                                          kod_ku) AS p50,
                   PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika,
                                          kod_ku) AS p75
            FROM #d WHERE jen_kraj = 0
        ) a
    ) b
    WHERE n >= min_bodu_prah AND p75 > p50;

    /* --- okres; pozemky s FVU sem také nepatří --- */
    INSERT INTO dbo.Valuo_prahy
        (klasifikace, klic, metrika, uroven, uzemi, n, median, p75,
         sigma, prah_dolni, prah_horni, datum_vypoctu)
    SELECT DISTINCT klasifikace, klic, metrika, N'okres', okres, n,
           CAST(EXP(p50) AS decimal(18,2)),
           CAST(EXP(p75) AS decimal(18,2)),
           CAST(sig AS decimal(8,4)),
           CAST(EXP(p50 - k_faktor * sig) AS decimal(18,2)),
           CAST(EXP(p50 + k_faktor * sig) AS decimal(18,2)),
           GETDATE()
    FROM (
        SELECT DISTINCT klasifikace, klic, metrika, okres, k_faktor,
               COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika,
                                           okres) AS n,
               p50, p75, (p75 - p50) / 0.6745 AS sig, min_bodu_prah
        FROM (
            SELECT klasifikace, klic, metrika, okres, k_faktor,
                   min_bodu_prah,
                   PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika,
                                          okres) AS p50,
                   PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika,
                                          okres) AS p75
            FROM #d WHERE jen_kraj = 0
        ) a
    ) b
    WHERE n >= min_bodu_prah AND p75 > p50;

    /* --- kraj; sem patří všechno včetně pozemků s FVU --- */
    INSERT INTO dbo.Valuo_prahy
        (klasifikace, klic, metrika, uroven, uzemi, n, median, p75,
         sigma, prah_dolni, prah_horni, datum_vypoctu)
    SELECT DISTINCT klasifikace, klic, metrika, N'kraj', kraj_nazev, n,
           CAST(EXP(p50) AS decimal(18,2)),
           CAST(EXP(p75) AS decimal(18,2)),
           CAST(sig AS decimal(8,4)),
           CAST(EXP(p50 - k_faktor * sig) AS decimal(18,2)),
           CAST(EXP(p50 + k_faktor * sig) AS decimal(18,2)),
           GETDATE()
    FROM (
        SELECT DISTINCT klasifikace, klic, metrika, kraj_nazev, k_faktor,
               COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika,
                                           kraj_nazev) AS n,
               p50, p75, (p75 - p50) / 0.6745 AS sig, min_bodu_prah
        FROM (
            SELECT klasifikace, klic, metrika, kraj_nazev, k_faktor,
                   min_bodu_prah,
                   PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika,
                                          kraj_nazev) AS p50,
                   PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika,
                                          kraj_nazev) AS p75
            FROM #d
        ) a
    ) b
    WHERE n >= min_bodu_prah AND p75 > p50;

    DROP TABLE #d;
END;
GO

EXEC dbo.sp_prepocet_prahu;
GO


/* ============================================================
   24a.4 ČITELNÉ VÝPISY
   ============================================================
   Každý výpis říká, co je kategorie, v jaké jednotce je číslo
   a na kolika vkladech práh stojí.
   ============================================================ */

/* --- 1) Co všechno vzniklo --------------------------------- */
SELECT  kategorie = CASE klasifikace
            WHEN 'JC_JEDNOTKA'  THEN N'jednotky'
            WHEN 'JC_PARCELY'   THEN N'pozemky'
            WHEN 'CELEK_BUDOVA' THEN N'budovy'
            ELSE N'nezařazeno' END,
        jednotka = CASE metrika WHEN 'JC' THEN N'Kč/m²'
                                ELSE N'Kč za vklad' END,
        uroven,
        kombinaci = COUNT(*),
        vkladu    = SUM(n),
        nejmensi  = MIN(n),
        nejvetsi  = MAX(n)
FROM dbo.Valuo_prahy
GROUP BY klasifikace, metrika, uroven
ORDER BY kategorie, jednotka, uroven;
GO

/* --- 2) Byty po katastrálních územích, Kč/m² ---------------- */
SELECT TOP 25
        kat_uzemi = uzemi,
        vzorku    = n,
        median    = CAST(median AS decimal(12,0)),
        prah_zdola= CAST(prah_dolni AS decimal(12,0)),
        prah_shora= CAST(prah_horni AS decimal(12,0)),
        rozptyl   = sigma
FROM dbo.Valuo_prahy
WHERE klasifikace = 'JC_JEDNOTKA' AND klic = N'DRUH:byt'
  AND uroven = N'k.ú.'
ORDER BY median DESC;
GO

/* --- 3) Pozemky v Praze: skupina FVU a výměra, Kč/m² ------- */
SELECT  skupina  = LEFT(REPLACE(klic, N'FVU:', N''),
                        CHARINDEX(N'|', REPLACE(klic, N'FVU:', N'')) - 1),
        vymera   = SUBSTRING(klic, CHARINDEX(N'|', klic) + 1, 20),
        vzorku   = n,
        median   = CAST(median AS decimal(12,0)),
        prah_zdola = CAST(prah_dolni AS decimal(12,0)),
        prah_shora = CAST(prah_horni AS decimal(12,0))
FROM dbo.Valuo_prahy
WHERE klic LIKE N'FVU:%' AND uzemi = N'Hlavní město Praha'
ORDER BY skupina, vymera;
GO

/* --- 4) Garáže, Kč za garáž -------------------------------- */
SELECT  uroven, uzemi,
        vzorku = n,
        median = CAST(median AS decimal(12,0)),
        prah_zdola = CAST(prah_dolni AS decimal(12,0)),
        prah_shora = CAST(prah_horni AS decimal(12,0))
FROM dbo.Valuo_prahy
WHERE klic = N'DRUH:garáž' ORDER BY uroven, n DESC;
GO

/* --- 5) Rodinné domy, Kč/m² podlahové plochy --------------- */
SELECT  uroven, uzemi,
        vzorku = n,
        median = CAST(median AS decimal(12,0)),
        prah_zdola = CAST(prah_dolni AS decimal(12,0)),
        prah_shora = CAST(prah_horni AS decimal(12,0))
FROM dbo.Valuo_prahy
WHERE klic = N'DRUH:rodinný dům' AND metrika = 'JC'
ORDER BY uroven, n DESC;
GO

/* --- 6) Kolik vkladů by novými prahy propadlo -------------- */
SELECT  kategorie = CASE q.klasifikace
            WHEN 'JC_JEDNOTKA'  THEN N'jednotky'
            WHEN 'JC_PARCELY'   THEN N'pozemky'
            WHEN 'CELEK_BUDOVA' THEN N'budovy'
            ELSE N'nezařazeno' END,
        vkladu     = COUNT(*),
        pod_prahem = SUM(CASE WHEN h.hodnota < p.prah_dolni THEN 1 ELSE 0 END),
        nad_prahem = SUM(CASE WHEN h.hodnota > p.prah_horni THEN 1 ELSE 0 END)
FROM dbo.v_Valuo_vzorek_q q
CROSS APPLY (SELECT hodnota = CASE WHEN q.metrika = 'JC'
                                   THEN q.jedn_cena_Kc_m2
                                   ELSE q.cena_Kc END) h
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = q.kod_ku
JOIN dbo.Valuo_prahy p
       ON p.klasifikace = q.klasifikace
      AND p.metrika = CASE WHEN q.metrika = 'JC' THEN 'JC' ELSE 'CENA' END
      AND p.uroven = N'k.ú.' AND p.uzemi = c.ku_nazev
      AND p.klic = N'DRUH:' + ISNULL(q.druh, '?')
WHERE h.hodnota > 0
GROUP BY q.klasifikace ORDER BY vkladu DESC;
GO
