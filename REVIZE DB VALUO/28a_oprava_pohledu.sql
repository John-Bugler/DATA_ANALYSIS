/* ============================================================================
   28a_oprava_pohledu.sql — oprava chyby v kroku 28

   CO SE STALO
   Krok 28 zrušil sloupec RUIAN_stavebni_objekty.plocha_podezrela, ale
   pohled v_RUIAN_budovy ho dál vybíral. Pohledy nejsou schema-bound,
   takže ALTER TABLE prošel a pohled se stal neplatným až za běhu.
   Vytvoření v_RUIAN_vzorek nad ním pak spadlo na Msg 207.

   Poučení: před zrušením sloupce projdi pohledy, které na něm visí —
   sys.sql_expression_dependencies je ukáže.

   CO UŽ PROBĚHLO A NEOPAKUJE SE
   CIS_stari_stavby, CIS_RUIAN_parametry, sloupec pomer_pp_op,
   zrušení plocha_podezrela a zaloha_prahy_pred_28 jsou hotové.

   TENTO SKRIPT
   Přepíše v_RUIAN_budovy tak, aby místo zrušeného příznaku nesl poměr
   podlahové plochy k obestavěnému prostoru, a znovu založí
   v_RUIAN_vzorek. Je bezpečné ho pustit opakovaně.
   ========================================================================= */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   1. v_RUIAN_budovy — zrušený příznak nahrazen poměrem

   ruian_pomer_pp_op = 3 x podlahová plocha / obestavěný prostor.
   Hodnota je data, mez je parametr v CIS_RUIAN_parametry — proto se
   příznak ruian_plocha_podezrela počítá až tady v pohledu.
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.v_RUIAN_budovy AS
SELECT
    v.id                        AS valuo_id,
    v.cislo_vkladu,
    v.nemovitost,
    v.typ,
    v.plocha                    AS plocha_valuo,
    v.typ_plochy                AS typ_plochy_valuo,
    r.kod_so,
    r.gml_id,
    r.dokonceni                 AS ruian_dokonceni,
    r.zastavena_plocha          AS ruian_zastavena_plocha,
    r.obestaveny_prostor        AS ruian_obestaveny_prostor,
    r.podlahova_plocha          AS ruian_podlahova_plocha,
    r.pomer_pp_op               AS ruian_pomer_pp_op,
    CAST(CASE WHEN r.pomer_pp_op IS NULL THEN NULL
              WHEN r.pomer_pp_op < p.pp_min OR r.pomer_pp_op > p.pp_max
              THEN 1 ELSE 0 END AS bit)  AS ruian_plocha_podezrela,
    r.pocet_podlazi             AS ruian_pocet_podlazi,
    r.pocet_bytu                AS ruian_pocet_bytu,
    r.druh_konstrukce_kod,
    ck.nazev                    AS druh_konstrukce,
    r.zpusob_vytapeni_kod,
    cv.nazev                    AS zpusob_vytapeni,
    r.vybaveni_vytahem_kod,
    cx.nazev                    AS vybaveni_vytahem,
    r.pripojeni_vodovod_kod,
    r.pripojeni_kanalizace_kod,
    r.pripojeni_plyn_kod,
    r.typ_so_kod,
    r.zpusob_vyuziti_kod,
    cu.nazev                    AS ruian_zpusob_vyuziti,
    r.soubor_datum              AS ruian_stav_k,
    r.plati_od                  AS ruian_plati_od
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data p2        ON p2.id_valuo = v.id
JOIN dbo.RUIAN_stavebni_objekty r ON r.gml_id = p2.gml_id
CROSS JOIN (
    SELECT MAX(CASE WHEN parametr = 'pomer_pp_op_min' THEN hodnota END) AS pp_min,
           MAX(CASE WHEN parametr = 'pomer_pp_op_max' THEN hodnota END) AS pp_max
    FROM dbo.CIS_RUIAN_parametry
) p
LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik = 'DruhKonstrukce'       AND ck.kod = r.druh_konstrukce_kod
LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik = 'ZpusobVytapeni'       AND cv.kod = r.zpusob_vytapeni_kod
LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik = 'VybaveniVytahem'      AND cx.kod = r.vybaveni_vytahem_kod
LEFT JOIN dbo.CIS_RUIAN cu ON cu.ciselnik = 'ZpusobVyuzitiObjektu' AND cu.kod = r.zpusob_vyuziti_kod
WHERE v.nemovitost = 'budova';
GO

PRINT 'v_RUIAN_budovy opraven.';
GO

/* ---------------------------------------------------------------------------
   2. v_RUIAN_vzorek — jeden řádek na vklad, klíč cislo_vkladu

   Plochy se sčítají přes RŮZNÉ stavební objekty vkladu (DISTINCT kod_so),
   aby se u vkladu s několika jednotkami v témže domě nezapočítal dům
   vícekrát.

   U jednotek jsou plochy a objem plochami CELÉHO DOMU, ne bytu. Slouží
   k popisu domu (stáří, konstrukce, výtah), ne k výpočtu jednotkové ceny
   bytu — proto se Kč/m3 a Kč/m2 počítají jen u budov. Rozlišuje to
   sloupec ruian_zdroj.
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.v_RUIAN_vzorek AS
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
    SELECT MAX(CASE WHEN parametr = 'pomer_pp_op_min' THEN hodnota END) AS pp_min,
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

    /* --- jednotkové ceny z údajů RÚIAN, jen u budov --- */
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
LEFT JOIN dbo.CIS_stari_stavby s ON a.rok_od BETWEEN s.rok_od AND s.rok_do
LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik = 'DruhKonstrukce'  AND ck.kod = a.druh_konstrukce_kod
LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik = 'ZpusobVytapeni'  AND cv.kod = a.zpusob_vytapeni_kod
LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik = 'VybaveniVytahem' AND cx.kod = a.vybaveni_vytahem_kod;
GO

PRINT 'v_RUIAN_vzorek pripraven.';
GO

/* ---------------------------------------------------------------------------
   3. Kontrola
   --------------------------------------------------------------------------- */
SELECT
    COUNT(*)                                                              AS vkladu,
    SUM(CASE WHEN ruian_rok IS NOT NULL THEN 1 ELSE 0 END)                AS s_rokem,
    SUM(CASE WHEN ruian_rok_presny = 1 THEN 1 ELSE 0 END)                 AS rok_presny,
    SUM(CASE WHEN ruian_obestaveny_prostor IS NOT NULL THEN 1 ELSE 0 END) AS s_kubaturou,
    SUM(CASE WHEN ruian_podlahova_plocha IS NOT NULL THEN 1 ELSE 0 END)   AS s_plochou,
    SUM(CASE WHEN ruian_plocha_podezrela = 1 THEN 1 ELSE 0 END)           AS plocha_podezrela,
    SUM(CASE WHEN ruian_druh_konstrukce IS NOT NULL THEN 1 ELSE 0 END)    AS s_konstrukci
FROM dbo.v_RUIAN_vzorek;
GO

SELECT ISNULL(ruian_pasmo, N'(bez roku)') AS pasmo, COUNT(*) AS vkladu
FROM dbo.v_RUIAN_vzorek
GROUP BY ruian_pasmo
ORDER BY pasmo;
GO

/* Násobnost — musí být 1,00, jinak se párování někde rozmnožilo */
SELECT COUNT(*) AS radku, COUNT(DISTINCT cislo_vkladu) AS vkladu,
       CAST(COUNT(*) * 1.0 / NULLIF(COUNT(DISTINCT cislo_vkladu), 0) AS decimal(6,2)) AS nasobnost
FROM dbo.v_RUIAN_vzorek;
GO
