/* ============================================================================
   KROK 45 — ČÁST 2 až 5
   Číselník typů jednotek, nové zdroje plochy, registr ploch po řádcích,
   výsledek na vkladu a parametry.

   Proč krok vznikl
   ----------------
   Karta nesla jedno číslo plochy na vklad, ale vklad není jedna jednotka.
   Valuovo pole vklad_plocha_jednotky sečte byt i garáž i nebytové prostory
   a krok 44 to navíc přepočítával součtem všech podílů krát podlahová plocha
   domu. U vkladu V-31790/2024-101 (Dejvice) tak vyšlo 223 m² místo 156,86 m²
   za dva byty, u V-1000/2025-202 (Beroun) 1 284 m² místo 90,46 m², protože
   se do součtu dostala garáž o 2 753 m².

   Plocha po řádcích je u Valua v rozumném rozmezí 5 až 400 m² v 99,4 %
   případů. Opravuje se tedy agregace, ne plocha.

   Co se tímto krokem vyvrací
   --------------------------
   Krok 44 předpokládal systematický posun desetinné čárky v podílu a hledal
   ho podle toho, jak blízko mocniny deseti leží násobek plochy z podílu proti
   použité ploše (parametr podil_posun_tolerance = 0,18, tedy pásmo 6,7 až 15).
   Měření 25. 10. 2026: histogram násobku po desetinách dekády NEMÁ na hodnotě
   10 žádný vrchol — 206 vkladů proti 261 u souseda vlevo a 100 vpravo. Posun
   desetinné čárky jako populace v datech neexistuje a pásmo 6,7 až 15 do sebe
   nabralo nesouvisející rozptyl. Z 1 020 vkladů, kterým krok 44 navrhoval
   posun o jedno místo nahoru, by návrh u 551 zhoršil jednotkovou cenu a jen
   u 35 zlepšil.

   Chyba v argumentaci kroku 44: z toho, že v datech je propad POD pásmem
   (mezi 3 a 6,7), se usuzovalo, že pásmo je správně široké. To z toho
   nevyplývá.

   Co místo toho
   -------------
   A  Plocha se počítá po řádcích a sčítá jen za nosnou nemovitost, což je
      nejvyšší typ jednotky přítomný ve vkladu (CIS_jednotka_typ.priorita).
      Ostatní jednotky se vyřadí a zapíše se, že jsou rozpuštěné v ceně.
   B  Je-li podíl pravý zlomek (1/6) a Valuo do řádku dalo plochu celého domu,
      plocha = poměr krát podlahová plocha domu dle RÚIAN.
   C  Je-li čitatel podílu plocha jednotky krát mocnina deseti, odvodí se
      škála z jmenovatele proti ploše domu a plocha = čitatel dělený škálou.
      Škála je vlastnost domu, ne řádku: u V-46661/2026-101 (Záběhlice) Valuo
      v jednom domě dělí čitatel 231 deseti a čitatel 147 jedničkou.
   D  Jednotková cena se porovnává jen v rámci stejné skupiny jednotek.
      Garáž padne do pásma mediánu bytů ve 4,9 % případů, byt v 87,9 %.

   Ověřeno znalcem 25. 10. 2026 na šesti vkladech: V-3012/2026-101 Smíchov,
   V-31790/2024-101 Dejvice, V-1000/2025-202 Beroun, V-10032/2026-101 Libeň,
   V-23003/2024-101 Kunratice, V-46661/2026-101 Záběhlice.

   Cenový medián k.ú. zůstává jen jako kontrola, nikdy jako volič plochy.
   Plochu určují pravidla A až C, cena jen rozsvítí, co se vyplatí prověřit
   v listině. Jinak by se plocha vybírala tak, aby cena vyšla do pásma, a to
   by uměle zúžilo rozptyl v porovnávací metodě.
   ============================================================================ */

SET XACT_ABORT ON;
SET NOCOUNT ON;

/* ---------------------------------------------------------------------------
   ČÁST 2 — číselník typů jednotek
   Priorita určuje nosnou nemovitost vkladu: nejnižší číslo, které se ve
   vkladu objeví. Skupina určuje, s čím se smí srovnávat jednotková cena.
   Rozmezí plochy je mez věrohodnosti pro ten typ, ne pro cenu.
   --------------------------------------------------------------------------- */

