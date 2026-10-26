/* ============================================================
   VALUO — KROK 20: POZEMEK SE STAVBOU JAKO SOUČÁSTÍ

   Jen pohledy, do dat nezasahuje. Spusť celé najednou.
   Nezávisí na krocích 17 a 18.

   ------------------------------------------------------------
   NÁLEZ
   ------------------------------------------------------------
   Je-li stavba součástí pozemku (nikoli samostatnou
   nemovitostí), obsahuje vklad jen parcely a klasifikace mu
   dá JC_PARCELY. Cena ale zahrnuje i tu stavbu, zatímco
   jednotková cena se počítá dělením výměrou pozemků — a vyjde
   proto nesmyslně vysoká.

   Rozsah ve srovnávacím vzorku:

   | vklady JC_PARCELY    | vkladů | řádově vysoká JC | podíl  |
   |----------------------|--------|------------------|--------|
   | jen pozemky          |  3 572 |              162 |  4,54 %|
   | na pozemku je stavba |     46 |               20 | 43,48 %|

   Desetinásobný rozdíl. Celkem je takových vkladů 76.

   Příklad — V-29743/2025-101, Strašnice:
       popis  „č. 3395/16 Strašnice (součástí je stavba
               č.p. 2397, čst obce Strašnice)"
       cena   5 000 000 EUR = 124 725 000 Kč
       plochy 501 m2 zastavěná plocha + 205 m2 zeleň
       JC     176 664 Kč/m2 proti mediánu 5 000 Kč/m2

   Cena je za pozemky i budovu na nich; jednotková cena za metr
   pozemku tu nemá žádný význam.

   ------------------------------------------------------------
   ŘEŠENÍ
   ------------------------------------------------------------
   Takový vklad se porovnává jako funkční celek — stejně jako
   rodinný dům, kde se jednotková cena neurčuje a hodnotí se
   poloha, velikost stavby, výměra pozemků a příslušenství
   zároveň.

   Prakticky:
     - základní pohled nese příznak na_pozemku_stavba
     - do cenových hladin takové vklady nevstupují, aby
       nenadhodnocovaly medián
     - v pracovním pohledu dostanou metriku CELEK a hodnocení
       „porovnává se cena", takže se cena a výměry zobrazí
       zvlášť a jednotková cena se nepočítá

   Rozpoznání stojí na textu „součástí je stavba" v popisu.
   Je to vlastní formulace katastru pro stavbu, která není
   samostatnou nemovitostí; jiný způsob, jak to z dat zjistit,
   není.
   ============================================================ */

USE VALUO;
GO

/* ---------- 20.1 KONTROLA PŘED ZMĚNOU ---------------------- */

SELECT COUNT(DISTINCT cislo_vkladu) AS vkladu_se_stavbou_na_pozemku
FROM dbo.Valuo_data
WHERE vklad_klasifikace = 'JC_PARCELY'
  AND popis LIKE N'%součástí je stavba%';
GO


/* ---------- 20.2 ZÁKLADNÍ POHLED S PŘÍZNAKEM --------------- */

CREATE OR ALTER VIEW dbo.v_Valuo_vzorek
AS
WITH vklad AS (
    SELECT  v.cislo_vkladu,
            MIN(v.id)                      AS id_prvni,
            MIN(v.datum_zplatneni)         AS datum_zplatneni,
            MIN(v.rok)                     AS rok,
            MIN(v.mesic)                   AS mesic,
            MIN(v.kod_ku)                  AS kod_ku,
            MAX(v.cena_Kc)                 AS cena,
            MAX(v.cenovy_udaj)             AS cena_v_mene,
            MIN(v.mena)                    AS mena,
            MIN(v.kurz_pouzity)            AS kurz_pouzity,
            MIN(v.kurz_datum)              AS kurz_datum,
            MIN(v.typ_prevodu)             AS typ_prevodu,
            MIN(v.vklad_klasifikace)       AS klasifikace,
            MIN(v.vklad_duvod)             AS duvod,
            MIN(v.vklad_nemovitosti)       AS nemovitosti,
            MIN(v.vklad_duplicit)          AS duplicit,
            MIN(v.vklad_plocha_parcel)     AS plocha_parcel,
            MIN(v.vklad_plocha_jednotky)   AS plocha_jednotky,
            MIN(v.vklad_plocha_budovy)     AS plocha_budovy,

            /* stavba je součástí pozemku, nikoli samostatnou
               nemovitostí — cena ji zahrnuje, výměra ne */
            MAX(CASE WHEN v.popis LIKE N'%součástí je stavba%'
                     THEN 1 ELSE 0 END)    AS na_pozemku_stavba,

            MIN(CASE WHEN v.vklad_klasifikace = 'JC_JEDNOTKA'
                      AND v.nemovitost = N'jednotka' THEN v.typ
                     WHEN v.vklad_klasifikace = 'CELEK_BUDOVA'
                      AND v.nemovitost = N'budova'   THEN v.typ
                     WHEN v.vklad_klasifikace = 'JC_PARCELY'
                      AND v.nemovitost = N'parcela'  THEN v.typ
                END)                       AS druh,
            COUNT(DISTINCT v.typ)          AS ruznych_druhu
    FROM dbo.Valuo_data v
    WHERE v.geo_zdroj   = 'KN_refPoint'
      AND v.cenovy_udaj > 0
    GROUP BY v.cislo_vkladu
)
SELECT  k.cislo_vkladu,
        k.datum_zplatneni,
        k.rok,
        k.mesic,

        k.kod_ku,
        c.ku_nazev                              AS kat_uzemi,
        c.obec_nazev                            AS obec,
        COALESCE(c.okres_nazev, c.kraj_nazev)   AS okres,
        c.kraj_nazev                            AS kraj,

        k.klasifikace,
        k.duvod,
        k.typ_prevodu,
        k.druh,
        k.ruznych_druhu,
        k.nemovitosti                           AS nemovitosti_ve_vkladu,
        k.duplicit                              AS duplicitnich_radku,
        k.na_pozemku_stavba,

        k.plocha_parcel                         AS plocha_parcel_m2,
        k.plocha_jednotky                       AS plocha_jednotky_m2,
        k.plocha_budovy                         AS plocha_budovy_m2,

        k.cena                                  AS cena_Kc,
        k.mena,
        k.cena_v_mene,
        k.kurz_pouzity,
        k.kurz_datum,

        /* u pozemku se stavbou jednotková cena smysl nemá */
        CASE WHEN k.klasifikace = 'JC_PARCELY'
              AND k.na_pozemku_stavba = 1 THEN NULL
             ELSE
                CASE k.klasifikace
                    WHEN 'JC_PARCELY'  THEN CAST(k.cena / NULLIF(k.plocha_parcel, 0)
                                                 AS decimal(14,2))
                    WHEN 'JC_JEDNOTKA' THEN CAST(k.cena / NULLIF(k.plocha_jednotky, 0)
                                                 AS decimal(14,2))
                    ELSE NULL
                END
        END                                     AS jedn_cena_Kc_m2,

        p.geo_bod,
        p.LAT,
        p.LON
