/* ============================================================
   VALUO — OPRAVA 07d: HLADINY PODLE DRUHU

   Obsahuje POUZE pohled v_cenove_hladiny z 07b, který
   neproběhl. Pohled v_Valuo_vzorek_q se nedotýká — ten je
   správně z 07c a obsahuje sloupec metrika.

   NESPOUŠTĚJ 07b — přepsal by vzorek na starší verzi.

   ------------------------------------------------------------
   DŮVOD
   ------------------------------------------------------------
   Hladiny pro jednotky se počítaly přes všechny druhy
   dohromady (klíč "(vše)"), zatímco vzorek už hledá klíč
   podle druhu. Spojení proto nenašlo medián a 24 386 záznamů
   vycházelo jako "bez srovnání".

   Mediány v Praze od 2023 ukazují, proč je dělení podle druhu
   nutné (Kč/m2):
       ateliér                 130 435
       byt                     127 660
       jiný nebytový prostor    72 967
       garáž                     7 733
   ============================================================ */

USE VALUO;
GO

CREATE OR ALTER VIEW dbo.v_cenove_hladiny
AS
WITH zaklad AS (
    SELECT  q.kod_ku,
            c.okres_nazev,
            c.kraj_nazev,
            q.klasifikace,
            /* pozemky: funkční využití dle ÚP, jinak druh
               jednotky a budovy: druh nemovitosti            */
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
      AND q.mena = 'CZK'
      AND q.rok >= YEAR(GETDATE()) - 5
),
u_ku AS (
    SELECT DISTINCT kod_ku, klasifikace, klic,
           COUNT(*) OVER (PARTITION BY kod_ku, klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY kod_ku, klasifikace, klic) AS med
    FROM zaklad
),
u_okres AS (
    SELECT DISTINCT COALESCE(okres_nazev, kraj_nazev) AS okres,
           klasifikace, klic,
           COUNT(*) OVER (PARTITION BY COALESCE(okres_nazev, kraj_nazev),
                                       klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY COALESCE(okres_nazev, kraj_nazev),
                                  klasifikace, klic) AS med
    FROM zaklad
),
u_kraj AS (
    SELECT DISTINCT kraj_nazev, klasifikace, klic,
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
                   AND a.klic = z.klic AND a.n >= 20
LEFT JOIN u_okres b ON b.okres = COALESCE(z.okres_nazev, z.kraj_nazev)
                   AND b.klasifikace = z.klasifikace
                   AND b.klic = z.klic AND b.n >= 20
LEFT JOIN u_kraj  c ON c.kraj_nazev = z.kraj_nazev
                   AND c.klasifikace = z.klasifikace
                   AND c.klic = z.klic AND c.n >= 20;
GO


/* ---------- KONTROLA ---------------------------------------- */

SELECT TOP 10 klasifikace, klic, COUNT(*) AS uzemi,
       SUM(CASE WHEN median IS NOT NULL THEN 1 ELSE 0 END) AS s_medianem
FROM dbo.v_cenove_hladiny
GROUP BY klasifikace, klic
ORDER BY COUNT(*) DESC;
GO
