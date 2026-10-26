-- =============================================================================
-- 39_mapa_data.sql — podkladová tabulka pro mapovou aplikaci
-- =============================================================================
-- Databáze: VALUO        Krok: 39        Datum: 24. 10. 2026
--
-- Proč samostatná tabulka
-- -----------------------
-- Pohled v_Valuo_karta_vkladu počítá za běhu z pěti tabulek. Jeden dotaz
-- přes všech 49 788 vkladů trvá přes minutu, takže mapa, která se překresluje
-- při každém posunu, z něj číst nemůže. Valuo_mapa je plochý výtah: jeden
-- řádek na vklad, souřadnice, kategorie, jednotková cena a popisek. Nic víc,
-- zato s indexy na to, podle čeho se filtruje.
--
-- Shluk
-- -----
-- Byty v jednom domě mají ve Valuo_data tentýž bod — v Libuši jich na jedné
-- souřadnici leží 74. V mapě by se překryly do jediné značky. Sloupec
-- shluk_id je zaokrouhlená souřadnice; aplikace podle něj značku označí
-- počtem vkladů a po kliknutí nabídne seznam jednotek.
--
-- Kategorie
-- ---------
-- Barevná škála jednotkových cen se počítá v rámci kategorie, ne napříč.
-- Míchat Kč/m² podlahové plochy bytu s Kč/m² orné půdy nedává smysl.
--
-- Plnění
-- ------
--    EXEC dbo.sp_prepocet_mapy                  -- vše, co chybí
--    EXEC dbo.sp_prepocet_mapy @prepocitat = 1  -- znovu celé
-- Volá se po sp_prepocet_karet_davka, protože u pozemků je jednotková cena
-- známá až z karty. U jednotek a budov je známá hned, ty se naplní i bez ní.
-- =============================================================================
GO

