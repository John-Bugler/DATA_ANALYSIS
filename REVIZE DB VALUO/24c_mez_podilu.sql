/* ============================================================
   VALUO — KROK 24c: MEZ PRO PODÍLY A PŘEPOČET PRAHŮ

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Zakládá číselník mezí, přepisuje proceduru z kroku 24a.
   Do hodnocení se pořád nic nezapojuje — to udělá krok 25.

   ============================================================
   PROČ
   ============================================================
   U pozemků se běžně prodávají spoluvlastnické podíly: zlomek
   cesty, zeleně, společného dvora. Cena je za podíl, výměra za
   celou parcelu, takže jednotková cena vyjde zlomkem skutečné.
   Podíl v datech není, z popisu se nedá vyčíst a detektor
   hromadných převodů je nezachytí, protože každý má jinou cenu.

   Kontaminace je tak velká, že selhává i odhad rozptylu z horní
   poloviny: u skupiny OBYTNE vycházel práh 0,35 Kč/m2 a horní
   mez v řádu stovek milionů.

   ------------------------------------------------------------
   PODÍL SE POZNÁ NA CELKOVÉ CENĚ, NE NA JEDNOTKOVÉ
   ------------------------------------------------------------
   Praha, pozemky s funkčním využitím:

   | cena vkladu     |    n | medián Kč/m2 | prům. výměra |
   |-----------------|------|--------------|--------------|
   | do 20 tis.      |  562 |            3 |     1 449 m2 |
   | 20-100 tis.     |  296 |          192 |     2 652 m2 |
   | 100-500 tis.    |  485 |          820 |     2 876 m2 |
   | nad 500 tis.    | 1267 |        3 590 |    12 280 m2 |

   Mimo Prahu:

   | cena vkladu     |    n | medián Kč/m2 | prům. výměra |
   |-----------------|------|--------------|--------------|
   | do 20 tis.      |  295 |           45 |       947 m2 |
   | 20-50 tis.      |  196 |          243 |     1 853 m2 |
   | 50-100 tis.     |  154 |          161 |     2 833 m2 |
   | nad 100 tis.    | 1521 |        1 280 |     8 613 m2 |

   Pozemek o 1 449 m2 za méně než 20 000 Kč v Praze neexistuje.
   Mezi pásmem do 100 tisíc a nad ním je řádový zlom — to je
   hranice, za kterou podíly končí.

   MEZ TEDY NENÍ ZVOLENÁ OD OKA, vychází z toho zlomu. Je ale
   v číselníku a dá se po krajích upravit.

   ------------------------------------------------------------
   CO MEZ UDĚLÁ
   ------------------------------------------------------------
   Vklady pod ní se VYŘADÍ Z VÝPOČTU PRAHŮ. Nemažou se a nikam
   nemizí — v kroku 25 dostanou vlastní hodnocení, místo aby se
   tvářily jako platné prodeje za 3 Kč/m2.

   Účinek na mediány skupin:

   | skupina   | před  |  po   |
   |-----------|-------|-------|
   | JADRO     | 12034 | 19546 |
   | OBYTNE    |  1183 |  4000 |
   | SMISENE   |  1099 |  1921 |
   | ZELEN     |  1060 |  1400 |
   | LES_LOUKY |   168 |   247 |

   U skupiny OBYTNE klesl poměr P75 k mediánu z 6,3 na 3,2.

   ------------------------------------------------------------
   ČEHO SE TÍM NEDOSÁHNE
   ------------------------------------------------------------
   Medián skupiny OBYTNE je i po vyčištění 4 000 Kč/m2, což je
   na pražský STAVEBNÍ pozemek pořád málo. Ta skupina totiž
   obsahuje i nestavební plochy ve funkčním využití pro bydlení
   — zbytky, zeleň mezi domy, nezastavitelné díly.

   Prahy odfiltrují nesmysly. Porovnávací vzorek stavebních
   parcel z nich ale nevznikne sám, ten je vždy potřeba vybrat
   ručně.
   ============================================================ */

USE VALUO;
GO

/* ---------- 24c.1 ČÍSELNÍK MEZÍ ---------------------------- */

IF OBJECT_ID('dbo.CIS_mez_podilu') IS NULL
CREATE TABLE dbo.CIS_mez_podilu (
    kraj     nvarchar(100) NOT NULL PRIMARY KEY,
    mez_Kc   decimal(14,0) NOT NULL,
    poznamka nvarchar(300) NULL
);
GO

MERGE dbo.CIS_mez_podilu AS c
USING (VALUES
 (N'Hlavní město Praha', 100000,
  N'Zlom mezi pásmy: do 100 tis. medián 192 Kč/m2, nad 100 tis. 820 Kč/m2. Pod mezí 858 z 2 610 vkladů.'),
 (N'*', 100000,
  N'Výchozí pro ostatní kraje. Zlom: 50-100 tis. medián 161 Kč/m2, nad 100 tis. 1 280 Kč/m2.')
) AS n (kraj, mez, pozn)
ON c.kraj = n.kraj
WHEN MATCHED THEN UPDATE SET mez_Kc = n.mez, poznamka = n.pozn
WHEN NOT MATCHED THEN INSERT (kraj, mez_Kc, poznamka)
     VALUES (n.kraj, n.mez, n.pozn);
GO

SELECT kraj, mez_Kc, poznamka FROM dbo.CIS_mez_podilu ORDER BY kraj;
GO

