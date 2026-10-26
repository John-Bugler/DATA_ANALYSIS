/* ============================================================
   VALUO — KROK 23: DETEKCE HROMADNÝCH PŘEVODŮ

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Zakládá tabulku a proceduru, mění dva pohledy.
   Spusť celé najednou.

   ============================================================
   NÁLEZ
   ============================================================
   Při privatizaci obecního fondu, převodu z družstva nebo
   prodeji celého domu po bytech se cena nevyjednává za každou
   jednotku, ale stanoví vzorcem

       cena = plocha × pevná cena za metr

   Jednotková cena pak u všech vyjde NAPROSTO STEJNÁ, na haléře,
   i když se plochy a celkové ceny liší. Na trhu to nenastane —
   tam se vyjednává cena za celou věc a jednotková cena z ní
   vychází až jako podíl, u každého prodeje jiný.

   Doložený případ, k. ú. Kobylisy:

   | cena       | plocha   | jednotková cena |
   |------------|----------|-----------------|
   | 335 513 Kč | 68,40 m2 |        4 905,16 |
   | 314 421 Kč | 64,10 m2 |        4 905,16 |

   Takových bytů je v Kobylisích 283 z 532, tedy 53 %. Medián
   bytů tam proto vycházel 4 905 Kč/m2 místo trhu, a protože
   kontaminace přesáhla polovinu, nepomohla ani robustnost
   mediánu.

   Dopad na hodnocení byl obrácený, než má být:

       bez výhrad       336 vkladů, průměrná JC   6 763 Kč/m2
       řádově vysoká    192 vkladů, průměrná JC 121 755 Kč/m2

   Tedy skutečné tržní prodeje označené jako vadné a privatizační
   převody propuštěné jako bezvadné.

   ------------------------------------------------------------
   PROČ TO NEZACHYTILY STÁVAJÍCÍ PŘÍZNAKY
   ------------------------------------------------------------
   typ_prevodu       hledá v listině odkaz na zákon 311/2013;
                     tyto převody jsou vedené jako kupní smlouva
   prodeju_tehoz_objektu  počítá se jen pro budovy, ne pro
                     jednotky
   cena_min          práh 100 000 Kč je na CELKOVÉ ceně vkladu,
                     takže byt za 335 513 Kč jím projde

   ------------------------------------------------------------
   JAK SE TO POZNÁ
   ------------------------------------------------------------
   Skupina vkladů se shodnou kombinací

       klasifikace + katastrální území + druh + jednotková cena

   u níž je PĚT A VÍCE vkladů při ALESPOŇ TŘECH různých
   plochách.

   Podmínka tří různých ploch vylučuje náhodu: dva byty stejné
   velikosti za stejnou cenu shoda být může, pět bytů se třemi
   různými plochami a jednotkovou cenou shodnou na haléř nikoli.

   Detektor nestojí na žádném mediánu ani prahu, takže do
   výpočtu hladin nevnáší kruhovou závislost.

   ------------------------------------------------------------
   ROZSAH
   ------------------------------------------------------------
       jednotky   43 skupin,  711 vkladů
       pozemky    23 skupin,  180 vkladů
       budovy      0 skupin,    0 vkladů

   Ověřený dopad na mediány bytů:

   | k. ú.       | před    | po      | n před → po |
   |-------------|---------|---------|-------------|
   | Kobylisy    |   4 905 | 108 726 |  531 → 271  |
   | Háje        | 126 400 | 130 559 |  535 → 502  |
   | Chodov      | 112 545 | 116 383 |  987 → 898  |
   | Krč         | 110 976 | 113 065 |  597 → 583  |
   | Stodůlky    |  94 249 |  95 488 |  892 → 876  |
   | Nové Město  | 171 764 | 173 269 |  806 → 805  |
   | Modřany     | 117 146 | 117 146 |  423 → 423  |

   Kde byla kontaminace malá, medián se zpřesnil o jednotky
   procent. Kde byla velká, hladina se opravila. Žádná funkční
   hladina se nerozbila.

   ------------------------------------------------------------
   PROČ TABULKA A NE POHLED
   ------------------------------------------------------------
   Detekce potřebuje jednotkovou cenu, kterou teprve počítá
   v_Valuo_vzorek. Pohled nad pohledem by vedl k tomu, že se
   v_Valuo_vzorek vyhodnotí při každém dotazu několikrát.
   Výsledek se proto ukládá do tabulky a plní procedurou.

   PROCEDURU JE NUTNÉ SPUSTIT PO KAŽDÉM IMPORTU, stejně jako
   tři stávající přepočty.
   ============================================================ */

