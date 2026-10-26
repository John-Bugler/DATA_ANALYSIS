-- =============================================================================
-- 44_plochy_zdroje.sql — registr zdrojů plochy a posunutá desetinná čárka
-- =============================================================================
-- Databáze: VALUO        Krok: 44        Datum: 25. 10. 2026
-- Provedeno na pokyn znalce.
--
-- Co to vyvolalo
-- --------------
-- Znalec procházel mapu a našel vklad V-23003/2024-101 (Kunratice, jednotka
-- 1833/2): rodinný dům rozdělený na dvě jednotky, prodávala se jedna. Valuo
-- u ní uvádí plochu **26,57 m²** s typem „Plocha spočítaná z podílu na
-- budově“. Podíl na společných částech je v popisu: **2657/5812**.
--
-- Valuo tedy vzalo čitatele a vydělilo ho stem. Správně je ale dělitel deset:
-- skutečná plocha jednotky je **265,7 m²**, což odpovídá polovině podlahové
-- plochy domu (RÚIAN uvádí 582 m², jmenovatel 5812 je 581,2 m² — sedí to na
-- desetinu). Jednotková cena tím vyšla **809 183 Kč/m² místo 80 918**.
--
-- Zlomek sám o sobě škálu neobsahuje
-- ----------------------------------
-- Čitatel je plocha vynásobená mocninou deseti, a *kolikrát*, to si volí ten,
-- kdo prohlášení vlastníka sepisoval. Z čísel 2657/5812 nelze poznat, jde-li
-- o 26,57 nebo 265,7 m². Valuo si proto dělitele hádá, a hádá ho různě:
--
--   dělí stem     10 578 řádků
--   dělí deseti   27 266 řádků
--   nedělí         4 447 řádků
--
-- Takže to není konstantní chyba, kterou by šlo prostě odečíst.
--
-- Klíč: poměr je bezrozměrný
-- --------------------------
-- Čitatel ku jmenovateli žádnou škálu nenese — ta se v poměru vykrátí.
-- Vynásobený podlahovou plochou domu dle RÚIAN dá plochu jednotky přímo:
--
--   2657/5812 × 582 = **266,1 m²**
--
-- To je nezávislý údaj, který Valuovu plochu potvrdí, nebo prozradí posun.
-- Násobek mezi oběma se pak buď drží jedničky (souhlasí), nebo leží u mocniny
-- deseti (posun čárky).
--
-- Co se v datech ukázalo (19 500 řádků, kde RÚIAN plochu zná)
-- -----------------------------------------------------------
--   násobek          řádků   výklad
--   pod 0,02            42   Valuo 100× větší
--   0,02 – 0,2       1 701   Valuo 10× větší
--   0,2 – 0,5          199   *propad*
--   0,5 – 1,2        6 841   v pořádku
--   1,2 – 3          6 587   v pořádku — společné prostory, více čísel popisných
--   3 – 5               58   *propad*
--   5 – 8              769   nejednoznačné
--   8 – 15           1 238   Valuo 10× menší
--   15 – 40             97   *propad*
--   40 – 200         1 992   Valuo 100× menší
--   nad 200              7
--
-- **Ty propady jsou to podstatné.** Kdyby šlo o spojitý přechod, nešlo by
-- posun čárky odlišit od domu s velkými společnými prostorami. Takhle je
-- legitimní pásmo 0,5–3 oddělené od desítkového hrbu propady na 58 a 97
-- řádcích, a posun je proto rozhodnutelný. **Násobek kolem 2 posun NENÍ** —
-- tolik dělají společné prostory, případně dům o více číslech popisných
-- (poznatek znalce), a do oprav nesmí vstupovat.
--
-- Dvě nezávislá vodítka
-- ---------------------
-- 1. **poměrové** (přesné): poměr × podlahová plocha domu dle RÚIAN.
--    Určí posun. Dostupné u 43 % řádků — jen tam, kde RÚIAN plochu zná.
-- 2. **počtové** (hrubé, návrh znalce): podlahová plocha domu dělená počtem
--    bytů dá očekávanou velikost jednotky. Nezávisí na tom, co zlomek
--    znamená, ale potřebuje pojistku: u domu s podlahovou plochou 11 825 m²
--    a počtem bytů 1 vyjde očekávání 11 825 m² a vodítko lže. RÚIAN totiž
--    počítá *byty*, ne jednotky, takže u domu garáží a ateliérů je tam
--    jednička. Proto `nabyt_plocha_min` a `nabyt_plocha_max`.
--
-- Co se NEDĚLÁ
-- ------------
-- Použitá plocha zůstává Valuova, i když je posun prokázaný (volba znalce).
-- Databáze z dopočtu nepočítá — jen ho nabídne jako návrh a znalec ho
-- potvrdí do `Valuo_vklad_rucne.plocha_rucne`. Platí pravidlo č. 1:
-- plochu nedopočítávat odhadem. Výjimka je jediná a znalec ji zvolil:
-- **nemá-li Valuo plochu vůbec**, dopočet se použije a zdroj to přizná
-- (21 vkladů).
--
-- Měřeno 25. 10. 2026 nad celou databází
-- ---------------------------------------
--   jednotek s dopočtem z podílu            47 835 řádků
--   zlomek v popisu rozparsován             47 729 řádků / 35 458 vkladů
--   vklady s dopočtem proti RÚIAN           13 966
--     z toho poměr souhlasí                  9 036
--     z toho prokázaný posun čárky           1 807   ← návrh k potvrzení
--     z toho nejednoznačné                   3 123
--   vklady mimo očekávání dle počtu bytů     1 677
--   dopočet použit jako plocha                  21
-- =============================================================================
GO

