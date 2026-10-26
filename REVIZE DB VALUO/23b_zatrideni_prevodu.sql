/* ============================================================
   VALUO — KROK 23b: ZATŘÍDĚNÍ HROMADNÝCH PŘEVODŮ

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Spusť celé najednou, po kroku 23.

   ============================================================
   CO SE MĚNÍ A PROČ
   ============================================================
   Krok 23 odhalil, že se shodnou jednotkovou cenou při různých
   plochách se prodává z několika věcně různých důvodů:

   1  PRIVATIZACE — převod obecního fondu nebo z družstva.
      Cena hluboko pod trhem. Kobylisy byt 4 905 Kč/m2 proti
      mediánu 109 590, Žižkov 45 554 proti 141 094.

   2  CENIK_NOVOSTAVBA — ceníkový prodej nových jednotek
      developerem. Cena tržní. Nové Město byt 170 000 proti
      mediánu 175 000, Chodov 100 000 proti 116 572.

   3  VYKUP_LINIOVY — výkup pro liniovou stavbu za násobek ceny
      obvyklé podle zákona o urychlení výstavby. Obvyklou cenu
      stanoví znalecký posudek z porovnání skutečných prodejů,
      nikoli z ceny zjištěné podle vyhlášky.

      Výkupní ceny se v jedné trase liší, protože se vykupuje
      postupně v čase a od různých vlastníků, kterým se nabízí
      různě. Jedna skupina parcel může být vykoupena za násobek
      z 220 Kč/m2, jiná z 100 Kč/m2, jiná z 60 Kč/m2. Žádná
      konkrétní jednotková cena proto není znakem výkupu.

      Nejlépe doložená skupina: 1 760 Kč/m2 u 36 vkladů ve
      čtyřech katastrálních územích (Škvorec, Tuklaty, Úvaly
      u Prahy, Květnice) u tří různých druhů pozemku.

   4  STAVEBNI_PARCELY — prodej připravených stavebních parcel
      v rámci developmentu. V katastru bývají dál vedené jako
      orná půda, převod druhu nastává až později nebo vůbec.
      Tuklaty: 8 parcel po 801 m2 za 7 598 Kč/m2 a 7 parcel za
      7 998 Kč/m2 proti mediánu orné půdy 880 Kč/m2.

   Pro výpočet mediánu je správné vyřadit všechny — opakovaný
   tentýž cenový bod není n nezávislých pozorování. Pro práci
   znalce je ale rozdíl zásadní: privatizace je jako srovnání
   nepoužitelná, ceníková cena novostavby je nejkvalitnější
   dostupné srovnání nových jednotek, výkupní cena je srovnání
   pro úplně jinou úlohu a stavební parcely patří do srovnání
   stavebních parcel, ne orné půdy.

   ------------------------------------------------------------
   PROČ SE ZATŘÍĎUJE RUČNĚ
   ------------------------------------------------------------
   Automaticky to nejde. Vyzkoušené znaky selhávají:

   Táž cena ve více katastrech zachytí 2 skupiny ze 66.
   Ostatní liniové výkupy mají v každém území jinou cenu,
   protože se počítají z jiné ceny zjištěné.

   Poměr k mediánu neoddělí nic. Táž výkupní cena 1 760 Kč/m2
   vychází proti tržnímu mediánu jako poměr 2,0 (Tuklaty,
   Úvaly), 3,0 (Květnice) i 4,8 (Škvorec), protože v každém
   území je jiná skladba srovnávaných prodejů. A protože se
   v téže trase vykupuje za různé ceny, nemá pevnou hodnotu
   ani sám násobek vůči okolním prodejům.

   Skupin je 66. Znalec je projde a zatřídí správně, podmínka
   by u části z nich rozhodla špatně a ta chyba by se do
   mediánů vracela.

   ------------------------------------------------------------
   ZATŘÍDĚNÍ PŘEŽIJE IMPORT
   ------------------------------------------------------------
   Procedura z kroku 23 dělala TRUNCATE, čímž by každý přepočet
   ruční práci smazal. Přepisuje se na MERGE podle klíče
   (klasifikace, území, druh, jednotková cena). Skupiny jsou
   proti tomuto klíči stabilní — novým importem roste jen počet
   vkladů ve skupině.

   Zanikne-li zatříděná skupina (oprava chybné plochy změní
   jednotkovou cenu), nemaže se, ale dostane vkladu = 0, aby
   bylo vidět, co se stalo. Nezatříděná se smaže.

   ------------------------------------------------------------
   PRÁVO VETA
   ------------------------------------------------------------
   Typ TRH vrátí skupinu zpět do výpočtu mediánu. Detektor tedy
   navrhuje, rozhoduje znalec.
   ============================================================ */

