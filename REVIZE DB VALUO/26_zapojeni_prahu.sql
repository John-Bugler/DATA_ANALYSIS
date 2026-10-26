/* ============================================================
   VALUO — KROK 26: ZAPOJENÍ PRAHŮ DO HODNOCENÍ

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Přepisuje v_Valuo_vzorek_q. Přehodnotí všech 48 066 vkladů
   ve vzorku, do dat nezasahuje.

   ============================================================
   CO SE MĚNÍ
   ============================================================
   Hodnocení dosud stálo na čtyřech pevných číslech v
   CIS_prahy_ceny.cena_min — 100 000 Kč u jednotek, 200 000
   u budov, 10 000 u pozemků, 0 u nerozlišitelných vkladů — a
   na mediánu z pohledu v_cenove_hladiny.

   Nově čte z tabulky Valuo_prahy, která je spočítaná z dat.
   Tím se sjednotí zdroj: medián i obě meze pocházejí z jednoho
   výpočtu, ne ze dvou různých míst.

   ------------------------------------------------------------
   PROPADÁVÁNÍ
   ------------------------------------------------------------
   Mez se hledá nejdřív pro katastrální území, pak pro okres,
   pak pro kraj. Vezme se první nalezená, takže čím podrobnější
   úroveň má dost vkladů, tím přesnější mez.

   Sloupce uroven_meze a bodu_v_mezi říkají, odkud mez je a na
   kolika vkladech stojí. V posudku je to podstatné — mez z pěti
   set bytů v témže území je něco jiného než ze třiceti vkladů
   za celý kraj.

   ============================================================
   CO JSEM MUSEL PŘI PŘÍPRAVĚ PŘEHODNOTIT
   ============================================================
   Při kontrole schémat vyšly najevo tři věci, se kterými jsem
   původně nepočítal. Píšu je, protože jsou to rozhodnutí, ne
   technické detaily.

   1  METRIKA KUS
      Metrika není jen JC a CELEK — garáže mají KUS, protože se
      porovnávají jako jeden kus, ne na m². Ve vzorku je takových
      vkladů 2 358. Mapuje se na mez z celkové ceny stejně jako
      CELEK, tedy shodně s tím, jak to dělá sp_prepocet_prahu.

   2  VKLADY S KLASIFIKACÍ NELZE — 10 589 vkladů
      Tohle je největší skupina po jednotkách a dosud měla
      hodnocení „porovnává se cena". Jsou to vklady, u nichž
      jednotkovou cenu spočítat nelze — víc nemovitostí, různé
      druhy. Prahy pro ně v tabulce jsou, pod klíčem DRUH:?, a
      10 583 z nich by mez našlo.

      Nepoužívám je. Medián vkladu, který míchá byt s pozemkem
      a garáží, neříká nic, a horní mez z něj by označila jako
      podezřelý každý větší soubor. Tyto vklady dostanou
      hodnocení „nelze porovnat" a projdou jen kontrolou na
      symbolickou cenu.

      Ta kontrola potřebuje absolutní číslo. CIS_prahy_ceny má
      u NELZE nulu, takže se bere mez z CIS_mez_podilu pro „*",
      dnes 100 000 Kč. Je to nepodložené číslo stejného druhu,
      jaká jsme v kroku 24 odstraňovali — u smíchaných vkladů ale
      nic lepšího není. Je na jednom místě a lze ho změnit.

   3  POZEMKY SE STAVBOU
      Pro pozemky žádné prahy na celkové ceně neexistují, všechny
      jsou jednotkové. 72 vkladů s pozemkem, kde je stavba
      součástí, má metriku CELEK, takže by mez nenašlo. Dostanou
      hodnocení „chybí podlahová plocha" dřív, než se na mez
      dojde, takže to nevadí.

   ------------------------------------------------------------
   ZMĚNY V HODNOCENÍ
   ------------------------------------------------------------
   zaniká    řádově nízká        nahrazeno mezí z dat
   zaniká    řádově vysoká       nahrazeno mezí z dat
   zaniká    porovnává se cena   u budov a jednotek nahrazeno mezí
                                 na celkové ceně — 2 860 vkladů je
                                 poprvé pod kontrolou; u NELZE
                                 přejmenováno

   přibývá   pod mezí            hodnota pod spodní mezí
   přibývá   nad mezí            hodnota nad horní mezí
   přibývá   podíl nebo          pozemek s cenou vkladu pod mezí
             symbolický převod   z CIS_mez_podilu; dosud se tvářily
                                 jako prodeje za 3 Kč/m²
   přibývá   nelze porovnat      vklad s klasifikací NELZE

   zůstává   symbolická cena     ale jen pro vklady, pro které mez
                                 z dat nevznikla — tam zůstává
                                 absolutní číslo jako záchyt
   zůstává   bez srovnání        pro kombinaci nevznikla mez ani
                                 na úrovni kraje; čekám kolem
                                 1 900 vkladů, z toho 1 062 pozemků

   ------------------------------------------------------------
   PŘEJMENOVANÉ SLOUPCE
   ------------------------------------------------------------
   median_Kc_m2   →  median_Kc        už to nemusí být Kč/m²; u
                                      metriky CELEK a KUS je to
                                      medián celkové ceny
   bodu_v_hladine →  bodu_v_mezi
   uroven_hladiny →  uroven_meze

   Nové: mez_zdola, mez_shora, porovnavana_hodnota, fvu_skupina,
   velikostni_pasmo. Pohled má 55 sloupců místo 50.

   Prověřil jsem, co na starých názvech viselo: 23c_mapa_prevodu.py
   je nepoužívá a ostatní výskyty jsou v už proběhlých krocích.

   ------------------------------------------------------------
   PROČ TO NENÍ KRUH
   ------------------------------------------------------------
   sp_prepocet_prahu čte z v_Valuo_vzorek_q a ten teď čte z
   Valuo_prahy. Kruh se neuzavírá ze dvou důvodů:

   Procedura naplní #d z pohledu na řádku 121 a tabulku maže až
   na 141, takže čte ještě staré prahy a nové do výpočtu nevstoupí.

   Důležitější je, že procedura nefiltruje podle hodnoceni_ceny.
   Filtruje podle měny, typu převodu, hromadného převodu, roku a
   meze podílu — tedy podle věcí, které na mezi nezávisí. Kdyby
   brala jen vklady „bez výhrad", meze by se při každém přepočtu
   stahovaly k mediánu, až by nakonec vyřadily všechno kromě
   středu. Oddíl 26.3 ověřuje, že druhý přepočet dá totéž.

   ------------------------------------------------------------
   CO ZŮSTÁVÁ NEVYŘEŠENÉ
   ------------------------------------------------------------
   Prahy stojí na vkladech za posledních 5 let, hodnotí se jimi
   ale i vklady starší. Cena z roku 2016 bude označena „pod mezí",
   přestože v té době mohla být běžná. Oddíl 26.4 ukáže, kolik
   takových případů je. Řešením je deflace na datum ocenění —
   roční mediány, které jsou další na řadě.

   v_cenove_hladiny zůstává v databázi, pohled už ji nepoužívá.
   Nemazal jsem ji, může sloužit k výpisům.
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

        CASE WHEN hp.jedn_cena_Kc_m2 IS NULL THEN 0 ELSE 1 END
                                                    AS hromadny_prevod,
        hp.vkladu                                   AS hromadne_vkladu,
        hp.typ_jevu,
        hp.poznamka                                 AS hromadna_poznamka,

        mt.metrika,
        CASE WHEN mt.metrika = 'JC' THEN v.jedn_cena_Kc_m2 END AS jedn_cena_Kc_m2,

        up.fvu_kod,
        up.mira_vyuziti,
        fs.skupina                                  AS fvu_skupina,
        vp.pasmo                                    AS velikostni_pasmo,

        /* co se poměřuje mezí — podle metriky jednotková nebo
           celková cena */
        h.hodnota                                   AS porovnavana_hodnota,

        /* medián i meze z jednoho zdroje */
        CAST(p.median     AS decimal(18,2))         AS median_Kc,
        CAST(p.prah_dolni AS decimal(18,2))         AS mez_zdola,
        CAST(p.prah_horni AS decimal(18,2))         AS mez_shora,
        p.n                                         AS bodu_v_mezi,
        p.uroven                                    AS uroven_meze,
        CASE WHEN p.median > 0
             THEN CAST(h.hodnota / p.median AS decimal(10,3)) END
                                                    AS pomer_k_medianu,

        CASE
            WHEN ISNULL(v.mena, 'CZK') <> 'CZK'
             AND v.kurz_pouzity IS NULL              THEN N'cizí měna bez kurzu'
            WHEN v.typ_prevodu <> 'KUPNI_SMLOUVA'    THEN N'nestandardní převod'
            WHEN hp.jedn_cena_Kc_m2 IS NOT NULL
             AND ISNULL(y.do_medianu, 0) = 0         THEN N'hromadný převod'

            /* u pozemku je nízká cena vkladu známkou podílu —
               plocha je za celou parcelu, cena za zlomek */
            WHEN v.klasifikace = 'JC_PARCELY'
             AND v.cena_Kc < ISNULL(mzk.mez_Kc, mzg.mez_Kc)
                                                     THEN N'podíl nebo symbolický převod'

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
            WHEN mt.metrika = 'JC'
             AND ISNULL(v.jedn_cena_Kc_m2, 0) <= 0    THEN N'bez JC'
            WHEN ISNULL(h.hodnota, 0) <= 0            THEN N'bez ceny'

            /* smíchané vklady: jen záchyt na symbolickou cenu,
               statistická mez z nich nic neříká */
            WHEN v.klasifikace = 'NELZE'
             AND v.cena_Kc < ISNULL(NULLIF(t.cena_min, 0), mzg.mez_Kc)
                                                     THEN N'symbolická cena'
            WHEN v.klasifikace = 'NELZE'              THEN N'nelze porovnat'

            /* mez z dat nevznikla — zůstává absolutní číslo */
            WHEN p.median IS NULL
             AND v.cena_Kc < ISNULL(NULLIF(t.cena_min, 0), mzg.mez_Kc)
                                                     THEN N'symbolická cena'
            WHEN p.median IS NULL                     THEN N'bez srovnání'

            WHEN h.hodnota < p.prah_dolni             THEN N'pod mezí'
            WHEN h.hodnota > p.prah_horni             THEN N'nad mezí'
            ELSE                                           N'bez výhrad'
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
            WHEN pd.citatel_podilu IS NULL           THEN N'nenačteno'
            WHEN pd.citatel_podilu < 100             THEN N'malý čitatel - podezřelý'
            ELSE                                          N'plošný zlomek'
        END                                         AS hodnoceni_podilu,

        CASE WHEN v.duplicitnich_radku > 0 THEN N'ano' ELSE N'ne' END
                                                    AS obsahuje_duplicity,

        v.geo_bod,
        v.LAT,
        v.LON
