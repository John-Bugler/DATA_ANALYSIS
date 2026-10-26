/* ============================================================================
   27a_oprava_jednotek.sql — oprava pohledu v_RUIAN_jednotky

   CHYBA V KROKU 27
   Pohled párovat jednotku na stavební objekt podle čísla popisného v rámci
   OBCE. V Praze se ale čísla popisná číslují po katastrálních územích, ne
   po obci — č. p. 40 odpovídá v Praze 116 různým stavebním objektům.

   Dopad: každá jednotka se napojila na desítky domů. Ve výpisu to nebylo
   vidět, protože se počítalo COUNT(DISTINCT valuo_id).

   Měřeno na pražských datech:
       přes parcelu        44 626 jednotek,  1,05 objektu na jednotku
       přes č. p. v obci   44 621 jednotek, 36,30 objektu na jednotku

   OPRAVA
   Jednotka se páruje přes parcelu, stejně jako budova. Vklad na jednotku
   obsahuje i podíl na pozemku pod domem, takže vazba existuje a je přesná.
   Pokrytí je o pět jednotek vyšší než u čísla popisného, nic se neztrácí.

   Číslo popisné zůstává jako KONTROLA: sloupec cp_souhlasi říká, zda
   stavební objekt opravdu nese to číslo popisné, které má jednotka
   v označení. Tabulka RUIAN_so_cisla_domovni se proto nemaže.
   ========================================================================= */

SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.v_RUIAN_jednotky') IS NOT NULL DROP VIEW dbo.v_RUIAN_jednotky;
GO

CREATE VIEW dbo.v_RUIAN_jednotky AS
SELECT
    v.id                        AS valuo_id,
    v.cislo_vkladu,
    v.typ,
    v.jednotka_oznaceni,
    v.jednotka_cp,
    r.kod_so,
    r.gml_id,

    /* kontrola napojení: nese ten objekt opravdu číslo popisné jednotky? */
    CAST(CASE WHEN EXISTS (
            SELECT 1 FROM dbo.RUIAN_so_cisla_domovni cd
            WHERE cd.kod_so = r.kod_so
              AND cd.cislo_domovni = TRY_CAST(v.jednotka_cp AS int))
         THEN 1 ELSE 0 END AS bit)          AS cp_souhlasi,

    r.dokonceni                 AS dum_dokonceni,
    r.pocet_bytu                AS dum_pocet_bytu,
    r.pocet_podlazi             AS dum_pocet_podlazi,
    r.zastavena_plocha          AS dum_zastavena_plocha,
    r.obestaveny_prostor        AS dum_obestaveny_prostor,
    r.druh_konstrukce_kod,
    ck.nazev                    AS dum_druh_konstrukce,
    r.vybaveni_vytahem_kod,
    cx.nazev                    AS dum_vytah,
    r.zpusob_vytapeni_kod,
    cv.nazev                    AS dum_vytapeni,
    r.pripojeni_vodovod_kod,
    r.pripojeni_kanalizace_kod,
    r.pripojeni_plyn_kod,
    r.zpusob_vyuziti_kod,
    cu.nazev                    AS dum_zpusob_vyuziti,
    r.soubor_datum              AS ruian_stav_k
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data p         ON p.id_valuo = v.id
JOIN dbo.RUIAN_stavebni_objekty r ON r.gml_id = p.gml_id
LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik = 'DruhKonstrukce'       AND ck.kod = r.druh_konstrukce_kod
LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik = 'ZpusobVytapeni'       AND cv.kod = r.zpusob_vytapeni_kod
LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik = 'VybaveniVytahem'      AND cx.kod = r.vybaveni_vytahem_kod
LEFT JOIN dbo.CIS_RUIAN cu ON cu.ciselnik = 'ZpusobVyuzitiObjektu' AND cu.kod = r.zpusob_vyuziti_kod
WHERE v.nemovitost = 'jednotka';
GO

PRINT 'v_RUIAN_jednotky opraven — parovani pres parcelu.';
GO

/* Kontrola po opravě: na kolik objektů připadá jedna jednotka.
   Očekávaná hodnota je kolem 1,0; dřív to bylo 36,3.                       */
SELECT
    COUNT(DISTINCT valuo_id)                                   AS jednotek,
    COUNT(*)                                                   AS radku,
    CAST(COUNT(*) * 1.0 / NULLIF(COUNT(DISTINCT valuo_id), 0)
         AS decimal(6,2))                                      AS objektu_na_jednotku,
    SUM(CASE WHEN cp_souhlasi = 1 THEN 1 ELSE 0 END)           AS cp_souhlasi,
    SUM(CASE WHEN dum_dokonceni IS NOT NULL THEN 1 ELSE 0 END) AS s_rokem
FROM dbo.v_RUIAN_jednotky;
GO
