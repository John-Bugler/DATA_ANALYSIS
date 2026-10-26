-- =============================================================================
-- 41_rucni_zjisteni.sql — co o nemovitosti zjistí znalec sám
-- =============================================================================
-- Databáze: VALUO        Krok: 41        Datum: 25. 10. 2026
--
-- Proč to vzniklo
-- ---------------
-- Procházením mapy znalec zjišťuje věci, které v datech nejsou a být nemohou:
-- že plocha jednotky je ve skutečnosti plocha celého domu, že na parcele
-- žádná stavba nestojí, že převod nebyl tržní. Dosud se takové zjištění
-- nikam neukládalo a při příštím procházení se muselo hledat znovu.
--
-- Zásada, na které to stojí
-- -------------------------
-- **Do Valuo_data ani do ničeho, co přišlo z Valua, se nezapisuje.** Zjištění
-- jdou do vlastních tabulek a pohled je upřednostní — stejně jako to dělá
-- Valuo_parcely_role se zdrojem „ruční“. Jinak by po příštím importu nešlo
-- poznat, co je údaj z katastru a co znalcův závěr, a u posudku musí být
-- dohledatelné, odkud každé číslo je.
--
-- Plocha má čtyři zdroje a ruční má přednost
-- ------------------------------------------
--   1. plocha ověřená znalcem (Valuo_vklad_rucne.plocha_rucne)  <- nejvyšší
--   2. plocha jednotky dle Valuo (Valuo_data.vklad_plocha_jednotky)
--   3. podlahová plocha dle Valuo (Valuo_data.plocha, typ „Podlahová plocha“)
--   4. podlahová plocha dle RÚIAN — jen u budov, u jednotek popisuje celý dům
-- Pohled vrací použitou hodnotu v plocha_podlahova_karty a její původ
-- v plocha_podlahova_zdroj; u ruční plochy napíše „ověřeno znalcem“.
--
-- Měřeno 25. 10. 2026
-- -------------------
--   Typ plochy u jednotek:  dopočet z podílu 35 605 vkladů
--                           výměra parcely   1 487
--                           změřená plocha     484
--   Takže skoro všechny ceny bytů v databázi stojí na ploše odvozené
--   z podílu na společných částech, ne na změřené. Karta to u ceny uvádí.
--
--   Automatické nálezy:     plocha = celý dům   154 vkladů
--                           dopočet z podílu 35 605 vkladů
--
-- Oprávnění
-- ---------
-- Cizí klíč mezi nálezy a jejich číselníkem vyžaduje REFERENCES; znalec jej
-- udělil 25. 10. 2026 (GRANT REFERENCES ON SCHEMA::dbo TO claude_reader).
-- =============================================================================
GO

-- ČÁST 1: číselník nálezů ----------------------------------------------------
-- Popis je plná věta, protože se ukazuje přímo v aplikaci u zaškrtávátka —
-- znalec nemá nikde dohledávat, co který kód znamená.

IF OBJECT_ID('dbo.CIS_nalezy', 'U') IS NULL
CREATE TABLE dbo.CIS_nalezy (
    kod             varchar(24)   NOT NULL PRIMARY KEY,
    skupina         varchar(20)   NOT NULL,   -- poloha | plocha | cena | role | jine
    nazev           nvarchar(80)  NOT NULL,
    popis           nvarchar(400) NOT NULL,
    vyrazuje_vzorek bit           NOT NULL DEFAULT 0,
    automaticky     bit           NOT NULL DEFAULT 0,   -- umí ho najít databáze
    poradi          int           NOT NULL DEFAULT 100
);
GO

-- ČÁST 2: zjištění ke vkladu -------------------------------------------------

IF OBJECT_ID('dbo.Valuo_vklad_rucne', 'U') IS NULL
CREATE TABLE dbo.Valuo_vklad_rucne (
    cislo_vkladu        varchar(50)    NOT NULL PRIMARY KEY,
    pouzitelnost        varchar(16)    NULL,  -- vhodny | s_vyhradou | nepouzitelny
    pouzitelnost_duvod  nvarchar(400)  NULL,
    plocha_rucne        decimal(14,2)  NULL,  -- má přednost před Valuem i RÚIANem
    plocha_rucne_zdroj  nvarchar(200)  NULL,  -- odkud ji znalec vzal
    kdo                 nvarchar(128)  NULL,
    kdy                 datetime2      NULL
);