IF OBJECT_ID('dbo.CIS_jednotka_typ') IS NULL
CREATE TABLE dbo.CIS_jednotka_typ (
    typ        nvarchar(100) NOT NULL CONSTRAINT PK_CIS_jednotka_typ PRIMARY KEY,
    priorita   int           NOT NULL,
    skupina    nvarchar(40)  NOT NULL,
    plocha_min decimal(14,2) NULL,
    plocha_max decimal(14,2) NULL,
    popis      nvarchar(400) NULL
);

MERGE dbo.CIS_jednotka_typ AS c
USING (VALUES
 (N'byt', 1, N'byt', 10.00, 400.00,
  N'Nosná nemovitost vkladu. Medián plochy v databázi 58,3 m².'),
 (N'skupina bytů', 1, N'byt', 10.00, 1000.00,
  N'Více bytů zapsaných jako jedna jednotka.'),
 (N'skupina bytů a nebytových prostorů', 1, N'byt', 10.00, 1000.00,
  N'Více jednotek zapsaných jako jedna. Cena v sobě nese i nebytovou část.'),
 (N'rozestavěná jednotka', 1, N'rozestavěná', 10.00, 400.00,
  N'Nosná jako byt, ale cena se nesrovnává s dokončenými — vlastní skupina.'),
 (N'ateliér', 2, N'ateliér', 10.00, 400.00,
  N'Medián plochy 41,5 m². Do pásma mediánu bytů padne v 74,9 % případů.'),
 (N'dílna nebo provozovna', 3, N'dílna', 10.00, 1000.00,
  N'Do pásma mediánu bytů padne v 37,2 % případů, vlastní skupina je nutná.'),
 (N'jiný nebytový prostor', 4, N'nebyt', 2.00, 1000.00,
  N'Sklep, sklad, kancelář. Do pásma mediánu bytů padne v 48,7 % případů. Nosná je jen tam, kde ve vkladu nic vyššího není — například dokup sklepa.'),
 (N'garáž', 5, N'garáž', 5.00, 3000.00,
  N'Garáž bývá jedna jednotka za celou halu, proto horní mez 3 000 m². Do pásma mediánu bytů padne ve 4,9 % případů. Z plochy nosné nemovitosti je vždy venku, pokud ve vkladu je cokoli vyššího.'),
 (N'Neznámé', 6, N'ostatní', NULL, NULL,
  N'Valuo typ neuvedlo. Priorita nejnižší, aby nepřebila skutečný typ.')
) AS v (typ, priorita, skupina, plocha_min, plocha_max, popis)
ON c.typ = v.typ
WHEN MATCHED THEN UPDATE SET c.priorita = v.priorita, c.skupina = v.skupina,
     c.plocha_min = v.plocha_min, c.plocha_max = v.plocha_max, c.popis = v.popis
WHEN NOT MATCHED BY TARGET THEN
     INSERT (typ, priorita, skupina, plocha_min, plocha_max, popis)
     VALUES (v.typ, v.priorita, v.skupina, v.plocha_min, v.plocha_max, v.popis);

/* ---------------------------------------------------------------------------
   ČÁST 3 — nové zdroje plochy
   --------------------------------------------------------------------------- */

MERGE dbo.CIS_plochy_zdroje AS c
USING (VALUES
 ('VALUO_RADEK', N'plocha jednotky dle Valuo', 10, CAST(1 AS bit), CAST(0 AS bit),
  N'Valuo_data.plocha u konkrétní jednotky vkladu, ne vkladové pole. V rozumném rozmezí 5 až 400 m² v 99,4 % řádků, proto je to výchozí zdroj.'),
 ('PODIL_RADEK', N'podíl × podlahová plocha domu dle RÚIAN', 11, CAST(1 AS bit), CAST(0 AS bit),
  N'Poměr čitatele a jmenovatele podílu na společných částech krát podlahová plocha domu dle RÚIAN, u jedné jednotky. Používá se tam, kde je podíl pravý zlomek a Valuo do řádku dalo plochu celého domu — například V-3012/2026-101, podíl 1/6 a plocha 933 m² dá 155,50 m².'),
 ('CITATEL_SKALA', N'čitatel podílu dělený škálou domu', 12, CAST(1 AS bit), CAST(0 AS bit),
  N'V prohlášení vlastníka bývá čitatel podílu plocha jednotky krát mocnina deseti a jmenovatel součet ploch všech jednotek. Škála se odvodí z jmenovatele proti podlahové ploše domu dle RÚIAN a platí pro celý dům. Dostupná jen tam, kde jmenovatel dělený škálou vyjde jako plocha domu.')
) AS v (kod, nazev, poradi, pro_cenu, autoritativni, popis)
ON c.kod = v.kod
WHEN MATCHED THEN UPDATE SET c.nazev = v.nazev, c.poradi = v.poradi,
     c.pro_cenu = v.pro_cenu, c.autoritativni = v.autoritativni, c.popis = v.popis
