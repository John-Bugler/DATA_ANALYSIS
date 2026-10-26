/* ============================================================
   VALUO — KROK 21a: OPRAVA FILTRU V CENOVÝCH HLADINÁCH

   Jen pohled, do dat nezasahuje. Spusť celé najednou.

   ------------------------------------------------------------
   CO BYLO ŠPATNĚ
   ------------------------------------------------------------
   Krok 20 přidal do v_cenove_hladiny podmínku

       AND q.na_pozemku_stavba = 0

   Měla vyřadit pozemky, jejichž součástí je stavba, protože
   u nich cena zahrnuje i tu stavbu, ale dělí se výměrou
   pozemků. Podmínka však platí pro všechny klasifikace, a to
   je chyba.

   Příznak na_pozemku_stavba se nastavuje podle textu
   „součástí je stavba" v popisu. U jednotky má popis tvar

       jednotka č. 2350323, byt v budově č.p. 235, část obce
       Třebonice, na parcele 330/20 Třebonice (součástí je
       stavba č.p. 235, čst obce Třebonice), podíl …

   Ta formulace tam je proto, že budova je součástí pozemku —
   s hodnocením bytu nemá nic společného. Totéž u budovy, která
   stojí na vlastní parcele.

   Dopad — vklady s jednotkovou cenou, které podmínka
   z mediánů vyřadila:

   | klasifikace  | příznak 0 | příznak 1 (vyřazeno) |
   |--------------|-----------|----------------------|
   | JC_JEDNOTKA  |    11 353 |               14 076 |
   | CELEK_BUDOVA |       189 |                  920 |
   | JC_PARCELY   |     5 018 |                    0 |

   Z cenových hladin tedy vypadla víc než polovina bytů
   a čtyři pětiny staveb; mediány se od kroku 20 počítaly
   z poloviny dat.

   ------------------------------------------------------------
   PROČ JE PODMÍNKA ZBYTEČNÁ
   ------------------------------------------------------------
   Krok 20 zároveň zavedl, že u JC_PARCELY se stavbou se
   jednotková cena vůbec nepočítá — je NULL. Těch 72 vkladů
   tedy odfiltruje už podmínka jedn_cena_Kc_m2 > 0, která
   v pohledu byla od začátku. Stačí podmínku odstranit.
   ============================================================ */

USE VALUO;
GO

/* ---------- 21a.1 STAV PŘED OPRAVOU ------------------------ */

SELECT klasifikace, uroven, COUNT(*) AS kombinaci, SUM(bodu) AS bodu
INTO #pred
FROM dbo.v_cenove_hladiny GROUP BY klasifikace, uroven;
GO

SELECT * FROM #pred ORDER BY klasifikace, uroven;
GO


/* ---------- 21a.2 OPRAVENÝ POHLED -------------------------- */

CREATE OR ALTER VIEW dbo.v_cenove_hladiny
AS
WITH zaklad AS (
    SELECT  q.kod_ku,
            c.okres_nazev,
            c.kraj_nazev,
            q.klasifikace,
            t.prah_bodu,
            CASE WHEN q.klasifikace = 'JC_PARCELY'
                  AND up.fvu_kod IS NOT NULL THEN N'FVU:'  + up.fvu_kod
                 ELSE                              N'DRUH:' + ISNULL(q.druh, N'?')
            END                 AS klic,
            q.jedn_cena_Kc_m2   AS jc
    FROM dbo.v_Valuo_vzorek q
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod      = q.kod_ku
    JOIN dbo.CIS_prahy_ceny        t ON t.klasifikace = q.klasifikace
    LEFT JOIN dbo.v_vklad_UP      up ON up.cislo_vkladu = q.cislo_vkladu
    WHERE q.jedn_cena_Kc_m2 > 0          /* pozemek se stavbou má NULL */
      AND q.cena_Kc >= t.cena_min
      AND ISNULL(q.mena, 'CZK') = 'CZK'
      AND q.typ_prevodu         = 'KUPNI_SMLOUVA'
      AND ISNULL(q.prodeju_tehoz_objektu, 0) < 5
      AND q.rok >= YEAR(GETDATE()) - 5
),
u_ku AS (
    SELECT DISTINCT kod_ku, klasifikace, klic, prah_bodu,
           COUNT(*) OVER (PARTITION BY kod_ku, klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY kod_ku, klasifikace, klic) AS med
    FROM zaklad
),
u_okres AS (
    SELECT DISTINCT COALESCE(okres_nazev, kraj_nazev) AS okres,
           klasifikace, klic, prah_bodu,
           COUNT(*) OVER (PARTITION BY COALESCE(okres_nazev, kraj_nazev),
                                       klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY COALESCE(okres_nazev, kraj_nazev),
                                  klasifikace, klic) AS med
    FROM zaklad
),
u_kraj AS (
    SELECT DISTINCT kraj_nazev, klasifikace, klic, prah_bodu,
           COUNT(*) OVER (PARTITION BY kraj_nazev, klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY kraj_nazev, klasifikace, klic) AS med
    FROM zaklad
)
SELECT DISTINCT
        z.kod_ku,
        z.klasifikace,
        z.klic,
        CAST(COALESCE(a.med, b.med, c.med) AS decimal(14,2)) AS median,
        COALESCE(a.n, b.n, c.n)                              AS bodu,
        CASE WHEN a.med IS NOT NULL THEN N'k.ú.'
             WHEN b.med IS NOT NULL THEN N'okres'
             WHEN c.med IS NOT NULL THEN N'kraj'
             ELSE N'—' END                                   AS uroven
