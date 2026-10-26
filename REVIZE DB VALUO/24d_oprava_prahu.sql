/* ============================================================
   VALUO — KROK 24d: DVĚ OPRAVY PRAHŮ

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Přepisuje proceduru z kroku 24c. Do hodnocení se pořád nic
   nezapojuje.

   ============================================================
   OPRAVA 1: FUNKČNÍ VYUŽITÍ MIMO PRAHU
   ============================================================
   Ve výpisu stála skupina OBYTNE|nad1500 dvakrát:

       Hlavní město Praha   n=170   medián 3 381 Kč/m2
       Středočeský kraj     n=137   medián    66 Kč/m2

   Funkční využití je přitom z územního plánu Prahy a mimo ni
   platit nemůže. Tabulka KN_parcel_UP je v pořádku — obsahuje
   jen pražské parcely, 122 933 v 96 územích.

   Chyba je v tom, že v_vklad_UP přiřazuje funkční využití CELÉMU
   VKLADU. Obsahuje-li vklad parcelu v Praze i mimo ni, propíše
   se pražské FVU na celý vklad, a ten pak v datech vystupuje
   podle svého hlavního území:

       V-5007/2025-208  Kluk, okres Nymburk     FVU:OB  249 366 m2
       V-6681/2024-208  Loučeň, okres Nymburk   FVU:OB   34 184 m2
       V-593/2024-210   Dolní Břežany           FVU:OB   28 922 m2

   Kluk je od Prahy padesát kilometrů. Oprava: klíč podle FVU se
   použije jen tehdy, leží-li vklad v Praze.

   ============================================================
   OPRAVA 2: ABSURDNÍ HORNÍ PRAHY
   ============================================================
   Horní prahy vycházely nepoužitelně:

   | skupina            | medián |  horní práh | poměr |
   |--------------------|--------|-------------|-------|
   | OBYTNE 600-1500    |  8 793 |     169 127 |   19x |
   | OBYTNE 100-300     |  4 342 |     446 884 |  103x |
   | orná půda Zlatá    |    819 |   8 230 609 | 10048x|

   Příčina je v konstrukci: práh je exp(medián + k × sigma), a
   kde jsou data rozptýlená, vyjde sigma 1,5 až 3,0. Při k = 3
   je pak exp(3 × 3,0) faktor 8 100.

   Rozptyl přitom není měřítkem trhu, ale toho, jak je vzorek
   nehomogenní. Čím je kategorie zasolenější, tím širší pásmo —
   tedy přesně naopak, než by mělo být.

   Oprava: pásmo se omezí na desetinásobek mediánu oběma směry.
   Deset je tentýž faktor, s jakým pracuje hodnocení „řádově
   nízká" a „řádově vysoká", takže se tím prahy s hodnocením
   sladí.

       práh zdola = GREATEST(exp(medián - k·sigma), medián / 10)
       práh shora = LEAST   (exp(medián + k·sigma), medián × 10)

   U čistých dat se strop neuplatní a rozhoduje sigma. Zahrady
   v okrese Praha-východ mají sigmu 0,4, takže pásmo 2 866 až
   16 092 Kč/m2 zůstane. U zasolených kategorií strop zabrání
   nesmyslu.

   Sloupce prah_dolni a prah_horni proto nově nesou užší z obou
   mezí; původní nezkrácené hodnoty se dají dopočítat ze sigmy
   a mediánu, které v tabulce zůstávají.
   ============================================================ */

USE VALUO;
GO

/* ---------- 24d.1 STROP DO ČÍSELNÍKU ----------------------- */

IF COL_LENGTH('dbo.CIS_prahy_ceny', 'max_nasobek') IS NULL
    ALTER TABLE dbo.CIS_prahy_ceny ADD max_nasobek decimal(6,2) NULL;
GO

UPDATE dbo.CIS_prahy_ceny SET max_nasobek = 10.00
 WHERE max_nasobek IS NULL;
GO

SELECT klasifikace, k_faktor, min_bodu_prah, max_nasobek, prah_bodu
FROM dbo.CIS_prahy_ceny ORDER BY klasifikace;
GO


/* ---------- 24d.2 PROCEDURA -------------------------------- */

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
            /* funkční využití jen pro vklady v Praze — jinde
               územní plán Prahy neplatí */
            CASE WHEN q.klasifikace = 'JC_PARCELY'
                  AND f.skupina IS NOT NULL
                  AND c.kraj_nazev = N'Hlavní město Praha'
                 THEN N'FVU:' + f.skupina + N'|' + v.pasmo
                 ELSE N'DRUH:' + ISNULL(q.druh, '?') END AS klic,
            CASE WHEN q.klasifikace = 'JC_PARCELY'
                  AND f.skupina IS NOT NULL
                  AND c.kraj_nazev = N'Hlavní město Praha'
                 THEN 1 ELSE 0 END AS jen_kraj,
            t.k_faktor,
            t.min_bodu_prah,
            t.max_nasobek,
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
           CAST(GREATEST(EXP(p50 - k_faktor * sig),
                         EXP(p50) / max_nasobek) AS decimal(18,2)),
           CAST(LEAST   (EXP(p50 + k_faktor * sig),
                         EXP(p50) * max_nasobek) AS decimal(18,2)),
           GETDATE()
    FROM (
        SELECT DISTINCT klasifikace, klic, metrika, ku_nazev, k_faktor,
               max_nasobek,
               COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika,
                                           kod_ku) AS n,
               p50, p75, (p75 - p50) / 0.6745 AS sig, min_bodu_prah
        FROM (
            SELECT klasifikace, klic, metrika, ku_nazev, kod_ku,
                   k_faktor, min_bodu_prah, max_nasobek,
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
           CAST(GREATEST(EXP(p50 - k_faktor * sig),
                         EXP(p50) / max_nasobek) AS decimal(18,2)),
           CAST(LEAST   (EXP(p50 + k_faktor * sig),
                         EXP(p50) * max_nasobek) AS decimal(18,2)),
           GETDATE()
    FROM (
        SELECT DISTINCT klasifikace, klic, metrika, okres, k_faktor,
               max_nasobek,
               COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika,
                                           okres) AS n,
               p50, p75, (p75 - p50) / 0.6745 AS sig, min_bodu_prah
        FROM (
            SELECT klasifikace, klic, metrika, okres, k_faktor,
                   min_bodu_prah, max_nasobek,
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
           CAST(GREATEST(EXP(p50 - k_faktor * sig),
                         EXP(p50) / max_nasobek) AS decimal(18,2)),
           CAST(LEAST   (EXP(p50 + k_faktor * sig),
                         EXP(p50) * max_nasobek) AS decimal(18,2)),
           GETDATE()
    FROM (
        SELECT DISTINCT klasifikace, klic, metrika, kraj_nazev, k_faktor,
               max_nasobek,
               COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika,
                                           kraj_nazev) AS n,
               p50, p75, (p75 - p50) / 0.6745 AS sig, min_bodu_prah
        FROM (
            SELECT klasifikace, klic, metrika, kraj_nazev, k_faktor,
                   min_bodu_prah, max_nasobek,
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


/* ---------- 24d.3 KONTROLA -------------------------------- */

/* Funkční využití musí být jen pro Prahu */
SELECT uzemi, COUNT(*) AS kombinaci, SUM(n) AS vkladu
FROM dbo.Valuo_prahy WHERE klic LIKE N'FVU:%'
GROUP BY uzemi;
GO

/* Pozemky v Praze po obou opravách */
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

/* Nejširší pásma — kde se uplatnil strop */
SELECT TOP 20
        kategorie = CASE klasifikace
            WHEN 'JC_JEDNOTKA'  THEN N'jednotka'
            WHEN 'JC_PARCELY'   THEN N'pozemek'
            WHEN 'CELEK_BUDOVA' THEN N'budova'
            ELSE N'nezařazeno' END + N' ' + REPLACE(klic, N'DRUH:', N''),
        jednotka = CASE metrika WHEN 'JC' THEN N'Kč/m²' ELSE N'Kč' END,
        uroven, uzemi, vzorku = n,
        median = CAST(median AS decimal(12,0)),
        zdola  = CAST(prah_dolni AS decimal(12,0)),
        shora  = CAST(prah_horni AS decimal(12,0)),
        rozptyl = sigma,
        strop = CASE WHEN ABS(prah_horni - median * 10) < 1
                     THEN N'ano' ELSE N'ne' END
FROM dbo.Valuo_prahy
ORDER BY sigma DESC;
GO

/* Byty — kontrola, že se čistým datům nic nezkazilo */
SELECT  co = N'BYT, Kč/m²',
        kat_uzemi = uzemi, vzorku = n,
        median = CAST(median AS decimal(12,0)),
        zdola  = CAST(prah_dolni AS decimal(12,0)),
        shora  = CAST(prah_horni AS decimal(12,0)),
        rozptyl = sigma
FROM dbo.Valuo_prahy
WHERE klic = N'DRUH:byt' AND uroven = N'k.ú.'
ORDER BY median DESC;
GO
