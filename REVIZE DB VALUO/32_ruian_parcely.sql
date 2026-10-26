/* =========================================================================
   32_ruian_parcely.sql — parcely a geometrie z výměnného formátu RÚIAN

   Patří k 27_ruian_import.py verze 27.5 a výš. Spouští se JEDNOU, před
   prvním importem varianty UKSH.

   PROČ
   Základní sada UZSZ, stažená v kroku 27, nese u parcel pouze definiční
   bod. Ověřeno 24. 10. 2026 na obci Kostelec (503916): 3 196 parcel,
   7 926 definičních bodů, nula polygonů. Kompletní sada UKSH má u všech
   3 196 parcel originální hranici a navíc půdorysy 477 z 482 stavebních
   objektů.

   ZÁSADA
   Z RÚIANu se nezapisuje nic do Valuo_data ani KN_parcel_data (krok 28).
   Parcely z RÚIANu jsou samostatná vrstva vedle parcel z katastru, ne
   místo nich — jsou to dva různé okamžiky: RÚIAN je měsíční snapshot,
   katastr se dotahuje k datu importu. Napojení obstarává gml_id.
   ========================================================================= */

SET NOCOUNT ON;
GO

/* -------------------------------------------------------------------------
   32.1  RUIAN_parcely — jedna parcela = jeden řádek
   ------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.RUIAN_parcely', 'U') IS NULL
CREATE TABLE dbo.RUIAN_parcely (
    kod_parcely        bigint        NOT NULL,   -- pai:Id, totéž co CP.<id>
    obec_kod           int           NOT NULL,
    kod_ku             int           NOT NULL,
    kmenove_cislo      int           NOT NULL,
    poddeleni          int           NULL,
    druh_cislovani_kod tinyint       NULL,       -- 1 stavební, 2 pozemková
    druh_pozemku_kod   tinyint       NULL,
    zpusob_vyuziti_kod int           NULL,
    vymera_m2          int           NULL,       -- výměra dle RÚIAN
    plati_od           date          NULL,
    geo_bod            geography     NULL,       -- definiční bod, WGS84
    geo_plocha         geography     NULL,       -- originální hranice, WGS84
    geo_plocha_m2      decimal(18,2) NULL,       -- plocha z geometrie, kontrolní
    soubor_datum       date          NOT NULL,
    nacteno            datetime2(0)  NOT NULL
        CONSTRAINT DF_RUIAN_parcely_nacteno DEFAULT SYSDATETIME(),
    gml_id AS ('CP.' + CAST(kod_parcely AS varchar(20))) PERSISTED,
    CONSTRAINT PK_RUIAN_parcely PRIMARY KEY CLUSTERED (kod_parcely)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_RUIAN_parcely_gml' AND object_id = OBJECT_ID('dbo.RUIAN_parcely'))
CREATE INDEX IX_RUIAN_parcely_gml ON dbo.RUIAN_parcely (gml_id)
    INCLUDE (kod_ku, vymera_m2, geo_plocha_m2);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_RUIAN_parcely_ku' AND object_id = OBJECT_ID('dbo.RUIAN_parcely'))
CREATE INDEX IX_RUIAN_parcely_ku ON dbo.RUIAN_parcely (kod_ku, kmenove_cislo, poddeleni)
    INCLUDE (druh_cislovani_kod, druh_pozemku_kod, vymera_m2);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_RUIAN_parcely_obec' AND object_id = OBJECT_ID('dbo.RUIAN_parcely'))
CREATE INDEX IX_RUIAN_parcely_obec ON dbo.RUIAN_parcely (obec_kod);
GO

/* -------------------------------------------------------------------------
   32.2  RUIAN_parcely_bpej — bonitované díly zemědělské půdy
   U Kostelce 1 702 dílů na 1 159 parcelách. Vlastní tabulka, protože
   jedna parcela má dílů víc.
   ------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.RUIAN_parcely_bpej', 'U') IS NULL
CREATE TABLE dbo.RUIAN_parcely_bpej (
    kod_parcely  bigint       NOT NULL,
    bpej_kod     int          NOT NULL,
    vymera_m2    int          NULL,
    soubor_datum date         NOT NULL,
    CONSTRAINT PK_RUIAN_parcely_bpej PRIMARY KEY CLUSTERED (kod_parcely, bpej_kod)
);
GO

/* -------------------------------------------------------------------------
   32.3  Půdorysy stavebních objektů
   UKSH nese u stavebních objektů MultiSurface (u Kostelce 477 z 482).
   Sloupec je NULL u všech obcí, které zůstanou na UZSZ.
   ------------------------------------------------------------------------- */
IF COL_LENGTH('dbo.RUIAN_stavebni_objekty', 'geo_plocha') IS NULL
    ALTER TABLE dbo.RUIAN_stavebni_objekty ADD geo_plocha geography NULL;
GO

IF COL_LENGTH('dbo.RUIAN_stavebni_objekty', 'geo_plocha_m2') IS NULL
    ALTER TABLE dbo.RUIAN_stavebni_objekty ADD geo_plocha_m2 decimal(18,2) NULL;
GO

/* -------------------------------------------------------------------------
   32.4  Evidence obcí — která varianta a kolik parcel
   ------------------------------------------------------------------------- */
IF COL_LENGTH('dbo.RUIAN_obce_stav', 'varianta') IS NULL
    ALTER TABLE dbo.RUIAN_obce_stav ADD varianta varchar(4) NULL;
GO

IF COL_LENGTH('dbo.RUIAN_obce_stav', 'pocet_parcel') IS NULL
    ALTER TABLE dbo.RUIAN_obce_stav ADD pocet_parcel int NULL;
GO

/* Dosavadním řádkům doplní variantu z názvu souboru. */
UPDATE dbo.RUIAN_obce_stav
SET varianta = UPPER(SUBSTRING(soubor_nazev,
        CHARINDEX('_OB_', soubor_nazev) + 4 + 7, 4))
WHERE varianta IS NULL
  AND soubor_nazev LIKE '%[_]OB[_]%[_]____.xml.zip';
GO

/* -------------------------------------------------------------------------
   32.5  Prostorové indexy — AŽ PO prvním naplnění
   Nad prázdnou tabulkou se založit dají, ale stavba indexu nad miliony
   řádků je rychlejší po vložení dat. Pusť ručně, až doběhne import.

   CREATE SPATIAL INDEX SIX_RUIAN_parcely_plocha
       ON dbo.RUIAN_parcely (geo_plocha)
       USING GEOGRAPHY_AUTO_GRID WITH (CELLS_PER_OBJECT = 16);

   CREATE SPATIAL INDEX SIX_RUIAN_parcely_bod
       ON dbo.RUIAN_parcely (geo_bod)
       USING GEOGRAPHY_AUTO_GRID WITH (CELLS_PER_OBJECT = 1);
   ------------------------------------------------------------------------- */

/* -------------------------------------------------------------------------
   32.6  Kontrola
   ------------------------------------------------------------------------- */
SELECT 'RUIAN_parcely'      AS tabulka, COUNT(*) AS radku FROM dbo.RUIAN_parcely
UNION ALL
SELECT 'RUIAN_parcely_bpej', COUNT(*) FROM dbo.RUIAN_parcely_bpej;

SELECT varianta, COUNT(*) AS obci FROM dbo.RUIAN_obce_stav GROUP BY varianta;
GO
