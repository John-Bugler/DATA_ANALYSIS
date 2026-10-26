/* ============================================================
   VALUO — KROK 20: JEDNOTKOVÁ CENA U STAVEB

   Jen pohledy a číselník, do dat nezasahuje.
   Spusť celé najednou. Nezávisí na krocích 17 a 18.

   Nahrazuje dřívější verzi 20_pozemek_se_stavbou.sql — pohledy
   se přepisují, takže je lhostejné, zda byla spuštěna.

   ============================================================
   CO SE ŘEŠÍ
   ============================================================

   1) JEDNOTKOVÁ CENA U RODINNÝCH DOMŮ

   Jednotková cena u rodinného domu se počítá dělením ceny
   podlahovou plochou, ne výměrou parcely. Podlahová plocha
   v datech u části domů je:

       rodinný dům, typ_plochy = Podlahová plocha   842 vkladů
       rodinný dům, typ_plochy = Výměra parcely   1 981 vkladů

   Dosavadní metrika CELEK jednotkovou cenu nepočítala ani těm
   842, kde je jmenovatel k dispozici. U 457 z nich, které jsou
   ve vzorku, vychází průměr 80 536 Kč/m2 — tedy věrohodně.

   2) U BYTOVÝCH DOMŮ TOTÉŽ NEPLATÍ

   Tam je „podlahová plocha" plochou celé budovy, zatímco cena
   je za podíl v ní. Příklad — dvanáct různých vkladů na téže
   parcele 496/77 Střížkov:

       plocha 28 000 m2 u všech, ceny 2,5 až 8,0 mil. Kč
       jednotková cena vychází 89 až 286 Kč/m2

   Jde o prodeje spoluvlastnických podílů na bytovém domě, který
   není rozdělen na jednotky. Plocha celé budovy jmenovatelem
   být nemůže.

   Rozlišení je v opakování: táž budova (shodný popis i plocha)
   se v datech prodává opakovaně.

   | druh stavby        | skupin 5+ prodejů | vkladů |
   |--------------------|-------------------|--------|
   | bytový dům         |               203 |  2 289 |
   | garáž              |                51 |    299 |
   | jiná stavba        |                16 |    174 |
   | rodinný dům        |                 2 |     11 |

   U rodinných domů je jev okrajový, u bytových převažuje.
   Skript proto počítá jednotkovou cenu jen tam, kde se táž
   stavba prodává méně než pětkrát.

   3) POZEMEK SE STAVBOU JAKO SOUČÁSTÍ

   Je-li stavba součástí pozemku, obsahuje vklad jen parcely
   a klasifikace mu dá JC_PARCELY. Cena zahrnuje i tu stavbu,
   ale dělí se výměrou pozemků:

   | vklady JC_PARCELY    | vkladů | řádově vysoká JC | podíl  |
   |----------------------|--------|------------------|--------|
   | jen pozemky          |  3 572 |              162 |  4,54 %|
   | na pozemku je stavba |     46 |               20 | 43,48 %|

   Příklad — V-29743/2025-101, Strašnice: popis „č. 3395/16
   Strašnice (součástí je stavba č.p. 2397)", cena 124 725 000 Kč,
   plochy 501 + 205 m2, jednotková cena 176 664 Kč/m2 proti
   mediánu 5 000 Kč/m2.

   Podlahová plocha té stavby v datech není, takže jednotkovou
   cenu spočítat nelze — vklad dostane hodnocení „chybí
   podlahová plocha" a je kandidátem na doplnění z RÚIAN.

   ============================================================
   NOVÁ HODNOCENÍ
   ============================================================
       chybí podlahová plocha  jmenovatel by existoval, ale
                               data mají jen výměru parcely
       podíl na budově         táž stavba se prodává opakovaně,
                               plocha je za celou budovu
   ============================================================ */

USE VALUO;
GO

/* ---------- 20.1 METRIKA V ČÍSELNÍKU -----------------------
   JC_PODLAHOVA znamená: jednotkovou cenu počítej z podlahové
   plochy, je-li v datech. Číselník je určený k ruční úpravě —
   přidá-li se sem druh stavby, začne se u něj jednotková cena
   počítat, aniž by se měnily pohledy.                        */

