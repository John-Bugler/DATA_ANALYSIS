/* ============================================================================
   27_ruian_tabulky.sql — tabulky pro technickoekonomické atributy z RÚIAN

   Spustit jednou před prvním během 27_ruian_import.py.
   Data se do těchto tabulek NIKDY nepřelévají do Valuo_data — zůstávají
   oddělená, aby v posudku šlo doložit, odkud který údaj pochází.
   ========================================================================= */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   1. Číselníky RÚIAN — jeden soubor za ČR (ST_UCIS), plní se jednou.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.CIS_RUIAN') IS NULL
CREATE TABLE dbo.CIS_RUIAN (
    ciselnik      varchar(40)   NOT NULL,   -- napr. 'DruhKonstrukce'
    kod           int           NOT NULL,
    nazev         nvarchar(250) NOT NULL,
    platnost_od   date          NULL,
    platnost_do   date          NULL,       -- vyplneno = kod uz se nepouziva
    nacteno       datetime2(0)  NOT NULL CONSTRAINT DF_CIS_RUIAN_nacteno DEFAULT SYSDATETIME(),
    CONSTRAINT PK_CIS_RUIAN PRIMARY KEY (ciselnik, kod)
);
GO

/* ---------------------------------------------------------------------------
   2. Stavební objekty — jádro.

   kod_so      = kód stavebního objektu v RÚIAN (soi:Kod), jednoznačný v ČR
   parcela_id  = soi:IdentifikacniParcela/pai:Id
   gml_id      = tentýž údaj ve tvaru, v jakém ho má KN_parcel_data ('CP.…'),
                 takže join je varchar = varchar bez konverze

   plocha_podezrela: podlahová plocha v RÚIAN bývá u části objektů plochou
   jednoho bytu či vchodu, ne celé budovy. Příznak označí případy, kde je
   podlahová plocha proti součinu zastavěné plochy a počtu podlaží
   nevěrohodně nízká. Ověřeno na vzorku: medián poměru 0,68, pod 0,5 leží
   necelá pětina objektů.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.RUIAN_stavebni_objekty') IS NULL
CREATE TABLE dbo.RUIAN_stavebni_objekty (
    kod_so                    bigint      NOT NULL,
    obec_kod                  int         NOT NULL,
    cast_obce_kod             int         NULL,
    parcela_id                bigint      NULL,
    gml_id AS CASE WHEN parcela_id IS NULL THEN NULL
                   ELSE 'CP.' + CAST(parcela_id AS varchar(20)) END PERSISTED,

    typ_so_kod                tinyint     NULL,   -- 1 = s c.p., 2 = s c.e., 3 = bez cisla
    zpusob_vyuziti_kod        int         NULL,
    dokonceni                 date        NULL,
    iskn_budova_id            bigint      NULL,

    pocet_bytu                int         NULL,
    pocet_podlazi             int         NULL,
    zastavena_plocha          int         NULL,
    podlahova_plocha          int         NULL,
    obestaveny_prostor        int         NULL,

    druh_konstrukce_kod       int         NULL,
    zpusob_vytapeni_kod       int         NULL,
    vybaveni_vytahem_kod      int         NULL,
    pripojeni_kanalizace_kod  int         NULL,
    pripojeni_plyn_kod        int         NULL,
    pripojeni_vodovod_kod     int         NULL,

    plati_od                  date        NULL,   -- posledni editace objektu v RUIAN
    soubor_datum              date        NOT NULL,
    nacteno                   datetime2(0) NOT NULL
        CONSTRAINT DF_RUIAN_so_nacteno DEFAULT SYSDATETIME(),

    plocha_podezrela AS CAST(CASE
        WHEN podlahova_plocha IS NULL OR zastavena_plocha IS NULL
          OR pocet_podlazi IS NULL OR zastavena_plocha <= 0 OR pocet_podlazi <= 0 THEN NULL
        WHEN CAST(podlahova_plocha AS float) / (zastavena_plocha * pocet_podlazi) < 0.5 THEN 1
        ELSE 0 END AS bit) PERSISTED,

    CONSTRAINT PK_RUIAN_stavebni_objekty PRIMARY KEY (kod_so)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_RUIAN_so_gml')
    CREATE NONCLUSTERED INDEX IX_RUIAN_so_gml
        ON dbo.RUIAN_stavebni_objekty (gml_id)
        INCLUDE (dokonceni, obestaveny_prostor, zastavena_plocha,
                 podlahova_plocha, pocet_podlazi);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_RUIAN_so_obec')
    CREATE NONCLUSTERED INDEX IX_RUIAN_so_obec
        ON dbo.RUIAN_stavebni_objekty (obec_kod);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_RUIAN_so_iskn')
    CREATE NONCLUSTERED INDEX IX_RUIAN_so_iskn
        ON dbo.RUIAN_stavebni_objekty (iskn_budova_id);
GO

/* ---------------------------------------------------------------------------
   3. Čísla domovní — jeden objekt jich může mít několik (doloženo: 5).
      Samostatná tabulka, ne slepenec oddělený svislítkem, aby šlo
      joinovat jednotky podle jednotka_cp.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.RUIAN_so_cisla_domovni') IS NULL
CREATE TABLE dbo.RUIAN_so_cisla_domovni (
    kod_so        bigint NOT NULL,
    cislo_domovni int    NOT NULL,
    obec_kod      int    NOT NULL,
    CONSTRAINT PK_RUIAN_so_cd PRIMARY KEY (kod_so, cislo_domovni)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_RUIAN_cd_obec_cislo')
    CREATE NONCLUSTERED INDEX IX_RUIAN_cd_obec_cislo
        ON dbo.RUIAN_so_cisla_domovni (obec_kod, cislo_domovni) INCLUDE (kod_so);
GO

/* ---------------------------------------------------------------------------
   4. Evidence stažených obcí — odkud a jak staré údaje jsou.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.RUIAN_obce_stav') IS NULL
CREATE TABLE dbo.RUIAN_obce_stav (
    obec_kod      int          NOT NULL CONSTRAINT PK_RUIAN_obce_stav PRIMARY KEY,
    obec_nazev    nvarchar(100) NULL,
    soubor_datum  date         NOT NULL,
    soubor_nazev  nvarchar(200) NULL,
    pocet_so      int          NULL,
    nacteno       datetime2(0) NOT NULL
        CONSTRAINT DF_RUIAN_obce_nacteno DEFAULT SYSDATETIME()
);
GO

/* ---------------------------------------------------------------------------
   5. Pohledy pro párování.

   v_RUIAN_budovy  — budova z Valuo → stavební objekt přes parcelu.
   v_RUIAN_jednotky — jednotka z Valuo → stavební objekt přes číslo popisné.

   Pohledy NIC nepřepisují; vracejí údaje z RÚIAN vedle údajů od Valua,
   takže v posudku jde uvést zdroj každého čísla.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.v_RUIAN_budovy') IS NOT NULL DROP VIEW dbo.v_RUIAN_budovy;
GO
CREATE VIEW dbo.v_RUIAN_budovy AS
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
    r.plocha_podezrela          AS ruian_podlahova_podezrela,
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
JOIN dbo.KN_parcel_data p        ON p.id_valuo = v.id
JOIN dbo.RUIAN_stavebni_objekty r ON r.gml_id = p.gml_id
LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik = 'DruhKonstrukce'   AND ck.kod = r.druh_konstrukce_kod
LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik = 'ZpusobVytapeni'   AND cv.kod = r.zpusob_vytapeni_kod
LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik = 'VybaveniVytahem'  AND cx.kod = r.vybaveni_vytahem_kod
LEFT JOIN dbo.CIS_RUIAN cu ON cu.ciselnik = 'ZpusobVyuzitiObjektu' AND cu.kod = r.zpusob_vyuziti_kod
WHERE v.nemovitost = 'budova';
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
    r.dokonceni                 AS dum_dokonceni,
    r.pocet_bytu                AS dum_pocet_bytu,
    r.pocet_podlazi             AS dum_pocet_podlazi,
    r.zastavena_plocha          AS dum_zastavena_plocha,
    r.druh_konstrukce_kod,
    ck.nazev                    AS dum_druh_konstrukce,
    r.vybaveni_vytahem_kod,
    cx.nazev                    AS dum_vytah,
    r.zpusob_vytapeni_kod,
    cv.nazev                    AS dum_vytapeni,
    r.soubor_datum              AS ruian_stav_k
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data p   ON p.id_valuo = v.id
JOIN dbo.CIS_katastralni_uzemi ku ON ku.ku_kod = p.kod_ku
JOIN dbo.RUIAN_so_cisla_domovni cd
       ON cd.obec_kod = ku.obec_kod
      AND cd.cislo_domovni = TRY_CAST(v.jednotka_cp AS int)
JOIN dbo.RUIAN_stavebni_objekty r ON r.kod_so = cd.kod_so
LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik = 'DruhKonstrukce'  AND ck.kod = r.druh_konstrukce_kod
LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik = 'ZpusobVytapeni'  AND cv.kod = r.zpusob_vytapeni_kod
LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik = 'VybaveniVytahem' AND cx.kod = r.vybaveni_vytahem_kod
WHERE v.nemovitost = 'jednotka';
GO

PRINT 'Tabulky a pohledy RUIAN pripraveny.';
GO