-- ČÁST 1: zlomek podílu z popisu ---------------------------------------------
-- Zlomek je jediný údaj, který o podílu máme, a je v textu popisu. Parser
-- hledá „společných částech“ a bere první zlomek za ním — zvládne tak
-- „…domu a pozemku 2657/5812“ i kratší „…domu 1/2“.

IF OBJECT_ID('dbo.Valuo_podil_jednotky', 'U') IS NULL
CREATE TABLE dbo.Valuo_podil_jednotky (
    id            int           NOT NULL PRIMARY KEY,   -- Valuo_data.id
    cislo_vkladu  varchar(50)   NOT NULL,
    zlomek_text   varchar(40)   NOT NULL,
    citatel       decimal(18,2) NOT NULL,
    jmenovatel    decimal(18,2) NOT NULL,
    pomer AS (CAST(CASE WHEN jmenovatel > 0 THEN citatel / jmenovatel END AS decimal(18,10))) PERSISTED,
    kdy           datetime2     NOT NULL
);
GO

DELETE FROM dbo.Valuo_podil_jednotky;
GO

INSERT INTO dbo.Valuo_podil_jednotky (id, cislo_vkladu, zlomek_text, citatel, jmenovatel, kdy)
SELECT x.id, x.cislo_vkladu, x.zlomek,
       TRY_CAST(LEFT(x.zlomek, CHARINDEX('/', x.zlomek) - 1) AS decimal(18,2)),
       TRY_CAST(SUBSTRING(x.zlomek, CHARINDEX('/', x.zlomek) + 1, 30) AS decimal(18,2)),
       SYSDATETIME()
FROM (
  SELECT y.id, y.cislo_vkladu,
         LEFT(y.od_cislice, PATINDEX('%[^0-9/]%', y.od_cislice + 'x') - 1) AS zlomek
  FROM (
    SELECT z.id, z.cislo_vkladu,
           SUBSTRING(z.zbytek, PATINDEX('%[0-9]%', z.zbytek), 40) AS od_cislice
    FROM (
      SELECT v.id, v.cislo_vkladu,
             SUBSTRING(v.popis, CHARINDEX(N'společných částech', v.popis) + 18, 60) AS zbytek
      FROM dbo.Valuo_data v
      WHERE v.nemovitost = 'jednotka' AND v.popis LIKE N'%společných částech%'
    ) z WHERE PATINDEX('%[0-9]%', z.zbytek) > 0
  ) y
) x
WHERE CHARINDEX('/', x.zlomek) > 1
  AND TRY_CAST(LEFT(x.zlomek, CHARINDEX('/', x.zlomek) - 1) AS decimal(18,2)) > 0
  AND TRY_CAST(SUBSTRING(x.zlomek, CHARINDEX('/', x.zlomek) + 1, 30) AS decimal(18,2)) > 0;
-- Čekáno 25. 10. 2026: 47 729 řádků / 35 458 vkladů
GO

-- ČÁST 2: číselník zdrojů plochy ---------------------------------------------
-- Pořadí přednosti je tady, ne v kódu. `pro_cenu = 0` znamená zdroj, který
-- se k jednotkové ceně nikdy nepoužije a slouží jen ke kontrole.

IF OBJECT_ID('dbo.CIS_plochy_zdroje', 'U') IS NULL
CREATE TABLE dbo.CIS_plochy_zdroje (
    kod           varchar(24)   NOT NULL PRIMARY KEY,
    nazev         nvarchar(80)  NOT NULL,
    popis         nvarchar(400) NOT NULL,
    poradi        int           NOT NULL,
    pro_cenu      bit           NOT NULL,
    autoritativni bit           NOT NULL
);
GO

