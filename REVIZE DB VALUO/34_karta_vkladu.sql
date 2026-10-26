/* =============================================================================
   34_karta_vkladu.sql — KARTA VKLADU, databázová vrstva
   =============================================================================
   Databáze: VALUO (MS SQL)        Krok: 34        Datum: 24. 10. 2026

   K čemu to je
   ------------
   Vzorek ukazuje jeden řádek na vklad s jednotkovou cenou. Na otázku
   "co přesně kupující za tu cenu dostal" neodpovídá. Karta vkladu ji
   rozkládá na pět položek:

       1. hlavní nemovitost (kotva) — to, co se porovnává
       2. vedlejší stavby ve vkladu
       3. výhradní pozemky tvořící celek s kotvou
       4. výhradní pozemky mimo celek (stání přes cestu apod.)
       5. podíly na společných pozemcích (cesta, zeleň, zahrada, stání)

   Karta platí pro VŠECHNY vklady, ne jen pro rodinné domy. Kotva se určuje
   podle klasifikace: JC_JEDNOTKA → jednotka, CELEK_BUDOVA → budova,
   JC_PARCELY → bez kotvy (vypíšou se jen souvislé celky), NELZE → více
   kotev vedle sebe, PRAVO_STAVBY → právo stavby.

   Dvě nezávislé osy, ne jeden výčet rolí
   --------------------------------------
   Rozhodnutí znalce 24. 10. 2026. Parcela může být výhradní a zároveň
   oddělená (venkovní stání přes cestu), nebo podílová a zároveň přilehlá
   (společná zahrada u řadových domů). Jako jeden výčet se to zapsat nedá:

       vlastnictvi      : výhradní | podílová | neověřeno
       prostorova_role  : kotva | celek | oddělená | bez kotvy

   "Sporná" není role, ale příznak (sporna + sporna_duvod) nad oběma osami.

   Databáze nerozhoduje, jen označuje s důkazem. Každá parcela nese vodítka
   v samostatných sloupcích a textový důvod; posouzení je na znalci a musí
   být v posudku přezkoumatelné.

   Čtyři vodítka, prahy změřené na datech (24. 10. 2026)
   -----------------------------------------------------
   1. POČET RŮZNÝCH HLAVNÍCH NEMOVITOSTÍ, u nichž parcela vystupuje.
      NE hrubý počet vkladů: ze 12 379 parcel ve více vkladech má 4 033
      jen jednu hlavní nemovitost — to jsou opakované prodeje téhož domu,
      ne podíly. Časové okno se jako test NEPOUŽÍVÁ: pozemek pod bytovým
      domem se prodává s každou jednotkou klidně deset let a podílem
      přitom je (3 930 parcel má rozptyl nad 2 roky).

   2. DRUH POZEMKU "ostatní komunikace" — slabé vodítko, znalec upozornil,
      že komunikace tak vedená být nemusí a naopak.

   3. TVAR: kompaktnost 4*PI*A/P^2 < 0,30 A ZÁROVEŇ průměrná šířka
      2*A/P < 6 m. Obě podmínky zároveň jsou nutné: parkovací stání je
      taky úzké (medián 2,6 m), ale kompaktní (0,72), kdežto pás cesty je
      úzký a protáhlý. Šířka sama by to spletla.
      Měřeno na parcelách vkladů s rodinným domem:
        ostatní komunikace  zachyceno  84 z 149  (56 %)
        garáž                           0 z 370  (0 %)
        rodinný dům                    18 z 2719 (0,7 %)
        zahrada                       240 z 2251 (11 %)   <- záměrné
        orná půda                      59 z 526  (11 %)   <- záměrné
      Zahrada a orná půda se zachytávají úmyslně: pás cesty bývá
      v katastru veden jako orná půda (Písnice 835/205, 835/32).

   4. POČET CIZÍCH PARCEL SE STAVBOU V SOUSEDSTVÍ >= 4.
      Měřeno na 800 parcelách, u nichž je vlastnictví výhradní:
        0 sousedů se stavbou  207      3 sousedi   57
        1                     291      4-5         24
        2                     219      6+           2
      Řadový dům se dotýká dvou cizích domů, proto práh musí být nad 2.
      Při prahu 4 je falešná pozitivita 3 % (26 z 800).

   Ověření na vkladu V-76414/2024-101 (Písnice, 9 řadových domů)
   -------------------------------------------------------------
   parcela  hlavních  druh  tvar  staveb  výsledek
   835/223         1     -     -       1  výhradní, kotva (dům č.p. 735)
   835/213         1     -     -       0  výhradní, oddělená (stání přes cestu)
   835/132         8     -     -       8  podílová (společná zahrada)
   835/204         8   ANO     -       8  podílová (hlavní cesta)
   835/32          8     -   ANO       0  podílová (pás 4,6 m)
   835/205         8     -   ANO       0  podílová (pás 3,3 m)
   767/2,3,4,5     8  část   ANO       0  podílová (pásy 0,8-2,9 m)
   835/207, /217   8     -     -       0  podílová (společná stání)
   Odpovídá tomu, co znalec zjistil rozklikem v katastru.

   Trvalost zjištění
   -----------------
   Detekce podílů stojí na tom, že se v datech sejde několik prodejů téže
   skupiny. To platí jen v časovém okně nákupu dat. Prodá-li se za pět let
   jeden z devíti domů a ostatní ne, vypadal by vklad jako obrovský
   výhradní pozemek. Proto se zjištění ukládá do Valuo_parcely_role
   klíčované gml_id a platí dál, i kdyby byl pozdější prodej jediný.
   Vodítka 2-4 na počtu vkladů nezávisí vůbec.

   Opravy nalezené ověřením na vzorcích (podrobně u sp_prepocet_karty)
   -------------------------------------------------------------------
   1. Podíl vyžaduje DVA RŮZNÉ VKLADY, ne jen dvě hlavní nemovitosti.
   2. Na kotvu vodítka 2-4 neplatí.
   3. Komponenty se počítají jen přes výhradní parcely — řetězit přes
      společnou cestu by slilo stání za cestou s domem.

   Oprávnění
   ---------
   Účet claude_reader NEMÁ EXECUTE na procedury. Smí je vytvořit a změnit,
   ale ne spustit; pouští je Python pod účtem Windows nebo SSMS. Viz oddíl 8.

   Co skript zakládá
   -----------------
   CIS_karta_parametry     prahy vodítek, určeno k ruční úpravě
   Valuo_parcely_role      trvalá zjištění o parcele (klíč gml_id)
   Valuo_karta_okoli       sousedi a stavby v okolí; inkrementální evidence
   Valuo_karta_parcely     karta po parcelách (klíč vklad + gml_id)
   sp_prepocet_karty_okoli prostorová vodítka, dávkuje po k. ú.
   sp_prepocet_karty       role, komponenty a výměry
   v_Valuo_karta_vkladu    JEDEN ŘÁDEK = JEDEN VKLAD; to je ta karta

   Pořadí spouštění: sp_prepocet_karty_okoli (jen nové parcely),
   potom sp_prepocet_karty. Obojí pouští 30_import_valuo.py --prepocty
   pod účtem Windows; přes spojení asistenta ne, má minutový limit.

   Poučení, která skript respektuje (data/STAV.md, oddíl 0)
   -------------------------------------------------------
   - prostorový join a korelovaný EXISTS v jednom dotazu optimalizátor
     nezvládne: sousedy a stavby na nich hledej dvěma kroky
   - počítaný sloupec nesmí odkazovat na jiný počítaný sloupec (Msg 1759)
   - TRUNCATE v proceduře ji shodí na timeout, používá se DELETE
   - COUNT(DISTINCT) schová rozmnožené párování, kontroluj poměr k COUNT(*)
   - nic se nemaže z Valuo_data ani KN_parcel_data; skript do nich NEZAPISUJE
============================================================================= */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   1. CIS_karta_parametry — prahy vodítek
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.CIS_karta_parametry', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CIS_karta_parametry (
        parametr  varchar(40)    NOT NULL PRIMARY KEY,
        hodnota   decimal(12,4)  NOT NULL,
        popis     nvarchar(300)  NULL
    );
    PRINT 'CIS_karta_parametry: založena';