UPDATE dbo.CIS_metrika_ceny SET metrika = 'JC_PODLAHOVA'
WHERE nemovitost = N'budova'
  AND typ IN (N'rodinný dům', N'stavba pro rodinnou rekreaci');
GO

/* bytový dům zůstává záměrně na CELEK — viz oddíl 2 v hlavičce */

MERGE dbo.CIS_metrika_ceny AS c
USING (VALUES
    (N'budova', N'objekt k bydlení',      'JC_PODLAHOVA'),
    (N'budova', N'budova s číslem popisným', 'JC_PODLAHOVA')
) AS n (nemovitost, typ, metrika)
   ON c.nemovitost = n.nemovitost AND c.typ = n.typ
WHEN MATCHED     THEN UPDATE SET metrika = n.metrika
WHEN NOT MATCHED THEN INSERT (nemovitost, typ, metrika)
                      VALUES (n.nemovitost, n.typ, n.metrika);
GO

SELECT nemovitost, typ, metrika FROM dbo.CIS_metrika_ceny
ORDER BY nemovitost, metrika, typ;
GO


/* ---------- 20.2 ZÁKLADNÍ POHLED --------------------------- */

CREATE OR ALTER VIEW dbo.v_Valuo_vzorek
AS
WITH opakovani AS (
    /* kolikrát se táž stavba v datech prodává; shodu určuje
       popis (nese parcelu a území) a plocha */
    SELECT  popis, plocha,
            COUNT(DISTINCT cislo_vkladu) AS prodeju
    FROM dbo.Valuo_data
    WHERE nemovitost = N'budova' AND plocha > 0
    GROUP BY popis, plocha
),
vklad AS (
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

            /* zdroj plochy u řádku stavby — rozhoduje o tom,
               zda lze počítat jednotkovou cenu */
            MIN(CASE WHEN v.nemovitost = N'budova'
                     THEN v.typ_plochy END) AS typ_plochy_stavby,

            /* nejvyšší počet prodejů téže stavby ve vkladu */
            MAX(CASE WHEN v.nemovitost = N'budova'
                     THEN o.prodeju END)    AS prodeju_tehoz_objektu,

            MIN(CASE WHEN v.vklad_klasifikace = 'JC_JEDNOTKA'
                      AND v.nemovitost = N'jednotka' THEN v.typ
                     WHEN v.vklad_klasifikace = 'CELEK_BUDOVA'
                      AND v.nemovitost = N'budova'   THEN v.typ
                     WHEN v.vklad_klasifikace = 'JC_PARCELY'
                      AND v.nemovitost = N'parcela'  THEN v.typ
                END)                       AS druh,
            COUNT(DISTINCT v.typ)          AS ruznych_druhu
    FROM dbo.Valuo_data v
    LEFT JOIN opakovani o ON o.popis = v.popis AND o.plocha = v.plocha
                         AND v.nemovitost = N'budova'
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
        k.typ_plochy_stavby,
        k.prodeju_tehoz_objektu,

        k.plocha_parcel                         AS plocha_parcel_m2,
        k.plocha_jednotky                       AS plocha_jednotky_m2,
        k.plocha_budovy                         AS plocha_budovy_m2,

        /* podlahová plocha stavby — jen je-li to skutečně ona */
        CASE WHEN k.typ_plochy_stavby = N'Podlahová plocha'
             THEN k.plocha_budovy END           AS plocha_podlahova_m2,

        k.cena                                  AS cena_Kc,
        k.mena,
        k.cena_v_mene,
        k.kurz_pouzity,
        k.kurz_datum,

        /* jednotková cena podle klasifikace:
             pozemky   cena / výměra parcel
             jednotka  cena / plocha z podílu na budově
             stavba    cena / podlahová plocha
           u pozemku se stavbou se nepočítá vůbec — jmenovatel
           by musel zahrnovat i tu stavbu */
        CASE
            WHEN k.klasifikace = 'JC_PARCELY' AND k.na_pozemku_stavba = 1
                 THEN NULL
            WHEN k.klasifikace = 'JC_PARCELY'
                 THEN CAST(k.cena / NULLIF(k.plocha_parcel, 0) AS decimal(14,2))
            WHEN k.klasifikace = 'JC_JEDNOTKA'
                 THEN CAST(k.cena / NULLIF(k.plocha_jednotky, 0) AS decimal(14,2))
            WHEN k.klasifikace = 'CELEK_BUDOVA'
             AND k.typ_plochy_stavby = N'Podlahová plocha'
                 THEN CAST(k.cena / NULLIF(k.plocha_budovy, 0) AS decimal(14,2))
            ELSE NULL
        END                                     AS jedn_cena_Kc_m2,

        p.geo_bod,
        p.LAT,
        p.LON
FROM vklad k
JOIN dbo.Valuo_data p            ON p.id     = k.id_prvni
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku;
GO


/* ---------- 20.3 CENOVÉ HLADINY ----------------------------
   Do mediánu nevstupují: cizí měny, nestandardní převody,
   pozemky se stavbou a opakovaně prodávané stavby.         */

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
      AND ISNULL(q.prodeju_tehoz_objektu, 0) < 5
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

            /* metrika, kterou číselník předepisuje */
            ISNULL(m.metrika,
                   CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                        ELSE 'CELEK' END)            AS metrika_dle_ciselniku,

            /* metrika, kterou data skutečně umožňují */
            CASE
                /* pozemek se stavbou: jmenovatel by musel
                   zahrnovat podlahovou plochu stavby */
                WHEN v.klasifikace = 'JC_PARCELY'
                 AND v.na_pozemku_stavba = 1                 THEN 'CELEK'

                /* opakovaně prodávaná stavba: plocha je za
                   celou budovu, cena za podíl v ní */
                WHEN v.klasifikace = 'CELEK_BUDOVA'
                 AND ISNULL(v.prodeju_tehoz_objektu, 0) >= 5 THEN 'CELEK'

                /* stavba s podlahovou plochou v datech */
                WHEN ISNULL(m.metrika, '') = 'JC_PODLAHOVA'
                 AND v.plocha_podlahova_m2 > 0               THEN 'JC'

                /* stavba, u níž jmenovatel chybí */
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

            /* táž stavba se prodává opakovaně — plocha je za
               celou budovu, jde o podíl v ní */
            WHEN v.klasifikace = 'CELEK_BUDOVA'
             AND ISNULL(v.prodeju_tehoz_objektu, 0) >= 5
                                                     THEN N'podíl na budově'

            /* jednotková cena by se počítala, ale data nesou
               jen výměru parcely — doplnitelné z RÚIAN */
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

/* Rodinné domy — kolik jich nově má jednotkovou cenu */
SELECT  druh, metrika, hodnoceni_ceny, COUNT(*) AS vkladu,
        CAST(AVG(jedn_cena_Kc_m2) AS decimal(14,0)) AS prum_JC,
        CAST(AVG(plocha_podlahova_m2) AS decimal(10,1)) AS prum_plocha
FROM dbo.v_Valuo_vzorek_q
WHERE druh IN (N'rodinný dům', N'stavba pro rodinnou rekreaci')
GROUP BY druh, metrika, hodnoceni_ceny
ORDER BY druh, vkladu DESC;
GO

/* Pozemky — srovnej s 4,54 % a 43,48 % před úpravou */
SELECT  pozemek_se_stavbou, metrika, hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
WHERE klasifikace = 'JC_PARCELY'
GROUP BY pozemek_se_stavbou, metrika, hodnoceni_ceny
ORDER BY pozemek_se_stavbou DESC, vkladu DESC;
GO

/* Kolik vkladů čeká na podlahovou plochu z RÚIAN */
SELECT  druh, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
WHERE hodnoceni_ceny = N'chybí podlahová plocha'
GROUP BY druh ORDER BY COUNT(*) DESC;
GO

/* Opakovaně prodávané stavby */
SELECT  druh, COUNT(*) AS vkladu, MAX(prodeju_tehoz_objektu) AS nejvic_prodeju
FROM dbo.v_Valuo_vzorek_q
WHERE hodnoceni_ceny = N'podíl na budově'
GROUP BY druh ORDER BY COUNT(*) DESC;
GO

/* Celkový přehled vzorku */
SELECT klasifikace, metrika, hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY klasifikace, metrika, hodnoceni_ceny
ORDER BY klasifikace, vkladu DESC;
GO