MERGE dbo.CIS_plochy_zdroje AS c
USING (VALUES
 ('RUCNE', N'ověřeno znalcem',
  N'Plochu dohledal znalec v katastru, ve smlouvě nebo při místním šetření a zapsal ji do Valuo_vklad_rucne. Má přednost přede všemi ostatními zdroji.', 1, 1, 1),
 ('VALUO_JEDNOTKA', N'plocha jednotky dle Valuo',
  N'Sloupec Valuo_data.vklad_plocha_jednotky. Vyplněný u 94,8 % jednotek. Jakost se různí — u velké části jde o dopočet z podílu, ne o změřenou plochu.', 2, 1, 0),
 ('VALUO_PODLAHOVA', N'podlahová plocha dle Valuo',
  N'Valuo_data.plocha u řádku s typem plochy „Podlahová plocha“. U jednotek vyplněná zřídka, u budov je to hlavní zdroj.', 3, 1, 0),
 ('PODIL_RUIAN', N'dopočet z podílu proti RÚIAN',
  N'Poměr čitatele a jmenovatele podílu na společných částech, vynásobený podlahovou plochou budovy dle RÚIAN. Poměr je bezrozměrný, takže na rozdíl od Valuova dopočtu nezávisí na tom, kolikrát je v zlomku posunutá desetinná čárka. Používá se jen tam, kde Valuo plochu nemá.', 4, 1, 0),
 ('RUIAN_PP', N'podlahová plocha dle RÚIAN',
  N'Technickoekonomický atribut stavebního objektu. U budovy popisuje tu správnou stavbu, u jednotky popisuje celý dům, a tam se proto k ceně nepoužívá.', 5, 1, 0),
 ('RUIAN_NA_BYT', N'podlahová plocha na jednu jednotku dle RÚIAN',
  N'Podlahová plocha budovy dělená počtem bytů. Není to plocha prodávané jednotky, slouží výhradně jako kontrola řádu. Nedůvěryhodná tam, kde RÚIAN počet bytů nevyplnil nebo kde se dům skládá z více čísel popisných.', 90, 0, 0)
) AS s (kod, nazev, popis, poradi, pro_cenu, autoritativni)
   ON c.kod = s.kod
WHEN MATCHED THEN UPDATE SET c.nazev = s.nazev, c.popis = s.popis, c.poradi = s.poradi,
     c.pro_cenu = s.pro_cenu, c.autoritativni = s.autoritativni
WHEN NOT MATCHED THEN INSERT (kod, nazev, popis, poradi, pro_cenu, autoritativni)
     VALUES (s.kod, s.nazev, s.popis, s.poradi, s.pro_cenu, s.autoritativni);
GO

-- ČÁST 3: registr ploch vkladu -----------------------------------------------
-- Jeden řádek na (vklad, zdroj). Nic se nepřepisuje; všechny plochy, které
-- o vkladu víme, leží vedle sebe a dají se porovnat.