END
GO

MERGE dbo.CIS_karta_parametry AS t
USING (VALUES
    ('min_hlavnich_pro_podil', 2.0000,
     N'Od kolika různých hlavních nemovitostí se parcela bere jako podílová. Ne počet vkladů — ten míchá podíly s opakovaným prodejem.'),
    ('komp_max_cesta',         0.3000,
     N'Kompaktnost 4*PI*A/P^2 pod tuto hodnotu = protáhlý tvar. Platí jen spolu se sirka_max_cesta_m.'),
    ('sirka_max_cesta_m',      6.0000,
     N'Průměrná šířka 2*A/P pod tuto hodnotu. Spolu s kompaktností odlišuje pás cesty od parkovacího stání.'),
    ('min_staveb_v_okoli',     4.0000,
     N'Od kolika cizích parcel se stavbou v sousedství je parcela podezřelá ze společné. Řadový dům má 2, proto práh nad 2.'),
    ('tolerance_sousednosti_m', 0.0000,
     N'Mezera, kterou se parcely ještě berou jako sousedící. 0 = musí se dotýkat; katastrální parcely sdílejí hranici přesně. Zvýšením se přeskočí cizí cesta mezi parcelami.')
) AS s (parametr, hodnota, popis)
ON t.parametr = s.parametr
WHEN NOT MATCHED THEN INSERT (parametr, hodnota, popis) VALUES (s.parametr, s.hodnota, s.popis);
GO

/* ---------------------------------------------------------------------------
   2. Valuo_parcely_role — trvalá zjištění o parcele

   Klíč je gml_id, ne vklad. Co se o parcele zjistí dnes, platí i pro
   budoucí vklady. zdroj = 'data' doplňuje přepočet, zdroj = 'ruční'
   zapisuje znalec a přepočet to NEPŘEPISUJE.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.Valuo_parcely_role', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Valuo_parcely_role (
        gml_id            varchar(50)   NOT NULL PRIMARY KEY,
        vlastnictvi       nvarchar(20)  NOT NULL,
        zdroj             varchar(10)   NOT NULL CONSTRAINT CK_parcely_role_zdroj
                              CHECK (zdroj IN ('data', 'ruční')),
        hlavnich_max      int           NULL,
        prvni_zjisteno    date          NULL,
        naposled_overeno  date          NULL,
        poznamka          nvarchar(300) NULL
    );
    PRINT 'Valuo_parcely_role: založena';
END
GO

/* ---------------------------------------------------------------------------
   3. Valuo_karta_okoli — prostorová vodítka, inkrementálně

   Nejdražší část celé karty: 40 329 parcel s geometrií proti 4,7 mil.
   parcel v RUIAN_parcely. Řádek se zakládá KAŽDÉ zpracované parcele,
   i když žádného souseda nemá — tabulka je zároveň evidencí, aby se
   parcela nepočítala při každém běhu znovu (poučení z KN_parcel_UP_stav).
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.Valuo_karta_okoli', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Valuo_karta_okoli (
        gml_id              varchar(50)  NOT NULL PRIMARY KEY,
        kod_ku              int          NULL,
        cizich_sousedu      int          NOT NULL DEFAULT 0,
        cizich_se_stavbou   int          NOT NULL DEFAULT 0,
        prepocteno          datetime2    NOT NULL DEFAULT SYSDATETIME()
    );
    PRINT 'Valuo_karta_okoli: založena';
END
GO

/* ---------------------------------------------------------------------------
   4. Valuo_karta_parcely — karta po parcelách
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.Valuo_karta_parcely', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Valuo_karta_parcely (
        cislo_vkladu          varchar(100)  NOT NULL,
        gml_id                varchar(50)   NOT NULL,
        kn_id                 int           NULL,
        parcel_number         varchar(20)   NULL,
        kod_ku                int           NULL,
        vymera_m2             float         NULL,
        druh_valuo            varchar(200)  NULL,
        druh_ruian_kod        tinyint       NULL,

        /* --- osa 1: vlastnictví --- */
        vlastnictvi           nvarchar(20)  NOT NULL,
        vlastnictvi_zdroj     varchar(10)   NULL,

        /* --- osa 2: prostorová role --- */
        prostorova_role       nvarchar(20)  NOT NULL,
        komponenta            int           NULL,
        je_kotva              bit           NOT NULL DEFAULT 0,
        sousedi_s_kotvou      bit           NULL,
        vzdalenost_od_kotvy_m decimal(10,2) NULL,

        /* --- příznak nad oběma osami --- */
        sporna                bit           NOT NULL DEFAULT 0,
        sporna_duvod          nvarchar(300) NULL,

        /* --- vodítka, každé zvlášť a dohledatelné --- */
        hlavnich_nemovitosti  int           NULL,
        vkladu_s_parcelou     int           NULL,
        je_druh_komunikace    bit           NULL,
        kompaktnost           decimal(6,3)  NULL,
        prum_sirka_m          decimal(10,2) NULL,
        tvar_cesty            bit           NULL,
        cizich_se_stavbou     int           NULL,

        /* --- odhad podílu; JEN odhad, velikost podílu data neobsahují --- */
        podil_odhad           decimal(9,6)  NULL,
        vymera_dle_podilu     decimal(14,2) NULL,

        duvod                 nvarchar(400) NULL,
        prepocteno            datetime2     NOT NULL DEFAULT SYSDATETIME(),

        CONSTRAINT PK_Valuo_karta_parcely PRIMARY KEY (cislo_vkladu, gml_id)
    );
    CREATE INDEX IX_karta_parcely_gml ON dbo.Valuo_karta_parcely (gml_id);
    CREATE INDEX IX_karta_parcely_vlastnictvi ON dbo.Valuo_karta_parcely (vlastnictvi);
    PRINT 'Valuo_karta_parcely: založena';
END
GO

/* ---------------------------------------------------------------------------
   5. sp_prepocet_karty_okoli — prostorová vodítka (nejdražší část)

   Dávkuje PO KATASTRÁLNÍCH ÚZEMÍCH: parcely jednoho k. ú. leží blízko sebe
   a prostorový index je najde naráz. Měřeno 24. 10. 2026 — 654 parcel
   Písnice dalo 6 381 vazeb hluboko pod minutou.

   Sousedy a stavby na nich hledá DVĚMA KROKY: prostorový join a korelovaný
   EXISTS v jednom dotazu optimalizátor nezvládne (poučení z kroku 33).

   @max_sekund je strop, po kterém se smyčka sama ukončí a vrátí stav. Je
   tu kvůli spojení asistenta, které zabalí volání do transakce a po minutě
   celé vrátí — bez stropu by se neuložilo nic. Volá se opakovaně, dokud
   zbyva_ku není nula. Z Pythonu pod účtem Windows dej @max_sekund vysoké.

   @jen_nove = 1 zpracuje jen parcely, které v Valuo_karta_okoli ještě
   nejsou (tabulka je zároveň evidencí); @jen_nove = 0 přepočítá vše,
   což je potřeba po obnově RÚIANu.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_prepocet_karty_okoli
    @jen_nove    bit = 1,
    @limit_ku    int = NULL,
    @kod_ku      int = NULL,
    @max_sekund  int = 45,
    @podrobne    bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start datetime2 = SYSDATETIME();

    IF OBJECT_ID('tempdb..#ku')      IS NOT NULL DROP TABLE #ku;
    IF OBJECT_ID('tempdb..#parcely') IS NOT NULL DROP TABLE #parcely;
    IF OBJECT_ID('tempdb..#sousedi') IS NOT NULL DROP TABLE #sousedi;

    CREATE TABLE #ku (poradi int IDENTITY(1,1) PRIMARY KEY, kod_ku int NOT NULL);
    CREATE TABLE #parcely (gml_id varchar(50) PRIMARY KEY, kn_id int NOT NULL);
    CREATE TABLE #sousedi (gml_id varchar(50) NOT NULL, kod_parcely bigint NOT NULL,
                           PRIMARY KEY (gml_id, kod_parcely));

    INSERT INTO #ku (kod_ku)
    SELECT DISTINCT k.kod_ku
    FROM dbo.KN_parcel_data k
    WHERE k.geo_plocha IS NOT NULL AND k.kod_ku IS NOT NULL
      AND (@kod_ku IS NULL OR k.kod_ku = @kod_ku)
      AND (@jen_nove = 0
           OR NOT EXISTS (SELECT 1 FROM dbo.Valuo_karta_okoli o WHERE o.gml_id = k.gml_id))
    ORDER BY k.kod_ku;

    DECLARE @celkem int = (SELECT COUNT(*) FROM #ku);
    IF @limit_ku IS NOT NULL AND @limit_ku < @celkem SET @celkem = @limit_ku;
    IF @celkem = 0
    BEGIN
        SELECT 0 AS zpracovano_ku, 0 AS zbyva_ku, 0 AS parcel, 0 AS vazeb, 'nic ke zpracovani' AS stav;
        RETURN;
    END

    DECLARE @i int = 1, @k int, @vlozeno int = 0, @vazeb int = 0, @stav varchar(30) = 'hotovo';

    WHILE @i <= @celkem
    BEGIN
        IF DATEDIFF(second, @start, SYSDATETIME()) >= @max_sekund
        BEGIN
            SET @stav = 'preruseno casovym stropem';
            BREAK;
        END

        SELECT @k = kod_ku FROM #ku WHERE poradi = @i;

        DELETE FROM #parcely;
        INSERT INTO #parcely (gml_id, kn_id)
        SELECT k.gml_id, MIN(k.id)
        FROM dbo.KN_parcel_data k
        WHERE k.kod_ku = @k AND k.geo_plocha IS NOT NULL
          AND (@jen_nove = 0
               OR NOT EXISTS (SELECT 1 FROM dbo.Valuo_karta_okoli o WHERE o.gml_id = k.gml_id))
        GROUP BY k.gml_id;

        /* KROK 1: sousedi z RUIAN_parcely. Bez omezení na k. ú. — soused
           může ležet za hranicí; prostorový index si poradí. */
        DELETE FROM #sousedi;
        INSERT INTO #sousedi (gml_id, kod_parcely)
        SELECT DISTINCT p.gml_id, r.kod_parcely
        FROM #parcely p
        JOIN dbo.KN_parcel_data k ON k.id = p.kn_id
        JOIN dbo.RUIAN_parcely r ON r.geo_plocha.STIntersects(k.geo_plocha) = 1
        WHERE 'CP.' + CAST(r.kod_parcely AS varchar(20)) <> p.gml_id;
        SET @vazeb = @vazeb + @@ROWCOUNT;

        /* KROK 2: které ze sousedů nesou stavbu. Řádek se zakládá KAŽDÉ
           parcele, i bez souseda — jinak by se počítala při každém běhu
           znovu (poučení z KN_parcel_UP_stav). */
        WITH se_stavbou AS (
            SELECT s.gml_id, COUNT(DISTINCT s.kod_parcely) AS cizich,
                   COUNT(DISTINCT CASE WHEN so.parcela_id IS NOT NULL THEN s.kod_parcely END) AS se_stavbou
            FROM #sousedi s
            LEFT JOIN dbo.RUIAN_stavebni_objekty so ON so.parcela_id = s.kod_parcely
            GROUP BY s.gml_id
        )
        MERGE dbo.Valuo_karta_okoli AS t
        USING (SELECT p.gml_id, @k AS kod_ku, ISNULL(ss.cizich, 0) AS cizich,
                      ISNULL(ss.se_stavbou, 0) AS se_stavbou
               FROM #parcely p LEFT JOIN se_stavbou ss ON ss.gml_id = p.gml_id) AS s
        ON t.gml_id = s.gml_id
        WHEN MATCHED THEN UPDATE SET
            t.kod_ku = s.kod_ku, t.cizich_sousedu = s.cizich,
            t.cizich_se_stavbou = s.se_stavbou, t.prepocteno = SYSDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (gml_id, kod_ku, cizich_sousedu, cizich_se_stavbou, prepocteno)
            VALUES (s.gml_id, s.kod_ku, s.cizich, s.se_stavbou, SYSDATETIME());
        SET @vlozeno = @vlozeno + @@ROWCOUNT;

        SET @i = @i + 1;
    END

    SELECT @i - 1 AS zpracovano_ku,
           (SELECT COUNT(DISTINCT k.kod_ku) FROM dbo.KN_parcel_data k
            WHERE k.geo_plocha IS NOT NULL AND k.kod_ku IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM dbo.Valuo_karta_okoli o WHERE o.gml_id = k.gml_id)) AS zbyva_ku,
           @vlozeno AS parcel, @vazeb AS vazeb, @stav AS stav;
END
GO

/* ---------------------------------------------------------------------------
   6. sp_prepocet_karty — role, komponenty a výměry

   Nepracuje inkrementálně: přepočítá celou Valuo_karta_parcely, stejně jako
   ostatní přepočtové procedury. Prostorová vodítka si nepočítá, bere je
   hotová z Valuo_karta_okoli.

   @cislo_vkladu omezí zápis na jeden vklad (ladění). Počet hlavních
   nemovitostí se i tehdy počítá NAPŘÍČ všemi vklady — jinak by parcela
   vyšla jako výhradní jen proto, že se díváme na jeden prodej.

   TŘI OPRAVY NALEZENÉ OVĚŘENÍM NA VZORCÍCH (24. 10. 2026):

   1. Podíl vyžaduje i DVA RŮZNÉ VKLADY, ne jen dvě hlavní nemovitosti.
      Vklad V-9837/2023-101 (Libuš) obsahuje dům i garáž, tedy dvě hlavní
      nemovitosti uvnitř jednoho vkladu, a všechny jeho parcely proto
      vycházely jako podílové. Sám o sobě podíl nedokládá.

   2. Na KOTVU vodítka 2-4 neplatí. Parcela 1089/1 (Libuš) nesoucí rodinný
      dům vyšla jako "neověřeno", protože se dotýká čtyř cizích parcel se
      stavbou. Parcela, která nese hlavní nemovitost, není společná cesta;
      v hustší zástavbě se cizích domů dotýká běžně.

   3. Komponenty se počítají JEN PŘES VÝHRADNÍ PARCELY. Řetězení přes
      podílovou parcelu je věcně špatně: v Písnici se stání 835/213 dotýká
      společné cesty 835/204 a ta parcely s domem, takže se celý vklad slil
      do jednoho celku — ačkoli stání je od domu právě tou cestou oddělené
      (znalec to potvrdil rozklikem v katastru; vzdálenost 9,4 m).
      Podílová parcela do komponent nevstupuje a roli dostává podle
      PŘÍMÉHO dotyku s celkem.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_prepocet_karty
    @cislo_vkladu varchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @mh int   = (SELECT CAST(hodnota AS int)   FROM dbo.CIS_karta_parametry WHERE parametr = 'min_hlavnich_pro_podil');
    DECLARE @km float = (SELECT CAST(hodnota AS float) FROM dbo.CIS_karta_parametry WHERE parametr = 'komp_max_cesta');
    DECLARE @sm float = (SELECT CAST(hodnota AS float) FROM dbo.CIS_karta_parametry WHERE parametr = 'sirka_max_cesta_m');
    DECLARE @ms int   = (SELECT CAST(hodnota AS int)   FROM dbo.CIS_karta_parametry WHERE parametr = 'min_staveb_v_okoli');
    DECLARE @tol float= (SELECT CAST(hodnota AS float) FROM dbo.CIS_karta_parametry WHERE parametr = 'tolerance_sousednosti_m');
    DECLARE @dnes date = CAST(SYSDATETIME() AS date);

    IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;
    IF OBJECT_ID('tempdb..#hl') IS NOT NULL DROP TABLE #hl;
    IF OBJECT_ID('tempdb..#hlavni') IS NOT NULL DROP TABLE #hlavni;
    IF OBJECT_ID('tempdb..#druh') IS NOT NULL DROP TABLE #druh;
    IF OBJECT_ID('tempdb..#hrany') IS NOT NULL DROP TABLE #hrany;

    CREATE TABLE #p (cislo_vkladu varchar(100) NOT NULL, gml_id varchar(50) NOT NULL, kn_id int NOT NULL,
        parcel_number varchar(20) NULL, kod_ku int NULL, vymera_m2 float NULL, je_kotva bit NOT NULL,
        kotva_priorita int NULL, druh_valuo varchar(200) NULL, druh_ruian_kod tinyint NULL,
        hlavnich int NULL, vkladu int NULL, je_komunikace bit NULL, komp float NULL, sirka float NULL,
        tvar_cesty bit NULL, staveb int NULL, okoli_zname bit NULL, role_trvala nvarchar(20) NULL,
        role_zdroj varchar(10) NULL, hlavnich_max int NULL, vlastnictvi nvarchar(20) NULL, lab int NULL,
        PRIMARY KEY (cislo_vkladu, gml_id));

    /* kotva_priorita: hlavní kotvou je parcela nesoucí OBYTNOU nemovitost.
       Abecední výběr by u vkladu "dům + garáž" určil celek podle garáže. */
    INSERT INTO #p (cislo_vkladu, gml_id, kn_id, parcel_number, kod_ku, vymera_m2, je_kotva, kotva_priorita)
    SELECT d.cislo_vkladu, k.gml_id, MIN(k.id), MIN(k.parcel_number), MIN(k.kod_ku), MAX(k.areaValue_m2),
      MAX(CASE WHEN d.nemovitost IN ('budova','jednotka','---') THEN 1 ELSE 0 END),
      MIN(CASE WHEN d.nemovitost NOT IN ('budova','jednotka','---') THEN 99
               WHEN d.typ IN (N'rodinný dům', N'objekt k bydlení') THEN 1
               WHEN d.typ IN (N'byt', N'bytový dům') THEN 2
               WHEN d.typ = N'stavba pro rodinnou rekreaci' THEN 3
               WHEN d.typ IN (N'ateliér', N'jiný nebytový prostor') THEN 4
               WHEN d.typ = N'jiná stavba' THEN 8
               WHEN d.typ = N'garáž' THEN 9 ELSE 5 END)
    FROM dbo.Valuo_data d JOIN dbo.KN_parcel_data k ON k.id_valuo = d.id
    WHERE @cislo_vkladu IS NULL OR d.cislo_vkladu = @cislo_vkladu
    GROUP BY d.cislo_vkladu, k.gml_id;

    CREATE TABLE #hl (cislo_vkladu varchar(100) NOT NULL, klic nvarchar(300) NOT NULL, PRIMARY KEY (cislo_vkladu, klic));
    INSERT INTO #hl SELECT DISTINCT d.cislo_vkladu, ISNULL(d.adresa,N'?')+N'|'+ISNULL(d.jednotka_oznaceni,N'')
    FROM dbo.Valuo_data d WHERE d.nemovitost IN ('budova','jednotka');

    CREATE TABLE #hlavni (gml_id varchar(50) PRIMARY KEY, hlavnich int NULL, vkladu int NOT NULL);
    INSERT INTO #hlavni SELECT k.gml_id, NULLIF(COUNT(DISTINCT h.klic),0), COUNT(DISTINCT d.cislo_vkladu)
    FROM dbo.KN_parcel_data k JOIN dbo.Valuo_data d ON d.id = k.id_valuo
    LEFT JOIN #hl h ON h.cislo_vkladu = d.cislo_vkladu
    WHERE k.gml_id IN (SELECT gml_id FROM #p) GROUP BY k.gml_id;

    /* OPRAVA 1: podíl vyžaduje dva různé vklady */
    MERGE dbo.Valuo_parcely_role AS t
    USING (SELECT gml_id, hlavnich FROM #hlavni WHERE hlavnich >= @mh AND vkladu >= @mh) AS s
    ON t.gml_id = s.gml_id
    WHEN MATCHED AND t.zdroj = 'data' THEN UPDATE SET t.vlastnictvi = N'podílová',
        t.hlavnich_max = CASE WHEN s.hlavnich > ISNULL(t.hlavnich_max,0) THEN s.hlavnich ELSE t.hlavnich_max END,
        t.naposled_overeno = @dnes
    WHEN NOT MATCHED THEN INSERT (gml_id, vlastnictvi, zdroj, hlavnich_max, prvni_zjisteno, naposled_overeno, poznamka)
        VALUES (s.gml_id, N'podílová', 'data', s.hlavnich, @dnes, @dnes,
          N'Zjištěno z dat: parcela doprovází ' + CAST(s.hlavnich AS nvarchar(10)) + N' různých hlavních nemovitostí.');

    CREATE TABLE #druh (gml_id varchar(50) PRIMARY KEY, druh_valuo varchar(200) NULL, druh_ruian_kod tinyint NULL);
    INSERT INTO #druh SELECT p.gml_id,
      COALESCE((SELECT MIN(d2.typ) FROM dbo.KN_parcel_data k2 JOIN dbo.Valuo_data d2 ON d2.id=k2.id_valuo
                WHERE k2.gml_id=p.gml_id AND d2.nemovitost='parcela'),
               (SELECT MIN(d3.typ) FROM dbo.KN_parcel_data k3 JOIN dbo.Valuo_data d3 ON d3.id=k3.id_valuo
                WHERE k3.gml_id=p.gml_id)),
      (SELECT MIN(r.druh_pozemku_kod) FROM dbo.RUIAN_parcely r WHERE r.gml_id=p.gml_id)
    FROM (SELECT DISTINCT gml_id FROM #p) p;

    UPDATE p SET p.druh_valuo = dr.druh_valuo, p.druh_ruian_kod = dr.druh_ruian_kod,
        p.hlavnich = hl.hlavnich, p.vkladu = hl.vkladu,
        p.je_komunikace = CASE WHEN dr.druh_valuo = N'ostatní komunikace' THEN 1 ELSE 0 END,
        p.komp = CASE WHEN k.geo_plocha IS NULL OR p.vymera_m2 <= 0 THEN NULL
                      ELSE 4*PI()*p.vymera_m2/SQUARE(k.geo_plocha.STLength()) END,
        p.sirka = CASE WHEN k.geo_plocha IS NULL OR p.vymera_m2 <= 0 THEN NULL
                       ELSE 2*p.vymera_m2/k.geo_plocha.STLength() END,
        p.staveb = ISNULL(o.cizich_se_stavbou, 0),
        p.okoli_zname = CASE WHEN o.gml_id IS NULL THEN 0 ELSE 1 END,
        p.role_trvala = r.vlastnictvi, p.role_zdroj = r.zdroj, p.hlavnich_max = r.hlavnich_max
    FROM #p p
    LEFT JOIN #druh dr ON dr.gml_id = p.gml_id
    LEFT JOIN #hlavni hl ON hl.gml_id = p.gml_id
    LEFT JOIN dbo.KN_parcel_data k ON k.id = p.kn_id
    LEFT JOIN dbo.Valuo_karta_okoli o ON o.gml_id = p.gml_id
    LEFT JOIN dbo.Valuo_parcely_role r ON r.gml_id = p.gml_id;

    UPDATE #p SET tvar_cesty = CASE WHEN komp IS NOT NULL AND komp < @km AND sirka IS NOT NULL AND sirka < @sm THEN 1 ELSE 0 END;

    /* OPRAVA 2: na kotvu vodítka 2-4 neplatí */
    UPDATE #p SET vlastnictvi =
        CASE WHEN role_zdroj = N'ruční' THEN role_trvala
             WHEN hlavnich >= @mh AND vkladu >= @mh THEN N'podílová'
             WHEN role_trvala = N'podílová' THEN N'podílová'
             WHEN je_kotva = 1 THEN N'výhradní'
             WHEN je_komunikace = 1 OR tvar_cesty = 1 OR staveb >= @ms
                  OR (hlavnich IS NULL AND vkladu >= @mh) THEN N'neověřeno'
             ELSE N'výhradní' END;
    UPDATE #p SET lab = kn_id;

    /* OPRAVA 3: hrany jen mezi výhradními parcelami */
    CREATE TABLE #hrany (cislo_vkladu varchar(100) NOT NULL, a varchar(50) NOT NULL, b varchar(50) NOT NULL,
        PRIMARY KEY (cislo_vkladu, a, b));
    INSERT INTO #hrany SELECT x.cislo_vkladu, x.a, x.b FROM (
      SELECT p1.cislo_vkladu, p1.gml_id AS a, p2.gml_id AS b
      FROM #p p1 JOIN #p p2 ON p2.cislo_vkladu = p1.cislo_vkladu AND p2.gml_id <> p1.gml_id
      JOIN dbo.KN_parcel_data k1 ON k1.id = p1.kn_id
      JOIN dbo.KN_parcel_data k2 ON k2.id = p2.kn_id
      WHERE p1.vlastnictvi = N'výhradní' AND p2.vlastnictvi = N'výhradní'
        AND k1.geo_plocha IS NOT NULL AND k2.geo_plocha IS NOT NULL
        AND k1.geo_plocha.STDistance(k2.geo_plocha) <= @tol) x;

    DECLARE @zmen int = 1, @kolo int = 0;
    WHILE @zmen > 0 AND @kolo < 50
    BEGIN
        UPDATE p SET lab = x.minlab FROM #p p
        JOIN (SELECT h.cislo_vkladu, h.a, MIN(p2.lab) AS minlab FROM #hrany h
              JOIN #p p2 ON p2.cislo_vkladu = h.cislo_vkladu AND p2.gml_id = h.b
              GROUP BY h.cislo_vkladu, h.a) x ON x.cislo_vkladu = p.cislo_vkladu AND x.a = p.gml_id
        WHERE x.minlab < p.lab;
        SET @zmen = @@ROWCOUNT; SET @kolo = @kolo + 1;
    END
    IF @kolo >= 50 PRINT '   [!] sireni nalepek nedobehlo do 50 kol';

    IF @cislo_vkladu IS NULL
        DELETE FROM dbo.Valuo_karta_parcely;
    ELSE
        DELETE FROM dbo.Valuo_karta_parcely WHERE cislo_vkladu = @cislo_vkladu;

    ;WITH kl AS (
      SELECT cislo_vkladu, lab AS lab_kotvy, kn_id AS kn_kotvy FROM (
        SELECT cislo_vkladu, lab, kn_id,
               ROW_NUMBER() OVER (PARTITION BY cislo_vkladu ORDER BY kotva_priorita, vymera_m2 DESC, kn_id) AS rn
        FROM #p WHERE je_kotva = 1) x WHERE rn = 1),
    dotyk AS (SELECT DISTINCT p.cislo_vkladu, p.gml_id FROM #p p
      JOIN #p q ON q.cislo_vkladu = p.cislo_vkladu AND q.gml_id <> p.gml_id
      JOIN kl ON kl.cislo_vkladu = p.cislo_vkladu
      JOIN dbo.KN_parcel_data k1 ON k1.id = p.kn_id
      JOIN dbo.KN_parcel_data k2 ON k2.id = q.kn_id
      WHERE p.vlastnictvi <> N'výhradní' AND q.vlastnictvi = N'výhradní' AND q.lab = kl.lab_kotvy
        AND k1.geo_plocha IS NOT NULL AND k2.geo_plocha IS NOT NULL
        AND k1.geo_plocha.STDistance(k2.geo_plocha) <= @tol)
    INSERT INTO dbo.Valuo_karta_parcely (cislo_vkladu, gml_id, kn_id, parcel_number, kod_ku, vymera_m2,
      druh_valuo, druh_ruian_kod, vlastnictvi, vlastnictvi_zdroj, prostorova_role, komponenta, je_kotva,
      sousedi_s_kotvou, vzdalenost_od_kotvy_m, sporna, sporna_duvod, hlavnich_nemovitosti, vkladu_s_parcelou,
      je_druh_komunikace, kompaktnost, prum_sirka_m, tvar_cesty, cizich_se_stavbou, podil_odhad,
      vymera_dle_podilu, duvod, prepocteno)
    SELECT p.cislo_vkladu, p.gml_id, p.kn_id, p.parcel_number, p.kod_ku, p.vymera_m2,
      p.druh_valuo, p.druh_ruian_kod, p.vlastnictvi,
      CASE WHEN p.role_zdroj = N'ruční' THEN N'ruční' WHEN p.vlastnictvi = N'výhradní' THEN NULL ELSE 'data' END,
      CASE WHEN kl.lab_kotvy IS NULL THEN N'bez kotvy'
           WHEN p.vlastnictvi = N'výhradní' AND p.lab = kl.lab_kotvy
                THEN CASE WHEN p.je_kotva = 1 THEN N'kotva' ELSE N'celek' END
           WHEN p.je_kotva = 1 THEN N'kotva'
           WHEN p.vlastnictvi <> N'výhradní' AND dt.gml_id IS NOT NULL THEN N'celek'
           ELSE N'oddělená' END,
      DENSE_RANK() OVER (PARTITION BY p.cislo_vkladu ORDER BY p.lab), p.je_kotva,
      CASE WHEN kl.lab_kotvy IS NULL THEN NULL WHEN p.lab = kl.lab_kotvy OR dt.gml_id IS NOT NULL THEN 1 ELSE 0 END,
      CASE WHEN p.kn_id = kl.kn_kotvy OR kl.kn_kotvy IS NULL THEN NULL
           ELSE (SELECT CAST(kk.geo_plocha.STDistance(kp2.geo_plocha) AS decimal(10,2))
                 FROM dbo.KN_parcel_data kk, dbo.KN_parcel_data kp2
                 WHERE kk.id = p.kn_id AND kp2.id = kl.kn_kotvy) END,
      CASE WHEN p.vlastnictvi = N'neověřeno' THEN 1 WHEN p.okoli_zname = 0 THEN 1 ELSE 0 END,
      CASE WHEN p.vlastnictvi = N'neověřeno' THEN N'Vypadá jako společná, ale v datech je jen '
             + CAST(ISNULL(p.hlavnich,0) AS nvarchar(10)) + N' hlavní nemovitost.'
           WHEN p.okoli_zname = 0 THEN N'Okolí parcely není v RÚIANu — vodítko o cizích stavbách nelze použít.'
           ELSE NULL END,
      p.hlavnich, p.vkladu, p.je_komunikace, CAST(p.komp AS decimal(6,3)), CAST(p.sirka AS decimal(10,2)),
      p.tvar_cesty, p.staveb,
      CASE WHEN p.vlastnictvi = N'podílová' AND ISNULL(p.hlavnich,0) > 0 THEN CAST(1.0/p.hlavnich AS decimal(9,6)) END,
      CASE WHEN p.vlastnictvi = N'podílová' AND ISNULL(p.hlavnich,0) > 0 THEN CAST(p.vymera_m2*1.0/p.hlavnich AS decimal(14,2)) END,
      STUFF(
        CASE WHEN p.je_kotva = 1 THEN N'; nese hlavní nemovitost' ELSE N'' END +
        CASE WHEN p.hlavnich >= @mh AND p.vkladu >= @mh THEN N'; doprovází ' + CAST(p.hlavnich AS nvarchar(10)) + N' různých hlavních nemovitostí v ' + CAST(p.vkladu AS nvarchar(10)) + N' vkladech' ELSE N'' END +
        CASE WHEN p.role_zdroj = N'ruční' THEN N'; označeno ručně znalcem' ELSE N'' END +
        CASE WHEN p.je_kotva = 0 AND p.je_komunikace = 1 THEN N'; vedena jako ostatní komunikace' ELSE N'' END +
        CASE WHEN p.je_kotva = 0 AND p.tvar_cesty = 1 THEN N'; tvar pásu (kompaktnost ' + CAST(CAST(p.komp AS decimal(4,2)) AS nvarchar(10))
             + N', šířka ' + CAST(CAST(p.sirka AS decimal(6,1)) AS nvarchar(10)) + N' m)' ELSE N'' END +
        CASE WHEN p.je_kotva = 0 AND p.staveb >= @ms THEN N'; sousedí s ' + CAST(p.staveb AS nvarchar(10)) + N' cizími parcelami se stavbou' ELSE N'' END +
        CASE WHEN p.je_kotva = 0 AND kl.lab_kotvy IS NOT NULL
                  AND NOT (p.vlastnictvi = N'výhradní' AND p.lab = kl.lab_kotvy) AND dt.gml_id IS NULL
             THEN N'; s celkem přímo nesousedí' ELSE N'' END, 1, 2, N''),
      SYSDATETIME()
    FROM #p p
    LEFT JOIN kl ON kl.cislo_vkladu = p.cislo_vkladu
    LEFT JOIN dotyk dt ON dt.cislo_vkladu = p.cislo_vkladu AND dt.gml_id = p.gml_id;

    SELECT (SELECT COUNT(*) FROM dbo.Valuo_karta_parcely) AS radku_karty, @kolo AS kol_sireni;
END
GO

/* ---------------------------------------------------------------------------
   7. v_Valuo_karta_vkladu — JEDEN ŘÁDEK = JEDEN VKLAD

   Tohle je ta karta. HTML stránka je jen její vykreslení; nic, co je na
   stránce vidět, na ní nevzniká.

   Pohled ZÁMĚRNĚ nejoinuje v_Valuo_vzorek_q — ten je sám na hranici 60 s.
   Karta stojí vedle vzorku a joinuje se na něj přes cislo_vkladu.

   Pozor na rozdíl, kvůli kterému karta vznikla:
     vymera_pozemku_vse     = celý předmět vkladu (v Písnici 4 532 m²)
     vymera_vyhradni_celek  = funkční celek ve výhradním vlastnictví (108 m²)
   Rozdíl mezi nimi JE ta informace. Karta ukazuje obojí a nenutí vybrat.

   Reprezentativní hlavní nemovitost se vybírá podle obytného druhu, ne
   abecedně: u vkladu "dům + garáž" by jinak vyšla garáž (Libuš).
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.v_Valuo_karta_vkladu
AS
WITH vklad AS (
    SELECT d.cislo_vkladu,
        MIN(d.datum_zplatneni) AS datum_zplatneni, MIN(d.rok) AS rok,
        MAX(d.cena_Kc) AS cena_Kc, MIN(d.mena) AS mena, MIN(d.kod_ku) AS kod_ku,
        MIN(d.vklad_klasifikace) AS klasifikace, MIN(d.vklad_nemovitosti) AS nemovitosti_ve_vkladu,
        SUM(CASE WHEN d.nemovitost = 'budova'   THEN 1 ELSE 0 END) AS pocet_budov,
        SUM(CASE WHEN d.nemovitost = 'jednotka' THEN 1 ELSE 0 END) AS pocet_jednotek,
        SUM(CASE WHEN d.nemovitost = 'parcela'  THEN 1 ELSE 0 END) AS pocet_parcel_valuo
    FROM dbo.Valuo_data d GROUP BY d.cislo_vkladu
),
hlavni_agr AS (
    SELECT d.cislo_vkladu,
        MAX(CASE WHEN d.typ_plochy = N'Podlahová plocha' THEN d.plocha END) AS plocha_podlahova_valuo,
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
                          WHEN d.typ IN (N'jiná stavba') THEN 8
                          WHEN d.typ IN (N'garáž') THEN 9
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
    rv.ruian_podlahova_plocha, rv.ruian_zastavena_plocha, rv.ruian_obestaveny_prostor,
    rv.ruian_pocet_podlazi, rv.ruian_pocet_bytu, rv.ruian_rok, rv.ruian_rok_presny,
    rv.ruian_pasmo, rv.ruian_druh_konstrukce, rv.ruian_vytapeni, rv.ruian_vytah,
    rv.pripojeni_vodovod_kod, rv.pripojeni_kanalizace_kod, rv.pripojeni_plyn_kod,
    rv.ruian_pomer_pp_op, rv.ruian_plocha_podezrela,
    CASE WHEN ISNULL(ha.plocha_podlahova_valuo, rv.ruian_podlahova_plocha) > 0
         THEN CAST(v.cena_Kc / ISNULL(ha.plocha_podlahova_valuo, rv.ruian_podlahova_plocha) AS decimal(14,2)) END AS jc_Kc_m2_podlahova,
    CASE WHEN k.vymera_vyhradni_celek > 0
         THEN CAST(v.cena_Kc / k.vymera_vyhradni_celek AS decimal(14,2)) END AS jc_Kc_m2_vyhradni_celek,
    CASE WHEN k.vymera_pozemku_vse > 0
         THEN CAST(v.cena_Kc / k.vymera_pozemku_vse AS decimal(14,2)) END AS jc_Kc_m2_vsech_pozemku,
    CASE WHEN rv.ruian_obestaveny_prostor > 0
         THEN CAST(v.cena_Kc / rv.ruian_obestaveny_prostor AS decimal(14,2)) END AS jc_Kc_m3
FROM vklad v
LEFT JOIN hlavni h ON h.cislo_vkladu = v.cislo_vkladu
LEFT JOIN hlavni_agr ha ON ha.cislo_vkladu = v.cislo_vkladu
LEFT JOIN druhy d ON d.cislo_vkladu = v.cislo_vkladu
LEFT JOIN karta k ON k.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku;
GO

/* ---------------------------------------------------------------------------
   8. Jak to spustit

   POZOR: účet claude_reader NEMÁ oprávnění EXECUTE na procedury (zjištěno
   24. 10. 2026). Smí je vytvořit a změnit, ale ne spustit. Procedury proto
   pouští Python pod účtem Windows, nebo SSMS. Chce-li znalec, aby je
   spouštěl asistent sám, stačí jednou v SSMS:

       GRANT EXECUTE ON SCHEMA::dbo TO claude_reader;

   Pořadí spuštění:
       EXEC dbo.sp_prepocet_karty_okoli @jen_nove = 1, @max_sekund = 3600;
       EXEC dbo.sp_prepocet_karty;

   První běh počítá prostorová vodítka pro 40 329 parcel v 826 k. ú.
   a je jednorázový; další běhy doplní jen nové parcely.
   --------------------------------------------------------------------------- */
PRINT '34_karta_vkladu.sql: objekty vytvoreny.';
GO