IF OBJECT_ID('dbo.Valuo_mapa', 'U') IS NULL
CREATE TABLE dbo.Valuo_mapa (
    cislo_vkladu      varchar(50)   NOT NULL PRIMARY KEY,
    kod_ku            int           NULL,
    kat_uzemi         nvarchar(200) NULL,
    obec              nvarchar(200) NULL,
    lat               decimal(9,6)  NULL,   -- od 25. 10. 2026 je u jednotek
    lon               decimal(9,6)  NULL,   -- a budov bodem STŘED STAVBY dle
                                            -- RÚIANu, ne definiční bod parcely
    bod_zdroj         varchar(24)   NULL,   -- „stavba RÚIAN" / „definiční bod"
    bod_posun_m       decimal(8,1)  NULL,   -- o kolik se značka přesunula
    nalez_bod_daleko  bit           NULL,   -- stavba se našla, ale dál než
                                            -- CIS_karta_parametry.bod_stavba_do_m
                                            -- (100 m): spárování je podezřelé
                                            -- a bod zůstal na definičním bodě
    shluk_id          varchar(32)   NULL,   -- klíč budovy = zaokrouhlený bod
    kategorie         varchar(20)   NULL,   -- CO TO JE: byt|rodinny_dum|
                                            -- bytovy_dum|pozemek|jednotka_jina|
                                            -- jine. Od 25. 10. 2026 se řídí
                                            -- nosnou skupinou (krok 46), ne
                                            -- klasifikací.
    klasifikace       varchar(20)   NULL,   -- ŠLO TO SPOČÍTAT: stará klasifikace
                                            -- vkladu (JC_JEDNOTKA, CELEK_BUDOVA,
                                            -- JC_PARCELY, PRAVO_STAVBY, NELZE).
                                            -- Od 25. 10. 2026 vlastní sloupec.
                                            -- Jeden sloupec se dvěma významy
                                            -- schovával 8 905 bytů mezi „jiné"
                                            -- jen proto, že se s bytem prodávaly
                                            -- podíly na nebytových prostorech.
    druh              varchar(100)  NULL,
    jednotka_oznaceni nvarchar(50)  NULL,
    adresa            varchar(300)  NULL,
    datum_zplatneni   date          NULL,
    rok               int           NULL,
    cena_Kc           decimal(18,2) NULL,
    cena_m2           decimal(14,2) NULL,
    jc_orientacni     bit           NULL,   -- 1 = nerozklíčovatelný balík
                                            -- pozemků: žádná parcela se
                                            -- nekvalifikovala jako nosná,
                                            -- cena se dělí součtem výměr všech
                                            -- parcel včetně podílů na
                                            -- komunikacích. Znalec ji chce
                                            -- vidět jako hrubý přehled, ale
                                            -- do mediánů ani do barevné škály
                                            -- nevstupuje (rozsah 0 až
                                            -- 1 152 580 Kč/m²).
    zaklad_ceny       nvarchar(100) NULL,   -- z čeho je cena_m2; od 25. 10.
                                            -- 2026 šíře 100: krok 45 zavedl
                                            -- složené popisy až 67 znaků
                                            -- („plocha jednotky dle Valuo
                                            --  + podíl × podlahová plocha
                                            --  domu dle RÚIAN"). Při 40 to
                                            -- MERGE celého k. ú. odrolovalo.
    plocha            decimal(14,2) NULL,   -- jmenovatel ceny_m2
    parcel_celkem     int           NULL,
    ma_kartu          bit           NOT NULL DEFAULT 0,
    -- pro filtry v aplikaci: co vklad obsahuje a údaje o stavbě z RÚIAN
    ma_budovu         bit           NULL,
    ma_jednotku       bit           NULL,
    ma_parcelu        bit           NULL,
    konstrukce        nvarchar(80)  NULL,
    rok_stavby        int           NULL,   -- rok dokončení stavby, ne rok prodeje
    podlazi           int           NULL,
    bytu_v_dome       int           NULL,
    prepocteno        datetime2     NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Valuo_mapa_vyber')
CREATE INDEX IX_Valuo_mapa_vyber ON dbo.Valuo_mapa (kategorie, lat, lon)
    INCLUDE (cena_m2, shluk_id, ma_kartu);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Valuo_mapa_shluk')
CREATE INDEX IX_Valuo_mapa_shluk ON dbo.Valuo_mapa (shluk_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Valuo_mapa_ku')
CREATE INDEX IX_Valuo_mapa_ku ON dbo.Valuo_mapa (kod_ku);
GO

-- Dodatečné sloupce, pokud tabulka už existuje ze starší verze
IF COL_LENGTH('dbo.Valuo_mapa', 'ma_budovu') IS NULL
ALTER TABLE dbo.Valuo_mapa ADD
    ma_budovu   bit          NULL,
    ma_jednotku bit          NULL,
    ma_parcelu  bit          NULL,
    konstrukce  nvarchar(80) NULL,
    rok_stavby  int          NULL,
    podlazi     int          NULL,
    bytu_v_dome int          NULL;
GO

-- Dodatečné sloupce a šíře z 25. 10. 2026 (kroky 45 a 46). Pouštět i nad
-- existující tabulkou — jinak první přepočet spadne na truncation nebo na
-- chybějící sloupec.
IF COL_LENGTH('dbo.Valuo_mapa', 'klasifikace') IS NULL
ALTER TABLE dbo.Valuo_mapa ADD klasifikace varchar(20) NULL;
GO
IF COL_LENGTH('dbo.Valuo_mapa', 'jc_orientacni') IS NULL
ALTER TABLE dbo.Valuo_mapa ADD jc_orientacni bit NULL;
GO
IF COL_LENGTH('dbo.Valuo_mapa', 'bod_zdroj') IS NULL
ALTER TABLE dbo.Valuo_mapa ADD bod_zdroj varchar(24) NULL,
                               bod_posun_m decimal(8,1) NULL,
                               nalez_bod_daleko bit NULL;
GO
IF COL_LENGTH('dbo.Valuo_mapa', 'zaklad_ceny') < 200   -- nvarchar: bajty, ne znaky
ALTER TABLE dbo.Valuo_mapa ALTER COLUMN zaklad_ceny nvarchar(100) NULL;
GO

-- POZOR: tělo procedury níž je verze z kroku 39 a je PŘEKONANÉ. Kroky 45 a 46
-- ji přepsaly (příznaky registru ploch, nosná nemovitost, kategorie podle nosné
-- skupiny, klasifikace ve vlastním sloupci, parametr @kod_ku_jen, fronta podle
-- zdroje novějšího než řádek mapy). Závazné znění je v záloze definic
-- `_definice\definice_RRRRMMDD.sql` z 42_export_definic.py; důvody v
-- `data/ROZHODNUTI.md`. Pustíš-li tenhle skript celý, procedura se vrátí
-- o dva kroky zpět a mapa se zase rozejde s pohledem.
CREATE OR ALTER PROCEDURE dbo.sp_prepocet_mapy
    @prepocitat bit = 0,
    @limit_ku int = 100000,
    @max_sekund int = 45
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME();
    DECLARE @ku int, @hotovo int = 0, @radku int = 0;

    /* Jede se po katastrálních územích, aby se to dalo přerušit. Do fronty
       jde k. ú., jehož některý vklad v mapě chybí, nebo kde přibyla karta
       u vkladu, který ji dřív neměl. */
    DECLARE @fronta TABLE (kod_ku int PRIMARY KEY);
    INSERT INTO @fronta (kod_ku)
    SELECT TOP (@limit_ku) d.kod_ku
    FROM (SELECT DISTINCT kod_ku FROM dbo.Valuo_data WHERE kod_ku IS NOT NULL) d
    WHERE @prepocitat = 1
       OR EXISTS (SELECT 1 FROM dbo.Valuo_data vd
                  WHERE vd.kod_ku = d.kod_ku
                    AND NOT EXISTS (SELECT 1 FROM dbo.Valuo_mapa m
                                    WHERE m.cislo_vkladu = vd.cislo_vkladu))
       OR EXISTS (SELECT 1 FROM dbo.Valuo_mapa m
                  WHERE m.kod_ku = d.kod_ku AND m.ma_kartu = 0
                    AND EXISTS (SELECT 1 FROM dbo.Valuo_karta_parcely kp
                                WHERE kp.cislo_vkladu = m.cislo_vkladu))
    ORDER BY d.kod_ku;

    DECLARE kurzor CURSOR LOCAL FAST_FORWARD FOR SELECT kod_ku FROM @fronta;
    OPEN kurzor;
    FETCH NEXT FROM kurzor INTO @ku;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        ;WITH body AS (
            /* Bod se bere z JEDNOHO řádku vkladu, ne jako MIN přes všechny —
               MIN(Lat) a MIN(Long) mohou pocházet z různých nemovitostí
               a výsledek pak neleží nikde. Pořadí je stejné jako u volby
               hlavní nemovitosti v pohledu. */
            SELECT cislo_vkladu, lat, lon FROM (
                SELECT d.cislo_vkladu, d.geo_bod.Lat AS lat, d.geo_bod.Long AS lon,
                       ROW_NUMBER() OVER (PARTITION BY d.cislo_vkladu ORDER BY
                           CASE WHEN d.nemovitost IN ('budova', 'jednotka') THEN 0
                                ELSE 1 END,
                           CASE WHEN d.typ IN (N'rodinný dům', N'objekt k bydlení') THEN 1
                                WHEN d.typ IN (N'byt', N'bytový dům') THEN 2
                                WHEN d.typ IN (N'stavba pro rodinnou rekreaci') THEN 3
                                WHEN d.typ IN (N'ateliér', N'jiný nebytový prostor') THEN 4
                                WHEN d.typ IN (N'garáž') THEN 9
                                WHEN d.typ IN (N'jiná stavba') THEN 8
                                ELSE 5 END,
                           ISNULL(d.plocha, 0) DESC, d.id) AS rn
                FROM dbo.Valuo_data d
                WHERE d.kod_ku = @ku AND d.geo_bod IS NOT NULL) x
            WHERE rn = 1
        ),
        slozeni AS (
            /* Co vklad obsahuje. Tři nezávislé příznaky, ne jedna hodnota —
               vklad s domem, garáží a zahradou je budova i parcela zároveň
               a ve filtru má vyjít na obojí. */
            SELECT d.cislo_vkladu,
                   MAX(CASE WHEN d.nemovitost = 'budova'   THEN 1 ELSE 0 END) AS ma_budovu,
                   MAX(CASE WHEN d.nemovitost = 'jednotka' THEN 1 ELSE 0 END) AS ma_jednotku,
                   MAX(CASE WHEN d.nemovitost = 'parcela'  THEN 1 ELSE 0 END) AS ma_parcelu
            FROM dbo.Valuo_data d WHERE d.kod_ku = @ku GROUP BY d.cislo_vkladu
        ),
        zdroj AS (
            SELECT v.cislo_vkladu, v.kod_ku, v.kat_uzemi, v.obec, b.lat, b.lon,
                   CONVERT(varchar(32), CAST(ROUND(b.lat, 5) AS decimal(9,5))) + '_' +
                   CONVERT(varchar(32), CAST(ROUND(b.lon, 5) AS decimal(9,5))) AS shluk_id,
                   CASE
                     WHEN v.klasifikace = 'JC_JEDNOTKA' AND v.hlavni_druh = N'byt' THEN 'byt'
                     WHEN v.klasifikace = 'JC_JEDNOTKA' THEN 'jednotka_jina'
                     WHEN v.klasifikace = 'JC_PARCELY' THEN 'pozemek'
                     WHEN v.hlavni_druh IN (N'rodinný dům', N'objekt k bydlení',
                                            N'stavba pro rodinnou rekreaci') THEN 'rodinny_dum'
                     WHEN v.hlavni_druh = N'bytový dům' THEN 'bytovy_dum'
                     ELSE 'jine' END AS kategorie,
                   v.hlavni_druh AS druh, v.jednotka_oznaceni, v.hlavni_adresa AS adresa,
                   CAST(v.datum_zplatneni AS date) AS datum_zplatneni, v.rok, v.cena_Kc,
                   COALESCE(v.jc_Kc_m2_podlahova, v.jc_Kc_m2_vsech_pozemku) AS cena_m2,
                   CASE WHEN v.jc_Kc_m2_podlahova IS NOT NULL
                        THEN ISNULL(v.plocha_podlahova_zdroj, N'podlahová plocha')
                        WHEN v.jc_Kc_m2_vsech_pozemku IS NOT NULL THEN N'výměra pozemků'
                   END AS zaklad_ceny,
                   COALESCE(v.plocha_podlahova_karty, v.vymera_pozemku_vse) AS plocha,
                   v.parcel_celkem,
                   CASE WHEN v.parcel_celkem IS NULL THEN 0 ELSE 1 END AS ma_kartu,
                   s.ma_budovu, s.ma_jednotku, s.ma_parcelu,
                   v.ruian_druh_konstrukce AS konstrukce,
                   v.ruian_rok AS rok_stavby,
                   v.ruian_pocet_podlazi AS podlazi,
                   v.ruian_pocet_bytu AS bytu_v_dome
            FROM dbo.v_Valuo_karta_vkladu v
            JOIN body b ON b.cislo_vkladu = v.cislo_vkladu
            LEFT JOIN slozeni s ON s.cislo_vkladu = v.cislo_vkladu
            WHERE v.kod_ku = @ku
        )
        MERGE dbo.Valuo_mapa AS cil
        USING zdroj AS z ON cil.cislo_vkladu = z.cislo_vkladu
        WHEN MATCHED THEN UPDATE SET
            cil.kod_ku = z.kod_ku, cil.kat_uzemi = z.kat_uzemi, cil.obec = z.obec,
            cil.lat = z.lat, cil.lon = z.lon, cil.shluk_id = z.shluk_id,
            cil.kategorie = z.kategorie, cil.druh = z.druh,
            cil.jednotka_oznaceni = z.jednotka_oznaceni, cil.adresa = z.adresa,
            cil.datum_zplatneni = z.datum_zplatneni, cil.rok = z.rok,
            cil.cena_Kc = z.cena_Kc, cil.cena_m2 = z.cena_m2,
            cil.zaklad_ceny = z.zaklad_ceny, cil.plocha = z.plocha,
            cil.parcel_celkem = z.parcel_celkem, cil.ma_kartu = z.ma_kartu,
            cil.ma_budovu = z.ma_budovu, cil.ma_jednotku = z.ma_jednotku,
            cil.ma_parcelu = z.ma_parcelu, cil.konstrukce = z.konstrukce,
            cil.rok_stavby = z.rok_stavby, cil.podlazi = z.podlazi,
            cil.bytu_v_dome = z.bytu_v_dome,
            cil.prepocteno = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (cislo_vkladu, kod_ku, kat_uzemi, obec, lat, lon, shluk_id, kategorie,
             druh, jednotka_oznaceni, adresa, datum_zplatneni, rok, cena_Kc,
             cena_m2, zaklad_ceny, plocha, parcel_celkem, ma_kartu,
             ma_budovu, ma_jednotku, ma_parcelu, konstrukce, rok_stavby,
             podlazi, bytu_v_dome, prepocteno)
            VALUES (z.cislo_vkladu, z.kod_ku, z.kat_uzemi, z.obec, z.lat, z.lon,
                    z.shluk_id, z.kategorie, z.druh, z.jednotka_oznaceni, z.adresa,
                    z.datum_zplatneni, z.rok, z.cena_Kc, z.cena_m2, z.zaklad_ceny,
                    z.plocha, z.parcel_celkem, z.ma_kartu,
                    z.ma_budovu, z.ma_jednotku, z.ma_parcelu, z.konstrukce,
                    z.rok_stavby, z.podlazi, z.bytu_v_dome, SYSDATETIME());

        SET @radku = @radku + @@ROWCOUNT;
        SET @hotovo = @hotovo + 1;
        IF DATEDIFF(SECOND, @t0, SYSDATETIME()) >= @max_sekund BREAK;
        FETCH NEXT FROM kurzor INTO @ku;
    END
    CLOSE kurzor; DEALLOCATE kurzor;

    /* Zbývá = kolik k. ú. by fronta ještě vzala. Dřívější "počet k. ú. bez
       řádku v mapě" byl zavádějící: Valuo_mapa.kod_ku pochází z pohledu,
       fronta z Valuo_data, a kde se liší, vypadalo k. ú. jako nezpracované,
       ačkoli všechny jeho vklady v mapě byly. */
    SELECT @hotovo AS zpracovano_ku, @radku AS radku,
           (SELECT COUNT(*) FROM (SELECT DISTINCT kod_ku FROM dbo.Valuo_data
                                  WHERE kod_ku IS NOT NULL) d
            WHERE EXISTS (SELECT 1 FROM dbo.Valuo_data vd
                          WHERE vd.kod_ku = d.kod_ku
                            AND NOT EXISTS (SELECT 1 FROM dbo.Valuo_mapa m
                                            WHERE m.cislo_vkladu = vd.cislo_vkladu))) AS zbyva_ku,
           DATEDIFF(SECOND, @t0, SYSDATETIME()) AS sekund;
END
GO