WHEN NOT MATCHED BY TARGET THEN
     INSERT (kod, nazev, poradi, pro_cenu, autoritativni, popis)
     VALUES (v.kod, v.nazev, v.poradi, v.pro_cenu, v.autoritativni, v.popis);

/* Vkladový dopočet z kroku 44 se ruší: sečítal podíly všech jednotek vkladu
   včetně garáží a nebytů a násobil je plochou jednoho domu. Záznam v
   číselníku zůstává kvůli dohledatelnosti starých výstupů, ale pro cenu se
   už nepoužívá. */
UPDATE dbo.CIS_plochy_zdroje
SET pro_cenu = 0,
    popis = N'ZRUŠENO 25. 10. 2026 krokem 45. Sečítalo podíly všech jednotek vkladu včetně garáží a nebytových prostorů a násobilo je podlahovou plochou jednoho domu. U V-1000/2025-202 to dalo 1 284 m² místo 90,46 m². Nahrazuje PODIL_RADEK po řádcích.'
WHERE kod = 'PODIL_RUIAN';

/* ---------------------------------------------------------------------------
   ČÁST 4 — registr ploch po řádcích
   id = Valuo_data.id konkrétní jednotky, 0 = údaj za celý vklad (RUCNE).
   --------------------------------------------------------------------------- */

/* Nové sloupce a klíč jdou přes EXEC: v jedné dávce by se příkaz, který
   nový sloupec jmenuje, kompiloval dřív, než sloupec vznikne. */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_plochy') AND name = 'id')
