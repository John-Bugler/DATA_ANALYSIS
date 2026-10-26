/* ============================================================
   VALUO — KROK 23f: OPRAVA PARSERU PODÍLU V PRACOVNÍM POHLEDU

   Jen pohled, do dat nezasahuje. Spusť celé najednou.

   ============================================================
   CO BYLO ŠPATNĚ
   ============================================================
       SELECT * FROM dbo.v_Valuo_vzorek_q

       Msg 537 — Invalid length parameter passed to the LEFT or
       SUBSTRING function.

   V CTE hlavni se z popisu vytahuje čitatel podílu na společných
   částech. Popis jednotky ho uvádí za frází „domu a pozemku":

       … podíl na společných částech domu a pozemku 378/14283

   Výraz ale lomítko hledal od ZAČÁTKU popisu, ne od té fráze:

       CHARINDEX(N'/', v.popis + N'/',
                 CHARINDEX(N'domu a pozemku ', v.popis))

   Nemá-li popis tu frázi, vnější CHARINDEX vrátí 0, počátek
   SUBSTRING vyjde 15 a délka se spočítá jako

       pozice prvního lomítka  -  0  -  15

   U popisu s lomítkem v parcelním čísle na pozici do 14 je
   výsledek negativní a SQL Server skončí chybou:

       č. 1958/1 Ostrov u Stříbra        lomítko na pozici 8
       stavební č. 3/1 Ostrov u Stříbra  lomítko na pozici 14

   Takových řádků je ve vzorku 15 178 ze 47 112.

   ------------------------------------------------------------
   PROČ SE TO PROJEVILO AŽ TEĎ
   ------------------------------------------------------------
   Sloupec citatel_podilu se používá jedině v hodnoceni_podilu.
   Dotazy, které z pohledu brala kontrola jednotlivých kroků,
   vybíraly hodnoceni_ceny nebo počty, takže ten výraz SQL
   Server nemusel vyhodnotit a chyba zůstala skrytá. Teprve
   SELECT * si vyžádá všechny sloupce.

   Chyba tam byla od zavedení hodnoceni_podilu. Znamená to, že
   hodnoceni_podilu dosud nikdy nefungovalo — každý dotaz, který
   by ten sloupec vybral, musel skončit chybou.

   ------------------------------------------------------------
   OPRAVA
   ------------------------------------------------------------
   Lomítko se hledá OD POZICE ZA FRÁZÍ a celý výraz se počítá
   jen tam, kde fráze je:

       CASE WHEN CHARINDEX(N'domu a pozemku ', popis) > 0
            THEN SUBSTRING(popis, P, NULLIF(CHARINDEX(N'/', popis, P), 0) - P)
       END

   kde P je pozice za frází. Chybí-li lomítko za frází, NULLIF
   udělá z nuly NULL, délka je NULL a SUBSTRING vrátí NULL místo
   chyby.

   Ověřeno proti datům: čitatele vycházejí 690, 732, 738, 7162,
   7370, 110090 a na řádcích bez fráze je NULL.

   ------------------------------------------------------------
   K TOMU DRUHÉMU HLÁŠENÍ
   ------------------------------------------------------------
       Warning: Null value is eliminated by an aggregate or
       other SET operation.

   To je jen upozornění od MIN() nad sloupcem, kde jsou NULL —
   přesně to chování, které je tady žádoucí. Nic se s ním nedělá.
   ============================================================ */

USE VALUO;
GO

CREATE OR ALTER VIEW dbo.v_Valuo_vzorek_q
AS
WITH hlavni AS (
    SELECT  v.cislo_vkladu,
            MIN(v.nemovitost) AS nemovitost,
            MIN(v.typ)        AS typ,
            MIN(v.typ_plochy) AS typ_plochy,

            /* čitatel podílu na společných částech; lomítko se
               hledá od pozice za frází, jinak vyjde negativní
               délka u popisů s lomítkem v parcelním čísle */
            MIN(CASE WHEN CHARINDEX(N'domu a pozemku ', v.popis) > 0
                     THEN TRY_CONVERT(decimal(18,2),
                            SUBSTRING(v.popis,
                              CHARINDEX(N'domu a pozemku ', v.popis) + 15,
                              NULLIF(CHARINDEX(N'/', v.popis,
                                       CHARINDEX(N'domu a pozemku ',
                                                 v.popis) + 15), 0)
                              - CHARINDEX(N'domu a pozemku ', v.popis) - 15))
                END)          AS citatel_podilu
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

        /* cena stanovená vzorcem, ne vyjednaná */
        CASE WHEN hp.jedn_cena_Kc_m2 IS NULL THEN 0 ELSE 1 END
                                                    AS hromadny_prevod,
        hp.vkladu                                   AS hromadne_vkladu,
        hp.typ_jevu,
        hp.poznamka                                 AS hromadna_poznamka,

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
            WHEN hp.jedn_cena_Kc_m2 IS NOT NULL
             AND ISNULL(y.do_medianu, 0) = 0         THEN N'hromadný převod'
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
LEFT JOIN dbo.CIS_typy_hromadneho_prevodu y ON y.typ_jevu = hp.typ_jevu
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


/* ---------- KONTROLA ---------------------------------------- */

/* Tohle dřív skončilo chybou 537 */
SELECT TOP 5 cislo_vkladu, kat_uzemi, klasifikace, druh,
       jedn_cena_Kc_m2, hodnoceni_ceny, hodnoceni_podilu
FROM dbo.v_Valuo_vzorek_q
WHERE klasifikace = 'JC_JEDNOTKA';
GO

/* Hodnocení podílu — poprvé funkční */
SELECT hodnoceni_podilu, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_podilu ORDER BY vkladu DESC;
GO

/* Hodnocení ceny — musí zůstat jako po kroku 23 */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY vkladu DESC;
GO

/* Zkouška, že SELECT * projde celým vzorkem */
SELECT COUNT(*) AS vkladu_ve_vzorku,
       COUNT(hodnoceni_podilu) AS s_hodnocenim_podilu
FROM dbo.v_Valuo_vzorek_q;
GO