USE VALUO;
GO

/* ---------- 23b.1 ČÍSELNÍK TYPŮ ---------------------------- */

IF OBJECT_ID('dbo.CIS_typy_hromadneho_prevodu') IS NULL
CREATE TABLE dbo.CIS_typy_hromadneho_prevodu (
    typ_jevu        varchar(20)   NOT NULL PRIMARY KEY,
    popis           nvarchar(200) NOT NULL,
    do_medianu      bit           NOT NULL,
    pouziti         nvarchar(200) NULL
);
GO

MERGE dbo.CIS_typy_hromadneho_prevodu AS c
USING (VALUES
 ('PRIVATIZACE',       N'Převod obecního fondu nebo z bytového družstva za cenu stanovenou vzorcem.',
  0, N'Jako srovnání tržní ceny nepoužitelné.'),
 ('CENIK_NOVOSTAVBA',  N'Ceníkový prodej nových jednotek developerem za pevnou cenu za metr.',
  0, N'Srovnání pro novostavby v téže lokalitě.'),
 ('VYKUP_LINIOVY',     N'Výkup pro liniovou stavbu za násobek ceny obvyklé stanovené znaleckým posudkem. Ceny se v téže trase liší podle doby výkupu a vlastníka.',
  0, N'Srovnání pro ocenění pozemků pro liniovou výstavbu.'),
 ('STAVEBNI_PARCELY',  N'Prodej připravených stavebních parcel v rámci developmentu, v katastru často dál vedených jako orná půda.',
  0, N'Srovnání pro stavební parcely, nikoli pro druh uvedený v katastru.'),
 ('PREVOD_PODILU',     N'Hromadný převod podílů na společné věci za pevnou cenu za metr — typicky podíly na pozemku pod domem nebo na společných částech.',
  0, N'Srovnání jen pro ocenění podílu, nikoli celé věci.'),
 ('JINE',              N'Jiný mechanismus hromadného převodu.',
  0, N'Posoudit u konkrétní zakázky.'),
 ('TRH',               N'Po přezkoumání jde o běžné nezávislé tržní prodeje. Shoda jednotkové ceny je náhodná.',
  1, N'Zůstává ve výpočtu mediánu i v porovnání.')
) AS n (typ_jevu, popis, do_medianu, pouziti)
ON c.typ_jevu = n.typ_jevu
WHEN MATCHED THEN UPDATE SET popis = n.popis, do_medianu = n.do_medianu,
                             pouziti = n.pouziti
WHEN NOT MATCHED THEN INSERT (typ_jevu, popis, do_medianu, pouziti)
     VALUES (n.typ_jevu, n.popis, n.do_medianu, n.pouziti);
GO

SELECT typ_jevu, do_medianu, LEFT(popis, 70) AS popis
FROM dbo.CIS_typy_hromadneho_prevodu ORDER BY do_medianu, typ_jevu;
GO


/* ---------- 23b.2 NOVÉ SLOUPCE ----------------------------- */