FROM zaklad z
LEFT JOIN u_ku    a ON a.kod_ku = z.kod_ku
                   AND a.klasifikace = z.klasifikace
                   AND a.klic = z.klic AND a.n >= z.prah_bodu
LEFT JOIN u_okres b ON b.okres = COALESCE(z.okres_nazev, z.kraj_nazev)
                   AND b.klasifikace = z.klasifikace
                   AND b.klic = z.klic AND b.n >= z.prah_bodu
LEFT JOIN u_kraj  c ON c.kraj_nazev = z.kraj_nazev
                   AND c.klasifikace = z.klasifikace
                   AND c.klic = z.klic AND c.n >= z.prah_bodu;
GO


/* ---------- 21a.3 SROVNÁNÍ PŘED A PO ----------------------- */

SELECT  ISNULL(p.klasifikace, n.klasifikace) AS klasifikace,
        ISNULL(p.uroven, n.uroven)           AS uroven,
        p.kombinaci AS kombinaci_pred,
        n.kombinaci AS kombinaci_po,
        p.bodu      AS bodu_pred,
        n.bodu      AS bodu_po
FROM #pred p
FULL JOIN (SELECT klasifikace, uroven, COUNT(*) AS kombinaci, SUM(bodu) AS bodu
           FROM dbo.v_cenove_hladiny GROUP BY klasifikace, uroven) n
       ON n.klasifikace = p.klasifikace AND n.uroven = p.uroven
ORDER BY klasifikace, uroven;
GO

DROP TABLE #pred;
GO


/* ---------- 21a.4 JAK SE ZMĚNILY MEDIÁNY -------------------
   Pražské byty — kontrolní hodnoty, které musí odpovídat
   skutečnému trhu. Před opravou stály na polovině dat.      */

SELECT  c.ku_nazev AS kat_uzemi, h.klic, h.median, h.bodu, h.uroven
FROM dbo.v_cenove_hladiny h
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = h.kod_ku
WHERE h.klasifikace = 'JC_JEDNOTKA' AND h.klic = N'DRUH:byt'
  AND c.kraj_nazev = N'Hlavní město Praha' AND h.uroven = N'k.ú.'
ORDER BY h.median DESC;
GO

/* Vzorek — „bez srovnání" bylo 1 888 */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO

/* Stavby podle úrovně hladiny */
SELECT druh, uroven_hladiny, hodnoceni_ceny, COUNT(*) AS vkladu,
       CAST(AVG(jedn_cena_Kc_m2) AS decimal(14,0)) AS prum_JC,
       CAST(AVG(median_Kc_m2) AS decimal(14,0))    AS prum_median
FROM dbo.v_Valuo_vzorek_q
WHERE klasifikace = 'CELEK_BUDOVA' AND metrika = 'JC'
GROUP BY druh, uroven_hladiny, hodnoceni_ceny
ORDER BY druh, vkladu DESC;
GO