BEGIN
    EXEC('ALTER TABLE dbo.Valuo_plochy DROP CONSTRAINT PK_Valuo_plochy');
    EXEC('ALTER TABLE dbo.Valuo_plochy ADD id int NOT NULL
              CONSTRAINT DF_Valuo_plochy_id DEFAULT 0');
    EXEC('ALTER TABLE dbo.Valuo_plochy ADD CONSTRAINT PK_Valuo_plochy
              PRIMARY KEY CLUSTERED (cislo_vkladu, id, zdroj)');
END;

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_plochy') AND name = 'pouzito')
    EXEC('ALTER TABLE dbo.Valuo_plochy ADD pouzito bit NOT NULL
              CONSTRAINT DF_Valuo_plochy_pouzito DEFAULT 0');

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.Valuo_plochy') AND name = 'IX_Valuo_plochy_pouzito')
    EXEC('CREATE NONCLUSTERED INDEX IX_Valuo_plochy_pouzito
              ON dbo.Valuo_plochy (pouzito, zdroj)
              INCLUDE (cislo_vkladu, id, plocha)');

/* ---------------------------------------------------------------------------
   ČÁST 5 — výsledek na vkladu a parametry
   --------------------------------------------------------------------------- */

IF OBJECT_ID('dbo.Valuo_vklad_plocha') IS NULL
CREATE TABLE dbo.Valuo_vklad_plocha (
    cislo_vkladu    varchar(50)   NOT NULL CONSTRAINT PK_Valuo_vklad_plocha PRIMARY KEY,
    nosna_priorita  int           NULL,
    nosna_skupina   nvarchar(40)  NULL,
    nosny_typ       nvarchar(100) NULL,
    radku_nosnych   int           NOT NULL,
    radku_mimo      int           NOT NULL,
    plocha          decimal(14,2) NULL,
    plocha_zdroje   nvarchar(400) NULL,
    rozpusteno      nvarchar(400) NULL,
    nalezu          int           NOT NULL,
    kdy             datetime2     NOT NULL
);

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.Valuo_vklad_plocha') AND name = 'IX_Valuo_vklad_plocha_skupina')
CREATE NONCLUSTERED INDEX IX_Valuo_vklad_plocha_skupina
    ON dbo.Valuo_vklad_plocha (nosna_skupina, nalezu) INCLUDE (plocha);

MERGE dbo.CIS_karta_parametry AS c
USING (VALUES
 ('dum_skala_od', 0.50,
  N'Jmenovatel podílu dělený škálou musí vyjít aspoň jako tento násobek podlahové plochy domu dle RÚIAN. Jmenovatel je součet ploch všech jednotek a ten nemůže být o mnoho menší než plocha domu.'),
 ('dum_skala_do', 1.20,
  N'A nejvýš tento násobek. Plocha domu dle RÚIAN zahrnuje i společné prostory, takže součet ploch jednotek ji nemá přesáhnout. Nevyjde-li ani jedna mocnina deseti, škála se neurčí a plocha zůstane z Valua — tak je to u V-1000/2025-202, kde jmenovatel pokrývá pět čísel popisných a RÚIAN jen jedno.'),
 ('skala_rozpor_od', 5.00,
  N'Od jakého násobku mezi plochou z čitatele a Valuovou plochou jde o rozpor ve škále. Pod ním jsou to drobné rozdíly v zaokrouhlení, nad ním chybí nebo přebývá celý řád.'),
 ('dum_plocha_shoda', 0.03,
  N'Jak blízko musí být Valuova plocha řádku podlahové ploše domu dle RÚIAN, aby se brala za plochu celého domu místo plochy jednotky.'),
 ('jc_median_min_vzorku', 10.00,
  N'Od kolika čistých vzorků ve skupině a katastrálním území se počítá medián jednotkové ceny. Pod tím se kontrola neprovádí a vzorek se označí za neověřený, ne za vadný.'),
 ('jc_pasmo_nasobek', 3.00,
  N'Kolikrát se jednotková cena smí lišit od mediánu své skupiny v katastrálním území, než se vzorek označí k prověření. Je to kontrola, nikoli volič plochy.')
) AS v (parametr, hodnota, popis)
ON c.parametr = v.parametr
WHEN MATCHED THEN UPDATE SET c.hodnota = v.hodnota, c.popis = v.popis
WHEN NOT MATCHED BY TARGET THEN INSERT (parametr, hodnota, popis)
     VALUES (v.parametr, v.hodnota, v.popis);

/* Parametry kroku 44, které krok 45 ruší. Zůstávají v číselníku s vysvětlením,
   proč se nepoužívají — rozhodnutí se nepřepisují. */
UPDATE dbo.CIS_karta_parametry
SET popis = N'NEPOUŽÍVÁ SE od 25. 10. 2026, krok 45. Pásmo 6,7 až 15 pro posun o jedno místo nemá v datech oporu: histogram násobku nemá na hodnotě 10 žádný vrchol. Z 1 020 vkladů s navrženým posunem nahoru by návrh u 551 zhoršil jednotkovou cenu a jen u 35 zlepšil.'
WHERE parametr = 'podil_posun_tolerance';

UPDATE dbo.CIS_karta_parametry
SET popis = N'NEPOUŽÍVÁ SE od 25. 10. 2026, krok 45. Nahrazuje to oprava po řádcích: plocha celého domu se pozná podle parametru dum_plocha_shoda u jednotlivé jednotky, ne podle podílu plochy vkladu.'
WHERE parametr = 'cely_dum_od';

UPDATE dbo.CIS_karta_parametry
SET popis = N'NEPOUŽÍVÁ SE od 25. 10. 2026, krok 45. Pásmo „v pořádku“ se vázalo na vkladový dopočet z podílu, který se ruší.'
WHERE parametr IN ('podil_pasmo_ok_od', 'podil_pasmo_ok_do');

SELECT (SELECT COUNT(*) FROM dbo.CIS_jednotka_typ)    AS typu_jednotek,
       (SELECT COUNT(*) FROM dbo.CIS_plochy_zdroje)   AS zdroju_plochy,
       (SELECT COUNT(*) FROM dbo.CIS_karta_parametry) AS parametru,
       (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Valuo_plochy')) AS sloupcu_registru,
       (SELECT COUNT(*) FROM dbo.CIS_jednotka_typ t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.Valuo_data d
                          WHERE d.nemovitost = 'jednotka' AND d.typ = t.typ)) AS typu_bez_dat,
       (SELECT COUNT(DISTINCT d.typ) FROM dbo.Valuo_data d
        WHERE d.nemovitost = 'jednotka'
          AND NOT EXISTS (SELECT 1 FROM dbo.CIS_jednotka_typ t WHERE t.typ = d.typ)) AS typu_v_datech_bez_ciselniku;

/* ---------------------------------------------------------------------------
   ČÁST 5b — doplnění Valuo_mapa
   nalez_plocha_posun se neruší, ale od 25. 10. 2026 se už nenaplňuje:
   posun desetinné čárky jako jev v datech neexistuje. Nahrazuje ho
   nalez_skala, což je rozpor mezi Valuovou plochou a čitatelem podílu
   přepočteným škálou domu. nosna_skupina a jc_verdikt jsou potřeba pro
   filtry v aplikaci a pro srovnání jednotkové ceny jen v rámci stejné
   skupiny jednotek.
   --------------------------------------------------------------------------- */

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_mapa') AND name = 'nalez_skala')
    EXEC('ALTER TABLE dbo.Valuo_mapa ADD nalez_skala bit NULL');

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_mapa') AND name = 'nosna_skupina')
    EXEC('ALTER TABLE dbo.Valuo_mapa ADD nosna_skupina nvarchar(40) NULL');

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_mapa') AND name = 'jc_verdikt')
    EXEC('ALTER TABLE dbo.Valuo_mapa ADD jc_verdikt varchar(20) NULL');

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_vklad_plocha') AND name = 'nalez_dum')
    EXEC('ALTER TABLE dbo.Valuo_vklad_plocha ADD nalez_dum bit NOT NULL
              CONSTRAINT DF_Valuo_vklad_plocha_dum DEFAULT 0');

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_vklad_plocha') AND name = 'nalez_skala')
    EXEC('ALTER TABLE dbo.Valuo_vklad_plocha ADD nalez_skala bit NOT NULL
              CONSTRAINT DF_Valuo_vklad_plocha_skala DEFAULT 0');

/* ---------------------------------------------------------------------------
   ČÁST 5c — medián jednotkové ceny v katastrálním území a skupině
   Kontrola, nikoli volič plochy. Plochu určují pravidla po řádcích; medián
   jen rozsvítí vzorek, který se vyplatí prověřit v listině. Kdyby plochu
   vybíral medián, cena by vyšla do pásma vždy a rozptyl v porovnávací
   metodě by se uměle zúžil.
   --------------------------------------------------------------------------- */

IF OBJECT_ID('dbo.CIS_ku_median_jc') IS NULL
CREATE TABLE dbo.CIS_ku_median_jc (
    kod_ku        int           NOT NULL,
    nosna_skupina nvarchar(40)  NOT NULL,
    vzorku        int           NOT NULL,
    median_jc     decimal(14,2) NOT NULL,
    kdy           datetime2     NOT NULL,
    CONSTRAINT PK_CIS_ku_median_jc PRIMARY KEY CLUSTERED (kod_ku, nosna_skupina)
);

MERGE dbo.CIS_karta_parametry AS c
USING (VALUES
 ('skala_rad_tolerance', 0.05,
  N'O kolik m² se smí čitatel dělený škálou lišit od Valuovy plochy krát deset nebo sto, aby šlo o rozpor přesně o řád. Nekrouhlý násobek chybu ve škále NEDOKLÁDÁ: v datech je rozpor 6× nebo 14× stejně častý jako 10×, a tam podíl prostě není plocha.'),
 ('skala_svedek_dekada', 0.50,
  N'O kolik dekád musí být čitatel blíž ploše domu na jednu jednotku než Valuova plocha, aby to byl doklad, že chybná je Valuova. Půl dekády je faktor 3,2.')
) AS v (parametr, hodnota, popis)
ON c.parametr = v.parametr
WHEN MATCHED THEN UPDATE SET c.hodnota = v.hodnota, c.popis = v.popis
WHEN NOT MATCHED BY TARGET THEN INSERT (parametr, hodnota, popis)
     VALUES (v.parametr, v.hodnota, v.popis);

UPDATE dbo.CIS_karta_parametry
SET popis = N'NEPOUŽÍVÁ SE od 25. 10. 2026. Podmínka „liší se aspoň pětkrát“ propustila i nekrouhlé násobky a přepsala by 616 řádků, z toho 50 s násobkem, který chybu ve škále nedokládá, a stovky s nemožnou výslednou plochou (medián návrhu 4,9 m²). Nahrazuje ji skala_rad_tolerance plus nezávislý svědek.'
WHERE parametr = 'skala_rozpor_od';

/* ---------------------------------------------------------------------------
   ČÁST 6 a 7 — procedura sp_prepocet_ploch a view v_Valuo_karta_vkladu

   Text obou programovatelných objektů v tomto souboru NENÍ. Je v
   `_definice\definice_20261025.sql`, který vyrábí 42_export_definic.py
   přímo z sys.sql_modules.

   Důvod: dvě kopie téhož textu se rozejdou. V kroku 44 jsme to měli
   v souboru i v databázi a ověřovat shodu bylo potřeba po každé úpravě.
   Export z sys.sql_modules je vždy to, co v databázi skutečně běží.

   Pořadí nasazení je podstatné:
     1. tento soubor (části 2 až 5c) — tabulky, číselníky, parametry;
     2. CREATE OR ALTER VIEW dbo.v_Valuo_karta_vkladu z definic;
     3. CREATE OR ALTER PROCEDURE dbo.sp_prepocet_ploch z definic;
     4. EXEC dbo.sp_prepocet_ploch @prepocitat = 1;
     5. 42_export_definic.py — nový export definic.

   Krok 2 musí být před krokem 3: procedura ve své části 7 jmenuje sloupce
   view (nalez_skala, nosna_skupina, jc_verdikt, plocha_podlahova_karty,
   plocha_navrh). Odložená vazba v SQL Serveru platí pro chybějící OBJEKTY,
   ne pro chybějící sloupce objektu, který existuje — CREATE PROCEDURE se
   starým view proto selže na „Invalid column name“.
   --------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
   ČÁST 8 — kontroly
   --------------------------------------------------------------------------- */

/* 8.1 Šest vkladů ověřených znalcem 25. 10. 2026. Musí vyjít přesně takto:
       V-3012/2026-101   Smíchov    155,50  podíl × plocha domu dle RÚIAN
       V-31790/2024-101  Dejvice    156,86  2 byty, garáž a 3 nebyty v ceně
       V-1000/2025-202   Beroun      90,46  byt, garáž v ceně
       V-10032/2026-101  Libeň       47,00  jen nebytový prostor
       V-23003/2024-101  Kunratice  265,70  čitatel dělený škálou domu
       V-46661/2026-101  Záběhlice  107,20  6 ateliérů, z toho 5 přeškálovaných */
SELECT cislo_vkladu, nosny_typ, radku_nosnych, radku_mimo, plocha,
       plocha_zdroje, rozpusteno, nalez_dum, nalez_skala
FROM dbo.Valuo_vklad_plocha
WHERE cislo_vkladu IN ('V-3012/2026-101', 'V-31790/2024-101', 'V-1000/2025-202',
                       'V-10032/2026-101', 'V-23003/2024-101', 'V-46661/2026-101')
ORDER BY cislo_vkladu;

/* 8.2 Tři vklady, na kterých se ladily svědkové. Musí vyjít takto:
       V-2107/2026-202   garáže — NEpřepsáno na 12 008,52 m² (svědek 1 přebil svědka 2)
       V-10253/2024-101  nebyty — NEpřepsáno na 5 675,30 m²
       V-40227/2024-101  nebyt  — nález celého domu se najde, ale nepřepíše
                                  (podíl dává hodnotu mimo věrohodné rozmezí) */
SELECT cislo_vkladu, nosny_typ, plocha, plocha_zdroje, nalez_dum, nalez_skala
FROM dbo.Valuo_vklad_plocha
WHERE cislo_vkladu IN ('V-2107/2026-202', 'V-10253/2024-101', 'V-40227/2024-101')
ORDER BY cislo_vkladu;

/* 8.3 Rozsah změny proti vkladovému poli Valua. Změřeno 25. 10. 2026:
       bez změny 29 238, nová je menší 6 425 (medián 148,8 → 64,6),
       karta plochu neměla a nově má 1 265, nová je větší 93. */
WITH stara AS (
    SELECT d.cislo_vkladu,
           COALESCE(MAX(d.vklad_plocha_jednotky),
                    MAX(CASE WHEN d.typ_plochy = N'Podlahová plocha' THEN d.plocha END)) AS pl_stara
    FROM dbo.Valuo_data d
    WHERE EXISTS (SELECT 1 FROM dbo.Valuo_data e
                  WHERE e.cislo_vkladu = d.cislo_vkladu AND e.nemovitost = 'jednotka')
    GROUP BY d.cislo_vkladu
)
SELECT CASE WHEN s.pl_stara IS NULL AND v.plocha IS NOT NULL THEN N'karta plochu neměla, nově má'
            WHEN v.plocha IS NULL  THEN N'plochu nemá ani nyní'
            WHEN ABS(s.pl_stara - v.plocha) <= 0.02 THEN N'bez změny'
            WHEN v.plocha < s.pl_stara THEN N'nová je menší'
            ELSE N'nová je větší' END AS zmena,
    COUNT(*) AS vkladu,
    CAST(APPROX_PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.pl_stara) AS decimal(10,1)) AS med_stara,
    CAST(APPROX_PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v.plocha)   AS decimal(10,1)) AS med_nova
FROM stara s
FULL OUTER JOIN dbo.Valuo_vklad_plocha v ON v.cislo_vkladu = s.cislo_vkladu
GROUP BY CASE WHEN s.pl_stara IS NULL AND v.plocha IS NOT NULL THEN N'karta plochu neměla, nově má'
              WHEN v.plocha IS NULL  THEN N'plochu nemá ani nyní'
              WHEN ABS(s.pl_stara - v.plocha) <= 0.02 THEN N'bez změny'
              WHEN v.plocha < s.pl_stara THEN N'nová je menší'
              ELSE N'nová je větší' END
ORDER BY COUNT(*) DESC;

/* 8.4 Jednotková cena proti mediánu vlastní skupiny. Změřeno 25. 10. 2026:
       byt 27 537 v pásmu z 31 681 (86,9 %), garáž 1 136 z 1 700 proti
       4,9 % u společného mediánu bytů — tím je doložená oprava D. */
SELECT nosna_skupina, jc_verdikt, COUNT(*) AS vkladu,
       CAST(APPROX_PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY jc_Kc_m2_podlahova)
            AS decimal(12,0)) AS med_jc
FROM dbo.v_Valuo_karta_vkladu
WHERE nosna_skupina IS NOT NULL
GROUP BY nosna_skupina, jc_verdikt
ORDER BY nosna_skupina, jc_verdikt;

/* 8.5 Nálezy a přepisy. Změřeno 25. 10. 2026: 393 nálezů celého domu,
       z toho 212 přepsáno; 2 571 nálezů škály, z toho 57 přepsáno.
       Přepis vyžaduje nezávislého svědka, nález ne — rozdíl mezi oběma
       čísly je seznam k prověření v listině. */
SELECT (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE nalez_dum = 1)   AS vkladu_nalez_dum,
       (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE nalez_skala = 1) AS vkladu_nalez_skala,
       (SELECT COUNT(*) FROM dbo.Valuo_plochy
        WHERE zdroj = 'PODIL_RADEK'   AND pouzito = 1 AND id > 0)          AS radku_z_podilu,
       (SELECT COUNT(*) FROM dbo.Valuo_plochy
        WHERE zdroj = 'CITATEL_SKALA' AND pouzito = 1 AND id > 0)          AS radku_z_citatele,
       (SELECT COUNT(*) FROM dbo.Valuo_plochy
        WHERE zdroj = 'VALUO_RADEK'   AND pouzito = 1 AND id > 0)          AS radku_z_valua;

/* 8.6 Registr musí mít u každé jednotky právě jednu použitou plochu.
       Výsledek 0 řádků = v pořádku. */
SELECT z.cislo_vkladu, z.id, SUM(CASE WHEN z.pouzito = 1 THEN 1 ELSE 0 END) AS pouzitych
FROM dbo.Valuo_plochy z WHERE z.id > 0
GROUP BY z.cislo_vkladu, z.id
HAVING SUM(CASE WHEN z.pouzito = 1 THEN 1 ELSE 0 END) <> 1;

/* 8.7 Plocha vkladu musí být součtem použitých ploch nosné nemovitosti.
       Výsledek 0 řádků = v pořádku. */
SELECT vp.cislo_vkladu, vp.plocha AS na_vkladu,
       CAST(SUM(z.plocha) AS decimal(14,2)) AS soucet_radku
FROM dbo.Valuo_vklad_plocha vp
JOIN dbo.Valuo_plochy z ON z.cislo_vkladu = vp.cislo_vkladu AND z.id > 0 AND z.pouzito = 1
JOIN dbo.Valuo_data d ON d.id = z.id
JOIN dbo.CIS_jednotka_typ t ON t.typ = d.typ
WHERE t.priorita = vp.nosna_priorita AND t.skupina = vp.nosna_skupina
GROUP BY vp.cislo_vkladu, vp.plocha
HAVING ABS(ISNULL(vp.plocha, 0) - SUM(z.plocha)) > 0.02;

/* 8.8 Krok 45 se týká JEN vkladů s jednotkou — `#radek` v proceduře má
       `WHERE d.nemovitost = 'jednotka'`, takže `Valuo_vklad_plocha` pro
       vklad s budovou vůbec nevzniká. View proto u takového vkladu drží
       postup z kroku 36: podlahová plocha z Valua, jinak z RÚIANu.

       Bez té větve přišlo 1 682 vkladů s budovou o plochu i o Kč/m²
       (nalezl znalec 25. 10. 2026 dotazem „to se týkalo vkladů, kde jsou
       jednotky, jestli se nepletu").

       Kontrola musí dát 0 rozdílů proti původnímu postupu: */
SELECT COUNT(*) AS vkladu_s_budovou,
    SUM(CASE WHEN ISNULL(v.plocha_podlahova_karty, CAST(-1 AS decimal(14,2)))
              <> ISNULL(COALESCE(r.plocha_rucne, v.plocha_podlahova_valuo,
                                 CAST(v.ruian_podlahova_plocha AS decimal(14,2))),
                        CAST(-1 AS decimal(14,2)))
             THEN 1 ELSE 0 END) AS rozdilu_proti_puvodnimu,
    SUM(CASE WHEN v.plocha_podlahova_karty IS NOT NULL THEN 1 ELSE 0 END) AS ma_plochu
FROM dbo.v_Valuo_karta_vkladu v
LEFT JOIN dbo.Valuo_vklad_rucne r ON r.cislo_vkladu = v.cislo_vkladu
WHERE v.pocet_jednotek = 0 AND v.pocet_budov > 0;

/* 8.9 Plocha podle typu vkladu. Změřeno 25. 10. 2026 po opravě:
       s jednotkou 37 340 / bez plochy 319; s budovou 7 101 / bez plochy
       5 419 (ty plochu nikdy neměly — Valuo ji neuvádí a RÚIAN stavbu
       nezná); jen pozemky 5 347 / bez plochy všechny, a tak to má být. */
SELECT CASE WHEN v.pocet_jednotek > 0 THEN N'vklad s jednotkou'
            WHEN v.pocet_budov > 0   THEN N'vklad s budovou'
            ELSE N'jen pozemky' END AS typ_vkladu,
    COUNT(*) AS vkladu,
    SUM(CASE WHEN v.plocha_podlahova_karty IS NULL THEN 1 ELSE 0 END) AS bez_plochy,
    SUM(CASE WHEN v.jc_Kc_m2_podlahova IS NOT NULL THEN 1 ELSE 0 END) AS ma_jc_podlahovou
FROM dbo.v_Valuo_karta_vkladu v
GROUP BY CASE WHEN v.pocet_jednotek > 0 THEN N'vklad s jednotkou'
              WHEN v.pocet_budov > 0   THEN N'vklad s budovou'
              ELSE N'jen pozemky' END
ORDER BY COUNT(*) DESC;