IF OBJECT_ID('dbo.Valuo_vklad_nalezy', 'U') IS NULL
CREATE TABLE dbo.Valuo_vklad_nalezy (
    cislo_vkladu varchar(50)   NOT NULL,
    nalez_kod    varchar(24)   NOT NULL,
    poznamka     nvarchar(400) NULL,
    kdo          nvarchar(128) NULL,
    kdy          datetime2     NULL,
    CONSTRAINT PK_Valuo_vklad_nalezy PRIMARY KEY (cislo_vkladu, nalez_kod)
);

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Valuo_vklad_nalezy_cis')
ALTER TABLE dbo.Valuo_vklad_nalezy
    ADD CONSTRAINT FK_Valuo_vklad_nalezy_cis FOREIGN KEY (nalez_kod)
        REFERENCES dbo.CIS_nalezy (kod);

-- Poznámky se přidávají, nepřepisují — stejně jako záznamy v ROZHODNUTI.md
IF OBJECT_ID('dbo.Valuo_poznamky', 'U') IS NULL
CREATE TABLE dbo.Valuo_poznamky (
    id           int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    cislo_vkladu varchar(50)       NOT NULL,
    text_pozn    nvarchar(max)     NOT NULL,
    kdo          nvarchar(128)     NULL,
    kdy          datetime2         NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Valuo_poznamky_vklad')
CREATE INDEX IX_Valuo_poznamky_vklad ON dbo.Valuo_poznamky (cislo_vkladu, kdy DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Valuo_vklad_nalezy_kod')
CREATE INDEX IX_Valuo_vklad_nalezy_kod ON dbo.Valuo_vklad_nalezy (nalez_kod);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Valuo_vklad_rucne_pouz')
CREATE INDEX IX_Valuo_vklad_rucne_pouz ON dbo.Valuo_vklad_rucne (pouzitelnost);
GO

-- ČÁST 3: příznaky do podkladu mapy -----------------------------------------
-- Aby šlo filtrovat „jen k doplnění“ bez dotazu do pomalého pohledu.

IF COL_LENGTH('dbo.Valuo_mapa', 'nalez_plocha_cely_dum') IS NULL
ALTER TABLE dbo.Valuo_mapa ADD
    nalez_plocha_cely_dum bit NULL,
    nalez_plocha_z_podilu bit NULL;
GO

UPDATE m SET m.nalez_plocha_cely_dum = v.nalez_plocha_cely_dum,
             m.nalez_plocha_z_podilu = v.nalez_plocha_z_podilu
FROM dbo.Valuo_mapa m
JOIN dbo.v_Valuo_karta_vkladu v ON v.cislo_vkladu = m.cislo_vkladu;
GO

-- ČÁST 4: naplnění číselníku -------------------------------------------------
-- MERGE, aby se skript dal pustit znovu a přepsal jen texty.

MERGE dbo.CIS_nalezy AS c
USING (VALUES
 ('POLOHA_JINDE','poloha',
  N'Bod nesedí, nemovitost je jinde na parcele',
  N'Značka ukazuje na definiční bod parcely, který ČÚZK umisťuje dovnitř parcely, ne na stavbu. U velké stavební parcely se zpevněnými plochami padne klidně doprostřed parkoviště. Vzorek je použitelný, jen poloha značky je nepřesná.',
  0, 0, 10),
 ('STAVBA_NENI','poloha',
  N'Na parcele žádná stavba není',
  N'Na parcele podle mapových podkladů nestojí stavba, kterou vklad popisuje. Buď byla zbořena, nebo je vklad napárovaný na nesprávnou parcelu. Vzorek je do porovnání nepoužitelný, dokud se to nevyjasní.',
  1, 0, 20),
 ('PARCELA_NESEDI','poloha',
  N'Vklad je navázán na jinou parcelu',
  N'Parcela uvedená ve vkladu neodpovídá nemovitosti, která se prodávala. Výměry i tvar v kartě jsou pak cizí a vzorek nelze použít.',
  1, 0, 30),
 ('PLOCHA_CELY_DUM','plocha',
  N'Plocha jednotky je plocha celého domu',
  N'Valuo u jednotky uvádí podlahovou plochu celé budovy, ne prodávaného bytu. Pozná se tak, že plocha jednotky odpovídá podlahové ploše budovy dle RÚIAN a v domě jsou aspoň dvě jednotky. Jednotková cena je pak několikanásobně nižší, než má být. Napraví se doplněním ověřené plochy.',
  1, 1, 40),
 ('PLOCHA_CHYBI','plocha',
  N'Plocha není známa',
  N'Databáze nezná plochu, ze které by se počítala jednotková cena. U vkladů s jednotkou je to 1 581 případů z 37 340. Napraví se doplněním ověřené plochy.',
  1, 1, 50),
 ('PLOCHA_DOPOCET','plocha',
  N'Plocha je dopočtena z podílu, ne změřena',
  N'Valuo uvádí u jednotky typ plochy „Plocha spočítaná z podílu na budově“. Není to změřená podlahová plocha, ale odvození z podílu na společných částech. Odpovídá-li podíl skutečné ploše, je číslo použitelné; jinak může být hrubě vedle.',
  0, 1, 60),
 ('CENA_ZA_PODIL','cena',
  N'Cena je za podíl, plocha za celek',
  N'Převáděl se spoluvlastnický podíl, ale plocha v databázi je za celou nemovitost. Jednotková cena je tím zkreslená dolů v poměru podílu.',
  1, 0, 70),
 ('CENA_MIMO','cena',
  N'Jednotková cena mimo rozumný rozsah',
  N'Kč/m² vychází řádově mimo obvyklé hodnoty daného druhu. Příčinou bývá chybná plocha nebo cena za podíl. Vyžaduje prověření, než se vzorek použije.',
  1, 1, 80),
 ('PREVOD_NETRZNI','cena',
  N'Převod není tržní',
  N'Převod mezi spřízněnými osobami, vypořádání, vklad do společnosti nebo jiný úkon, jehož cena neodpovídá trhu. Do porovnání nepatří, i když je formálně kupní smlouvou.',
  1, 0, 90),
 ('ROLE_OPRAVENA','role',
  N'Role parcely opravena ručně',
  N'Role některé parcely vkladu byla určena znalcem, ne vodítky databáze. Přepočet ruční určení respektuje a nepřepisuje ho.',
  0, 0, 100),
 ('JINE','jine',
  N'Jiné zjištění',
  N'Cokoli, co se do ostatních nálezů nevejde. Podrobnost patří do poznámky u nálezu.',
  0, 0, 999)
) AS s (kod, skupina, nazev, popis, vyrazuje_vzorek, automaticky, poradi)
   ON c.kod = s.kod
WHEN MATCHED THEN UPDATE SET c.skupina = s.skupina, c.nazev = s.nazev,
     c.popis = s.popis, c.vyrazuje_vzorek = s.vyrazuje_vzorek,
     c.automaticky = s.automaticky, c.poradi = s.poradi
WHEN NOT MATCHED THEN INSERT (kod, skupina, nazev, popis, vyrazuje_vzorek, automaticky, poradi)
     VALUES (s.kod, s.skupina, s.nazev, s.popis, s.vyrazuje_vzorek, s.automaticky, s.poradi);
GO

-- ČÁST 5: pohled karty vkladu ------------------------------------------------
-- Úplné znění po kroku 41. Proti kroku 36 se změnil blok „plochy“ (ruční
-- plocha má přednost) a na konec výběru přibyla ruční zjištění a nálezy.
-- Pohled je zdrojem pro kartu (37), export do Wordu (35) i aplikaci (40);
-- proto se mění tady, na jednom místě, a ne v každém skriptu zvlášť.

IF OBJECT_ID('dbo.v_Valuo_karta_vkladu', 'V') IS NOT NULL
    DROP VIEW dbo.v_Valuo_karta_vkladu;
GO

CREATE VIEW dbo.v_Valuo_karta_vkladu
AS
WITH vklad AS (
    SELECT d.cislo_vkladu,
        MIN(d.datum_zplatneni) AS datum_zplatneni, MIN(d.rok) AS rok,
        MAX(d.cena_Kc) AS cena_Kc, MIN(d.mena) AS mena, MIN(d.kod_ku) AS kod_ku,
        MIN(d.vklad_klasifikace) AS klasifikace, MIN(d.vklad_nemovitosti) AS nemovitosti_ve_vkladu,
        SUM(CASE WHEN d.nemovitost = 'budova'   THEN 1 ELSE 0 END) AS pocet_budov,
        SUM(CASE WHEN d.nemovitost = 'jednotka' THEN 1 ELSE 0 END) AS pocet_jednotek,
        SUM(CASE WHEN d.nemovitost = 'parcela'  THEN 1 ELSE 0 END) AS pocet_parcel_valuo,
        MAX(d.vklad_plocha_jednotky) AS plocha_jednotky_valuo
    FROM dbo.Valuo_data d GROUP BY d.cislo_vkladu
),
hlavni_agr AS (
    SELECT d.cislo_vkladu,
        MAX(CASE WHEN d.typ_plochy = N'Podlahová plocha' THEN d.plocha END) AS plocha_podlahova_valuo,
        MAX(CASE WHEN d.typ_plochy = N'Plocha spočítaná z podílu na budově' THEN 1 ELSE 0 END) AS plocha_z_podilu,
        COUNT(*) AS hlavnich_radku
    FROM dbo.Valuo_data d WHERE d.nemovitost IN ('budova', 'jednotka', '---')
    GROUP BY d.cislo_vkladu
),
hlavni AS (
    SELECT cislo_vkladu, typ AS hlavni_druh, adresa AS hlavni_adresa,
           jednotka_oznaceni, popis AS hlavni_popis, plocha AS hlavni_plocha,
           typ_plochy AS hlavni_typ_plochy, nemovitost AS hlavni_nemovitost
    FROM (SELECT d.cislo_vkladu, d.typ, d.adresa, d.jednotka_oznaceni, d.popis,
                 d.plocha, d.typ_plochy, d.nemovitost,
                 ROW_NUMBER() OVER (PARTITION BY d.cislo_vkladu ORDER BY
                     CASE WHEN d.typ IN (N'rodinný dům', N'objekt k bydlení') THEN 1
                          WHEN d.typ IN (N'byt', N'bytový dům') THEN 2
                          WHEN d.typ IN (N'stavba pro rodinnou rekreaci') THEN 3
                          WHEN d.typ IN (N'ateliér', N'jiný nebytový prostor') THEN 4
                          WHEN d.typ IN (N'garáž') THEN 9
                          WHEN d.typ IN (N'jiná stavba') THEN 8
                          ELSE 5 END,
                     ISNULL(d.plocha, 0) DESC, d.id) AS rn
          FROM dbo.Valuo_data d
          WHERE d.nemovitost IN ('budova', 'jednotka', '---')) x
    WHERE rn = 1
),
druhy AS (
    SELECT cislo_vkladu, STRING_AGG(CAST(polozka AS nvarchar(max)), N', ') AS slozeni_vkladu
    FROM (SELECT DISTINCT d.cislo_vkladu,
                 CAST(d.nemovitost AS nvarchar(50)) + N' ' + CAST(ISNULL(d.typ, N'?') AS nvarchar(100)) AS polozka
          FROM dbo.Valuo_data d) x
    GROUP BY cislo_vkladu
),
karta AS (
    SELECT kp.cislo_vkladu,
        COUNT(*) AS parcel_celkem,
        SUM(kp.vymera_m2) AS vymera_pozemku_vse,
        SUM(CASE WHEN kp.vlastnictvi = N'výhradní' AND kp.prostorova_role IN (N'kotva', N'celek')
                 THEN kp.vymera_m2 END) AS vymera_vyhradni_celek,
        SUM(CASE WHEN kp.vlastnictvi = N'výhradní' AND kp.prostorova_role = N'oddělená'
                 THEN kp.vymera_m2 END) AS vymera_vyhradni_mimo,
        SUM(CASE WHEN kp.vlastnictvi = N'podílová' THEN kp.vymera_m2 END) AS vymera_podilova,
        SUM(kp.vymera_dle_podilu) AS vymera_podilova_dle_podilu,
        SUM(CASE WHEN kp.vlastnictvi = N'neověřeno' THEN kp.vymera_m2 END) AS vymera_neoverena,
        SUM(CASE WHEN kp.prostorova_role = N'bez kotvy' THEN kp.vymera_m2 END) AS vymera_bez_kotvy,
        SUM(CASE WHEN kp.je_kotva = 1 THEN 1 ELSE 0 END) AS parcel_kotva,
        SUM(CASE WHEN kp.vlastnictvi = N'výhradní' AND kp.prostorova_role IN (N'kotva', N'celek') THEN 1 ELSE 0 END) AS parcel_vyhradni_celek,
        SUM(CASE WHEN kp.vlastnictvi = N'výhradní' AND kp.prostorova_role = N'oddělená' THEN 1 ELSE 0 END) AS parcel_vyhradni_mimo,
        SUM(CASE WHEN kp.vlastnictvi = N'podílová'  THEN 1 ELSE 0 END) AS parcel_podilovych,
        SUM(CASE WHEN kp.vlastnictvi = N'neověřeno' THEN 1 ELSE 0 END) AS parcel_neoverenych,
        SUM(CASE WHEN kp.sporna = 1 THEN 1 ELSE 0 END) AS parcel_spornych,
        MAX(kp.komponenta) AS komponent_celkem,
        MIN(kp.podil_odhad) AS podil_odhad_min
    FROM dbo.Valuo_karta_parcely kp GROUP BY kp.cislo_vkladu
),
plochy AS (
    /* Z které plochy se počítá Kč/m2 podlahové plochy.

       Pořadí přednosti:
         1. plocha ověřená znalcem (Valuo_vklad_rucne) — ta má navrch vždy,
            protože si ji znalec dohledal v katastru nebo ve smlouvě
         2. u jednotky plocha jednotky z Valua, pak podlahová plocha z Valua;
            na RÚIAN se u jednotek NESAHÁ, protože popisuje celý dům
         3. u budovy podlahová plocha z Valua, pak z RÚIANu */
    SELECT v.cislo_vkladu,
        CASE WHEN r.plocha_rucne IS NOT NULL THEN r.plocha_rucne
             WHEN v.pocet_jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA'
             THEN COALESCE(v.plocha_jednotky_valuo, ha.plocha_podlahova_valuo)
             ELSE COALESCE(ha.plocha_podlahova_valuo, rv.ruian_podlahova_plocha)
        END AS plocha_podlahova_karty,
        CASE WHEN r.plocha_rucne IS NOT NULL THEN N'ověřeno znalcem'
             WHEN v.pocet_jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA'
             THEN CASE WHEN v.plocha_jednotky_valuo IS NOT NULL THEN N'plocha jednotky dle Valuo'
                       WHEN ha.plocha_podlahova_valuo IS NOT NULL THEN N'podlahová plocha dle Valuo'
                  END
             ELSE CASE WHEN ha.plocha_podlahova_valuo IS NOT NULL THEN N'podlahová plocha dle Valuo'
                       WHEN rv.ruian_podlahova_plocha IS NOT NULL THEN N'podlahová plocha dle RÚIAN'
                  END
        END AS plocha_podlahova_zdroj,
        CASE WHEN v.pocet_jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA' THEN 1 ELSE 0 END AS je_jednotka,
        /* Automatický nález: plocha jednotky z Valua se shoduje s podlahovou
           plochou budovy a v domě jsou aspoň dvě jednotky. Pak je to skoro
           jistě plocha celého domu a cena za m2 vychází násobně nižší. */
        CASE WHEN (v.pocet_jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA')
              AND rv.ruian_pocet_bytu >= 2 AND rv.ruian_podlahova_plocha > 0
              AND COALESCE(v.plocha_jednotky_valuo, ha.plocha_podlahova_valuo)
                  BETWEEN 0.97 * rv.ruian_podlahova_plocha AND 1.03 * rv.ruian_podlahova_plocha
             THEN 1 ELSE 0 END AS nalez_plocha_cely_dum
    FROM vklad v
    LEFT JOIN hlavni_agr ha ON ha.cislo_vkladu = v.cislo_vkladu
    LEFT JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = v.cislo_vkladu
    LEFT JOIN dbo.Valuo_vklad_rucne r ON r.cislo_vkladu = v.cislo_vkladu
)
SELECT
    v.cislo_vkladu, v.datum_zplatneni, v.rok, v.kod_ku,
    CAST(c.ku_nazev AS nvarchar(200)) AS kat_uzemi,
    CAST(c.obec_nazev AS nvarchar(200)) AS obec,
    v.cena_Kc, v.mena, v.klasifikace,
    h.hlavni_nemovitost, h.hlavni_druh, h.hlavni_adresa, h.jednotka_oznaceni,
    h.hlavni_popis, h.hlavni_plocha, h.hlavni_typ_plochy, ha.hlavnich_radku,
    v.nemovitosti_ve_vkladu, v.pocet_budov, v.pocet_jednotek, v.pocet_parcel_valuo,
    d.slozeni_vkladu,
    k.parcel_celkem, k.vymera_pozemku_vse, k.vymera_vyhradni_celek, k.vymera_vyhradni_mimo,
    k.vymera_podilova, k.vymera_podilova_dle_podilu, k.vymera_neoverena, k.vymera_bez_kotvy,
    k.parcel_kotva, k.parcel_vyhradni_celek, k.parcel_vyhradni_mimo,
    k.parcel_podilovych, k.parcel_neoverenych, k.parcel_spornych,
    k.komponent_celkem, k.podil_odhad_min,
    ha.plocha_podlahova_valuo,
    v.plocha_jednotky_valuo,
    pl.plocha_podlahova_karty, pl.plocha_podlahova_zdroj,
    rv.ruian_podlahova_plocha, rv.ruian_zastavena_plocha, rv.ruian_obestaveny_prostor,
    rv.ruian_pocet_podlazi, rv.ruian_pocet_bytu, rv.ruian_rok, rv.ruian_rok_presny,
    rv.ruian_pasmo, rv.ruian_druh_konstrukce, rv.ruian_vytapeni, rv.ruian_vytah,
    rv.pripojeni_vodovod_kod, rv.pripojeni_kanalizace_kod, rv.pripojeni_plyn_kod,
    rv.ruian_pomer_pp_op, rv.ruian_plocha_podezrela,
    kv.pp_index_celku, kv.plocha_celku_m2, kv.obvod_celku_m, kv.casti_celku,
    kv.pp_index_vse, kv.plocha_vse_m2, kv.obvod_vse_m, kv.casti_vse,
    /* Ruční zjištění znalce */
    r.pouzitelnost, r.pouzitelnost_duvod, r.plocha_rucne, r.plocha_rucne_zdroj,
    r.kdy AS rucne_kdy,
    pl.nalez_plocha_cely_dum,
    ISNULL(ha.plocha_z_podilu, 0) AS nalez_plocha_z_podilu,
    (SELECT COUNT(*) FROM dbo.Valuo_vklad_nalezy n
     WHERE n.cislo_vkladu = v.cislo_vkladu) AS nalezu_rucne,
    (SELECT COUNT(*) FROM dbo.Valuo_poznamky p
     WHERE p.cislo_vkladu = v.cislo_vkladu) AS poznamek,
    CASE WHEN pl.plocha_podlahova_karty > 0
         THEN CAST(v.cena_Kc / pl.plocha_podlahova_karty AS decimal(14,2)) END AS jc_Kc_m2_podlahova,
    CASE WHEN pl.je_jednotka = 0 AND k.vymera_vyhradni_celek > 0
         THEN CAST(v.cena_Kc / k.vymera_vyhradni_celek AS decimal(14,2)) END AS jc_Kc_m2_vyhradni_celek,
    CASE WHEN pl.je_jednotka = 0 AND k.vymera_pozemku_vse > 0
         THEN CAST(v.cena_Kc / k.vymera_pozemku_vse AS decimal(14,2)) END AS jc_Kc_m2_vsech_pozemku,
    CASE WHEN pl.je_jednotka = 0 AND rv.ruian_obestaveny_prostor > 0
         THEN CAST(v.cena_Kc / rv.ruian_obestaveny_prostor AS decimal(14,2)) END AS jc_Kc_m3
FROM vklad v
LEFT JOIN hlavni h ON h.cislo_vkladu = v.cislo_vkladu
LEFT JOIN hlavni_agr ha ON ha.cislo_vkladu = v.cislo_vkladu
LEFT JOIN druhy d ON d.cislo_vkladu = v.cislo_vkladu
LEFT JOIN karta k ON k.cislo_vkladu = v.cislo_vkladu
LEFT JOIN plochy pl ON pl.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.Valuo_karta_vklad kv ON kv.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.Valuo_vklad_rucne r ON r.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku;
GO

-- ČÁST 6: kontroly ------------------------------------------------------------

-- 6.1 Číselník
SELECT skupina, COUNT(*) AS nalezu,
       SUM(CASE WHEN vyrazuje_vzorek = 1 THEN 1 ELSE 0 END) AS z_toho_vyrazuje,
       SUM(CASE WHEN automaticky = 1 THEN 1 ELSE 0 END) AS z_toho_automaticky
FROM dbo.CIS_nalezy GROUP BY skupina ORDER BY MIN(poradi);
-- Čekáno 25. 10. 2026: plocha 3 / cena 3 / poloha 3 / role 1 / jine 1 = 11

-- 6.2 Kolik vzorků si říká o doplnění plochy
SELECT SUM(CAST(nalez_plocha_cely_dum AS int)) AS plocha_je_cely_dum,
       SUM(CASE WHEN plocha_podlahova_karty IS NULL
                 AND (pocet_jednotek > 0 OR klasifikace = 'JC_JEDNOTKA')
                THEN 1 ELSE 0 END) AS jednotka_bez_plochy,
       SUM(CAST(nalez_plocha_z_podilu AS int)) AS plocha_z_podilu
FROM dbo.v_Valuo_karta_vkladu;
-- Čekáno 25. 10. 2026: 154 / 1 581 / 35 605

-- 6.3 Co už znalec doplnil
SELECT (SELECT COUNT(*) FROM dbo.Valuo_vklad_rucne WHERE plocha_rucne IS NOT NULL) AS plochy_rucne,
       (SELECT COUNT(*) FROM dbo.Valuo_vklad_rucne WHERE pouzitelnost IS NOT NULL) AS posouzeno,
       (SELECT COUNT(*) FROM dbo.Valuo_vklad_nalezy) AS nalezu,
       (SELECT COUNT(*) FROM dbo.Valuo_poznamky)     AS poznamek;

-- 6.4 Přednost ruční plochy — zkouška na jednom vkladu.
--     Zápis i úklid dohromady, aby v databázi nic nezůstalo.
/*
DECLARE @v varchar(50) = 'V-1172/2025-202';
SELECT 'před' AS kdy, plocha_podlahova_karty, plocha_podlahova_zdroj, jc_Kc_m2_podlahova
  FROM dbo.v_Valuo_karta_vkladu WHERE cislo_vkladu = @v;
INSERT INTO dbo.Valuo_vklad_rucne (cislo_vkladu, plocha_rucne, plocha_rucne_zdroj, kdo, kdy)
VALUES (@v, 160.00, N'zkouška', N'test', SYSDATETIME());
SELECT 'po' AS kdy, plocha_podlahova_karty, plocha_podlahova_zdroj, jc_Kc_m2_podlahova
  FROM dbo.v_Valuo_karta_vkladu WHERE cislo_vkladu = @v;
DELETE FROM dbo.Valuo_vklad_rucne WHERE cislo_vkladu = @v AND plocha_rucne_zdroj = N'zkouška';
*/
-- Ověřeno 25. 10. 2026: 43 031 Kč/m² („plocha jednotky dle Valuo“, 68 m²)
--                    → 86 063 Kč/m² („ověřeno znalcem“, 160 m²), pak uklizeno.
