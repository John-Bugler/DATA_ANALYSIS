/* ============================================================
   VALUO — KROK 24: PRAHY SPOČÍTANÉ Z DAT

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Zakládá tabulku a proceduru, spočítá prahy a vypíše je.
   DO HODNOCENÍ SE ZATÍM NIC NEZAPOJUJE — to udělá krok 24b,
   až si výsledky prohlédneš.

   ============================================================
   CO SE NAHRAZUJE
   ============================================================
   CIS_prahy_ceny.cena_min obsahuje tři čísla vzatá z ničeho:

       JC_JEDNOTKA     100 000 Kč
       JC_PARCELY      200 000 Kč
       CELEK_BUDOVA    100 000 Kč

   Jsou navíc na CELKOVÉ ceně vkladu, takže byt za 335 513 Kč
   jimi projde, i když je to převod z družstva za 4 905 Kč/m2.
   Dnes podle nich nese 2 318 vkladů hodnocení „symbolická cena"
   a jiných 1 801 „řádově nízká", aniž by to stálo na čemkoli.

   ------------------------------------------------------------
   VELIČINA PODLE METRIKY
   ------------------------------------------------------------
   Číselník CIS_metrika_ceny už u každé kombinace nemovitosti a
   typu určuje, co se porovnává. Práh se počítá z téže veličiny:

   | metrika | veličina            | co pokrývá                |
   |---------|---------------------|---------------------------|
   | JC      | Kč/m2               | byt, jiný nebytový        |
   |         |                     | prostor, ateliér,         |
   |         |                     | rozestavěná jednotka,     |
   |         |                     | dílna, pozemky, rodinný   |
   |         |                     | dům                       |
   | KUS     | Kč za kus           | garáže (2 284 vkladů)     |
   | CELEK   | Kč za celý vklad    | bytový dům, jiná stavba,  |
   |         |                     | objekt k bydlení, stavba  |
   |         |                     | pro rekreaci              |

   Tím se poprvé dostane pod kontrolu i těch 13 369 vkladů,
   které dnes nesou „porovnává se cena" a nekontroluje je nic.

   ------------------------------------------------------------
   JAK SE PRÁH POČÍTÁ
   ------------------------------------------------------------
   Ceny mají log-normální rozdělení, počítá se proto z logaritmů:

       sigma = (P75 - medián) / 0,6745
       práh zdola = exp(medián - k × sigma)
       práh shora = exp(medián + k × sigma)

   Rozptyl se odhaduje JEN Z HORNÍ POLOVINY dat. Důvod je
   doložený: kontaminace je u cen vždycky zdola — privatizace,
   dary, vypořádání. Kvantily celých dat jsou tím znehodnocené:

   | k. ú.      |   n |     P25 |  medián |     P75 |
   |------------|-----|---------|---------|---------|
   | Chodov     | 898 |  92 900 | 116 400 | 137 400 |
   | Nové Město | 805 | 134 900 | 173 000 | 197 700 |
   | Kobylisy   | 271 |  11 700 | 108 700 | 131 600 |
   | Stodůlky   | 876 |   6 450 |  95 500 | 127 700 |

   V Kobylisích a Stodůlkách leží dolní kvartil desetkrát pod
   mediánem. Práh počítaný z IQR nebo z MAD tam vyjde 1 240 a
   379 Kč/m2, tedy nevyřadí nic. Z horní poloviny vyjde 54 600 a
   33 000, což odpovídá ostatním územím.

   Odhad z rozdílu P75 a mediánu je zároveň odolný proti
   extrémům nahoře — byt za 357 995 227 Kč/m2 leží daleko nad
   P75 a na odhad nemá vliv.

   ------------------------------------------------------------
   PROČ SE NEDĚLÍ PO LETECH
   ------------------------------------------------------------
   Medián jednotkové ceny bytů v Praze vzrostl z 103 435 Kč/m2
   v roce 2021 na 139 374 v roce 2025, tedy faktor 1,35. Pásmo,
   které práh vymezuje, je při k = 3 široké faktor zhruba 2,1 a
   hodnocení „řádově nízká" pracuje s faktorem 10.

   Cenový vývoj je tedy užší než nejužší z těch pásem. Dělením
   po letech by se data roztříštila na šestinu, aniž by to na
   hodnocení mělo vliv, a v menších územích by stejně propadlo
   na delší okno.

   Vývoj po letech dá samostatný pohled v_mediany_rok, který se
   k hodnocení nepoužívá a slouží k deflaci porovnávacích
   vzorků na datum ocenění.

   ------------------------------------------------------------
   PROPADÁVÁNÍ
   ------------------------------------------------------------
   Jako u cenových hladin: nejdřív katastrální území, při
   nedostatku bodů okres, pak kraj. Minimální počet bodů je
   v číselníku — pro odhad rozptylu je potřeba víc než pro
   medián, proto zvlášť od prah_bodu.
   ============================================================ */