USE VALUO;
GO

/* ---------- 23.1 TABULKA ----------------------------------- */

IF OBJECT_ID('dbo.Valuo_hromadne_prevody') IS NULL
CREATE TABLE dbo.Valuo_hromadne_prevody (
    /* typy musí přesně odpovídat v_Valuo_vzorek, jinak by join
       dělal implicitní konverzi a nepoužil index */
    klasifikace      varchar(15)    NOT NULL,
    kat_uzemi        varchar(60)    NOT NULL,
    druh             varchar(100)   NOT NULL,
    jedn_cena_Kc_m2  decimal(14,2)  NOT NULL,
    vkladu           int            NOT NULL,
    ruznych_ploch    int            NOT NULL,
    cena_min         decimal(18,2)  NULL,
    cena_max         decimal(18,2)  NULL,
    datum_vypoctu    datetime2(0)   NOT NULL,
    CONSTRAINT PK_Valuo_hromadne_prevody PRIMARY KEY CLUSTERED
        (klasifikace, kat_uzemi, druh, jedn_cena_Kc_m2)
);
GO


/* ---------- 23.2 PROCEDURA --------------------------------- */

CREATE OR ALTER PROCEDURE dbo.sp_detekce_hromadnych_prevodu
    @min_vkladu int = 5,
    @min_ploch  int = 3
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Valuo_hromadne_prevody;

    INSERT INTO dbo.Valuo_hromadne_prevody
        (klasifikace, kat_uzemi, druh, jedn_cena_Kc_m2,
         vkladu, ruznych_ploch, cena_min, cena_max, datum_vypoctu)
    SELECT  v.klasifikace,
            v.kat_uzemi,
            ISNULL(v.druh, '?'),
            v.jedn_cena_Kc_m2,
            COUNT(*),
            COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2,
                                    v.plocha_parcel_m2,
                                    v.plocha_budovy_m2)),
            MIN(v.cena_Kc),
            MAX(v.cena_Kc),
            GETDATE()
    FROM dbo.v_Valuo_vzorek v
    WHERE v.jedn_cena_Kc_m2 > 0
    GROUP BY v.klasifikace, v.kat_uzemi, ISNULL(v.druh, '?'), v.jedn_cena_Kc_m2
    HAVING COUNT(*) >= @min_vkladu
       AND COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2,
                                   v.plocha_parcel_m2,
                                   v.plocha_budovy_m2)) >= @min_ploch;
END;
GO

EXEC dbo.sp_detekce_hromadnych_prevodu;
GO

SELECT klasifikace, COUNT(*) AS skupin, SUM(vkladu) AS vkladu
FROM dbo.Valuo_hromadne_prevody
GROUP BY klasifikace ORDER BY vkladu DESC;
GO

/* Deset největších skupin */
SELECT TOP 10 kat_uzemi, druh, jedn_cena_Kc_m2, vkladu, ruznych_ploch,
       cena_min, cena_max
FROM dbo.Valuo_hromadne_prevody
ORDER BY vkladu DESC;
GO