FROM vklad k
JOIN dbo.Valuo_data p            ON p.id     = k.id_prvni
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku;
GO


/* ---------- 20.3 CENOVÉ HLADINY ----------------------------
   Vyloučení je tu nadbytečné, protože takovým vkladům už
   základní pohled jednotkovou cenu nepočítá a podmínka
   jedn_cena_Kc_m2 > 0 je odfiltruje. Uvádí se výslovně,
   aby byl záměr čitelný i bez znalosti pohledu výše.       */

CREATE OR ALTER VIEW dbo.v_cenove_hladiny
AS
WITH zaklad AS (
    SELECT  q.kod_ku,
            c.okres_nazev,
            c.kraj_nazev,
            q.klasifikace,
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


/* ---------- 20.4 PRACOVNÍ POHLED --------------------------- */

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
            /* pozemek se stavbou se porovnává jako celek,
               ať číselník u druhu pozemku říká co chce */
            CASE WHEN v.klasifikace = 'JC_PARCELY'
                  AND v.na_pozemku_stavba = 1 THEN 'CELEK'
                 ELSE ISNULL(m.metrika,
                        CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                             ELSE 'CELEK' END)
            END AS metrika
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
        v.cena_Kc,
        v.mena,
        v.cena_v_mene,
        v.kurz_pouzity,
        v.kurz_datum,

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
            WHEN v.cena_Kc < t.cena_min              THEN N'symbolická cena'
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
LEFT JOIN dbo.CIS_prahy_ceny t ON t.klasifikace   = v.klasifikace
LEFT JOIN dbo.v_vklad_UP    up ON up.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.v_cenove_hladiny h
       ON h.kod_ku      = v.kod_ku
      AND h.klasifikace = v.klasifikace
      AND h.klic        = CASE WHEN v.klasifikace = 'JC_PARCELY'
                                AND up.fvu_kod IS NOT NULL
                               THEN N'FVU:'  + up.fvu_kod
                               ELSE N'DRUH:' + ISNULL(v.druh, N'?') END
LEFT JOIN dbo.CIS_rozsahy_ploch r
       ON r.nemovitost = p.nemovitost
      AND r.typ        = p.typ
      AND r.typ_plochy = p.typ_plochy;
GO


/* ---------- 20.5 KONTROLA ---------------------------------- */

/* Dostaly pozemky se stavbou metriku CELEK? */
SELECT  pozemek_se_stavbou, metrika, hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
WHERE klasifikace = 'JC_PARCELY'
GROUP BY pozemek_se_stavbou, metrika, hodnoceni_ceny
ORDER BY pozemek_se_stavbou DESC, vkladu DESC;
GO

/* Podíl řádově vysokých u pozemků — dřív 4,54 % a 43,48 % */
SELECT  CASE WHEN na_pozemku_stavba = 1 THEN N'na pozemku je stavba'
             ELSE N'jen pozemky' END         AS skupina,
        COUNT(*)                             AS vkladu_s_JC,
        SUM(CASE WHEN q.hodnoceni_ceny = N'řádově vysoká' THEN 1 ELSE 0 END)
                                             AS radove_vysoka
FROM dbo.v_Valuo_vzorek_q q
JOIN dbo.v_Valuo_vzorek   z ON z.cislo_vkladu = q.cislo_vkladu
WHERE q.klasifikace = 'JC_PARCELY'
  AND q.hodnoceni_ceny IN (N'bez výhrad', N'řádově nízká', N'řádově vysoká')
GROUP BY CASE WHEN na_pozemku_stavba = 1 THEN N'na pozemku je stavba'
              ELSE N'jen pozemky' END;
GO

/* Celkový přehled vzorku po všech úpravách */
SELECT klasifikace, metrika, hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY klasifikace, metrika, hodnoceni_ceny
ORDER BY klasifikace, vkladu DESC;
GO