IF OBJECT_ID('dbo.Valuo_plochy', 'U') IS NULL
CREATE TABLE dbo.Valuo_plochy (
    cislo_vkladu varchar(50)   NOT NULL,
    zdroj        varchar(24)   NOT NULL,
    plocha       decimal(14,2) NULL,
    platny       bit           NOT NULL,   -- lze použít k ceně
    poznamka     nvarchar(200) NULL,
    kdy          datetime2     NOT NULL,
    CONSTRAINT PK_Valuo_plochy PRIMARY KEY (cislo_vkladu, zdroj)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Valuo_plochy_zdroj')
ALTER TABLE dbo.Valuo_plochy ADD CONSTRAINT FK_Valuo_plochy_zdroj
    FOREIGN KEY (zdroj) REFERENCES dbo.CIS_plochy_zdroje (kod);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Valuo_plochy_zdroj')
CREATE INDEX IX_Valuo_plochy_zdroj ON dbo.Valuo_plochy (zdroj, platny) INCLUDE (plocha);
GO

-- ČÁST 4: parametry do číselníku ---------------------------------------------
-- Hranice pásem patří znalci, ne do kódu.

DELETE FROM dbo.CIS_karta_parametry WHERE parametr IN ('podil_posun_min', 'podil_posun_max');
GO

MERGE dbo.CIS_karta_parametry AS c
USING (VALUES
 ('podil_pasmo_ok_od', 0.5, N'Násobek plochy z podílu proti použité ploše — od této hodnoty se bere jako v pořádku. Pod ní je Valuova plocha podezřele velká.'),
 ('podil_pasmo_ok_do', 3.0, N'Horní hranice pásma „v pořádku“. Mezi 1 a 3 se vejdou společné prostory i dům o více číslech popisných, proto je takto široká.'),
 ('podil_posun_tolerance', 0.18, N'Jak blízko mocniny deseti musí násobek ležet, aby se posun desetinné čárky bral za prokázaný. V dekádách: 0,18 je faktor 1,5, tedy pásmo 6,7 až 15 pro posun o jedno místo. Mezi pásmem „v pořádku“ a tímto je v datech propad, proto to jde odlišit.'),
 ('nabyt_pomer_max', 3.0, N'Kolikrát se smí použitá plocha jednotky lišit od podlahové plochy domu dělené počtem bytů, než se vzorek označí za podezřelý. Není to doklad chyby — v domě bývají garáže a nebytové prostory.'),
 ('nabyt_plocha_min', 15.0, N'Dolní mez věrohodnosti podlahové plochy domu na jednu jednotku. Pod ní je počet bytů v RÚIAN zřejmě nevyplněný a kontrola se nepoužije.'),
 ('nabyt_plocha_max', 300.0, N'Horní mez téhož. Dům s podlahovou plochou 11 825 m² a počtem bytů 1 dá 11 825 m² na jednotku — takový údaj je nepoužitelný.')
) AS s (parametr, hodnota, popis)
   ON c.parametr = s.parametr
WHEN MATCHED THEN UPDATE SET c.hodnota = s.hodnota, c.popis = s.popis
WHEN NOT MATCHED THEN INSERT (parametr, hodnota, popis) VALUES (s.parametr, s.hodnota, s.popis);
GO

-- ČÁST 5: dva nové nálezy do číselníku ---------------------------------------

MERGE dbo.CIS_nalezy AS c
USING (VALUES
 ('PLOCHA_POSUN_CARKY','plocha',
  N'Posunutá desetinná čárka v ploše z podílu',
  N'Valuo spočítal plochu jednotky z podílu na společných částech, ale posunul v něm desetinnou čárku o řád vedle. Pozná se tak, že poměr čitatele a jmenovatele vynásobený podlahovou plochou domu dle RÚIAN vyjde jako mocnina deseti krát Valuova plocha. Poměr je bezrozměrný, takže na posunu čárky nezávisí. Databáze počítá dál z Valuovy plochy a navrhuje opravenou hodnotu; potvrdit ji musí znalec.',
  1, 1, 45),
 ('PLOCHA_MIMO_OCEKAVANI','plocha',
  N'Plocha jednotky se vymyká ploše domu na jednotku',
  N'Valuova plocha jednotky je víc než trojnásobně jinde než podlahová plocha domu dělená počtem bytů dle RÚIAN. Není to doklad chyby — v domě bývají i garáže a nebytové prostory a dům se může skládat z více čísel popisných — ale vzorek si zaslouží prověření.',
  0, 1, 46)
) AS s (kod, skupina, nazev, popis, vyrazuje_vzorek, automaticky, poradi)
   ON c.kod = s.kod
WHEN MATCHED THEN UPDATE SET c.skupina = s.skupina, c.nazev = s.nazev, c.popis = s.popis,
     c.vyrazuje_vzorek = s.vyrazuje_vzorek, c.automaticky = s.automaticky, c.poradi = s.poradi
WHEN NOT MATCHED THEN INSERT (kod, skupina, nazev, popis, vyrazuje_vzorek, automaticky, poradi)
     VALUES (s.kod, s.skupina, s.nazev, s.popis, s.vyrazuje_vzorek, s.automaticky, s.poradi);
GO

-- ČÁST 6: procedura, která registr naplní ------------------------------------
-- Set-based, bez cyklu — 83 510 řádků za 1 sekundu, takže nepotřebuje
-- přerušování ani časový strop jako přepočty karet.
-- Pouští se čtvrtým krokem `38_prepocty.py` před mapou (viz část 8).

CREATE OR ALTER PROCEDURE dbo.sp_prepocet_ploch
AS
BEGIN
    SET NOCOUNT ON;
    /* Registr zdrojů plochy. Nic nemaže ve zdrojových datech — jen sesbírá
       všechny plochy, které o vkladu víme, každou se svým původem, aby se
       daly porovnat a aby bylo v posudku dohledatelné, odkud použité číslo je.
       Pořadí přednosti drží CIS_plochy_zdroje.poradi. */

    DECLARE @t0 datetime2 = SYSDATETIME();

    /* Meze věrohodnosti „plochy domu na jednu jednotku“ se čtou z číselníku,
       ne z kódu — znalec je musí umět změnit bez zásahu do procedury. */
    DECLARE @nabyt_min decimal(18,4) = (SELECT hodnota FROM dbo.CIS_karta_parametry
                                        WHERE parametr = 'nabyt_plocha_min');
    DECLARE @nabyt_max decimal(18,4) = (SELECT hodnota FROM dbo.CIS_karta_parametry
                                        WHERE parametr = 'nabyt_plocha_max');
    IF @nabyt_min IS NULL OR @nabyt_max IS NULL
        THROW 51044, 'V CIS_karta_parametry chybí nabyt_plocha_min nebo nabyt_plocha_max.', 1;

    IF OBJECT_ID('tempdb..#v') IS NOT NULL DROP TABLE #v;
    SELECT d.cislo_vkladu,
           MIN(d.vklad_klasifikace) AS klasifikace,
           SUM(CASE WHEN d.nemovitost = 'jednotka' THEN 1 ELSE 0 END) AS jednotek,
           MAX(d.vklad_plocha_jednotky) AS plocha_jednotky,
           MAX(CASE WHEN d.typ_plochy = N'Podlahová plocha' THEN d.plocha END) AS plocha_podlahova
    INTO #v
    FROM dbo.Valuo_data d
    GROUP BY d.cislo_vkladu;
    CREATE UNIQUE CLUSTERED INDEX IX_v ON #v (cislo_vkladu);

    IF OBJECT_ID('tempdb..#pod') IS NOT NULL DROP TABLE #pod;
    SELECT p.cislo_vkladu, SUM(p.pomer) AS pomer_celkem, COUNT(*) AS radku
    INTO #pod
    FROM dbo.Valuo_podil_jednotky p
    GROUP BY p.cislo_vkladu;
    CREATE UNIQUE CLUSTERED INDEX IX_pod ON #pod (cislo_vkladu);

    DELETE FROM dbo.Valuo_plochy;

    INSERT INTO dbo.Valuo_plochy (cislo_vkladu, zdroj, plocha, platny, poznamka, kdy)
    SELECT cislo_vkladu, zdroj, plocha, platny, poznamka, @t0 FROM (

        SELECT r.cislo_vkladu, 'RUCNE' AS zdroj, r.plocha_rucne AS plocha,
               CAST(1 AS bit) AS platny, r.plocha_rucne_zdroj AS poznamka
        FROM dbo.Valuo_vklad_rucne r WHERE r.plocha_rucne > 0

        UNION ALL
        SELECT v.cislo_vkladu, 'VALUO_JEDNOTKA', v.plocha_jednotky, CAST(1 AS bit), NULL
        FROM #v v WHERE v.plocha_jednotky > 0

        UNION ALL
        SELECT v.cislo_vkladu, 'VALUO_PODLAHOVA', v.plocha_podlahova, CAST(1 AS bit), NULL
        FROM #v v WHERE v.plocha_podlahova > 0

        UNION ALL
        SELECT p.cislo_vkladu, 'PODIL_RUIAN',
               CAST(p.pomer_celkem * rv.ruian_podlahova_plocha AS decimal(14,2)),
               CAST(1 AS bit),
               CASE WHEN p.radku > 1
                    THEN CONCAT(N'součet podílů ', p.radku, N' jednotek vkladu')
                    END
        FROM #pod p
        JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = p.cislo_vkladu
        WHERE rv.ruian_podlahova_plocha > 0 AND p.pomer_celkem > 0

        UNION ALL
        SELECT rv.cislo_vkladu, 'RUIAN_PP', rv.ruian_podlahova_plocha,
               CASE WHEN v.jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA' THEN CAST(0 AS bit)
                    ELSE CAST(1 AS bit) END,
               CASE WHEN v.jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA'
                    THEN N'popisuje celý dům, ne prodávanou jednotku' END
        FROM dbo.RUIAN_vzorek rv
        JOIN #v v ON v.cislo_vkladu = rv.cislo_vkladu
        WHERE rv.ruian_podlahova_plocha > 0

        UNION ALL
        SELECT rv.cislo_vkladu, 'RUIAN_NA_BYT',
               CAST(rv.ruian_podlahova_plocha * 1.0 / rv.ruian_pocet_bytu AS decimal(14,2)),
               CAST(0 AS bit),
               CASE WHEN rv.ruian_podlahova_plocha * 1.0 / rv.ruian_pocet_bytu
                         NOT BETWEEN @nabyt_min AND @nabyt_max
                    THEN N'nedůvěryhodné — počet bytů v RÚIAN nesedí k ploše domu'
                    ELSE N'jen kontrola řádu' END
        FROM dbo.RUIAN_vzorek rv
        WHERE rv.ruian_podlahova_plocha > 0 AND rv.ruian_pocet_bytu > 0
    ) x;

    /* Příznaky do podkladu mapy, aby šlo filtrovat „jen k doplnění“ bez
       dotazu do pomalého pohledu. */
    UPDATE m SET m.nalez_plocha_cely_dum = v.nalez_plocha_cely_dum,
                 m.nalez_plocha_z_podilu = v.nalez_plocha_z_podilu,
                 m.nalez_plocha_posun    = v.nalez_plocha_posun,
                 m.plocha_navrh          = v.plocha_navrh
    FROM dbo.Valuo_mapa m
    JOIN dbo.v_Valuo_karta_vkladu v ON v.cislo_vkladu = m.cislo_vkladu;

    SELECT COUNT(*) AS radku, COUNT(DISTINCT cislo_vkladu) AS vkladu,
           (SELECT COUNT(*) FROM dbo.Valuo_mapa WHERE nalez_plocha_posun = 1) AS posun_v_mape,
           DATEDIFF(s, @t0, SYSDATETIME()) AS sekund
    FROM dbo.Valuo_plochy;
END
GO

-- Pozn.: meze 15 a 300 byly zprvu literály v kódu. Na pokyn znalce
-- (25. 10. 2026) je procedura čte z `nabyt_plocha_min` a `nabyt_plocha_max`
-- v CIS_karta_parametry, stejně jako pohled — hranice jsou tím na jednom
-- místě a dají se měnit bez zásahu do kódu. Chybí-li, procedura skončí
-- chybou 51044 místo aby počítala s něčím vymyšleným.

-- ČÁST 6b: příznaky do podkladu mapy -----------------------------------------
-- Filtr „jen k doplnění“ v aplikaci se ptá tabulky Valuo_mapa, ne pomalého
-- pohledu, takže příznak a návrh musí být i tam.

IF COL_LENGTH('dbo.Valuo_mapa', 'nalez_plocha_posun') IS NULL
ALTER TABLE dbo.Valuo_mapa ADD nalez_plocha_posun bit NULL,
                               plocha_navrh decimal(14,2) NULL;
GO

-- ČÁST 7: pohled karty vkladu ------------------------------------------------
-- Úplné znění po kroku 44. Proti kroku 41 přibyly: CTE `zdroje` (registr),
-- `posun` (násobek), `prm` (parametry), dopočet jako poslední záloha plochy
-- u jednotek, a na výstupu plocha_z_podilu, plocha_na_byt, podil_nasobek,
-- posun_radu, nalez_plocha_posun, plocha_navrh, nalez_plocha_mimo_ocekavani.
-- Ověřeno porovnáním délek všech 220 řádků proti sys.sql_modules.

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
zdroje AS (
    /* Registr zdrojů plochy z kroku 44 — každá plocha, kterou o vkladu víme,
       se svým původem. Nic se nepřepisuje, jen se porovnává. */
    SELECT z.cislo_vkladu,
        MAX(CASE WHEN z.zdroj = 'PODIL_RUIAN'  THEN z.plocha END) AS plocha_z_podilu,
        MAX(CASE WHEN z.zdroj = 'RUIAN_NA_BYT' THEN z.plocha END) AS plocha_na_byt,
        MAX(CASE WHEN z.zdroj = 'RUIAN_NA_BYT'
                  AND z.poznamka LIKE N'nedůvěryhodné%' THEN 1 ELSE 0 END) AS na_byt_neduveryhodne
    FROM dbo.Valuo_plochy z
    GROUP BY z.cislo_vkladu
),
plochy AS (
    /* Z které plochy se počítá Kč/m2 podlahové plochy.

       Pořadí přednosti:
         1. plocha ověřená znalcem (Valuo_vklad_rucne) — ta má navrch vždy,
            protože si ji znalec dohledal v katastru nebo ve smlouvě
         2. u jednotky plocha jednotky z Valua, pak podlahová plocha z Valua,
            pak dopočet z podílu proti RÚIAN (krok 44);
            na RÚIAN se u jednotek NESAHÁ, protože popisuje celý dům
         3. u budovy podlahová plocha z Valua, pak z RÚIANu */
    SELECT v.cislo_vkladu,
        CASE WHEN r.plocha_rucne IS NOT NULL THEN r.plocha_rucne
             WHEN v.pocet_jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA'
             THEN COALESCE(v.plocha_jednotky_valuo, ha.plocha_podlahova_valuo,
                           zd.plocha_z_podilu)
             ELSE COALESCE(ha.plocha_podlahova_valuo, rv.ruian_podlahova_plocha)
        END AS plocha_podlahova_karty,
        CASE WHEN r.plocha_rucne IS NOT NULL THEN N'ověřeno znalcem'
             WHEN v.pocet_jednotek > 0 OR v.klasifikace = 'JC_JEDNOTKA'
             THEN CASE WHEN v.plocha_jednotky_valuo IS NOT NULL THEN N'plocha jednotky dle Valuo'
                       WHEN ha.plocha_podlahova_valuo IS NOT NULL THEN N'podlahová plocha dle Valuo'
                       WHEN zd.plocha_z_podilu IS NOT NULL THEN N'dopočet z podílu proti RÚIAN'
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
             THEN 1 ELSE 0 END AS nalez_plocha_cely_dum,
        zd.plocha_z_podilu, zd.plocha_na_byt, zd.na_byt_neduveryhodne
    FROM vklad v
    LEFT JOIN hlavni_agr ha ON ha.cislo_vkladu = v.cislo_vkladu
    LEFT JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = v.cislo_vkladu
    LEFT JOIN dbo.Valuo_vklad_rucne r ON r.cislo_vkladu = v.cislo_vkladu
    LEFT JOIN zdroje zd ON zd.cislo_vkladu = v.cislo_vkladu
),
posun AS (
    /* Násobek plochy z podílu proti použité ploše. Leží-li blízko mocniny
       deseti, je to posunutá desetinná čárka v zlomku — poměr čitatele
       a jmenovatele je bezrozměrný, takže na posunu nezávisí a prozradí ho.
       Násobek kolem 2 posun NENÍ: tolik dělají společné prostory a dům
       o více číslech popisných. Hranice drží CIS_karta_parametry. */
    SELECT pl.cislo_vkladu,
           CAST(pl.plocha_z_podilu / pl.plocha_podlahova_karty AS float) AS nasobek
    FROM plochy pl
    WHERE pl.plocha_podlahova_karty > 0 AND pl.plocha_z_podilu > 0
),
prm AS (
    SELECT MAX(CASE WHEN parametr = 'podil_pasmo_ok_od' THEN hodnota END) AS ok_od,
           MAX(CASE WHEN parametr = 'podil_pasmo_ok_do' THEN hodnota END) AS ok_do,
           MAX(CASE WHEN parametr = 'podil_posun_tolerance' THEN hodnota END) AS tol,
           MAX(CASE WHEN parametr = 'nabyt_pomer_max' THEN hodnota END) AS nabyt_max
    FROM dbo.CIS_karta_parametry
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
    /* Registr zdrojů plochy a detekce posunu desetinné čárky (krok 44) */
    pl.plocha_z_podilu, pl.plocha_na_byt,
    CAST(po.nasobek AS decimal(18,4)) AS podil_nasobek,
    CASE WHEN po.nasobek IS NULL THEN NULL
         WHEN po.nasobek BETWEEN prm.ok_od AND prm.ok_do THEN 0
         WHEN ABS(LOG10(po.nasobek) - ROUND(LOG10(po.nasobek), 0)) <= prm.tol
              AND ROUND(LOG10(po.nasobek), 0) <> 0
         THEN CAST(ROUND(LOG10(po.nasobek), 0) AS int)
    END AS posun_radu,
    CASE WHEN po.nasobek IS NOT NULL
              AND po.nasobek NOT BETWEEN prm.ok_od AND prm.ok_do
              AND ABS(LOG10(po.nasobek) - ROUND(LOG10(po.nasobek), 0)) <= prm.tol
              AND ROUND(LOG10(po.nasobek), 0) <> 0
         THEN 1 ELSE 0 END AS nalez_plocha_posun,
    CASE WHEN po.nasobek IS NOT NULL
              AND po.nasobek NOT BETWEEN prm.ok_od AND prm.ok_do
              AND ABS(LOG10(po.nasobek) - ROUND(LOG10(po.nasobek), 0)) <= prm.tol
              AND ROUND(LOG10(po.nasobek), 0) <> 0
         THEN CAST(pl.plocha_podlahova_karty
                   * POWER(10.0, ROUND(LOG10(po.nasobek), 0)) AS decimal(14,2))
    END AS plocha_navrh,
    CASE WHEN pl.plocha_na_byt > 0 AND pl.na_byt_neduveryhodne = 0
              AND pl.plocha_podlahova_karty > 0
              AND (pl.plocha_podlahova_karty / pl.plocha_na_byt > prm.nabyt_max
                OR pl.plocha_na_byt / pl.plocha_podlahova_karty > prm.nabyt_max)
         THEN 1 ELSE 0 END AS nalez_plocha_mimo_ocekavani,
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
LEFT JOIN posun po ON po.cislo_vkladu = v.cislo_vkladu
CROSS JOIN prm
LEFT JOIN dbo.Valuo_karta_vklad kv ON kv.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.Valuo_vklad_rucne r ON r.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku;
GO

-- ČÁST 7b: aktuálnost karty a exportu ----------------------------------------
-- Požadavek znalce: karta v HTML i export do Wordu musí vždy vycházet z toho
-- nejaktuálnějšího, co data a aplikace vědí. `Valuo_plochy` je ale počítaná
-- tabulka — ručně zadaná plocha by se v ní objevila až po přepočtu. Řeší se
-- to dvojím způsobem, aby to vydrželo, i kdyby jeden z nich selhal:
--
--   1. **Registr se čte živě v té části, která se mění za provozu.** Dotaz
--      v aplikaci i v exportu (`SQL_ZDROJE_PLOCHY`, resp. `SQL_PLOCHY`) bere
--      řádek RUCNE přímo z `Valuo_vklad_rucne` a z registru jen odvozené
--      zdroje, které se mění pouze s importem:
--
--        SELECT 'RUCNE', r.plocha_rucne, 1, r.plocha_rucne_zdroj
--        FROM dbo.Valuo_vklad_rucne r WHERE r.cislo_vkladu = :v AND r.plocha_rucne > 0
--        UNION ALL
--        SELECT z.zdroj, z.plocha, z.platny, z.poznamka
--        FROM dbo.Valuo_plochy z WHERE z.cislo_vkladu = :v AND z.zdroj <> 'RUCNE'
--
--   2. **Po uložení se registr pro ten jeden vklad rovnou srovná.** Aplikace
--      hned za zápisem pustí MERGE jen pro dotčený vklad; celý přepočet se
--      kvůli jednomu vkladu pouštět nemusí. Větev NOT MATCHED BY SOURCE má
--      podmínku na číslo vkladu i na zdroj — bez ní by sáhla na celou tabulku
--      (poučení z kroku 29).
--
-- Ověřeno 25. 10. 2026 na V-23003/2024-101: po zápisu 265,70 m² přibyl
-- v registru právě jeden řádek (83 510 → 83 511), pohled začal vracet
-- „ověřeno znalcem“ a 80 918 Kč/m² místo 809 183, a **nález posunu sám
-- zmizel**, protože poměr proti RÚIANu už souhlasí. Zkušební data uklizena.

-- ČÁST 8: kontroly ------------------------------------------------------------

-- 8.1 ten vklad, který to vyvolal
SELECT plocha_podlahova_karty, plocha_podlahova_zdroj, plocha_z_podilu,
       plocha_na_byt, podil_nasobek, posun_radu, nalez_plocha_posun,
       plocha_navrh, jc_Kc_m2_podlahova
FROM dbo.v_Valuo_karta_vkladu WHERE cislo_vkladu = 'V-23003/2024-101';
-- Ověřeno 25. 10. 2026: 26,57 / plocha jednotky dle Valuo / 266,07 / 291,00
--                       / 10,0139 / 1 / 1 / 265,70 / 809 183,29

-- 8.2 všechny zdroje toho vkladu vedle sebe
SELECT c.poradi, p.zdroj, c.nazev, p.plocha, p.platny, p.poznamka
FROM dbo.Valuo_plochy p
JOIN dbo.CIS_plochy_zdroje c ON c.kod = p.zdroj
WHERE p.cislo_vkladu = 'V-23003/2024-101'
ORDER BY c.poradi;

-- 8.3 celkové počty
SELECT COUNT(*) AS vkladu,
  SUM(CAST(nalez_plocha_posun AS int)) AS posun_prokazan,
  SUM(CAST(nalez_plocha_mimo_ocekavani AS int)) AS mimo_ocekavani,
  SUM(CASE WHEN plocha_podlahova_zdroj = N'dopočet z podílu proti RÚIAN' THEN 1 ELSE 0 END) AS pouzit_dopocet,
  SUM(CASE WHEN posun_radu = 0 THEN 1 ELSE 0 END) AS podil_souhlasi,
  SUM(CASE WHEN posun_radu IS NULL AND plocha_z_podilu IS NOT NULL THEN 1 ELSE 0 END) AS nejednoznacnych,
  SUM(CASE WHEN plocha_z_podilu IS NULL THEN 1 ELSE 0 END) AS bez_dopoctu
FROM dbo.v_Valuo_karta_vkladu;
-- Ověřeno 25. 10. 2026: 49 788 / 1 807 / 1 677 / 21 / 9 036 / 3 123 / 35 822