/* ---------- 23.3 CENOVÉ HLADINY ----------------------------
   Proti předchozí verzi se mění jen to, že se vyřadí vklady
   z hromadných převodů.                                      */

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
                 ELSE                              N'DRUH:' + ISNULL(q.druh, '?')
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
      AND ISNULL(q.prodeju_tehoz_objektu, 0) < 5
      AND q.rok >= YEAR(GETDATE()) - 5
      AND NOT EXISTS (SELECT 1 FROM dbo.Valuo_hromadne_prevody h
                      WHERE h.klasifikace     = q.klasifikace
                        AND h.kat_uzemi       = q.kat_uzemi
                        AND h.druh            = ISNULL(q.druh, '?')
                        AND h.jedn_cena_Kc_m2 = q.jedn_cena_Kc_m2)
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


/* ---------- 23.4 PRACOVNÍ POHLED ---------------------------
   Nový sloupec hromadny_prevod a nové hodnocení.             */

CREATE OR ALTER VIEW dbo.v_Valuo_vzorek_q
AS
WITH hlavni AS (
    SELECT  v.cislo_vkladu,
            MIN(v.nemovitost) AS nemovitost,
            MIN(v.typ)        AS typ,
            MIN(v.typ_plochy) AS typ_plochy,
            MIN(TRY_CONVERT(decimal(18,2),
                SUBSTRING(v.popis,
                          CHARINDEX(N'domu a pozemku ', v.popis) + 15,
                          CHARINDEX(N'/', v.popis + N'/',
                                    CHARINDEX(N'domu a pozemku ', v.popis))
                          - CHARINDEX(N'domu a pozemku ', v.popis) - 15)))
                              AS citatel_podilu
    FROM dbo.Valuo_data v
    WHERE (v.vklad_klasifikace = 'JC_JEDNOTKA'  AND v.nemovitost = N'jednotka')
       OR (v.vklad_klasifikace = 'CELEK_BUDOVA' AND v.nemovitost = N'budova')
       OR (v.vklad_klasifikace = 'JC_PARCELY'   AND v.nemovitost = N'parcela')
    GROUP BY v.cislo_vkladu
),
metrika AS (
    SELECT  v.cislo_vkladu,
            ISNULL(m.metrika,
                   CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                        ELSE 'CELEK' END)            AS metrika_dle_ciselniku,
            CASE
                WHEN v.klasifikace = 'JC_PARCELY'
                 AND v.na_pozemku_stavba = 1                 THEN 'CELEK'
                WHEN v.klasifikace = 'CELEK_BUDOVA'
                 AND v.cena_patri_stavbe = 0                 THEN 'CELEK'
                WHEN v.klasifikace = 'CELEK_BUDOVA'
                 AND ISNULL(v.prodeju_tehoz_objektu, 0) >= 5 THEN 'CELEK'
                WHEN ISNULL(m.metrika, '') = 'JC_PODLAHOVA'
                 AND v.plocha_podlahova_m2 > 0               THEN 'JC'
                WHEN ISNULL(m.metrika, '') = 'JC_PODLAHOVA'  THEN 'CELEK'
                ELSE ISNULL(m.metrika,
                       CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                            ELSE 'CELEK' END)
            END                                              AS metrika
    FROM dbo.v_Valuo_vzorek v
    LEFT JOIN hlavni p ON p.cislo_vkladu = v.cislo_vkladu
    LEFT JOIN dbo.CIS_metrika_ceny m
           ON m.nemovitost = p.nemovitost AND m.typ = p.typ
)
SELECT  v.cislo_vkladu,
        v.datum_zplatneni,
        v.rok,
        v.mesic,
        v.kod_ku,
        v.kat_uzemi,
        v.obec,
        v.okres,
        v.kraj,
        v.klasifikace,
        v.duvod,
        v.typ_prevodu,
        v.druh,
        v.ruznych_druhu,
        v.nemovitosti_ve_vkladu,
        v.duplicitnich_radku,
        v.plocha_parcel_m2,
        v.plocha_jednotky_m2,
        v.plocha_budovy_m2,
        v.plocha_podlahova_m2,
        v.typ_plochy_stavby,
        v.prodeju_tehoz_objektu,
        v.cena_patri_stavbe,
        v.stavba_samostatna,
        v.cena_Kc,
        v.mena,
        v.cena_v_mene,
        v.kurz_pouzity,
        v.kurz_datum,

        /* vklad je součástí skupiny se shodnou jednotkovou cenou
           při různých plochách — cena byla stanovena vzorcem */
        CASE WHEN hp.jedn_cena_Kc_m2 IS NULL THEN 0 ELSE 1 END
                                                    AS hromadny_prevod,
        hp.vkladu                                   AS hromadne_vkladu,

        mt.metrika,
        CASE WHEN mt.metrika = 'JC' THEN v.jedn_cena_Kc_m2 END AS jedn_cena_Kc_m2,

        up.fvu_kod,
        up.mira_vyuziti,

        h.median                                    AS median_Kc_m2,
        h.bodu                                      AS bodu_v_hladine,
        h.uroven                                    AS uroven_hladiny,
        CASE WHEN mt.metrika = 'JC'
             THEN CAST(v.jedn_cena_Kc_m2 / NULLIF(h.median, 0)
                       AS decimal(10,3)) END        AS pomer_k_medianu,

        CASE
            WHEN ISNULL(v.mena, 'CZK') <> 'CZK'
             AND v.kurz_pouzity IS NULL              THEN N'cizí měna bez kurzu'
            WHEN v.typ_prevodu <> 'KUPNI_SMLOUVA'    THEN N'nestandardní převod'

            /* cena stanovená vzorcem plocha × pevná cena —
               privatizace, převod z družstva, prodej domu
               po bytech */
            WHEN hp.jedn_cena_Kc_m2 IS NOT NULL      THEN N'hromadný převod'

            WHEN v.cena_Kc < t.cena_min              THEN N'symbolická cena'
            WHEN v.klasifikace = 'CELEK_BUDOVA'
             AND v.cena_patri_stavbe = 0              THEN N'oddělené vlastnictví'
            WHEN v.klasifikace = 'CELEK_BUDOVA'
             AND ISNULL(v.prodeju_tehoz_objektu, 0) >= 5
                                                     THEN N'podíl na budově'
            WHEN mt.metrika_dle_ciselniku = 'JC_PODLAHOVA'
             AND ISNULL(v.plocha_podlahova_m2, 0) = 0
                                                     THEN N'chybí podlahová plocha'
            WHEN v.klasifikace = 'JC_PARCELY'
             AND v.na_pozemku_stavba = 1              THEN N'chybí podlahová plocha'
            WHEN mt.metrika <> 'JC'                  THEN N'porovnává se cena'
            WHEN v.jedn_cena_Kc_m2 IS NULL           THEN N'bez JC'
            WHEN h.median IS NULL                    THEN N'bez srovnání'
            WHEN v.jedn_cena_Kc_m2 / h.median < 0.1  THEN N'řádově nízká'
            WHEN v.jedn_cena_Kc_m2 / h.median > 10.0 THEN N'řádově vysoká'
            ELSE                                          N'bez výhrad'
        END                                         AS hodnoceni_ceny,

        CASE WHEN v.klasifikace = 'JC_PARCELY' AND v.na_pozemku_stavba = 1
             THEN N'stavba je součástí pozemku' ELSE N'—' END
                                                    AS pozemek_se_stavbou,

        CASE WHEN ISNULL(v.mena, 'CZK') = 'CZK' THEN N'—'
             WHEN v.kurz_pouzity IS NULL        THEN N'bez kurzu'
             ELSE v.mena + N' kurzem ČNB k '
                  + CONVERT(varchar(10), v.kurz_datum, 104)
        END                                         AS prepocet_meny,

        CASE
            WHEN r.nemovitost IS NULL                THEN N'bez pravidla'
            WHEN r.plocha_max = 0                    THEN N'nevhodný zdroj plochy'
            WHEN COALESCE(v.plocha_jednotky_m2,
                          v.plocha_budovy_m2,
                          v.plocha_parcel_m2)
                 BETWEEN r.plocha_min AND r.plocha_max
                                                     THEN N'v rozsahu'
            ELSE                                          N'mimo rozsah'
        END                                         AS hodnoceni_plochy,

        CASE
            WHEN v.klasifikace <> 'JC_JEDNOTKA'      THEN N'—'
            WHEN p.citatel_podilu IS NULL            THEN N'nenačteno'
            WHEN p.citatel_podilu < 100              THEN N'malý čitatel - podezřelý'
            ELSE                                          N'plošný zlomek'
        END                                         AS hodnoceni_podilu,

        CASE WHEN v.duplicitnich_radku > 0 THEN N'ano' ELSE N'ne' END
                                                    AS obsahuje_duplicity,

        v.geo_bod,
        v.LAT,
        v.LON
