/* ============================================================
   VALUO — KROK 22: ODDĚLENÉ VLASTNICTVÍ STAVBY A POZEMKU

   Jen pohledy, do dat nezasahuje. Spusť celé najednou.

   ------------------------------------------------------------
   NÁLEZ
   ------------------------------------------------------------
   V developerských projektech s odděleným vlastnictvím stavby
   a pozemku se obojí prodává zvlášť. Vklad pak obsahuje
   budovu, ale parcelu, na níž stojí, nikoli — prodávají se
   jiné parcely. Cena se vztahuje k nim, ne ke stavbě.

   Doložený případ — V-28897/2023-101, Horní Počernice:

   | nemovitost | typ         | plocha             | parcela   |
   |------------|-------------|--------------------|-----------|
   | budova     | rodinný dům | 118 m2 podlahová   | 4037/539  |
   | parcela    | orná půda   |  82 m2             | 4037/447  |
   | parcela    | orná půda   |  46 m2             | 4037/554  |

   Parcela 4037/539, na níž dům stojí, mezi prodávanými není.
   Cena 733 650 Kč dělená 128 m2 prodávaných pozemků dává
   5 732 Kč/m2 — běžnou cenu pozemku v lokalitě. Dělená
   podlahovou plochou domu dává 6 217 Kč/m2, zatímco trh je
   kolem 100 000 Kč/m2.

   Klasifikace z toho udělá CELEK_BUDOVA, protože budova ve
   vkladu je, a jednotková cena se spočítá na podlahovou
   plochu domu, který se neprodával. V Horních Počernicích
   takových vkladů je 31 a stlačily medián rodinných domů
   na 31 254 Kč/m2, zatímco ostatní pražská území mají
   82 000 až 170 000 Kč/m2.

   V tomtéž území je navíc 31 vkladů s právem stavby
   (nemovitost = '---') s průměrnou cenou 9 965 179 Kč — ty už
   odpovídají hodnotě domů.

   ------------------------------------------------------------
   JAK SE TO POZNÁ
   ------------------------------------------------------------
   Parcelní číslo z popisu budovy se porovná s parcelními
   čísly prodávaných parcel v tomtéž vkladu. Nenajde-li se,
   cena ke stavbě nepatří.

   Tři možné stavy:

     parcela pod stavbou se prodává  cena patří celku,
                                     jednotková cena platí
     prodávají se jiné parcely       cena patří pozemkům,
                                     jednotková cena neplatí
     ve vkladu žádná parcela         prodává se jen stavba,
                                     jednotková cena platí

   Nerozhoduje se podle druhu pozemku ani podle ceny — jen
   podle toho, co ve vkladu je.
   ============================================================ */

USE VALUO;
GO

/* ---------- 22.1 PARCELNÍ ČÍSLA Z POPISU -------------------
   Pomocný pohled: pro každý řádek vytáhne parcelní číslo
   a území z popisu. Použitelný i jinde — parsování je stejné
   jako v 17_oprava_parcel.py.                                */

CREATE OR ALTER VIEW dbo.v_Valuo_parcela_z_popisu
AS
SELECT  id,
        cislo_vkladu,
        nemovitost,
        vklad_klasifikace,
        CASE WHEN popis LIKE N'stavební č. %' THEN 1 ELSE 0 END AS je_stavebni,
        LTRIM(RTRIM(bez_zavorek)) AS parcela_s_uzemim
FROM (
    SELECT id, cislo_vkladu, nemovitost, vklad_klasifikace, popis,
           CASE WHEN CHARINDEX(N' (', za_prefixem) > 0
                THEN LEFT(za_prefixem, CHARINDEX(N' (', za_prefixem) - 1)
                ELSE za_prefixem END AS bez_zavorek
    FROM (
        SELECT id, cislo_vkladu, nemovitost, vklad_klasifikace, popis,
               CASE WHEN popis LIKE N'stavební č. %' THEN SUBSTRING(popis, 13, 400)
                    WHEN popis LIKE N'č. %'          THEN SUBSTRING(popis,  4, 400)
               END AS za_prefixem
        FROM dbo.Valuo_data
    ) a
    WHERE za_prefixem IS NOT NULL
) b;
GO


/* ---------- 22.2 ZÁKLADNÍ POHLED S PŘÍZNAKEM --------------- */

