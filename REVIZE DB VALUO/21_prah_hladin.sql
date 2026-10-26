/* ============================================================
   VALUO — KROK 21: PRÁH CENOVÝCH HLADIN DO ČÍSELNÍKU

   Jen číselník a pohledy, do dat nezasahuje.
   Spusť celé najednou, po krocích 17, 17b, 09 a 18.

   ------------------------------------------------------------
   PROČ
   ------------------------------------------------------------
   Medián se počítá pro každou kombinaci území × klasifikace ×
   klíč, kde klíč je u pozemků kód funkčního využití dle ÚP
   a u ostatních druh nemovitosti. Bod je jeden vklad
   s jednotkovou cenou. Nemá-li kombinace dost bodů, stoupá se
   k. ú. → okres → kraj.

   Práh byl dosud 20 bodů pro všechny klasifikace. U jednotek
   to ničemu nebrání, u staveb je nedosažitelný:

   | Klasifikace  | Hladin na k.ú. | Na okres | Na kraj | Bez mediánu |
   |--------------|----------------|----------|---------|-------------|
   | JC_JEDNOTKA  |             64 |      146 |       8 |          42 |
   | JC_PARCELY   |             36 |      473 |     164 |         350 |
   | CELEK_BUDOVA |              1 |       12 |       0 |          15 |

   Bodů u staveb je málo a jsou rozptýlené — rodinných domů je
   436 v 52 katastrálních územích, chat 7 v šesti. Následek:
   2 001 vkladů ve vzorku má hodnocení „bez srovnání".

   ------------------------------------------------------------
   PROČ JE 20 ZBYTEČNĚ VYSOKO
   ------------------------------------------------------------
   Hladina slouží výhradně k odhalení ŘÁDOVÉ odchylky, tedy
   faktoru deset a víc — ne k ocenění a ne k popisu trhu. Na to
   medián z pěti vkladů stačí: že je cena padesátkrát mimo,
   poznáš i z malého vzorku. Práh 20 byl nastavený, jako kdyby
   medián měl sloužit k ocenění, což nesmí.

   Dopad snížení na 5 u staveb: medián z vlastního katastrálního
   území by dostalo 634 vkladů místo dnešních 29.

   ------------------------------------------------------------
   CO ZŮSTÁVÁ
   ------------------------------------------------------------
   Pohled dál hlásí bodu_v_hladine a uroven_hladiny, takže
   u každého srovnání je v posudku vidět, na kolika bodech
   a z jaké územní úrovně medián stojí. Hladina z pěti bodů
   na úrovni kraje je rozpoznatelná a nemusí se jí věřit.

   Práh je v číselníku, takže se dá kdykoli změnit bez zásahu
   do pohledů.
   ============================================================ */

USE VALUO;
GO

/* ---------- 21.1 NOVÝ SLOUPEC V ČÍSELNÍKU ------------------ */

IF COL_LENGTH('dbo.CIS_prahy_ceny', 'prah_bodu') IS NULL
    ALTER TABLE dbo.CIS_prahy_ceny ADD prah_bodu int NULL;
GO

UPDATE dbo.CIS_prahy_ceny SET prah_bodu = 20 WHERE klasifikace = 'JC_JEDNOTKA';
UPDATE dbo.CIS_prahy_ceny SET prah_bodu = 20 WHERE klasifikace = 'JC_PARCELY';
UPDATE dbo.CIS_prahy_ceny SET prah_bodu =  5 WHERE klasifikace = 'CELEK_BUDOVA';
UPDATE dbo.CIS_prahy_ceny SET prah_bodu = 20 WHERE prah_bodu IS NULL;
GO

ALTER TABLE dbo.CIS_prahy_ceny ALTER COLUMN prah_bodu int NOT NULL;
GO

SELECT klasifikace, cena_min, prah_bodu, LEFT(ISNULL(poznamka,''), 50) AS poznamka
FROM dbo.CIS_prahy_ceny ORDER BY klasifikace;
GO


/* ---------- 21.2 HLADINY S PRAHEM Z ČÍSELNÍKU --------------
   Proti předchozí verzi se mění jen to, že se práh bere
   z CIS_prahy_ceny.prah_bodu místo pevné dvacítky.          */

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
    WHERE q.jedn_cena_Kc_m2 > 0
      AND q.cena_Kc >= t.cena_min
      AND ISNULL(q.mena, 'CZK') = 'CZK'
      AND q.typ_prevodu         = 'KUPNI_SMLOUVA'
      AND q.na_pozemku_stavba   = 0
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


/* ---------- 21.3 KONTROLA ---------------------------------- */

/* Hladiny podle úrovně — srovnej s tabulkou v hlavičce */
SELECT klasifikace, uroven, COUNT(*) AS kombinaci,
       MIN(bodu) AS min_bodu, MAX(bodu) AS max_bodu
FROM dbo.v_cenove_hladiny
GROUP BY klasifikace, uroven ORDER BY klasifikace, uroven;
GO

/* Vzorek — „bez srovnání" bylo 2 001 */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO

/* Stavby — kolik jich nově má srovnání a z jaké úrovně */
SELECT druh, uroven_hladiny, hodnoceni_ceny, COUNT(*) AS vkladu,
       CAST(AVG(jedn_cena_Kc_m2) AS decimal(14,0)) AS prum_JC,
       CAST(AVG(median_Kc_m2) AS decimal(14,0))    AS prum_median
FROM dbo.v_Valuo_vzorek_q
WHERE klasifikace = 'CELEK_BUDOVA' AND metrika = 'JC'
GROUP BY druh, uroven_hladiny, hodnoceni_ceny
ORDER BY druh, vkladu DESC;
GO

/* Na kolika bodech hladiny stojí — rozložení */
SELECT klasifikace,
       CASE WHEN bodu >= 100 THEN N'100 a víc'
            WHEN bodu >=  50 THEN N'50-99'
            WHEN bodu >=  20 THEN N'20-49'
            WHEN bodu >=  10 THEN N'10-19'
            ELSE                  N'5-9' END AS bodu_v_hladine,
       COUNT(*) AS kombinaci
FROM dbo.v_cenove_hladiny
WHERE median IS NOT NULL
GROUP BY klasifikace,
       CASE WHEN bodu >= 100 THEN N'100 a víc'
            WHEN bodu >=  50 THEN N'50-99'
            WHEN bodu >=  20 THEN N'20-49'
            WHEN bodu >=  10 THEN N'10-19'
            ELSE                  N'5-9' END
ORDER BY klasifikace, bodu_v_hladine;
GO