FROM dbo.v_Valuo_vzorek v
LEFT JOIN hlavni  p  ON p.cislo_vkladu  = v.cislo_vkladu
LEFT JOIN metrika mt ON mt.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.Valuo_hromadne_prevody hp
       ON hp.klasifikace     = v.klasifikace
      AND hp.kat_uzemi       = v.kat_uzemi
      AND hp.druh            = ISNULL(v.druh, '?')
      AND hp.jedn_cena_Kc_m2 = v.jedn_cena_Kc_m2
LEFT JOIN dbo.CIS_prahy_ceny t ON t.klasifikace   = v.klasifikace
LEFT JOIN dbo.v_vklad_UP    up ON up.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.v_cenove_hladiny h
       ON h.kod_ku      = v.kod_ku
      AND h.klasifikace = v.klasifikace
      AND h.klic        = CASE WHEN v.klasifikace = 'JC_PARCELY'
                                AND up.fvu_kod IS NOT NULL
                               THEN N'FVU:'  + up.fvu_kod
                               ELSE N'DRUH:' + ISNULL(v.druh, '?') END
LEFT JOIN dbo.CIS_rozsahy_ploch r
       ON r.nemovitost = p.nemovitost
      AND r.typ        = p.typ
      AND r.typ_plochy = p.typ_plochy;