CREATE OR ALTER VIEW dbo.v_Valuo_vzorek
AS
WITH opakovani AS (
    SELECT  popis, plocha,
            COUNT(DISTINCT cislo_vkladu) AS prodeju
    FROM dbo.Valuo_data
    WHERE nemovitost = N'budova' AND plocha > 0
    GROUP BY popis, plocha
),
parcely_ve_vkladu AS (
    /* vklady, v nichž se vůbec prodává nějaká parcela */
    SELECT DISTINCT cislo_vkladu
    FROM dbo.v_Valuo_parcela_z_popisu
    WHERE nemovitost = N'parcela'
),
stavba_vs_pozemek AS (
    /* 1 = parcela pod stavbou se prodává, nebo ve vkladu žádná
           parcela není  → cena patří stavbě
       0 = prodávají se jiné parcely → cena patří pozemkům

       Psáno přes JOIN, ne EXISTS: SQL Server nedovolí agregaci
       nad výrazem obsahujícím poddotaz (Msg 130).            */
    SELECT  b.cislo_vkladu,
            MAX(CASE WHEN pv.cislo_vkladu IS NULL      THEN 1
                     WHEN pod.cislo_vkladu IS NOT NULL THEN 1
                     ELSE 0 END) AS cena_patri_stavbe
    FROM dbo.v_Valuo_parcela_z_popisu b
    LEFT JOIN parcely_ve_vkladu pv
           ON pv.cislo_vkladu = b.cislo_vkladu
    LEFT JOIN dbo.v_Valuo_parcela_z_popisu pod
           ON pod.cislo_vkladu     = b.cislo_vkladu
          AND pod.nemovitost       = N'parcela'
          AND pod.parcela_s_uzemim = b.parcela_s_uzemim
    WHERE b.nemovitost = N'budova'
    GROUP BY b.cislo_vkladu
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

            MAX(CASE WHEN v.popis LIKE N'%součástí je stavba%'
                     THEN 1 ELSE 0 END)    AS na_pozemku_stavba,

            MIN(CASE WHEN v.nemovitost = N'budova'
                     THEN v.typ_plochy END) AS typ_plochy_stavby,

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
        ISNULL(sp.cena_patri_stavbe, 1)         AS cena_patri_stavbe,

        k.plocha_parcel                         AS plocha_parcel_m2,
        k.plocha_jednotky                       AS plocha_jednotky_m2,
        k.plocha_budovy                         AS plocha_budovy_m2,

        CASE WHEN k.typ_plochy_stavby = N'Podlahová plocha'
             THEN k.plocha_budovy END           AS plocha_podlahova_m2,

        k.cena                                  AS cena_Kc,
        k.mena,
        k.cena_v_mene,
        k.kurz_pouzity,
        k.kurz_datum,

        CASE
            WHEN k.klasifikace = 'JC_PARCELY' AND k.na_pozemku_stavba = 1
                 THEN NULL
            WHEN k.klasifikace = 'JC_PARCELY'
                 THEN CAST(k.cena / NULLIF(k.plocha_parcel, 0) AS decimal(14,2))
            WHEN k.klasifikace = 'JC_JEDNOTKA'
                 THEN CAST(k.cena / NULLIF(k.plocha_jednotky, 0) AS decimal(14,2))
            WHEN k.klasifikace = 'CELEK_BUDOVA'
             AND k.typ_plochy_stavby = N'Podlahová plocha'
             AND ISNULL(sp.cena_patri_stavbe, 1) = 1
                 THEN CAST(k.cena / NULLIF(k.plocha_budovy, 0) AS decimal(14,2))
            ELSE NULL
        END                                     AS jedn_cena_Kc_m2,

        p.geo_bod,
        p.LAT,
        p.LON
FROM vklad k
JOIN dbo.Valuo_data p            ON p.id     = k.id_prvni
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
LEFT JOIN stavba_vs_pozemek sp   ON sp.cislo_vkladu = k.cislo_vkladu;
GO


/* ---------- 22.3 CENOVÉ HLADINY ---------------------------- */

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


/* ---------- 22.4 PRACOVNÍ POHLED --------------------------- */

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

            /* stavba ve vkladu je, ale neprodává se — cena
               patří pozemkům */
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


/* ---------- 22.5 KONTROLA ---------------------------------- */

/* Rozsah jevu */
SELECT  cena_patri_stavbe, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek
WHERE klasifikace = 'CELEK_BUDOVA'
GROUP BY cena_patri_stavbe;
GO

/* Kde se to vyskytuje nejčastěji */
SELECT TOP 15 kat_uzemi, druh, COUNT(*) AS vkladu,
       CAST(AVG(cena_Kc) AS decimal(14,0)) AS prum_cena,
       CAST(AVG(plocha_parcel_m2) AS decimal(10,1)) AS prum_pozemek
FROM dbo.v_Valuo_vzorek_q
WHERE hodnoceni_ceny = N'oddělené vlastnictví'
GROUP BY kat_uzemi, druh ORDER BY COUNT(*) DESC;
GO

/* Medián rodinných domů — Horní Počernice bylo 31 254 Kč/m2 */
SELECT c.ku_nazev AS kat_uzemi, h.median AS median_Kc_m2, h.bodu, h.uroven
FROM dbo.v_cenove_hladiny h
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = h.kod_ku
WHERE h.klasifikace = 'CELEK_BUDOVA' AND h.klic = N'DRUH:rodinný dům'
  AND h.uroven = N'k.ú.'
ORDER BY h.bodu DESC;
GO

/* Vzorek */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO
