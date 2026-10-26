/* ============================================================================
   28_ruian_do_vzorku.sql — zpřístupnění RÚIAN dat pro sestavování vzorku

   Přidává, NIC NEMĚNÍ. Žádný stávající pohled ani procedura se nedotýká,
   meze se nepřepočítávají. Pustit se dá kdykoli a nic se tím nerozbije.

   Obsah:
     1. CIS_stari_stavby        — pásma stáří k ruční úpravě
     2. CIS_RUIAN_parametry     — meze věrohodnosti podlahové plochy
     3. RUIAN_stavebni_objekty  — nový počítaný sloupec pomer_pp_op,
                                  zrušení starého příznaku plocha_podezrela
     4. v_RUIAN_vzorek          — jeden řádek = jeden vklad, pro join
                                  na v_Valuo_vzorek_q přes cislo_vkladu
     5. zaloha_prahy_pred_28    — záloha mezí před krokem 28b

   Zapojení stáří do výpočtu mezí je krok 28b a vyžaduje úpravu
   sp_prepocet_prahu a v_Valuo_vzorek_q.
   ========================================================================= */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   1. Pásma stáří

   Hranice odpovídají stavebním epochám, ne rovnoměrnému dělení. Tabulka je
   určená k ruční úpravě — změna hranic se projeví v pohledu bez zásahu
   do SQL.

   POZOR na povahu údaje. Dvě omezení, obě měřená:

   a) 61,2 % dat dokončení v RÚIAN je 31. prosince a další 4,1 % je první
      den měsíce. Je to dávkově doplněný údaj „někdy v tom roce", ne
      přesné datum. Na pásma to stačí, na přesný rok ne. Pohled proto
      hlásí sloupec ruian_rok_presny.

   b) U staveb po rekonstrukci se údaj aktualizuje, takže rok nemusí být
      rokem původní výstavby. Pro ocenění to vadí málo — stav stavby
      odpovídá spíš té rekonstrukci. Proto se tomu údaji říká
      „rok dokončení", nikoli „stáří stavby".
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.CIS_stari_stavby') IS NULL
CREATE TABLE dbo.CIS_stari_stavby (
    pasmo    varchar(20)   NOT NULL CONSTRAINT PK_CIS_stari_stavby PRIMARY KEY,
    rok_od   int           NOT NULL,
    rok_do   int           NOT NULL,
    poradi   int           NOT NULL,
    popis    nvarchar(200) NULL,
    CONSTRAINT CK_CIS_stari_rozsah CHECK (rok_od <= rok_do)
);
GO

IF NOT EXISTS (SELECT 1 FROM dbo.CIS_stari_stavby)
INSERT INTO dbo.CIS_stari_stavby (pasmo, rok_od, rok_do, poradi, popis) VALUES
 ('do 1945',    0, 1945, 1, N'Starší zástavba, převážně zděná.'),
 ('1946-1990',  1946, 1990, 2, N'Poválečná a socialistická výstavba, panelové technologie.'),
 ('1991-2010',  1991, 2010, 3, N'Porevoluční výstavba.'),
 ('2011+',      2011, 9999, 4, N'Současná výstavba.');
GO