GO


/* ---------- 23.5 KONTROLA ---------------------------------- */

/* Kobylisy — medián byl 5 036,74 Kč/m2 při 528 bodech */
SELECT c.ku_nazev AS kat_uzemi, h.median AS median_Kc_m2, h.bodu, h.uroven
FROM dbo.v_cenove_hladiny h
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = h.kod_ku
WHERE h.klasifikace = 'JC_JEDNOTKA' AND h.klic = N'DRUH:byt'
  AND c.ku_nazev IN (N'Kobylisy', N'Chodov', N'Háje', N'Krč', N'Stodůlky',
                     N'Nové Město', N'Modřany', N'Smíchov', N'Žižkov')
ORDER BY h.median;
GO

/* Kobylisy — rozložení hodnocení. Bylo: bez výhrad 336 (JC 6 763),
   řádově vysoká 192 (JC 121 755)                              */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu,
       CAST(AVG(jedn_cena_Kc_m2) AS decimal(12,0)) AS prum_JC
FROM dbo.v_Valuo_vzorek_q
WHERE kat_uzemi = N'Kobylisy' AND druh = N'byt'
GROUP BY hodnoceni_ceny ORDER BY vkladu DESC;
GO

/* Celý vzorek */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO

/* Hladiny podle úrovně */
SELECT klasifikace, uroven, COUNT(*) AS kombinaci, SUM(bodu) AS bodu
FROM dbo.v_cenove_hladiny
GROUP BY klasifikace, uroven ORDER BY klasifikace, uroven;
GO

/* Kde se hromadné převody vyskytují nejčastěji */
SELECT TOP 15 kat_uzemi, druh, COUNT(*) AS skupin, SUM(vkladu) AS vkladu
FROM dbo.Valuo_hromadne_prevody
GROUP BY kat_uzemi, druh ORDER BY SUM(vkladu) DESC;
GO