IF COL_LENGTH('dbo.Valuo_hromadne_prevody', 'typ_jevu') IS NULL
    ALTER TABLE dbo.Valuo_hromadne_prevody ADD
        typ_jevu        varchar(20)    NULL,   /* zatříďuje znalec */
        poznamka        nvarchar(200)  NULL,   /* vlastní poznámka znalce */
        median_lokality decimal(14,2)  NULL,   /* doplní procedura */
        pomer           decimal(8,3)   NULL,
        katastru        int            NULL,   /* v kolika k.ú. je táž JC */
        rok_min         int            NULL,
        rok_max         int            NULL,
        plocha_min      decimal(14,2)  NULL,
        plocha_max      decimal(14,2)  NULL;
GO

IF OBJECT_ID('FK_hromadne_typ') IS NULL
    ALTER TABLE dbo.Valuo_hromadne_prevody ADD CONSTRAINT FK_hromadne_typ
        FOREIGN KEY (typ_jevu) REFERENCES dbo.CIS_typy_hromadneho_prevodu(typ_jevu);
GO


/* ---------- 23b.3 PROCEDURA S MERGE ------------------------
   Nahrazuje verzi z kroku 23. Zachová typ_jevu a poznamka.   */

CREATE OR ALTER PROCEDURE dbo.sp_detekce_hromadnych_prevodu
    @min_vkladu int = 5,
    @min_ploch  int = 3
AS
BEGIN
    SET NOCOUNT ON;

    /* --- fáze 1: detekce skupin --- */

    WITH nove AS (
        SELECT  v.klasifikace,
                v.kat_uzemi,
                ISNULL(v.druh, '?')               AS druh,
                v.jedn_cena_Kc_m2,
                COUNT(*)                          AS vkladu,
                COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2,
                                        v.plocha_parcel_m2,
                                        v.plocha_budovy_m2)) AS ruznych_ploch,
                MIN(v.cena_Kc)                    AS cena_min,
                MAX(v.cena_Kc)                    AS cena_max,
                MIN(v.rok)                        AS rok_min,
                MAX(v.rok)                        AS rok_max,
                MIN(COALESCE(v.plocha_jednotky_m2,
                             v.plocha_parcel_m2,
                             v.plocha_budovy_m2)) AS plocha_min,
                MAX(COALESCE(v.plocha_jednotky_m2,
                             v.plocha_parcel_m2,
                             v.plocha_budovy_m2)) AS plocha_max
        FROM dbo.v_Valuo_vzorek v
        WHERE v.jedn_cena_Kc_m2 > 0
        GROUP BY v.klasifikace, v.kat_uzemi, ISNULL(v.druh, '?'), v.jedn_cena_Kc_m2
        HAVING COUNT(*) >= @min_vkladu
           AND COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2,
                                       v.plocha_parcel_m2,
                                       v.plocha_budovy_m2)) >= @min_ploch
    )
    MERGE dbo.Valuo_hromadne_prevody AS t
    USING nove AS n
       ON  t.klasifikace     = n.klasifikace
       AND t.kat_uzemi       = n.kat_uzemi
       AND t.druh            = n.druh
       AND t.jedn_cena_Kc_m2 = n.jedn_cena_Kc_m2

    /* skupina trvá — aktualizuj čísla, zatřídění NECHEJ */
    WHEN MATCHED THEN UPDATE SET
        t.vkladu        = n.vkladu,
        t.ruznych_ploch = n.ruznych_ploch,
        t.cena_min      = n.cena_min,
        t.cena_max      = n.cena_max,
        t.rok_min       = n.rok_min,
        t.rok_max       = n.rok_max,
        t.plocha_min    = n.plocha_min,
        t.plocha_max    = n.plocha_max,
        t.datum_vypoctu = GETDATE()

    WHEN NOT MATCHED BY TARGET THEN INSERT
        (klasifikace, kat_uzemi, druh, jedn_cena_Kc_m2, vkladu, ruznych_ploch,
         cena_min, cena_max, rok_min, rok_max, plocha_min, plocha_max,
         datum_vypoctu)
        VALUES
        (n.klasifikace, n.kat_uzemi, n.druh, n.jedn_cena_Kc_m2, n.vkladu,
         n.ruznych_ploch, n.cena_min, n.cena_max, n.rok_min, n.rok_max,
         n.plocha_min, n.plocha_max, GETDATE())

    /* skupina zanikla a NEBYLA zatříděná — smaž */
    WHEN NOT MATCHED BY SOURCE AND t.typ_jevu IS NULL
        THEN DELETE

    /* skupina zanikla, ale JE zatříděná — nech ji a označ nulou,
       aby znalec viděl, že se rozpadla, a rozhodl sám */
    WHEN NOT MATCHED BY SOURCE AND t.typ_jevu IS NOT NULL
        THEN UPDATE SET t.vkladu = 0, t.datum_vypoctu = GETDATE();

    /* --- fáze 2: počet katastrů s touž jednotkovou cenou --- */

    UPDATE h SET h.katastru = k.katastru
    FROM dbo.Valuo_hromadne_prevody h
    JOIN (SELECT jedn_cena_Kc_m2, COUNT(DISTINCT kat_uzemi) AS katastru
          FROM dbo.Valuo_hromadne_prevody
          GROUP BY jedn_cena_Kc_m2) k
      ON k.jedn_cena_Kc_m2 = h.jedn_cena_Kc_m2;

    /* --- fáze 3: medián lokality a poměr ---
       v_cenove_hladiny už je po MERGE přepočítaná, takže medián
       je ten vyčištěný, bez hromadných převodů                 */

    UPDATE h
       SET h.median_lokality = x.median,
           h.pomer = CASE WHEN x.median > 0
                          THEN CAST(h.jedn_cena_Kc_m2 / x.median AS decimal(8,3))
                     END
    FROM dbo.Valuo_hromadne_prevody h
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_nazev = h.kat_uzemi
    OUTER APPLY (
        SELECT TOP 1 l.median
        FROM dbo.v_cenove_hladiny l
        WHERE l.kod_ku      = c.ku_kod
          AND l.klasifikace = h.klasifikace
          AND l.klic        = 'DRUH:' + h.druh
    ) x;