/* ---------------------------------------------------------------------------
   2. Meze věrohodnosti podlahové plochy

   Podlahová plocha v RÚIAN bývá u části objektů plochou jednoho bytu nebo
   vchodu, ne celé budovy. Doložený případ: SO.26177137 — bytový dům,
   39 bytů, 5 podlaží, zastavěná plocha 785 m², ale podlahová plocha
   190 m² a obestavěný prostor 831 m³.

   Příznak se počítá z OBESTAVĚNÉHO PROSTORU, ne z počtu podlaží.
   Důvod: podle definice RÚIAN se u podsklepené budovy počítají i podzemní
   podlaží a obyvatelné podkroví se počítá jako samostatné nadzemní
   podlaží. Běžný rodinný dům se sklepem a podkrovím má tedy 3 podlaží,
   přestože sklep i podkroví mají podstatně menší užitnou plochu než
   přízemí. Výraz (zastavená plocha x podlaží) je proto u českého
   rodinného domu systematicky nadsazený a příznak na něm postavený
   penalizoval běžné domy.

   Očekávaná podlahová plocha ~ obestavěný prostor / 3 m na podlaží.
   Naměřené rozdělení poměru 3 x PP / OP (104 427 objektů):

       pod 0,20      584   ( 0,6 %)
       0,20-0,35   2 530   ( 2,4 %)
       0,35-0,50  10 455   (10,0 %)
       0,50-1,00  77 345   (74,0 %)
       1,00-1,50  12 501   (12,0 %)
       nad 1,50    1 012   ( 1,0 %)

   Výchozí meze 0,35 a 1,50 označí dohromady 4,0 % objektů, tedy jen
   zjevné nesmysly. Hodnoty se dají měnit bez zásahu do pohledu.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.CIS_RUIAN_parametry') IS NULL
CREATE TABLE dbo.CIS_RUIAN_parametry (
    parametr varchar(40)    NOT NULL CONSTRAINT PK_CIS_RUIAN_parametry PRIMARY KEY,
    hodnota  decimal(10,4)  NOT NULL,
    popis    nvarchar(300)  NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM dbo.CIS_RUIAN_parametry)
INSERT INTO dbo.CIS_RUIAN_parametry (parametr, hodnota, popis) VALUES
 ('pomer_pp_op_min', 0.3500, N'Pod touto hodnotou je podlahová plocha proti obestavěnému prostoru nevěrohodně nízká.'),
 ('pomer_pp_op_max', 1.5000, N'Nad touto hodnotou je podlahová plocha proti obestavěnému prostoru nevěrohodně vysoká.'),
 ('vyska_podlazi_m', 3.0000, N'Předpokládaná výška podlaží pro odhad podlahové plochy z obestavěného prostoru.');
GO

/* ---------------------------------------------------------------------------
   3. Poměr podlahové plochy k obestavěnému prostoru jako počítaný sloupec

   Samotný poměr je data, mez je parametr — proto je poměr ve sloupci
   a porovnání s mezí až v pohledu.

   Starý příznak plocha_podezrela se ruší, viz odůvodnění výše.
   --------------------------------------------------------------------------- */
IF COL_LENGTH('dbo.RUIAN_stavebni_objekty', 'pomer_pp_op') IS NULL
    ALTER TABLE dbo.RUIAN_stavebni_objekty ADD pomer_pp_op AS
        CASE WHEN podlahova_plocha IS NULL OR obestaveny_prostor IS NULL
                  OR obestaveny_prostor <= 0 THEN NULL
             ELSE CAST(3.0 * podlahova_plocha / obestaveny_prostor AS decimal(8,3))
        END PERSISTED;
GO

IF COL_LENGTH('dbo.RUIAN_stavebni_objekty', 'plocha_podezrela') IS NOT NULL
    ALTER TABLE dbo.RUIAN_stavebni_objekty DROP COLUMN plocha_podezrela;
GO

/* ---------------------------------------------------------------------------
   4. v_RUIAN_vzorek — jeden řádek na vklad

   Klíč cislo_vkladu, takže se joinuje přímo na v_Valuo_vzorek_q.

   Plochy se sčítají přes RŮZNÉ stavební objekty vkladu (DISTINCT kod_so),
   aby se u vkladu s několika jednotkami v témže domě nezapočítal dům
   vícekrát.

   U jednotek jsou plochy a objem plochami CELÉHO DOMU, ne bytu —
   slouží k popisu domu (stáří, konstrukce, výtah), ne k výpočtu
   jednotkové ceny bytu. Rozlišuje to sloupec ruian_zdroj.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.v_RUIAN_vzorek') IS NOT NULL DROP VIEW dbo.v_RUIAN_vzorek;
GO

CREATE VIEW dbo.v_RUIAN_vzorek AS
WITH vaz AS (
    SELECT v.cislo_vkladu, b.kod_so,
           CAST(1 AS int) AS je_budova, CAST(0 AS int) AS je_jednotka
    FROM dbo.v_RUIAN_budovy b
    JOIN dbo.Valuo_data v ON v.id = b.valuo_id
    UNION ALL
    SELECT v.cislo_vkladu, j.kod_so, 0, 1
    FROM dbo.v_RUIAN_jednotky j
    JOIN dbo.Valuo_data v ON v.id = j.valuo_id
),
u AS (
    SELECT cislo_vkladu, kod_so,
           MAX(je_budova) AS je_budova, MAX(je_jednotka) AS je_jednotka
    FROM vaz
    GROUP BY cislo_vkladu, kod_so
),
a AS (
    SELECT
        u.cislo_vkladu,
        COUNT(*)                                     AS objektu,
        MAX(u.je_budova)                             AS ma_budovu,
        MAX(u.je_jednotka)                           AS ma_jednotku,
        MIN(YEAR(r.dokonceni))                       AS rok_od,
        MAX(YEAR(r.dokonceni))                       AS rok_do,
        MIN(CASE WHEN r.dokonceni IS NULL THEN NULL
                 WHEN (MONTH(r.dokonceni) = 12 AND DAY(r.dokonceni) = 31)
                   OR DAY(r.dokonceni) = 1 THEN 0 ELSE 1 END) AS rok_presny,
        SUM(r.zastavena_plocha)                      AS zastavena_plocha,
        SUM(r.podlahova_plocha)                      AS podlahova_plocha,
        SUM(r.obestaveny_prostor)                    AS obestaveny_prostor,
        SUM(r.pocet_bytu)                            AS pocet_bytu,
        MAX(r.pocet_podlazi)                         AS pocet_podlazi,
        MIN(r.pomer_pp_op)                           AS pomer_pp_op,
        MIN(r.druh_konstrukce_kod)                   AS druh_konstrukce_kod,
        MIN(r.zpusob_vytapeni_kod)                   AS zpusob_vytapeni_kod,
        MIN(r.vybaveni_vytahem_kod)                  AS vybaveni_vytahem_kod,
        MIN(r.pripojeni_vodovod_kod)                 AS pripojeni_vodovod_kod,
        MIN(r.pripojeni_kanalizace_kod)              AS pripojeni_kanalizace_kod,
        MIN(r.pripojeni_plyn_kod)                    AS pripojeni_plyn_kod,
        MAX(r.soubor_datum)                          AS stav_k
    FROM u
    JOIN dbo.RUIAN_stavebni_objekty r ON r.kod_so = u.kod_so
    GROUP BY u.cislo_vkladu
),
cena AS (
    SELECT cislo_vkladu, MAX(cena_Kc) AS cena_Kc
    FROM dbo.Valuo_data
    GROUP BY cislo_vkladu
),
p AS (
    SELECT
        MAX(CASE WHEN parametr = 'pomer_pp_op_min' THEN hodnota END) AS pp_min,
        MAX(CASE WHEN parametr = 'pomer_pp_op_max' THEN hodnota END) AS pp_max
    FROM dbo.CIS_RUIAN_parametry
)
SELECT
    a.cislo_vkladu,

    /* --- původ údajů --- */
    a.objektu                               AS ruian_objektu,
    CASE WHEN a.ma_budovu = 1 AND a.ma_jednotku = 1 THEN N'obojí'
         WHEN a.ma_budovu = 1 THEN N'budova'
         ELSE N'jednotka' END               AS ruian_zdroj,
    a.stav_k                                AS ruian_stav_k,

    /* --- rok dokončení --- */
    a.rok_od                                AS ruian_rok,
    CASE WHEN a.rok_do <> a.rok_od THEN a.rok_do END AS ruian_rok_nejnovejsi,
    CAST(a.rok_presny AS bit)               AS ruian_rok_presny,
    s.pasmo                                 AS ruian_pasmo,
    CASE WHEN a.rok_od IS NOT NULL
         THEN YEAR(GETDATE()) - a.rok_od END AS ruian_stari_let,

    /* --- plochy a objem --- */
    a.zastavena_plocha                      AS ruian_zastavena_plocha,
    a.podlahova_plocha                      AS ruian_podlahova_plocha,
    a.obestaveny_prostor                    AS ruian_obestaveny_prostor,
    a.pocet_podlazi                         AS ruian_pocet_podlazi,
    a.pocet_bytu                            AS ruian_pocet_bytu,

    /* --- věrohodnost podlahové plochy --- */
    a.pomer_pp_op                           AS ruian_pomer_pp_op,
    CAST(CASE WHEN a.pomer_pp_op IS NULL THEN NULL
              WHEN a.pomer_pp_op < p.pp_min OR a.pomer_pp_op > p.pp_max
              THEN 1 ELSE 0 END AS bit)     AS ruian_plocha_podezrela,

    /* --- jednotkové ceny z údajů RÚIAN --- */
    CASE WHEN a.ma_budovu = 1 AND a.obestaveny_prostor > 0
         THEN CAST(cena.cena_Kc / a.obestaveny_prostor AS decimal(18,2)) END
                                            AS ruian_jedn_cena_Kc_m3,
    CASE WHEN a.ma_budovu = 1 AND a.podlahova_plocha > 0
         THEN CAST(cena.cena_Kc / a.podlahova_plocha AS decimal(18,2)) END
                                            AS ruian_jedn_cena_Kc_m2,

    /* --- vlastnosti stavby --- */
    ck.nazev                                AS ruian_druh_konstrukce,
    cv.nazev                                AS ruian_vytapeni,
    cx.nazev                                AS ruian_vytah,
    a.pripojeni_vodovod_kod,
    a.pripojeni_kanalizace_kod,
    a.pripojeni_plyn_kod
FROM a
CROSS JOIN p
LEFT JOIN cena ON cena.cislo_vkladu = a.cislo_vkladu
LEFT JOIN dbo.CIS_stari_stavby s
       ON a.rok_od BETWEEN s.rok_od AND s.rok_do
LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik = 'DruhKonstrukce'  AND ck.kod = a.druh_konstrukce_kod
LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik = 'ZpusobVytapeni'  AND cv.kod = a.zpusob_vytapeni_kod
LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik = 'VybaveniVytahem' AND cx.kod = a.vybaveni_vytahem_kod;
GO

PRINT 'v_RUIAN_vzorek pripraven.';
GO

/* ---------------------------------------------------------------------------
   5. Záloha mezí před krokem 28b

   sp_prepocet_prahu čte z v_Valuo_vzorek_q. Jakmile se do pohledu v kroku
   28b něco přidá, meze se při nejbližším přepočtu změní. Bez téhle zálohy
   nepoznáme, co se posunulo záměrem a co chybou.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.zaloha_prahy_pred_28') IS NULL
BEGIN
    SELECT * INTO dbo.zaloha_prahy_pred_28 FROM dbo.Valuo_prahy WHERE 1 = 0;
    INSERT INTO dbo.zaloha_prahy_pred_28 SELECT * FROM dbo.Valuo_prahy;
    PRINT 'Zaloha mezi ulozena do zaloha_prahy_pred_28.';
END
ELSE
    PRINT 'zaloha_prahy_pred_28 uz existuje, ponechana beze zmeny.';
GO

/* ---------------------------------------------------------------------------
   6. Kontrola
   --------------------------------------------------------------------------- */
SELECT
    COUNT(*)                                                     AS vkladu,
    SUM(CASE WHEN ruian_rok IS NOT NULL THEN 1 ELSE 0 END)       AS s_rokem,
    SUM(CASE WHEN ruian_rok_presny = 1 THEN 1 ELSE 0 END)        AS rok_presny,
    SUM(CASE WHEN ruian_obestaveny_prostor IS NOT NULL THEN 1 ELSE 0 END) AS s_kubaturou,
    SUM(CASE WHEN ruian_podlahova_plocha IS NOT NULL THEN 1 ELSE 0 END)   AS s_plochou,
    SUM(CASE WHEN ruian_plocha_podezrela = 1 THEN 1 ELSE 0 END)  AS plocha_podezrela,
    SUM(CASE WHEN ruian_druh_konstrukce IS NOT NULL THEN 1 ELSE 0 END)    AS s_konstrukci
FROM dbo.v_RUIAN_vzorek;
GO

SELECT ruian_pasmo, COUNT(*) AS vkladu
FROM dbo.v_RUIAN_vzorek
GROUP BY ruian_pasmo
ORDER BY ruian_pasmo;
GO

/* ---------------------------------------------------------------------------
   7. Jak se to používá při sestavování vzorku

   Příznaky jsou vidět, nejsou schované ve filtru — vyřazení záznamu
   musí být v posudku odůvodnitelné.

DECLARE @stred  geography = geography::Point(50.0750, 14.4000, 4326);
DECLARE @radius int = 1500;

SELECT q.cislo_vkladu, q.datum_zplatneni, q.kat_uzemi, q.druh,
       q.plocha_podlahova_m2, q.cena_Kc, q.jedn_cena_Kc_m2,
       q.hodnoceni_ceny, q.bodu_v_mezi, q.uroven_meze,
       r.ruian_rok, r.ruian_pasmo, r.ruian_rok_presny,
       r.ruian_obestaveny_prostor, r.ruian_jedn_cena_Kc_m3,
       r.ruian_podlahova_plocha, r.ruian_pomer_pp_op, r.ruian_plocha_podezrela,
       r.ruian_druh_konstrukce, r.ruian_vytah,
       CAST(q.geo_bod.STDistance(@stred) AS decimal(10,1)) AS vzdalenost_m
FROM dbo.v_Valuo_vzorek_q q
LEFT JOIN dbo.v_RUIAN_vzorek r ON r.cislo_vkladu = q.cislo_vkladu
WHERE q.klasifikace = 'CELEK_BUDOVA'
  AND q.druh = N'rodinný dům'
  AND q.hodnoceni_ceny = N'bez výhrad'
  AND q.geo_bod.STDistance(@stred) <= @radius
  AND q.rok >= YEAR(GETDATE()) - 3
ORDER BY vzdalenost_m;

   Pro porovnání přes kubaturu místo plochy stačí řadit a filtrovat
   podle ruian_jedn_cena_Kc_m3. Meze pro ni zatím nejsou — ty přinese
   krok 28b.
   --------------------------------------------------------------------------- */