/* Kolik vkladů mez vyřadí */
SELECT  kraj = ISNULL(c.kraj_nazev, N'?'),
        vkladu_celkem = COUNT(*),
        pod_mezi = SUM(CASE WHEN q.cena_Kc < ISNULL(m.mez_Kc, d.mez_Kc)
                            THEN 1 ELSE 0 END),
        pct = CAST(100.0 * SUM(CASE WHEN q.cena_Kc < ISNULL(m.mez_Kc, d.mez_Kc)
                                    THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1))
FROM dbo.v_Valuo_vzorek_q q
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = q.kod_ku
LEFT JOIN dbo.CIS_mez_podilu m ON m.kraj = c.kraj_nazev
CROSS JOIN (SELECT mez_Kc FROM dbo.CIS_mez_podilu WHERE kraj = N'*') d
WHERE q.klasifikace = 'JC_PARCELY' AND q.jedn_cena_Kc_m2 > 0
  AND q.hromadny_prevod = 0 AND q.typ_prevodu = 'KUPNI_SMLOUVA'
  AND q.rok >= YEAR(GETDATE()) - 5
GROUP BY c.kraj_nazev
HAVING COUNT(*) >= 20
ORDER BY COUNT(*) DESC;
GO


/* ---------- 24c.2 PROCEDURA -------------------------------
   Proti kroku 24a přibývá jediná podmínka: u pozemků se
   vyřazují vklady pod mezí.                                  */

CREATE OR ALTER PROCEDURE dbo.sp_prepocet_prahu
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @mez_default decimal(14,0) =
        (SELECT mez_Kc FROM dbo.CIS_mez_podilu WHERE kraj = N'*');

    IF OBJECT_ID('tempdb..#d') IS NOT NULL DROP TABLE #d;

    SELECT  q.kod_ku,
            c.ku_nazev,
            COALESCE(c.okres_nazev, c.kraj_nazev) AS okres,
            c.kraj_nazev,
            q.klasifikace,
            CASE WHEN q.metrika = 'JC' THEN 'JC' ELSE 'CENA' END AS metrika,
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
    LEFT JOIN dbo.CIS_mez_podilu   mz ON mz.kraj      = c.kraj_nazev
    WHERE ISNULL(q.mena, 'CZK') = 'CZK'
      AND q.typ_prevodu = 'KUPNI_SMLOUVA'
      AND q.hromadny_prevod = 0
      AND ISNULL(q.prodeju_tehoz_objektu, 0) < 5
      AND q.rok >= YEAR(GETDATE()) - 5
      AND (CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                ELSE q.cena_Kc END) > 0
      /* podíly ven, ale jen u pozemků — u jednotek je cena vkladu
         cenou celé jednotky a mez by vyřadila levné byty */
      AND (q.klasifikace <> 'JC_PARCELY'
           OR q.cena_Kc >= ISNULL(mz.mez_Kc, @mez_default));

    CREATE INDEX IX_d ON #d (klasifikace, klic, metrika, kod_ku);

    TRUNCATE TABLE dbo.Valuo_prahy;

    /* --- katastrální území --- */
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

    /* --- okres --- */
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

    /* --- kraj --- */
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


/* ---------- 24c.3 VÝSLEDEK --------------------------------
   Pozemky v Praze po vyřazení podílů. Hodnoty u skupiny OBYTNE
   a pásma 600-1500 m2 mají odpovídat stavebním parcelám.     */

SELECT  co      = N'POZEMEK PRAHA, Kč/m²',
        skupina = LEFT(REPLACE(klic, N'FVU:', N''),
                       CHARINDEX(N'|', REPLACE(klic, N'FVU:', N'')) - 1),
        vymera  = SUBSTRING(klic, CHARINDEX(N'|', klic) + 1, 20),
        vzorku  = n,
        median  = CAST(median AS decimal(12,0)),
        zdola   = CAST(prah_dolni AS decimal(12,0)),
        shora   = CAST(prah_horni AS decimal(12,0)),
        rozptyl = sigma
FROM dbo.Valuo_prahy
WHERE klic LIKE N'FVU:%'
ORDER BY skupina, vymera;
GO

/* Ostatní pozemky podle druhu */
SELECT  co     = N'POZEMEK MIMO PRAHU, Kč/m²',
        druh   = REPLACE(klic, N'DRUH:', N''),
        uroven, uzemi,
        vzorku = n,
        median = CAST(median AS decimal(12,0)),
        zdola  = CAST(prah_dolni AS decimal(12,0)),
        shora  = CAST(prah_horni AS decimal(12,0))
FROM dbo.Valuo_prahy
WHERE klasifikace = 'JC_PARCELY' AND klic NOT LIKE N'FVU:%'
ORDER BY druh, uroven, n DESC;
GO

/* Souhrn — jednotky a budovy se nezměnily, mez se jich netýká */
SELECT  kategorie = CASE klasifikace
            WHEN 'JC_JEDNOTKA'  THEN N'jednotky'
            WHEN 'JC_PARCELY'   THEN N'pozemky'
            WHEN 'CELEK_BUDOVA' THEN N'budovy'
            ELSE N'nezařazeno' END,
        jednotka = CASE metrika WHEN 'JC' THEN N'Kč/m²'
                                ELSE N'Kč za vklad' END,
        uroven, kombinaci = COUNT(*), vkladu = SUM(n)
FROM dbo.Valuo_prahy
GROUP BY klasifikace, metrika, uroven
ORDER BY kategorie, jednotka, uroven;
GO