END;
GO

EXEC dbo.sp_detekce_hromadnych_prevodu;
GO


/* ---------- 23b.4 HLADINY S PRÁVEM VETA --------------------
   Proti kroku 23 se mění jen to, že skupina zatříděná jako TRH
   zůstává ve výpočtu mediánu.                                */

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
      AND NOT EXISTS (
            SELECT 1
            FROM dbo.Valuo_hromadne_prevody h
            LEFT JOIN dbo.CIS_typy_hromadneho_prevodu y
                   ON y.typ_jevu = h.typ_jevu
            WHERE h.klasifikace     = q.klasifikace
              AND h.kat_uzemi       = q.kat_uzemi
              AND h.druh            = ISNULL(q.druh, '?')
              AND h.jedn_cena_Kc_m2 = q.jedn_cena_Kc_m2
              AND ISNULL(y.do_medianu, 0) = 0)   /* TRH se nevyřazuje */
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


/* ---------- 23b.5 TYP JEVU V PRACOVNÍM POHLEDU -------------
   Proti kroku 23 přibývají sloupce typ_jevu a hromadna_poznamka
   a hodnocení respektuje právo veta.                          */

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

        /* cena stanovená vzorcem, ne vyjednaná */
        CASE WHEN hp.jedn_cena_Kc_m2 IS NULL THEN 0 ELSE 1 END
                                                    AS hromadny_prevod,
        hp.vkladu                                   AS hromadne_vkladu,
        hp.typ_jevu,                                /* zatřídil znalec */
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

            /* zatříděno jako TRH — detektor přehlasován, hodnotí se
               jako kterýkoli jiný vklad */
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


/* ---------- 23b.6 SEZNAM SKUPIN K ZATŘÍDĚNÍ ----------------
   Tohle je ten výpis, který projdeš. Jeden řádek = jedna
   skupina. Zatřídíš příkazem v oddílu 23b.7.                 */