USE VALUO;
GO

/* ---------- 24.1 ČÍSELNÍK --------------------------------- */

IF COL_LENGTH('dbo.CIS_prahy_ceny', 'k_faktor') IS NULL
    ALTER TABLE dbo.CIS_prahy_ceny ADD
        k_faktor      decimal(4,2) NULL,   /* kolik sigma od mediánu */
        min_bodu_prah int          NULL;   /* minimum pro odhad rozptylu */
GO

UPDATE dbo.CIS_prahy_ceny
   SET k_faktor = 3.00, min_bodu_prah = 30
 WHERE k_faktor IS NULL;
GO

SELECT klasifikace, cena_min AS stary_prah, prah_bodu, k_faktor, min_bodu_prah
FROM dbo.CIS_prahy_ceny ORDER BY klasifikace;
GO


/* ---------- 24.2 TABULKA PRAHŮ ----------------------------- */

/* Metrika MUSÍ být v klíči. Táž kombinace klasifikace, klíče a
   území může mít dvě veličiny: garáže mají 835 vkladů s metrikou
   KUS a 32 s CELEK, a u pozemků se stavbou se metrika mění
   z JC na CELEK. Bez metriky v klíči skončí vložení chybou
   Violation of PRIMARY KEY.

   Zároveň se metrika normalizuje na dvě hodnoty, protože KUS
   i CELEK počítají z téže veličiny — z celkové ceny vkladu:
       JC    jednotková cena Kč/m2
       CENA  cena vkladu v Kč (sloučené KUS a CELEK)           */

IF OBJECT_ID('dbo.Valuo_prahy') IS NOT NULL
    DROP TABLE dbo.Valuo_prahy;
GO

CREATE TABLE dbo.Valuo_prahy (
    klasifikace   varchar(15)   NOT NULL,
    klic          nvarchar(210) NOT NULL,  /* DRUH:byt nebo FVU:OB */
    metrika       varchar(10)   NOT NULL,  /* JC nebo CENA */
    uroven        nvarchar(10)  NOT NULL,  /* k.ú. / okres / kraj */
    uzemi         nvarchar(100) NOT NULL,  /* název území */
    n             int           NOT NULL,
    median        decimal(18,2) NOT NULL,
    p75           decimal(18,2) NOT NULL,
    sigma         decimal(8,4)  NOT NULL,
    prah_dolni    decimal(18,2) NOT NULL,
    prah_horni    decimal(18,2) NOT NULL,
    datum_vypoctu datetime2(0)  NOT NULL,
    CONSTRAINT PK_Valuo_prahy PRIMARY KEY CLUSTERED
        (klasifikace, klic, metrika, uroven, uzemi)
);
GO


/* ---------- 24.3 PROCEDURA --------------------------------
   Veličina se bere podle metriky: u JC jednotková cena, jinak
   celková cena vkladu. Vyřazuje se totéž co u hladin, navíc
   hromadné převody podle zatřídění.                          */

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
            CASE WHEN q.klasifikace = 'JC_PARCELY' AND q.fvu_kod IS NOT NULL
                 THEN N'FVU:'  + q.fvu_kod
                 ELSE N'DRUH:' + ISNULL(q.druh, '?') END AS klic,
            t.k_faktor,
            t.min_bodu_prah,
            /* u metriky JC jednotková cena, jinak cena vkladu */
            LOG(CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                     ELSE q.cena_Kc END) AS lg
    INTO #d
    FROM dbo.v_Valuo_vzorek_q q
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod      = q.kod_ku
    JOIN dbo.CIS_prahy_ceny        t ON t.klasifikace = q.klasifikace
    WHERE ISNULL(q.mena, 'CZK') = 'CZK'
      AND q.typ_prevodu = 'KUPNI_SMLOUVA'
      AND q.hromadny_prevod = 0
      AND ISNULL(q.prodeju_tehoz_objektu, 0) < 5
      AND q.rok >= YEAR(GETDATE()) - 5
      AND (CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                ELSE q.cena_Kc END) > 0;

    CREATE INDEX IX_d ON #d (klasifikace, klic, kod_ku);

    TRUNCATE TABLE dbo.Valuo_prahy;

    /* --- úroveň katastrálního území --- */
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
               COUNT(*)  OVER (PARTITION BY klasifikace, klic, metrika, kod_ku) AS n,
               p50, p75,
               /* 0,6745 je kvantil 0,75 normovaného rozdělení */
               (p75 - p50) / 0.6745 AS sig,
               min_bodu_prah
        FROM (
            SELECT klasifikace, klic, metrika, ku_nazev, kod_ku,
                   k_faktor, min_bodu_prah,
                   PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika, kod_ku) AS p50,
                   PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika, kod_ku) AS p75
            FROM #d
        ) a
    ) b
    WHERE n >= min_bodu_prah AND p75 > p50;

    /* --- úroveň okresu --- */
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
               COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika, okres) AS n,
               p50, p75, (p75 - p50) / 0.6745 AS sig, min_bodu_prah
        FROM (
            SELECT klasifikace, klic, metrika, okres, k_faktor, min_bodu_prah,
                   PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika, okres) AS p50,
                   PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika, okres) AS p75
            FROM #d
        ) a
    ) b
    WHERE n >= min_bodu_prah AND p75 > p50;

    /* --- úroveň kraje --- */
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
               COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika, kraj_nazev) AS n,
               p50, p75, (p75 - p50) / 0.6745 AS sig, min_bodu_prah
        FROM (
            SELECT klasifikace, klic, metrika, kraj_nazev, k_faktor,
                   min_bodu_prah,
                   PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika, kraj_nazev) AS p50,
                   PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                       OVER (PARTITION BY klasifikace, klic, metrika, kraj_nazev) AS p75
            FROM #d
        ) a
    ) b
    WHERE n >= min_bodu_prah AND p75 > p50;

    DROP TABLE #d;
END;
GO

EXEC dbo.sp_prepocet_prahu;
GO


/* ---------- 24.4 CO VZNIKLO -------------------------------- */

SELECT metrika, uroven, COUNT(*) AS kombinaci, SUM(n) AS bodu
FROM dbo.Valuo_prahy GROUP BY metrika, uroven
ORDER BY metrika, uroven;
GO

/* Pražské byty — tohle je kontrolní vzorek, čísla musí dávat
   smysl znalci                                               */
SELECT uzemi, n,
       CAST(median AS decimal(12,0))     AS median,
       CAST(prah_dolni AS decimal(12,0)) AS prah_zdola,
       CAST(prah_horni AS decimal(12,0)) AS prah_shora,
       sigma
FROM dbo.Valuo_prahy
WHERE klasifikace = 'JC_JEDNOTKA' AND klic = N'DRUH:byt'
  AND uroven = N'k.ú.'
ORDER BY median DESC;
GO

/* Garáže — poprvé pod kontrolou, práh na ceně za kus */
SELECT uroven, uzemi, n,
       CAST(median AS decimal(12,0))     AS median_Kc,
       CAST(prah_dolni AS decimal(12,0)) AS prah_zdola,
       CAST(prah_horni AS decimal(12,0)) AS prah_shora
FROM dbo.Valuo_prahy
WHERE klic = N'DRUH:garáž' ORDER BY uroven, n DESC;
GO

/* Pozemky v Praze podle funkčního využití */
SELECT uzemi, klic, n,
       CAST(median AS decimal(12,0))     AS median,
       CAST(prah_dolni AS decimal(12,0)) AS prah_zdola,
       CAST(prah_horni AS decimal(12,0)) AS prah_shora
FROM dbo.Valuo_prahy
WHERE klasifikace = 'JC_PARCELY' AND klic LIKE N'FVU:%'
  AND uroven = N'k.ú.'
ORDER BY n DESC;
GO

/* Srovnání se starými pevnými prahy — kolik vkladů by nově
   spadlo pod práh a kolik nad                                */
SELECT q.klasifikace, q.metrika,
       COUNT(*) AS vkladu,
       SUM(CASE WHEN CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                          ELSE q.cena_Kc END < p.prah_dolni
                THEN 1 ELSE 0 END) AS pod_prahem,
       SUM(CASE WHEN CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                          ELSE q.cena_Kc END > p.prah_horni
                THEN 1 ELSE 0 END) AS nad_prahem
FROM dbo.v_Valuo_vzorek_q q
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = q.kod_ku
JOIN dbo.Valuo_prahy p
       ON p.klasifikace = q.klasifikace
      AND p.uroven = N'k.ú.' AND p.uzemi = c.ku_nazev
      AND p.klic = CASE WHEN q.klasifikace = 'JC_PARCELY'
                         AND q.fvu_kod IS NOT NULL
                        THEN N'FVU:'  + q.fvu_kod
                        ELSE N'DRUH:' + ISNULL(q.druh, '?') END
WHERE (CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
            ELSE q.cena_Kc END) > 0
GROUP BY q.klasifikace, q.metrika ORDER BY vkladu DESC;
GO