FROM dbo.v_Valuo_vzorek v
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku
LEFT JOIN hlavni  pd ON pd.cislo_vkladu = v.cislo_vkladu
LEFT JOIN metrika mt ON mt.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.Valuo_hromadne_prevody hp
       ON hp.klasifikace     = v.klasifikace
      AND hp.kat_uzemi       = v.kat_uzemi
      AND hp.druh            = ISNULL(v.druh, '?')
      AND hp.jedn_cena_Kc_m2 = v.jedn_cena_Kc_m2
LEFT JOIN dbo.CIS_typy_hromadneho_prevodu y ON y.typ_jevu = hp.typ_jevu
LEFT JOIN dbo.v_vklad_UP      up ON up.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_FVU_skupiny fs ON fs.fvu_kod      = up.fvu_kod
LEFT JOIN dbo.CIS_velikost_pozemku vp
       ON v.plocha_parcel_m2 >= vp.od_m2 AND v.plocha_parcel_m2 < vp.do_m2
LEFT JOIN dbo.CIS_prahy_ceny   t  ON t.klasifikace = v.klasifikace
LEFT JOIN dbo.CIS_mez_podilu  mzk ON mzk.kraj      = c.kraj_nazev
LEFT JOIN dbo.CIS_mez_podilu  mzg ON mzg.kraj      = N'*'
LEFT JOIN dbo.CIS_rozsahy_ploch r
       ON r.nemovitost = pd.nemovitost
      AND r.typ        = pd.typ
      AND r.typ_plochy = pd.typ_plochy

CROSS APPLY (
    SELECT hodnota = CASE WHEN mt.metrika = 'JC' THEN v.jedn_cena_Kc_m2
                          ELSE v.cena_Kc END
) h

/* mez s propadáváním: k. ú., pak okres, pak kraj. Klíč se
   skládá stejně jako v sp_prepocet_prahu — kdyby se obě místa
   rozešla, nenašlo by se nic a všechno by spadlo do „bez
   srovnání".                                                  */
OUTER APPLY (
    SELECT TOP 1 pr.median, pr.prah_dolni, pr.prah_horni, pr.n, pr.uroven
    FROM dbo.Valuo_prahy pr
    WHERE pr.klasifikace = v.klasifikace
      AND v.klasifikace <> 'NELZE'
      AND pr.metrika = CASE WHEN mt.metrika = 'JC' THEN 'JC' ELSE 'CENA' END
      AND pr.klic = CASE
            WHEN v.klasifikace = 'JC_PARCELY'
             AND fs.skupina IS NOT NULL
             AND c.kraj_nazev = N'Hlavní město Praha'
            THEN N'FVU:' + CAST(fs.skupina AS nvarchar(20))
                 + N'|'  + CAST(vp.pasmo   AS nvarchar(12))
            ELSE N'DRUH:' + CAST(ISNULL(v.druh, '?') AS nvarchar(100)) END
      AND (   (pr.uroven = N'k.ú.'  AND pr.uzemi = c.ku_nazev)
           OR (pr.uroven = N'okres' AND pr.uzemi =
                   COALESCE(c.okres_nazev, c.kraj_nazev))
           OR (pr.uroven = N'kraj'  AND pr.uzemi = c.kraj_nazev))
    ORDER BY CASE pr.uroven WHEN N'k.ú.'  THEN 1
                            WHEN N'okres' THEN 2 ELSE 3 END
) p;
GO


/* ---------- 26.1 CO SE ZMĚNILO ---------------------------- */

/* Rozložení hodnocení. Předtím: bez výhrad 24 847,
   porovnává se cena 13 369, symbolická cena 2 305,
   řádově nízká 1 783, řádově vysoká 332.                     */
SELECT hodnoceni_ceny, vkladu = COUNT(*),
       podil_pct = CAST(100.0 * COUNT(*)
                        / SUM(COUNT(*)) OVER () AS decimal(5,1))
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO

/* Podle klasifikace a metriky — kde se co posunulo */
SELECT klasifikace, metrika, hodnoceni_ceny, vkladu = COUNT(*)
FROM dbo.v_Valuo_vzorek_q
GROUP BY klasifikace, metrika, hodnoceni_ceny
HAVING COUNT(*) >= 20
ORDER BY klasifikace, metrika, COUNT(*) DESC;
GO


/* ---------- 26.2 ODKUD MEZE POCHÁZEJÍ ---------------------- */

SELECT  uroven_meze, vkladu = COUNT(*),
        nejmene_bodu = MIN(bodu_v_mezi),
        prumer_bodu  = CAST(AVG(CAST(bodu_v_mezi AS float)) AS int),
        nejvic_bodu  = MAX(bodu_v_mezi)
FROM dbo.v_Valuo_vzorek_q
WHERE uroven_meze IS NOT NULL
GROUP BY uroven_meze
ORDER BY CASE uroven_meze WHEN N'k.ú.' THEN 1
                          WHEN N'okres' THEN 2 ELSE 3 END;
GO

/* Kontrola, že klíč sedí s procedurou. Čekám kolem 1 062
   pozemků a pár set budov; kdyby to byly desetitisíce, klíč
   se rozešel.                                                 */
SELECT klasifikace, metrika, druh, bez_meze = COUNT(*)
FROM dbo.v_Valuo_vzorek_q
WHERE hodnoceni_ceny IN (N'bez srovnání', N'symbolická cena')
GROUP BY klasifikace, metrika, druh
HAVING COUNT(*) >= 10
ORDER BY COUNT(*) DESC;
GO


/* ---------- 26.3 ŽE SE MEZE NESTAHUJÍ ---------------------
   Prahy se počítají z pohledu, který je teď sám používá.
   Druhý přepočet musí dát totéž — jinak by se meze při každém
   spuštění zužovaly.                                          */

IF OBJECT_ID('tempdb..#pred') IS NOT NULL DROP TABLE #pred;
SELECT * INTO #pred FROM dbo.Valuo_prahy;

EXEC dbo.sp_prepocet_prahu;

SELECT  kontrola = N'stabilita prahů při druhém přepočtu',
        kombinaci_pred = (SELECT COUNT(*) FROM #pred),
        kombinaci_po   = (SELECT COUNT(*) FROM dbo.Valuo_prahy),
        zmenenych      = (SELECT COUNT(*) FROM #pred a
                          JOIN dbo.Valuo_prahy b
                            ON b.klasifikace = a.klasifikace
                           AND b.klic = a.klic AND b.metrika = a.metrika
                           AND b.uroven = a.uroven AND b.uzemi = a.uzemi
                          WHERE ABS(b.median - a.median) > 0.01
                             OR ABS(b.prah_dolni - a.prah_dolni) > 0.01
                             OR ABS(b.prah_horni - a.prah_horni) > 0.01),
        zmizelych      = (SELECT COUNT(*) FROM #pred a
                          WHERE NOT EXISTS (SELECT 1 FROM dbo.Valuo_prahy b
                            WHERE b.klasifikace = a.klasifikace
                              AND b.klic = a.klic AND b.metrika = a.metrika
                              AND b.uroven = a.uroven AND b.uzemi = a.uzemi));

DROP TABLE #pred;
GO


/* ---------- 26.4 STARÉ VKLADY -----------------------------
   Meze stojí na posledních pěti letech, hodnotí se jimi ale
   i vklady starší. Tohle ukáže, jak velký problém to je —
   tedy jak nutné jsou roční mediány.                          */

SELECT  obdobi = CASE WHEN rok >= YEAR(GETDATE()) - 5
                      THEN N'v rozsahu prahů' ELSE N'starší' END,
        vkladu = COUNT(*),
        pod_mezi = SUM(CASE WHEN hodnoceni_ceny = N'pod mezí' THEN 1 ELSE 0 END),
        pod_mezi_pct = CAST(100.0 * SUM(CASE WHEN hodnoceni_ceny = N'pod mezí'
                            THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1)),
        nad_mezi = SUM(CASE WHEN hodnoceni_ceny = N'nad mezí' THEN 1 ELSE 0 END)
FROM dbo.v_Valuo_vzorek_q
GROUP BY CASE WHEN rok >= YEAR(GETDATE()) - 5
              THEN N'v rozsahu prahů' ELSE N'starší' END;
GO

/* Po letech — kde se zlom láme */
SELECT  rok, vkladu = COUNT(*),
        pod_mezi_pct = CAST(100.0 * SUM(CASE WHEN hodnoceni_ceny = N'pod mezí'
                            THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1))
FROM dbo.v_Valuo_vzorek_q
WHERE klasifikace = 'JC_JEDNOTKA' AND metrika = 'JC'
GROUP BY rok HAVING COUNT(*) >= 50 ORDER BY rok;
GO


/* ---------- 26.5 KONTROLNÍ VZORKY -------------------------- */

/* Kobylisy — případ, na kterém stál celý krok 23 */
SELECT  hodnoceni_ceny, vkladu = COUNT(*),
        od = CAST(MIN(porovnavana_hodnota) AS decimal(12,0)),
        do = CAST(MAX(porovnavana_hodnota) AS decimal(12,0)),
        mez_zdola = CAST(MIN(mez_zdola) AS decimal(12,0)),
        mez_shora = CAST(MAX(mez_shora) AS decimal(12,0))
FROM dbo.v_Valuo_vzorek_q
WHERE kat_uzemi = 'Kobylisy' AND druh = 'byt'
GROUP BY hodnoceni_ceny ORDER BY vkladu DESC;
GO

/* Garáže — poprvé hodnocené, metrika KUS */
SELECT  hodnoceni_ceny, vkladu = COUNT(*),
        od = CAST(MIN(cena_Kc) AS decimal(12,0)),
        do = CAST(MAX(cena_Kc) AS decimal(12,0))
FROM dbo.v_Valuo_vzorek_q
WHERE druh = 'garáž'
GROUP BY hodnoceni_ceny ORDER BY vkladu DESC;
GO

/* Pozemky v Praze podle funkčního využití */
SELECT  fvu_skupina, velikostni_pasmo,
        vkladu = COUNT(*),
        bez_vyhrad = SUM(CASE WHEN hodnoceni_ceny = N'bez výhrad'
                              THEN 1 ELSE 0 END),
        median = CAST(MIN(median_Kc) AS decimal(12,0)),
        zdola  = CAST(MIN(mez_zdola) AS decimal(12,0)),
        shora  = CAST(MAX(mez_shora) AS decimal(12,0))
FROM dbo.v_Valuo_vzorek_q
WHERE klasifikace = 'JC_PARCELY' AND fvu_skupina IS NOT NULL
GROUP BY fvu_skupina, velikostni_pasmo
HAVING COUNT(*) >= 10
ORDER BY fvu_skupina, velikostni_pasmo;
GO

/* Použitelné porovnávací vzorky — co z databáze vypadne
   na posudky                                                  */
SELECT  kategorie = CASE klasifikace
            WHEN 'JC_JEDNOTKA'  THEN N'jednotky'
            WHEN 'JC_PARCELY'   THEN N'pozemky'
            WHEN 'CELEK_BUDOVA' THEN N'budovy'
            ELSE N'nerozlišeno' END,
        druh, metrika,
        bez_vyhrad = COUNT(*),
        za_5_let = SUM(CASE WHEN rok >= YEAR(GETDATE()) - 5
                            THEN 1 ELSE 0 END)
FROM dbo.v_Valuo_vzorek_q
WHERE hodnoceni_ceny = N'bez výhrad'
GROUP BY klasifikace, druh, metrika
HAVING COUNT(*) >= 50
ORDER BY COUNT(*) DESC;
GO