SELECT  h.klasifikace,
        h.kat_uzemi,
        h.druh,
        CAST(h.jedn_cena_Kc_m2 AS decimal(12,0)) AS JC,
        CAST(h.median_lokality AS decimal(12,0)) AS median,
        h.pomer,
        h.vkladu,
        h.katastru,
        CAST(h.rok_min AS varchar) + CASE WHEN h.rok_max > h.rok_min
             THEN '-' + CAST(h.rok_max AS varchar) ELSE '' END AS roky,
        CAST(h.plocha_min AS decimal(10,0)) AS pl_min,
        CAST(h.plocha_max AS decimal(10,0)) AS pl_max,
        CAST(h.cena_min / 1000000.0 AS decimal(10,2)) AS cena_min_mil,
        CAST(h.cena_max / 1000000.0 AS decimal(10,2)) AS cena_max_mil,
        h.typ_jevu
FROM dbo.Valuo_hromadne_prevody h
ORDER BY h.klasifikace, h.vkladu DESC;
GO


/* ---------- 23b.7 JAK ZATŘÍDIT -----------------------------
   Odkomentuj a uprav. Klíč je území + druh + jednotková cena.

   Jedna skupina:

   UPDATE dbo.Valuo_hromadne_prevody
      SET typ_jevu = 'PRIVATIZACE'
    WHERE kat_uzemi = 'Kobylisy' AND druh = 'byt'
      AND jedn_cena_Kc_m2 BETWEEN 4905.00 AND 4906.00;

   Všechny skupiny s touž jednotkovou cenou napříč katastry —
   ten liniový výkup za 1 760 Kč/m2:

   UPDATE dbo.Valuo_hromadne_prevody
      SET typ_jevu = 'VYKUP_LINIOVY',
          poznamka = N'Výkup pro liniovou stavbu, osminásobek ceny obvyklé.'
    WHERE jedn_cena_Kc_m2 = 1760.00;

   Stavební parcely v Tuklatech vedené jako orná půda:

   UPDATE dbo.Valuo_hromadne_prevody
      SET typ_jevu = 'STAVEBNI_PARCELY',
          poznamka = N'Připravené stavební parcely, v katastru vedené jako orná půda.'
    WHERE kat_uzemi = 'Tuklaty' AND druh = 'orná půda'
      AND jedn_cena_Kc_m2 IN (7598.00, 7998.00);

   Po zatřídění NENÍ nutné nic přepočítávat — pohledy se
   vyhodnocují za běhu. Jen u typu TRH se změní mediány, takže
   se vyplatí zkontrolovat oddíl 23b.8.
   ------------------------------------------------------------ */


/* ---------- 23b.8 KONTROLA --------------------------------- */

/* Kolik je zatříděno */
SELECT ISNULL(typ_jevu, '(nezatříděno)') AS typ_jevu,
       COUNT(*) AS skupin, SUM(vkladu) AS vkladu
FROM dbo.Valuo_hromadne_prevody
GROUP BY typ_jevu ORDER BY vkladu DESC;
GO

/* Skupiny, kde chybí medián lokality — nelze spočítat poměr,
   protože hladina pro to území a druh neexistuje */
SELECT klasifikace, kat_uzemi, druh,
       CAST(jedn_cena_Kc_m2 AS decimal(12,0)) AS JC, vkladu
FROM dbo.Valuo_hromadne_prevody
WHERE median_lokality IS NULL ORDER BY vkladu DESC;
GO

/* Mediány pražských bytů — musí zůstat jako po kroku 23 */
SELECT c.ku_nazev AS kat_uzemi, h.median, h.bodu
FROM dbo.v_cenove_hladiny h
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = h.kod_ku
WHERE h.klasifikace = 'JC_JEDNOTKA' AND h.klic = N'DRUH:byt'
  AND c.ku_nazev IN (N'Kobylisy', N'Chodov', N'Háje', N'Nové Město')
ORDER BY h.median;
GO

/* Vzorek */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO
