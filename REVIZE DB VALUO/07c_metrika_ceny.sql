/* ============================================================
   VALUO — KROK 7c: ČÍM SE KTERÁ NEMOVITOST POROVNÁVÁ

   Navazuje na 07b_hladiny_dle_druhu.sql, přepisuje pohled
   v_Valuo_vzorek_q a doplňuje číselník metrik.

   ------------------------------------------------------------
   DŮVOD
   ------------------------------------------------------------
   Jednotková cena nedává smysl u každé nemovitosti. Garáž se
   oceňuje jako kus, ne na metr čtvereční — a u garážové
   jednotky je navíc "plocha" dopočtená z podílu na společných
   částech, tedy včetně ramp a komunikací:

       garáž jako budova    medián plochy  17,5 m2  (reálná)
       garáž jako jednotka  medián plochy  75,2 m2  (podíl)

   Celkové ceny přitom vycházejí správně — 668 tis. u řadové
   garáže, 590 tis. u jednotky (Praha, od 2023).

   ------------------------------------------------------------
   TŘI METRIKY
   ------------------------------------------------------------
     JC      jednotková cena za m2 má vypovídací hodnotu
             byt, ateliér, jiný nebytový prostor, dílna,
             rozestavěná jednotka, pozemky

     KUS     porovnává se cena za kus
             garáž, ať jako budova nebo jednotka

     CELEK   funkční celek — cena, výměra stavby a výměra
             pozemků se posuzují zvlášť
             rodinný dům, bytový dům, ostatní stavby
   ============================================================ */

USE VALUO;
GO

DROP VIEW IF EXISTS dbo.v_Valuo_vzorek_q;
GO


/* ---------- 7c.1 ČÍSELNÍK METRIK ---------------------------- */

IF OBJECT_ID('dbo.CIS_metrika_ceny') IS NOT NULL
    DROP TABLE dbo.CIS_metrika_ceny;
GO

CREATE TABLE dbo.CIS_metrika_ceny (
    nemovitost  nvarchar(50)  NOT NULL,
    typ         nvarchar(100) NOT NULL,
    metrika     varchar(10)   NOT NULL,   -- JC / KUS / CELEK
    poznamka    nvarchar(200) NULL,
    CONSTRAINT PK_CIS_metrika_ceny PRIMARY KEY CLUSTERED (nemovitost, typ)
);
GO

INSERT INTO dbo.CIS_metrika_ceny (nemovitost, typ, metrika, poznamka) VALUES
 /* jednotky */
 (N'jednotka', N'byt',                   'JC',   NULL),
 (N'jednotka', N'ateliér',               'JC',   NULL),
 (N'jednotka', N'rozestavěná jednotka',  'JC',   NULL),
 (N'jednotka', N'jiný nebytový prostor', 'JC',
  N'kancelář, obchod - cena za m2 je běžná metrika'),
 (N'jednotka', N'dílna nebo provozovna', 'JC',   NULL),
 (N'jednotka', N'garáž',                 'KUS',
  N'plocha je podíl na celé garáži včetně ramp a komunikací'),

 /* budovy */
 (N'budova',   N'garáž',                 'KUS',
  N'řadová garáž - oceňuje se jako kus, byť je plocha reálná'),
 (N'budova',   N'rodinný dům',           'CELEK', NULL),
 (N'budova',   N'bytový dům',            'CELEK', NULL),
 (N'budova',   N'objekt k bydlení',      'CELEK', NULL),
 (N'budova',   N'stavba pro rodinnou rekreaci', 'CELEK', NULL),
 (N'budova',   N'jiná stavba',           'CELEK', NULL);
GO
/* Druhy, které zde nejsou uvedeny:
     parcely        -> vždy JC (cena za m2 souboru)
     ostatní budovy -> CELEK                                   */


/* ---------- 7c.2 VZOREK S METRIKOU A PŘÍZNAKY --------------- */

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
        v.druh,
        v.ruznych_druhu,
        v.nemovitosti_ve_vkladu,
        v.duplicitnich_radku,
        v.plocha_parcel_m2,
        v.plocha_jednotky_m2,
        v.plocha_budovy_m2,
        v.cena_Kc,
        v.mena,

        /* jak se tato nemovitost porovnává */
        ISNULL(m.metrika,
               CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                    ELSE 'CELEK' END)                AS metrika,

        /* jednotková cena jen tam, kde má smysl */
        CASE WHEN ISNULL(m.metrika,
                 CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                      ELSE 'CELEK' END) = 'JC'
             THEN v.jedn_cena_Kc_m2 END              AS jedn_cena_Kc_m2,

        up.fvu_kod,
        up.mira_vyuziti,

        h.median                                    AS median_Kc_m2,
        h.bodu                                      AS bodu_v_hladine,
        h.uroven                                    AS uroven_hladiny,
        CASE WHEN ISNULL(m.metrika,
                 CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                      ELSE 'CELEK' END) = 'JC'
             THEN CAST(v.jedn_cena_Kc_m2 / NULLIF(h.median, 0)
                       AS decimal(10,3)) END        AS pomer_k_medianu,

        CASE
            WHEN v.mena <> 'CZK'                     THEN N'cizí měna'
            WHEN v.cena_Kc < t.cena_min              THEN N'symbolická cena'
            WHEN ISNULL(m.metrika,
                 CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                      ELSE 'CELEK' END) <> 'JC'      THEN N'porovnává se cena'
            WHEN v.jedn_cena_Kc_m2 IS NULL           THEN N'bez JC'
            WHEN h.median IS NULL                    THEN N'bez srovnání'
            WHEN v.jedn_cena_Kc_m2 / h.median < 0.1  THEN N'řádově nízká'
            WHEN v.jedn_cena_Kc_m2 / h.median > 10.0 THEN N'řádově vysoká'
            ELSE                                          N'bez výhrad'
        END                                         AS hodnoceni_ceny,

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
LEFT JOIN hlavni p ON p.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_metrika_ceny m
       ON m.nemovitost = p.nemovitost AND m.typ = p.typ
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


/* ---------- 7c.3 KONTROLA ----------------------------------- */

SELECT  metrika,
        druh,
        COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
WHERE metrika <> 'CELEK'
GROUP BY metrika, druh
ORDER BY metrika, COUNT(*) DESC;
GO

SELECT klasifikace, hodnoceni_ceny, COUNT(*) AS bodu
FROM dbo.v_Valuo_vzorek_q
GROUP BY klasifikace, hodnoceni_ceny
ORDER BY klasifikace, COUNT(*) DESC;
GO


/* ============================================================
   7c.4  SROVNÁVACÍ VZOREK — GARÁŽE
         Porovnává se cena za kus, plocha jen pro orientaci.
   ============================================================ */

DECLARE @stred  geography = geography::Point(50.034433, 14.450230, 4326);

SELECT  cislo_vkladu,
        datum_zplatneni,
        kat_uzemi,
        klasifikace,
        CASE WHEN klasifikace = 'CELEK_BUDOVA' THEN N'řadová garáž'
             ELSE N'jednotka v domě' END          AS typ_garaze,
        COALESCE(plocha_budovy_m2, plocha_jednotky_m2) AS plocha_m2,
        cena_Kc,
        hodnoceni_ceny,
        CAST(geo_bod.STDistance(@stred) AS decimal(10,1)) AS vzdalenost_m
FROM dbo.v_Valuo_vzorek_q
WHERE druh = N'garáž'
  AND metrika = 'KUS'
  AND geo_bod.STDistance(@stred) <= 3000
  AND rok >= YEAR(GETDATE()) - 2
  AND mena = 'CZK'
ORDER BY vzdalenost_m;
GO
