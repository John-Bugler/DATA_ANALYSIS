/* ================================================================
   VALUO — ZÁLOHA DEFINIC POHLEDŮ A PROCEDUR
   Stav databáze k 25. 10. 2026, znacka na stavbu dle RUIAN.

   Export z sys.sql_modules, text beze změny.

   Obnova jednoho objektu: zkopíruj jeho blok, „CREATE“ přepiš
   na „CREATE OR ALTER“ a spusť v SSMS nad databází VALUO.

   Obsah (24 objektů):
     SQL_STORED_PROCEDURE   dbo.sp_detekce_hromadnych_prevodu    změněno 2026-10-23 18:59
     SQL_STORED_PROCEDURE   dbo.sp_detekce_prevodu_dle_ceny      změněno 2026-10-23 19:00
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_jednotkovych_cen     změněno 2026-10-24 13:55
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_karet_davka          změněno 2026-10-25 07:20
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_karty                změněno 2026-10-24 18:25
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_karty_okoli          změněno 2026-10-24 18:07
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_karty_tvar           změněno 2026-10-25 07:22
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_mapy                 změněno 2026-10-25 19:24
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_men                  změněno 2026-10-22 19:19
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_ploch                změněno 2026-10-25 16:47
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_prahu                změněno 2026-10-23 19:59
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_ruian_vzorku         změněno 2026-10-23 18:34
     SQL_STORED_PROCEDURE   dbo.sp_prepocet_typu_prevodu         změněno 2026-10-22 21:23
     VIEW                   dbo.v_cenove_hladiny                 změněno 2026-10-23 10:00
     VIEW                   dbo.v_KN_parcely                     změněno 2026-10-22 15:58
     VIEW                   dbo.v_RUIAN_budovy                   změněno 2026-10-23 18:24
     VIEW                   dbo.v_RUIAN_jednotky                 změněno 2026-10-23 17:29
     VIEW                   dbo.v_RUIAN_vzorek                   změněno 2026-10-23 18:24
     VIEW                   dbo.v_Valuo                          změněno 2026-10-22 11:23
     VIEW                   dbo.v_Valuo_karta_vkladu             změněno 2026-10-25 15:41
     VIEW                   dbo.v_Valuo_parcela_z_popisu         změněno 2026-10-22 21:45
     VIEW                   dbo.v_Valuo_vzorek                   změněno 2026-10-22 21:45
     VIEW                   dbo.v_Valuo_vzorek_q                 změněno 2026-10-24 13:55
     VIEW                   dbo.v_vklad_UP                       změněno 2026-10-23 15:40
   ================================================================ */

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_detekce_hromadnych_prevodu
   změněno 2026-10-23 18:59
   ------------------------------------------------------------------------ */

CREATE   PROCEDURE dbo.sp_detekce_hromadnych_prevodu
    @min_vkladu int = 5,
    @min_ploch  int = 3
AS
BEGIN
    SET NOCOUNT ON;
    /* Detektor podle JEDNOTKOVÉ ceny (krok 23).
       Od kroku 29 je v téže tabulce i detektor podle CELKOVÉ ceny,
       proto je všechno omezené na detektor = 'JC' — bez toho by
       NOT MATCHED BY SOURCE smazalo skupiny druhého detektoru. */

    WITH nove AS (
        SELECT  v.klasifikace, v.kat_uzemi, ISNULL(v.druh, '?') AS druh,
                v.jedn_cena_Kc_m2,
                COUNT(*) AS vkladu,
                COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                                        v.plocha_budovy_m2)) AS ruznych_ploch,
                MIN(v.cena_Kc) AS cena_min, MAX(v.cena_Kc) AS cena_max,
                MIN(v.rok) AS rok_min, MAX(v.rok) AS rok_max,
                MIN(COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                             v.plocha_budovy_m2)) AS plocha_min,
                MAX(COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                             v.plocha_budovy_m2)) AS plocha_max
        FROM dbo.v_Valuo_vzorek v
        WHERE v.jedn_cena_Kc_m2 > 0
        GROUP BY v.klasifikace, v.kat_uzemi, ISNULL(v.druh, '?'), v.jedn_cena_Kc_m2
        HAVING COUNT(*) >= @min_vkladu
           AND COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                                       v.plocha_budovy_m2)) >= @min_ploch
    )
    MERGE dbo.Valuo_hromadne_prevody AS t
    USING nove AS n
       ON  t.klasifikace     = n.klasifikace
       AND t.kat_uzemi       = n.kat_uzemi
       AND t.druh            = n.druh
       AND t.jedn_cena_Kc_m2 = n.jedn_cena_Kc_m2
       AND t.detektor        = 'JC'
    WHEN MATCHED THEN UPDATE SET
        t.vkladu = n.vkladu, t.ruznych_ploch = n.ruznych_ploch,
        t.cena_min = n.cena_min, t.cena_max = n.cena_max,
        t.rok_min = n.rok_min, t.rok_max = n.rok_max,
        t.plocha_min = n.plocha_min, t.plocha_max = n.plocha_max,
        t.datum_vypoctu = GETDATE()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (klasifikace, kat_uzemi, druh, detektor, jedn_cena_Kc_m2,
         cena_skupiny_Kc, rok, vkladu, ruznych_ploch, cena_min, cena_max,
         rok_min, rok_max, plocha_min, plocha_max, datum_vypoctu)
        VALUES
        (n.klasifikace, n.kat_uzemi, n.druh, 'JC', n.jedn_cena_Kc_m2,
         0, 0, n.vkladu, n.ruznych_ploch, n.cena_min, n.cena_max,
         n.rok_min, n.rok_max, n.plocha_min, n.plocha_max, GETDATE())
    WHEN NOT MATCHED BY SOURCE AND t.detektor = 'JC' AND t.typ_jevu IS NULL
        THEN DELETE
    WHEN NOT MATCHED BY SOURCE AND t.detektor = 'JC' AND t.typ_jevu IS NOT NULL
        THEN UPDATE SET t.vkladu = 0, t.datum_vypoctu = GETDATE();

    /* počet katastrů s touž jednotkovou cenou — jen pro detektor JC */
    UPDATE h SET h.katastru = k.katastru
    FROM dbo.Valuo_hromadne_prevody h
    JOIN (SELECT jedn_cena_Kc_m2, COUNT(DISTINCT kat_uzemi) AS katastru
          FROM dbo.Valuo_hromadne_prevody WHERE detektor = 'JC'
          GROUP BY jedn_cena_Kc_m2) k ON k.jedn_cena_Kc_m2 = h.jedn_cena_Kc_m2
    WHERE h.detektor = 'JC';

    /* medián lokality a poměr */
    UPDATE h
       SET h.median_lokality = x.median,
           h.pomer = CASE WHEN x.median > 0
                          THEN CAST(h.jedn_cena_Kc_m2 / x.median AS decimal(8,3)) END
    FROM dbo.Valuo_hromadne_prevody h
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_nazev = h.kat_uzemi
    OUTER APPLY (
        SELECT TOP 1 l.median FROM dbo.v_cenove_hladiny l
        WHERE l.kod_ku = c.ku_kod AND l.klasifikace = h.klasifikace
          AND l.klic = 'DRUH:' + h.druh
    ) x
    WHERE h.detektor = 'JC';
END;

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_detekce_prevodu_dle_ceny
   změněno 2026-10-23 19:00
   ------------------------------------------------------------------------ */

CREATE   PROCEDURE dbo.sp_detekce_prevodu_dle_ceny
    @min_vkladu int = 5,
    @kulatost   int = 1000
AS
BEGIN
    SET NOCOUNT ON;
    /* ========================================================================
       Detektor hromadných převodů podle CELKOVÉ ceny vkladu (krok 29).

       Doplňuje sp_detekce_hromadnych_prevodu, který klíčuje podle
       JEDNOTKOVÉ ceny a vyžaduje tři a více různých ploch. Družstevní
       privatizace, kde má každý byt vlastní cenu podle téhož vzorce,
       tou podmínkou propadne: každá jednotková cena má plochu jedinou.

       Doložený případ — Stodůlky, byty, 2023: 46 vkladů za shodných
       251 361 Kč, 42 za 493 433 Kč, 35 za 275 137 Kč. Medián území za
       ten rok vyšel 6 436 Kč/m² proti 125 376 Kč/m² o rok později,
       a všech 318 vkladů prošlo jako „bez výhrad". Mez je nezachytila,
       protože si ji ty převody samy stáhly pod sebe (mez_zdola
       645 Kč/m²).

       KRITÉRIUM. Shodná celková cena u @min_vkladu a více vkladů
       v témže území, druhu a roce, A ZÁROVEŇ aspoň jedno z:
         - plochy se opakují (různých ploch nejvýš polovina vkladů)
         - cena není kulatá na @kulatost Kč

       Druhá podmínka odděluje trh od transakce: pět bytů za kulatých
       pět milionů s pěti různými plochami je náhoda, ne jedna smlouva.

       Nic nemaže ani nevyřazuje — skupiny jen označí. Zatřídění dělá
       znalec a MERGE ho zachová, stejně jako u detektoru JC.

       Zdroj je nejdřív v #nove: MERGE přímo nad CTE nad pohledem
       nestíhal.
       ======================================================================== */

    IF OBJECT_ID('tempdb..#nove') IS NOT NULL DROP TABLE #nove;

    SELECT  v.klasifikace, v.kat_uzemi, ISNULL(v.druh, '?') AS druh,
            v.rok, v.cena_Kc,
            COUNT(*) AS vkladu,
            COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                                    v.plocha_budovy_m2)) AS ruznych_ploch,
            COUNT(DISTINCT v.jedn_cena_Kc_m2) AS ruznych_cen,
            MIN(COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                         v.plocha_budovy_m2)) AS plocha_min,
            MAX(COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                         v.plocha_budovy_m2)) AS plocha_max
    INTO #nove
    FROM dbo.v_Valuo_vzorek v
    WHERE v.cena_Kc > 0
    GROUP BY v.klasifikace, v.kat_uzemi, ISNULL(v.druh, '?'), v.rok, v.cena_Kc
    HAVING COUNT(*) >= @min_vkladu
       AND ( COUNT(DISTINCT COALESCE(v.plocha_jednotky_m2, v.plocha_parcel_m2,
                                     v.plocha_budovy_m2)) * 2 <= COUNT(*)
          OR v.cena_Kc % @kulatost <> 0 );

    MERGE dbo.Valuo_hromadne_prevody AS t
    USING #nove AS n
       ON  t.klasifikace     = n.klasifikace
       AND t.kat_uzemi       = n.kat_uzemi
       AND t.druh            = n.druh
       AND t.detektor        = 'CENA'
       AND t.cena_skupiny_Kc = n.cena_Kc
       AND t.rok             = n.rok
    WHEN MATCHED THEN UPDATE SET
        t.vkladu = n.vkladu, t.ruznych_ploch = n.ruznych_ploch,
        t.ruznych_cen = n.ruznych_cen,
        t.cena_min = n.cena_Kc, t.cena_max = n.cena_Kc,
        t.rok_min = n.rok, t.rok_max = n.rok,
        t.plocha_min = n.plocha_min, t.plocha_max = n.plocha_max,
        t.datum_vypoctu = GETDATE()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (klasifikace, kat_uzemi, druh, detektor, jedn_cena_Kc_m2,
         cena_skupiny_Kc, rok, vkladu, ruznych_ploch, ruznych_cen,
         cena_min, cena_max, rok_min, rok_max, plocha_min, plocha_max,
         datum_vypoctu)
        VALUES
        (n.klasifikace, n.kat_uzemi, n.druh, 'CENA', 0,
         n.cena_Kc, n.rok, n.vkladu, n.ruznych_ploch, n.ruznych_cen,
         n.cena_Kc, n.cena_Kc, n.rok, n.rok, n.plocha_min, n.plocha_max,
         GETDATE())
    WHEN NOT MATCHED BY SOURCE AND t.detektor = 'CENA' AND t.typ_jevu IS NULL
        THEN DELETE
    WHEN NOT MATCHED BY SOURCE AND t.detektor = 'CENA' AND t.typ_jevu IS NOT NULL
        THEN UPDATE SET t.vkladu = 0, t.datum_vypoctu = GETDATE();

    DROP TABLE #nove;
END;

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_jednotkovych_cen
   změněno 2026-10-24 13:55
   ------------------------------------------------------------------------ */

CREATE PROCEDURE dbo.sp_prepocet_jednotkovych_cen
AS
BEGIN
    SET NOCOUNT ON;

    /* různé nemovitosti ve vkladu — bez duplicitních zápisů */
    WITH dedup AS (
        SELECT DISTINCT cislo_vkladu, nemovitost, typ, adresa, plocha,
                        typ_plochy
        FROM dbo.Valuo_data
    ),
    pocty AS (
        SELECT  cislo_vkladu,
                COUNT(*) AS nemovitosti,
                SUM(CASE WHEN nemovitost = N'parcela'  THEN 1 ELSE 0 END) AS parcel,
                SUM(CASE WHEN nemovitost = N'jednotka' THEN 1 ELSE 0 END) AS jednotek,
                SUM(CASE WHEN nemovitost = N'budova'   THEN 1 ELSE 0 END) AS budov,

                /* krok 31: právo stavby — Valuo ho vede jako '---' */
                SUM(CASE WHEN nemovitost = N'---'      THEN 1 ELSE 0 END) AS prav_stavby,

                /* součet výměr parcel */
                SUM(CASE WHEN nemovitost = N'parcela' THEN plocha ELSE 0 END)
                    AS plocha_parcel,

                /* plocha jednotky — jen z podílu na budově.
                   "Výměra parcely" u jednotky je pozemek,
                   ne byt, a do jmenovatele nepatří. */
                SUM(CASE WHEN nemovitost = N'jednotka'
                          AND typ_plochy = N'Plocha spočítaná z podílu na budově'
                         THEN plocha ELSE 0 END) AS plocha_jednotky,

                /* plocha budovy — jen podlahová či zastavěná */
                SUM(CASE WHEN nemovitost = N'budova'
                          AND typ_plochy IN (N'Podlahová plocha',
                                             N'Zastavěná plocha budovy')
                         THEN plocha ELSE 0 END) AS plocha_budovy
        FROM dedup
        GROUP BY cislo_vkladu
    ),
    radky AS (
        SELECT cislo_vkladu, COUNT(*) AS radku
        FROM dbo.Valuo_data
        GROUP BY cislo_vkladu
    )
    UPDATE v
    SET v.vklad_nemovitosti     = p.nemovitosti,
        v.vklad_radku           = r.radku,
        v.vklad_duplicit        = r.radku - p.nemovitosti,
        v.vklad_plocha_parcel   = NULLIF(p.plocha_parcel,   0),
        v.vklad_plocha_jednotky = NULLIF(p.plocha_jednotky, 0),
        v.vklad_plocha_budovy   = NULLIF(p.plocha_budovy,   0),

        v.vklad_klasifikace =
            CASE WHEN p.prav_stavby > 0                THEN 'PRAVO_STAVBY'
                 WHEN p.budov    > 1                   THEN 'NELZE'
                 WHEN p.jednotek > 1                   THEN 'NELZE'
                 WHEN p.budov = 1 AND p.jednotek = 1   THEN 'NELZE'
                 WHEN p.budov    = 1                   THEN 'CELEK_BUDOVA'
                 WHEN p.jednotek = 1                   THEN 'JC_JEDNOTKA'
                 WHEN p.parcel   > 0                   THEN 'JC_PARCELY'
                 ELSE                                       'NELZE'
            END,

        v.vklad_duvod =
            CASE WHEN p.prav_stavby > 0              THEN 'právo stavby'
                 WHEN p.budov    > 1                 THEN 'více budov ve vkladu'
                 WHEN p.jednotek > 1                 THEN 'více jednotek ve vkladu'
                 WHEN p.budov = 1 AND p.jednotek = 1 THEN 'budova i jednotka zároveň'
                 WHEN p.budov = 0 AND p.jednotek = 0
                  AND p.parcel = 0                   THEN 'nezařazená nemovitost'
                 ELSE NULL
            END
    FROM dbo.Valuo_data v
    JOIN pocty p ON p.cislo_vkladu = v.cislo_vkladu
    JOIN radky r ON r.cislo_vkladu = v.cislo_vkladu;
END;

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_karet_davka
   změněno 2026-10-25 07:20
   ------------------------------------------------------------------------ */

CREATE   PROCEDURE dbo.sp_prepocet_karet_davka
    @jen_nove bit = 1,          -- 1 = jen vklady, které kartu ještě nemají
    @limit int = 100000,        -- strop na počet vkladů v jednom běhu
    @max_sekund int = 45        -- sám se zastaví, ať dotaz nevyprší
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @t0 datetime2 = SYSDATETIME();
    DECLARE @v varchar(50), @hotovo int = 0, @chyb int = 0;

    CREATE TABLE #zahod (radku_karty int, kol_sireni int);

    /* Do fronty jde jen vklad, který má aspoň jednu parcelu v KN_parcel_data.
       Bez parcely nemůže sp_prepocet_karty zapsat nic, takže by takový vklad
       zůstal "nehotový" navždy a dávka by se o něj pokoušela donekonečna —
       přesně to se stalo v noci na 25. 10. 2026 u 138 vkladů, jejichž parcely
       katastr nikdy nedotáhl (zaniklé parcely, zjednodušená evidence). */
    DECLARE @fronta TABLE (cislo_vkladu varchar(50) PRIMARY KEY);
    INSERT INTO @fronta (cislo_vkladu)
    SELECT TOP (@limit) d.cislo_vkladu
    FROM (SELECT DISTINCT cislo_vkladu FROM dbo.Valuo_data) d
    WHERE (@jen_nove = 0
           OR NOT EXISTS (SELECT 1 FROM dbo.Valuo_karta_parcely kp
                          WHERE kp.cislo_vkladu = d.cislo_vkladu))
      AND EXISTS (SELECT 1 FROM dbo.Valuo_data vd
                  JOIN dbo.KN_parcel_data kn ON kn.id_valuo = vd.id
                  WHERE vd.cislo_vkladu = d.cislo_vkladu)
    ORDER BY d.cislo_vkladu;

    DECLARE kurzor CURSOR LOCAL FAST_FORWARD FOR
        SELECT cislo_vkladu FROM @fronta;
    OPEN kurzor;
    FETCH NEXT FROM kurzor INTO @v;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT INTO #zahod EXEC dbo.sp_prepocet_karty @cislo_vkladu = @v;
            SET @hotovo = @hotovo + 1;
        END TRY
        BEGIN CATCH
            SET @chyb = @chyb + 1;
        END CATCH
        DELETE FROM #zahod;
        IF DATEDIFF(SECOND, @t0, SYSDATETIME()) >= @max_sekund BREAK;
        FETCH NEXT FROM kurzor INTO @v;
    END
    CLOSE kurzor; DEALLOCATE kurzor;

    SELECT @hotovo AS zpracovano, @chyb AS chyb,
           (SELECT COUNT(*) FROM (SELECT DISTINCT cislo_vkladu FROM dbo.Valuo_data) d
            WHERE NOT EXISTS (SELECT 1 FROM dbo.Valuo_karta_parcely kp
                              WHERE kp.cislo_vkladu = d.cislo_vkladu)
              AND EXISTS (SELECT 1 FROM dbo.Valuo_data vd
                          JOIN dbo.KN_parcel_data kn ON kn.id_valuo = vd.id
                          WHERE vd.cislo_vkladu = d.cislo_vkladu)) AS zbyva,
           (SELECT COUNT(*) FROM (SELECT DISTINCT cislo_vkladu FROM dbo.Valuo_data) d
            WHERE NOT EXISTS (SELECT 1 FROM dbo.Valuo_karta_parcely kp
                              WHERE kp.cislo_vkladu = d.cislo_vkladu)) AS bez_karty_celkem,
           DATEDIFF(SECOND, @t0, SYSDATETIME()) AS sekund;
END

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_karty
   změněno 2026-10-24 18:25
   ------------------------------------------------------------------------ */

CREATE   PROCEDURE dbo.sp_prepocet_karty
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

    /* kotva_priorita: hlavní kotvou je parcela nesoucí OBYTNOU nemovitost;
       u vkladu "dům + garáž" by jinak celek určila garáž */
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

    /* hlavnich se počítá NAPŘÍČ všemi vklady, i při běhu na jeden vklad */
    CREATE TABLE #hlavni (gml_id varchar(50) PRIMARY KEY, hlavnich int NULL, vkladu int NOT NULL);
    INSERT INTO #hlavni SELECT k.gml_id, NULLIF(COUNT(DISTINCT h.klic),0), COUNT(DISTINCT d.cislo_vkladu)
    FROM dbo.KN_parcel_data k JOIN dbo.Valuo_data d ON d.id = k.id_valuo
    LEFT JOIN #hl h ON h.cislo_vkladu = d.cislo_vkladu
    WHERE k.gml_id IN (SELECT gml_id FROM #p) GROUP BY k.gml_id;

    /* podíl vyžaduje DVA RŮZNÉ VKLADY. Vklad "dům + garáž" má dvě hlavní
       nemovitosti uvnitř sebe a sám o sobě podíl nedokládá. */
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

    /* na KOTVU vodítka 2-4 neplatí: parcela nesoucí hlavní nemovitost není
       společná cesta a v hustší zástavbě se běžně dotýká cizích domů */
    UPDATE #p SET vlastnictvi =
        CASE WHEN role_zdroj = N'ruční' THEN role_trvala
             WHEN hlavnich >= @mh AND vkladu >= @mh THEN N'podílová'
             WHEN role_trvala = N'podílová' THEN N'podílová'
             WHEN je_kotva = 1 THEN N'výhradní'
             WHEN je_komunikace = 1 OR tvar_cesty = 1 OR staveb >= @ms
                  OR (hlavnich IS NULL AND vkladu >= @mh) THEN N'neověřeno'
             ELSE N'výhradní' END;
    UPDATE #p SET lab = kn_id;

    /* hrany jen mezi VÝHRADNÍMI parcelami: řetězit přes společnou cestu by
       slilo stání za cestou s domem (Písnice 835/213) */
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

    SELECT (SELECT COUNT(*) FROM dbo.Valuo_karta_parcely) AS radku_karty,
           @kolo AS kol_sireni;
END

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_karty_okoli
   změněno 2026-10-24 18:07
   ------------------------------------------------------------------------ */

CREATE   PROCEDURE dbo.sp_prepocet_karty_okoli
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

        DELETE FROM #sousedi;
        INSERT INTO #sousedi (gml_id, kod_parcely)
        SELECT DISTINCT p.gml_id, r.kod_parcely
        FROM #parcely p
        JOIN dbo.KN_parcel_data k ON k.id = p.kn_id
        JOIN dbo.RUIAN_parcely r ON r.geo_plocha.STIntersects(k.geo_plocha) = 1
        WHERE 'CP.' + CAST(r.kod_parcely AS varchar(20)) <> p.gml_id;
        SET @vazeb = @vazeb + @@ROWCOUNT;

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

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_karty_tvar
   změněno 2026-10-25 07:22
   ------------------------------------------------------------------------ */

CREATE   PROCEDURE dbo.sp_prepocet_karty_tvar
    @cislo_vkladu varchar(50) = NULL,   -- NULL = všechny vklady, které mají kartu
    @jen_nove bit = 0,                  -- 1 = přeskočit už spočítané
    @limit int = 2000,                  -- kolik vkladů v jedné dávce
    @max_sekund int = 600               -- sám se zastaví
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME();

    /* Tvar celku a tvar všech pozemků vkladu.

       Počítá se ze sloučené geometrie parcel, ne po parcelách — funkční celek
       složený ze tří parcel má jeden obvod, ne tři. Výsledkem je Polsby-Popperův
       index 4*pi*A/O^2 jako holé číslo; koeficient si ze souboru dělá znalec sám.

       "Celek" = parcely ve výhradním vlastnictví v roli kotva nebo celek.
       "Vše"   = všechny parcely vkladu včetně podílových a oddělených.

       Jede po dávkách: UnionAggregate nad 102 tisíci parcelami najednou je
       jeden dlouhý neukončitelný dotaz. Volá se opakovaně, dokud zbyva > 0. */

    DECLARE @vklady TABLE (cislo_vkladu varchar(50) PRIMARY KEY);
    INSERT INTO @vklady (cislo_vkladu)
    SELECT TOP (@limit) kp.cislo_vkladu
    FROM (SELECT DISTINCT cislo_vkladu FROM dbo.Valuo_karta_parcely) kp
    WHERE (@cislo_vkladu IS NULL OR kp.cislo_vkladu = @cislo_vkladu)
      AND (@jen_nove = 0 OR NOT EXISTS (SELECT 1 FROM dbo.Valuo_karta_vklad kv
                                        WHERE kv.cislo_vkladu = kp.cislo_vkladu))
    ORDER BY kp.cislo_vkladu;

    ;WITH g AS (
        SELECT kp.cislo_vkladu,
               CASE WHEN kp.vlastnictvi = N'výhradní'
                     AND kp.prostorova_role IN (N'kotva', N'celek') THEN 1 ELSE 0 END AS je_celek,
               k.geo_plocha
        FROM dbo.Valuo_karta_parcely kp
        JOIN @vklady v ON v.cislo_vkladu = kp.cislo_vkladu
        JOIN dbo.KN_parcel_data k ON k.id = kp.kn_id
        WHERE k.geo_plocha IS NOT NULL
    ),
    celek AS (
        SELECT cislo_vkladu, geography::UnionAggregate(geo_plocha) AS geo
        FROM g WHERE je_celek = 1 GROUP BY cislo_vkladu
    ),
    vse AS (
        SELECT cislo_vkladu, geography::UnionAggregate(geo_plocha) AS geo
        FROM g GROUP BY cislo_vkladu
    ),
    spoctene AS (
        SELECT v.cislo_vkladu,
            CAST(c.geo.STArea()   AS decimal(18,2)) AS plocha_celku_m2,
            CAST(c.geo.STLength() AS decimal(18,2)) AS obvod_celku_m,
            c.geo.STNumGeometries() AS casti_celku,
            CAST(a.geo.STArea()   AS decimal(18,2)) AS plocha_vse_m2,
            CAST(a.geo.STLength() AS decimal(18,2)) AS obvod_vse_m,
            a.geo.STNumGeometries() AS casti_vse
        FROM @vklady v
        LEFT JOIN celek c ON c.cislo_vkladu = v.cislo_vkladu
        LEFT JOIN vse   a ON a.cislo_vkladu = v.cislo_vkladu
    )
    MERGE dbo.Valuo_karta_vklad AS cil
    USING (SELECT cislo_vkladu, plocha_celku_m2, obvod_celku_m, casti_celku,
                  plocha_vse_m2, obvod_vse_m, casti_vse,
                  CASE WHEN obvod_celku_m > 0 THEN
                       CAST(4 * PI() * plocha_celku_m2 / (obvod_celku_m * obvod_celku_m) AS decimal(9,4)) END AS pp_celku,
                  CASE WHEN obvod_vse_m > 0 THEN
                       CAST(4 * PI() * plocha_vse_m2 / (obvod_vse_m * obvod_vse_m) AS decimal(9,4)) END AS pp_vse
           FROM spoctene) AS zdroj
    ON cil.cislo_vkladu = zdroj.cislo_vkladu
    WHEN MATCHED THEN UPDATE SET
        cil.plocha_celku_m2 = zdroj.plocha_celku_m2, cil.obvod_celku_m = zdroj.obvod_celku_m,
        cil.pp_index_celku = zdroj.pp_celku, cil.casti_celku = zdroj.casti_celku,
        cil.plocha_vse_m2 = zdroj.plocha_vse_m2, cil.obvod_vse_m = zdroj.obvod_vse_m,
        cil.pp_index_vse = zdroj.pp_vse, cil.casti_vse = zdroj.casti_vse,
        cil.prepocteno = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (cislo_vkladu, plocha_celku_m2, obvod_celku_m, pp_index_celku, casti_celku,
         plocha_vse_m2, obvod_vse_m, pp_index_vse, casti_vse, prepocteno)
        VALUES (zdroj.cislo_vkladu, zdroj.plocha_celku_m2, zdroj.obvod_celku_m,
                zdroj.pp_celku, zdroj.casti_celku, zdroj.plocha_vse_m2,
                zdroj.obvod_vse_m, zdroj.pp_vse, zdroj.casti_vse, SYSDATETIME());

    DECLARE @radku int = @@ROWCOUNT;

    SELECT @radku AS radku_tvaru,
           (SELECT COUNT(*) FROM (SELECT DISTINCT cislo_vkladu
                                  FROM dbo.Valuo_karta_parcely) kp
            WHERE NOT EXISTS (SELECT 1 FROM dbo.Valuo_karta_vklad kv
                              WHERE kv.cislo_vkladu = kp.cislo_vkladu)) AS zbyva,
           DATEDIFF(SECOND, @t0, SYSDATETIME()) AS sekund;
END

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_mapy
   změněno 2026-10-25 19:24
   ------------------------------------------------------------------------ */

CREATE   PROCEDURE dbo.sp_prepocet_mapy
    @prepocitat bit = 0,
    @limit_ku int = 100000,
    @max_sekund int = 45,
    @kod_ku_jen int = NULL,
    @od datetime2 = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME();
    DECLARE @ku int, @hotovo int = 0, @radku int = 0;
    /* Do kolika metrů od definičního bodu se značka přesune na stavbu. */
    DECLARE @bod_do decimal(9,2) = (SELECT p.hodnota FROM dbo.CIS_karta_parametry p
                                    WHERE p.parametr = 'bod_stavba_do_m');
    SET @bod_do = ISNULL(@bod_do, 100);

    /* Jede se po katastrálních územích, aby se to dalo přerušit.

       Od kroku 46 je tato procedura JEDINÝM vlastníkem Valuo_mapa a běží
       jako POSLEDNÍ, až po sp_prepocet_ploch. Dřív bylo pořadí obrácené
       a sp_prepocet_ploch si do mapy na konci dolepovala vlastní příznaky;
       tím se mapa rozešla sama se sebou — u V-23039/2026-101 (nalezl znalec
       25. 10. 2026) byla plocha 40,50 m² z nového přepočtu vedle ceny
       7 793 Kč/m² ze starého, a druh „bytový dům" u bytové jednotky.
       Zasaženo bylo 7 915 řádků v ceně, 11 093 v ploše a 2 789 v druhu.

       Do fronty jde k. ú., jehož některý vklad v mapě chybí, kde přibyla
       karta u vkladu, který ji dřív neměl, NEBO kde je zdroj novější než
       řádek mapy. Ta třetí podmínka je nová a podstatná: bez ní se po
       změně pohledu nebo přepočtu ploch mapa nepřepočítala vůbec, protože
       všechny vklady v ní už byly. */
    /* Čekající k. ú. se spočítají JEDNÍM průchodem do #ceka. Do 25. 10.
       2026 se tatáž korelovaná podmínka vyhodnocovala dvakrát: ve frontě
       a znovu v závěrečném zbyva_ku. Fronta ji přežila, protože TOP (n)
       se po n nálezech zkratkuje — závěrečný COUNT se zkratkovat nedá,
       musí projít všechna k. ú. A čím víc řádků mapy je přepočtených,
       tím déle to trvá, takže procedura byla pomalejší s každou dávkou.
       Set-based verze projde každou tabulku jednou. */
    CREATE TABLE #ceka (kod_ku int PRIMARY KEY);
    IF @prepocitat = 1
    BEGIN
        /* Vynucený přepočet. @od = začátek běhu; k. ú., které už v tomhle
           běhu prošlo, se podruhé nebere. Bez toho dávkování nefunguje:
           fronta by brala pořád stejných prvních @limit_ku k. ú. podle
           kod_ku, a skript, který po prvním kole přepne na @prepocitat = 0,
           by zbytek nikdy nedopočítal — a přitom ohlásil „mapa hotová".
           Nalezeno 25. 10. 2026 při přepnutí kategorie na nosnou skupinu,
           kdy bylo potřeba přepočítat všech 826 k. ú. */
        INSERT INTO #ceka (kod_ku)
        /* Odpíchnout se od MAPY, ne od Valuo_data. V datech je 826 k. ú.,
           ale řádky v mapě má jen 310 — zbylých 516 žádné nemá a mít nebude,
           protože jejich vklady nemají souřadnice. Verze z 25. 10. 2026
           brala všech 826, těch 516 se nikdy nevyloučilo (nemají prepocteno,
           které by se dalo posunout), fronta se zasekla na 555 a TOP 400
           se k posledním 155 nedostal: skript jel dokola a hlásil
           „hotovo 3200 k. ú." při 826 existujících. Vkládat není co —
           vkladů mimo mapu je 0 — a kdyby přibyly, vezme je nevynucená
           větev níž. */
        SELECT h.kod_ku
        FROM (SELECT m.kod_ku, MAX(m.prepocteno) AS posledni
              FROM dbo.Valuo_mapa m
              WHERE m.kod_ku IS NOT NULL
              GROUP BY m.kod_ku) h
        WHERE @od IS NULL OR h.posledni IS NULL OR h.posledni < @od;
    END
    ELSE
    BEGIN
        /* Čekající k. ú. jedním průchodem, ne korelovaným EXISTS. */
        INSERT INTO #ceka (kod_ku)
        SELECT z.kod_ku FROM (
            /* vklad v mapě vůbec není */
            SELECT DISTINCT vd.kod_ku
            FROM dbo.Valuo_data vd
            WHERE vd.kod_ku IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM dbo.Valuo_mapa m
                              WHERE m.cislo_vkladu = vd.cislo_vkladu)
            UNION
            /* karta přibyla u vkladu, který ji v mapě nemá */
            SELECT DISTINCT m.kod_ku
            FROM dbo.Valuo_mapa m
            WHERE m.ma_kartu = 0
              AND EXISTS (SELECT 1 FROM dbo.Valuo_karta_parcely kp
                          WHERE kp.cislo_vkladu = m.cislo_vkladu)
            UNION
            /* zdroj novější než řádek mapy, nebo mapa nikdy nepřepočítaná */
            SELECT DISTINCT m.kod_ku
            FROM dbo.Valuo_mapa m
            JOIN dbo.Valuo_vklad_plocha vp ON vp.cislo_vkladu = m.cislo_vkladu
            WHERE m.prepocteno IS NULL OR vp.kdy > m.prepocteno
        ) z
        WHERE z.kod_ku IS NOT NULL;
    END

    DECLARE @ceka_celkem int = (SELECT COUNT(*) FROM #ceka);

    DECLARE @fronta TABLE (kod_ku int PRIMARY KEY);
    INSERT INTO @fronta (kod_ku)
    SELECT TOP (@limit_ku) c.kod_ku
    FROM #ceka c
    WHERE @kod_ku_jen IS NULL OR c.kod_ku = @kod_ku_jen
    ORDER BY c.kod_ku;

    DECLARE kurzor CURSOR LOCAL FAST_FORWARD FOR SELECT kod_ku FROM @fronta;
    OPEN kurzor;
    FETCH NEXT FROM kurzor INTO @ku;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        ;WITH body0 AS (
            /* Bod se bere z JEDNOHO řádku vkladu, ne jako MIN přes všechny —
               MIN(Lat) a MIN(Long) mohou pocházet z různých nemovitostí
               a výsledek pak neleží nikde. Pořadí drží CIS_nemovitost_typ,
               stejně jako volba hlavní nemovitosti v pohledu. */
            SELECT cislo_vkladu, lat, lon, geo_bod FROM (
                SELECT d.cislo_vkladu, d.geo_bod.Lat AS lat, d.geo_bod.Long AS lon,
                       d.geo_bod,
                       ROW_NUMBER() OVER (PARTITION BY d.cislo_vkladu ORDER BY
                           ISNULL(t.priorita, 99), ISNULL(d.plocha, 0) DESC, d.id) AS rn
                FROM dbo.Valuo_data d
                LEFT JOIN dbo.CIS_nemovitost_typ t
                       ON t.nemovitost = d.nemovitost AND t.typ = d.typ
                WHERE d.kod_ku = @ku AND d.geo_bod IS NOT NULL) x
            WHERE rn = 1
        ),
        stavba AS (
            /* Značka jednotek a budov patří na STAVBU, ne na definiční bod
               parcely (pokyn znalce 25. 10. 2026). Bere se střed obálky
               polygonu stavebního objektu z RÚIANu, a to té stavby, která
               je k dnešnímu bodu NEJBLIŽŠÍ.

               Proč nejbližší a ne stavba na kotevní parcele: kotva karty
               a bod mapy se u vkladu s více budovami rozcházejí. Ve vkladu
               V-81105/2020-101 (Smíchov) jsou tři domy na parcelách 344, 811
               a 2415, kilometry od sebe; karta zakotvila 344, bod mapy mířil
               na jiný z nich a stavba na kotvě byla 1 226 m daleko. Dnešní
               bod je definiční bod TÉ nemovitosti, kterou vybrala priorita
               typů, takže nejbližší stavba je její.

               Vklad bez budovy i bez jednotky se nepřesouvá: u souboru
               pozemků by se značka mohla usadit na cizí stavbu stojící na
               některé z parcel. */
            SELECT b.cislo_vkladu, s.bod, s.d,
                   ROW_NUMBER() OVER (PARTITION BY b.cislo_vkladu ORDER BY s.d) AS rn
            FROM body0 b
            CROSS APPLY (
                SELECT so.geo_plocha.EnvelopeCenter() AS bod,
                       b.geo_bod.STDistance(so.geo_plocha.EnvelopeCenter()) AS d
                FROM dbo.Valuo_karta_parcely kp
                JOIN dbo.RUIAN_parcely rp ON rp.gml_id = kp.gml_id
                                         AND rp.kod_ku = kp.kod_ku
                JOIN dbo.RUIAN_stavebni_objekty so ON so.parcela_id = rp.kod_parcely
                WHERE kp.cislo_vkladu = b.cislo_vkladu
                  AND so.geo_plocha IS NOT NULL
            ) s
            /* Rozsah MUSÍ být stejný jako u slozeni, tedy řádky v právě
               zpracovávaném k. ú. Bez d2.kod_ku = @ku se tyto dva výpočty
               rozešly u vkladů, jejichž řádky leží ve dvou katastrálních
               územích: pojistka viděla budovu v jiném k. ú., slozeni ne,
               a 394 vkladů v 19 k. ú. dostalo bod ze stavby, přestože mapa
               u nich hlásila „bez budovy i jednotky" (kontrola 10.3,
               25. 10. 2026). Průměrný posun u nich byl 57,8 m proti
               celkovým 10,6 m, což to samo napovídalo. */
            WHERE EXISTS (SELECT 1 FROM dbo.Valuo_data d2
                          WHERE d2.cislo_vkladu = b.cislo_vkladu
                            AND d2.kod_ku = @ku
                            AND d2.nemovitost IN ('budova', 'jednotka'))
        ),
        body AS (
            /* Nad mezí @bod_do se bod NEPŘESOUVÁ a vyznačí se nález: spárování
               stavby s parcelou je tam podezřelé, typicky kotevní parcela
               z jiného k. ú. (564 vkladů k 25. 10. 2026). */
            SELECT b.cislo_vkladu,
                   CASE WHEN s.d <= @bod_do THEN s.bod.Lat  ELSE b.lat END AS lat,
                   CASE WHEN s.d <= @bod_do THEN s.bod.Long ELSE b.lon END AS lon,
                   CASE WHEN s.d <= @bod_do THEN N'stavba RÚIAN'
                        ELSE N'definiční bod' END AS bod_zdroj,
                   CASE WHEN s.d <= @bod_do THEN CAST(s.d AS decimal(8,1))
                        END AS bod_posun_m,
                   CASE WHEN s.d > @bod_do THEN CAST(1 AS bit)
                        ELSE CAST(0 AS bit) END AS nalez_bod_daleko
            FROM body0 b
            LEFT JOIN stavba s ON s.cislo_vkladu = b.cislo_vkladu AND s.rn = 1
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
                   b.bod_zdroj, b.bod_posun_m, b.nalez_bod_daleko,
                   CONVERT(varchar(32), CAST(ROUND(b.lat, 5) AS decimal(9,5))) + '_' +
                   CONVERT(varchar(32), CAST(ROUND(b.lon, 5) AS decimal(9,5))) AS shluk_id,
                   CASE
                     /* Kategorie = CO TO JE. Od 25. 10. 2026 ji řídí nosná skupina
                        z kroku 46, ne klasifikace. Klasifikace odpovídá na jinou
                        otázku — zda z vkladu šla podle starých pravidel spočítat
                        jednotková cena — a nese se teď ve vlastním sloupci.
                        Jeden sloupec se dvěma významy schovával 8 905 bytů mezi
                        „jiné" jen proto, že se s bytem prodávaly podíly na
                        nebytových prostorech (nalezl znalec 25. 10. 2026 na
                        V-23039/2026-101). Větev podle nosne_nemovitost = jednotka
                        je záměrně obecná: pokryje i typy jednotek, které do
                        číselníku teprve přibudou. */
                     WHEN v.nosna_skupina = N'byt'                         THEN 'byt'
                     WHEN v.nosna_skupina = N'bytový dům'                  THEN 'bytovy_dum'
                     WHEN v.nosna_skupina IN (N'rodinný dům', N'rekreace') THEN 'rodinny_dum'
                     WHEN v.nosna_skupina = N'pozemek'                     THEN 'pozemek'
                     WHEN v.nosna_nemovitost = 'jednotka'                  THEN 'jednotka_jina'
                     WHEN v.nosna_skupina IS NOT NULL                      THEN 'jine'
                     /* bez nosné nemovitosti zůstává starý postup */
                     WHEN v.klasifikace = 'JC_PARCELY' THEN 'pozemek'
                     WHEN v.hlavni_druh IN (N'rodinný dům', N'objekt k bydlení',
                                            N'stavba pro rodinnou rekreaci') THEN 'rodinny_dum'
                     WHEN v.hlavni_druh = N'bytový dům' THEN 'bytovy_dum'
                     ELSE 'jine' END AS kategorie,
                   v.hlavni_druh AS druh, v.jednotka_oznaceni, v.hlavni_adresa AS adresa,
                   v.klasifikace,
                   CAST(v.datum_zplatneni AS date) AS datum_zplatneni, v.rok, v.cena_Kc,
                   /* Pořadí metrik: podlahová plocha, pak nosná výměra
                      pozemku (krok 46), pak všechny pozemky. Nosná výměra
                      je u pozemkového vkladu ta správná — podíly na
                      komunikacích by cenu rozmělnily. */
                   /* Jednotková cena JEN na podlahovou plochu u všeho, co je
                      stavba nebo jednotka (pokyn znalce 25. 10. 2026: „dělej
                      to na podlahovou plochu metr čtvereční; u těch, který
                      nemají podlahovou plochu, cenu na výměru pozemku
                      neuvádět, je to zavádějící, tam nech pouze celkovou
                      cenu"). Na výměru pozemku se dělí POUZE čistý soubor
                      pozemků, tedy vklad bez budovy i bez jednotky.
                      Dotklo se to 5 534 řádků, které tím o jednotkovou cenu
                      přišly; 5 303 čistých pozemkových si ji ponechalo. */
                   CASE WHEN v.jc_Kc_m2_podlahova IS NOT NULL
                        THEN v.jc_Kc_m2_podlahova
                        WHEN s.ma_budovu = 0 AND s.ma_jednotku = 0
                        THEN COALESCE(v.jc_Kc_m2_nosne_vymery,
                                      v.jc_Kc_m2_vsech_pozemku)
                   END AS cena_m2,
                   CASE WHEN v.jc_Kc_m2_podlahova IS NOT NULL
                        THEN ISNULL(v.plocha_podlahova_zdroj, N'podlahová plocha')
                        WHEN s.ma_budovu = 0 AND s.ma_jednotku = 0
                         AND v.jc_Kc_m2_nosne_vymery IS NOT NULL
                        THEN N'nosná výměra pozemku'
                        WHEN s.ma_budovu = 0 AND s.ma_jednotku = 0
                         AND v.jc_Kc_m2_vsech_pozemku IS NOT NULL
                        THEN N'orientačně: výměra všech pozemků včetně podílů'
                   END AS zaklad_ceny,
                   /* Orientační cena: nerozklíčovatelný balík pozemků, kde se
                      žádná parcela nekvalifikovala jako nosná. Znalec ji chce
                      vidět jako hrubý přehled „takový balík se prodal průměrně
                      za tolik", ale do mediánů ani do barevné škály nepatří —
                      rozsah jde od 0 do 1 152 580 Kč/m² při průměru 5 415. */
                   CASE WHEN v.jc_Kc_m2_podlahova IS NULL
                         AND s.ma_budovu = 0 AND s.ma_jednotku = 0
                         AND v.jc_Kc_m2_nosne_vymery IS NULL
                         AND v.jc_Kc_m2_vsech_pozemku IS NOT NULL
                        THEN CAST(1 AS bit) ELSE CAST(0 AS bit)
                   END AS jc_orientacni,
                   /* Plocha drží TÝŽ jmenovatel jako cena. Neuvádí-li se cena,
                      neuvádí se ani plocha — jinak by u stavby svítila výměra
                      pozemku jako základ, kterým se vědomě nedělí. */
                   CASE WHEN v.jc_Kc_m2_podlahova IS NOT NULL
                        THEN v.plocha_podlahova_karty
                        WHEN s.ma_budovu = 0 AND s.ma_jednotku = 0
                        THEN COALESCE(v.vymera_nosna, v.vymera_pozemku_vse)
                   END AS plocha,
                   v.parcel_celkem,
                   CASE WHEN v.parcel_celkem IS NULL THEN 0 ELSE 1 END AS ma_kartu,
                   s.ma_budovu, s.ma_jednotku, s.ma_parcelu,
                   v.ruian_druh_konstrukce AS konstrukce,
                   v.ruian_rok AS rok_stavby,
                   v.ruian_pocet_podlazi AS podlazi,
                   v.ruian_pocet_bytu AS bytu_v_dome,
                   /* Příznaky z registru ploch. Od kroku 46 je plní tato
                      procedura, ne sp_prepocet_ploch — jeden vlastník
                      tabulky znamená, že se mapa nemůže rozejít sama
                      se sebou. */
                   v.nalez_plocha_cely_dum, v.nalez_plocha_z_podilu,
                   v.nalez_plocha_posun, v.nalez_skala,
                   v.nalez_vice_nosnych, v.nalez_bez_plochy,
                   v.plocha_navrh, v.nosna_skupina, v.jc_verdikt, v.vymera_nosna
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
            cil.kategorie = z.kategorie, cil.klasifikace = z.klasifikace,
            cil.druh = z.druh,
            cil.jednotka_oznaceni = z.jednotka_oznaceni, cil.adresa = z.adresa,
            cil.datum_zplatneni = z.datum_zplatneni, cil.rok = z.rok,
            cil.cena_Kc = z.cena_Kc, cil.cena_m2 = z.cena_m2,
            cil.zaklad_ceny = z.zaklad_ceny, cil.plocha = z.plocha,
            cil.parcel_celkem = z.parcel_celkem, cil.ma_kartu = z.ma_kartu,
            cil.ma_budovu = z.ma_budovu, cil.ma_jednotku = z.ma_jednotku,
            cil.ma_parcelu = z.ma_parcelu, cil.konstrukce = z.konstrukce,
            cil.rok_stavby = z.rok_stavby, cil.podlazi = z.podlazi,
            cil.bytu_v_dome = z.bytu_v_dome,
            cil.nalez_plocha_cely_dum = z.nalez_plocha_cely_dum,
            cil.nalez_plocha_z_podilu = z.nalez_plocha_z_podilu,
            cil.nalez_plocha_posun = z.nalez_plocha_posun,
            cil.nalez_skala = z.nalez_skala,
            cil.nalez_vice_nosnych = z.nalez_vice_nosnych,
            cil.nalez_bez_plochy = z.nalez_bez_plochy,
            cil.plocha_navrh = z.plocha_navrh,
            cil.nosna_skupina = z.nosna_skupina,
            cil.jc_verdikt = z.jc_verdikt,
            cil.jc_orientacni = z.jc_orientacni,
            cil.bod_zdroj = z.bod_zdroj, cil.bod_posun_m = z.bod_posun_m,
            cil.nalez_bod_daleko = z.nalez_bod_daleko,
            cil.vymera_nosna = z.vymera_nosna,
            cil.prepocteno = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (cislo_vkladu, kod_ku, kat_uzemi, obec, lat, lon, shluk_id, kategorie, klasifikace,
             druh, jednotka_oznaceni, adresa, datum_zplatneni, rok, cena_Kc,
             cena_m2, zaklad_ceny, jc_orientacni, plocha, parcel_celkem, ma_kartu,
             ma_budovu, ma_jednotku, ma_parcelu, konstrukce, rok_stavby,
             podlazi, bytu_v_dome, nalez_plocha_cely_dum, nalez_plocha_z_podilu,
             nalez_plocha_posun, nalez_skala, nalez_vice_nosnych, nalez_bez_plochy,
             plocha_navrh, nosna_skupina, jc_verdikt, vymera_nosna, bod_zdroj, bod_posun_m, nalez_bod_daleko, prepocteno)
            VALUES (z.cislo_vkladu, z.kod_ku, z.kat_uzemi, z.obec, z.lat, z.lon,
                    z.shluk_id, z.kategorie, z.klasifikace, z.druh, z.jednotka_oznaceni, z.adresa,
                    z.datum_zplatneni, z.rok, z.cena_Kc, z.cena_m2, z.zaklad_ceny, z.jc_orientacni,
                    z.plocha, z.parcel_celkem, z.ma_kartu,
                    z.ma_budovu, z.ma_jednotku, z.ma_parcelu, z.konstrukce,
                    z.rok_stavby, z.podlazi, z.bytu_v_dome,
                    z.nalez_plocha_cely_dum, z.nalez_plocha_z_podilu,
                    z.nalez_plocha_posun, z.nalez_skala, z.nalez_vice_nosnych,
                    z.nalez_bez_plochy, z.plocha_navrh, z.nosna_skupina,
                    z.jc_verdikt, z.vymera_nosna, z.bod_zdroj, z.bod_posun_m,
                    z.nalez_bod_daleko, SYSDATETIME());

        SET @radku = @radku + @@ROWCOUNT;
        SET @hotovo = @hotovo + 1;
        IF DATEDIFF(SECOND, @t0, SYSDATETIME()) >= @max_sekund BREAK;
        FETCH NEXT FROM kurzor INTO @ku;
    END
    CLOSE kurzor; DEALLOCATE kurzor;

    /* Zbývá = kolik k. ú. by fronta ještě vzala, včetně těch, kde je zdroj
       novější než řádek mapy. */
    SELECT @hotovo AS zpracovano_ku, @radku AS radku,
           CASE WHEN @kod_ku_jen IS NOT NULL THEN 0
                ELSE @ceka_celkem - @hotovo END AS zbyva_ku,
           DATEDIFF(SECOND, @t0, SYSDATETIME()) AS sekund;
END

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_men
   změněno 2026-10-22 19:19
   ------------------------------------------------------------------------ */



/* ============================================================
   19b.3  PROCEDURA PŘEPOČTU
   Spouštět po každém importu nových dat z Valua.
   ============================================================ */

CREATE   PROCEDURE dbo.sp_prepocet_men
AS
BEGIN
    SET NOCOUNT ON;

    /* a) korunové vklady — cena beze změny */
    UPDATE dbo.Valuo_data
    SET cena_Kc      = cenovy_udaj,
        kurz_pouzity = NULL,
        kurz_datum   = NULL
    WHERE mena IS NULL OR mena = 'CZK';

    /* b) cizí měny — poslední kurz ke dni podání nebo dříve.
          Kurz za jednotku je kurz / mnozstvi; ČNB vyhlašuje
          některé měny za sto či tisíc jednotek. */
    WITH kurz AS (
        SELECT  v.id,
                k.kurz / k.mnozstvi AS kurz_za_jednotku,
                k.datum,
                ROW_NUMBER() OVER (PARTITION BY v.id
                                   ORDER BY k.datum DESC) AS poradi
        FROM dbo.Valuo_data   v
        JOIN dbo.CIS_kurzy_CNB k
          ON k.mena  = v.mena
         AND k.datum <= CAST(v.datum_podani AS date)
        WHERE v.mena IS NOT NULL AND v.mena <> 'CZK'
    )
    UPDATE v
    SET v.cena_Kc      = CAST(v.cenovy_udaj * q.kurz_za_jednotku AS decimal(18,2)),
        v.kurz_pouzity = CAST(q.kurz_za_jednotku AS decimal(12,4)),
        v.kurz_datum   = q.datum
    FROM dbo.Valuo_data v
    JOIN kurz q ON q.id = v.id AND q.poradi = 1;

    /* c) měna bez kurzu — cena v Kč zůstává nevyplněná */
    UPDATE dbo.Valuo_data
    SET cena_Kc      = NULL,
        kurz_pouzity = NULL,
        kurz_datum   = NULL
    WHERE mena IS NOT NULL AND mena <> 'CZK'
      AND NOT EXISTS (SELECT 1 FROM dbo.CIS_kurzy_CNB k
                      WHERE k.mena  = dbo.Valuo_data.mena
                        AND k.datum <= CAST(dbo.Valuo_data.datum_podani AS date));
END;

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_ploch
   změněno 2026-10-25 16:47
   ------------------------------------------------------------------------ */

CREATE   PROCEDURE dbo.sp_prepocet_ploch
    @prepocitat bit = 0        -- 0 = jen nové řádky, 1 = zlomky načíst znovu
AS
BEGIN
    SET NOCOUNT ON;
    /* Registr zdrojů plochy po řádcích a NOSNÁ NEMOVITOST vkladu.
       Od kroku 46 pokrývá všechny tři kategorie: jednotku, budovu
       i soubor pozemků. Odůvodnění je v 45_plochy_po_radcich.sql,
       46_nosna_nemovitost.sql a v ROZHODNUTI_DATA.md.

       Nosná nemovitost = nejvyšší typ přítomný ve vkladu podle
       CIS_nemovitost_typ.priorita (jednotky 1-6, budovy 11-21, právo
       stavby 30). Plocha vkladu = součet ploch nosných řádků, ale JEN
       má-li plochu každý z nich; chybí-li u některého, nedělí se vůbec
       a uvede se jen celková cena (pokyn znalce 25. 10. 2026).

       Nález a přepis jsou dvě různé věci. Nález se zapíše vždy, když je
       s plochou něco v nepořádku. Přepsat se smí jen tam, kde je nezávislý
       doklad, KTERÁ z ploch je správná. */

    DECLARE @t0 datetime2 = SYSDATETIME();

    DECLARE @nabyt_min decimal(18,4) = (SELECT hodnota FROM dbo.CIS_karta_parametry WHERE parametr = 'nabyt_plocha_min');
    DECLARE @nabyt_max decimal(18,4) = (SELECT hodnota FROM dbo.CIS_karta_parametry WHERE parametr = 'nabyt_plocha_max');
    DECLARE @skala_od  decimal(18,4) = (SELECT hodnota FROM dbo.CIS_karta_parametry WHERE parametr = 'dum_skala_od');
    DECLARE @skala_do  decimal(18,4) = (SELECT hodnota FROM dbo.CIS_karta_parametry WHERE parametr = 'dum_skala_do');
    DECLARE @rad_tol   decimal(18,4) = (SELECT hodnota FROM dbo.CIS_karta_parametry WHERE parametr = 'skala_rad_tolerance');
    DECLARE @svedek    decimal(18,4) = (SELECT hodnota FROM dbo.CIS_karta_parametry WHERE parametr = 'skala_svedek_dekada');
    DECLARE @dum_shoda decimal(18,4) = (SELECT hodnota FROM dbo.CIS_karta_parametry WHERE parametr = 'dum_plocha_shoda');
    DECLARE @min_vzorku int = (SELECT CAST(hodnota AS int) FROM dbo.CIS_karta_parametry WHERE parametr = 'jc_median_min_vzorku');

    IF @nabyt_min IS NULL OR @nabyt_max IS NULL OR @skala_od IS NULL OR @skala_do IS NULL
       OR @rad_tol IS NULL OR @svedek IS NULL OR @dum_shoda IS NULL OR @min_vzorku IS NULL
        THROW 51045, 'V CIS_karta_parametry chybí parametr pro přepočet ploch.', 1;

    /* --- 1. zlomky podílu na společných částech (jen jednotky) ---------- */

    IF @prepocitat = 1 DELETE FROM dbo.Valuo_podil_jednotky;

    INSERT INTO dbo.Valuo_podil_jednotky (id, cislo_vkladu, zlomek_text, citatel, jmenovatel, kdy)
    SELECT x.id, x.cislo_vkladu, x.zlomek,
           TRY_CAST(LEFT(x.zlomek, CHARINDEX('/', x.zlomek) - 1) AS decimal(18,2)),
           TRY_CAST(SUBSTRING(x.zlomek, CHARINDEX('/', x.zlomek) + 1, 30) AS decimal(18,2)),
           @t0
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
            AND NOT EXISTS (SELECT 1 FROM dbo.Valuo_podil_jednotky p WHERE p.id = v.id)
        ) z WHERE PATINDEX('%[0-9]%', z.zbytek) > 0
      ) y
    ) x
    WHERE CHARINDEX('/', x.zlomek) > 1
      AND TRY_CAST(LEFT(x.zlomek, CHARINDEX('/', x.zlomek) - 1) AS decimal(18,2)) > 0
      AND TRY_CAST(SUBSTRING(x.zlomek, CHARINDEX('/', x.zlomek) + 1, 30) AS decimal(18,2)) > 0;

    DECLARE @novych_zlomku int = @@ROWCOUNT;

    /* --- 2. škála domu (jen jednotky — budova podíl nemá) --------------- */

    IF OBJECT_ID('tempdb..#dum') IS NOT NULL DROP TABLE #dum;
    SELECT p.jmenovatel,
           CAST(APPROX_PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY rv.ruian_podlahova_plocha)
                AS decimal(14,2)) AS pp_dom
    INTO #dum
    FROM dbo.Valuo_podil_jednotky p
    JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = p.cislo_vkladu
    WHERE rv.ruian_podlahova_plocha > 0
    GROUP BY p.jmenovatel;

    IF OBJECT_ID('tempdb..#skala') IS NOT NULL DROP TABLE #skala;
    SELECT d.jmenovatel, d.pp_dom, v.skala
    INTO #skala
    FROM #dum d
    CROSS APPLY (SELECT TOP 1 x.skala FROM (VALUES (1.0), (10.0), (100.0), (1000.0)) AS x(skala)
                 WHERE d.jmenovatel / x.skala BETWEEN @skala_od * d.pp_dom AND @skala_do * d.pp_dom
                 ORDER BY ABS(d.jmenovatel / x.skala - d.pp_dom)) v;
    CREATE UNIQUE CLUSTERED INDEX IX_skala ON #skala (jmenovatel);

    IF OBJECT_ID('tempdb..#dom_soucet') IS NOT NULL DROP TABLE #dom_soucet;
    SELECT s.jmenovatel,
           CAST(CASE WHEN SUM(j.pl_valuo) > s.jmenovatel / s.skala THEN 1 ELSE 0 END AS bit) AS valuo_presahuje
    INTO #dom_soucet
    FROM #skala s
    JOIN (SELECT DISTINCT p.jmenovatel, d.jednotka_oznaceni, p.citatel, d.plocha AS pl_valuo
          FROM dbo.Valuo_podil_jednotky p JOIN dbo.Valuo_data d ON d.id = p.id
          WHERE d.plocha > 0 AND d.jednotka_oznaceni IS NOT NULL) j ON j.jmenovatel = s.jmenovatel
    GROUP BY s.jmenovatel, s.skala;
    CREATE UNIQUE CLUSTERED INDEX IX_dom_soucet ON #dom_soucet (jmenovatel);

    /* --- 3. kandidáti plochy po řádcích --------------------------------
       U JEDNOTKY je pole plocha vždy plocha jednotky. U BUDOVY jen tam,
       kde to typ_plochy říká — jinak je v něm výměra parcely a dělit se
       jí nesmí (u rodinných domů je to 2 076 řádků z 2 960). Chybí-li
       Valuova podlahová plocha a je-li ve vkladu jediná budova, nastoupí
       RÚIAN; u více budov RÚIAN popisuje jednu z nich a rozdělit ho nelze. */

    IF OBJECT_ID('tempdb..#radek') IS NOT NULL DROP TABLE #radek;
    SELECT d.id, d.cislo_vkladu, d.nemovitost, d.typ, d.jednotka_oznaceni,
           ISNULL(t.priorita, 99)        AS priorita,
           ISNULL(t.skupina, N'ostatní') AS skupina,
           ISNULL(t.plocha_min, 0)       AS pl_min,
           ISNULL(t.plocha_max, 999999)  AS pl_max,
           CASE WHEN d.nemovitost = 'jednotka' THEN d.plocha
                WHEN d.typ_plochy = N'Podlahová plocha' THEN d.plocha END AS pl_valuo,
           CASE WHEN d.nemovitost <> 'jednotka'
                 AND COUNT(*) OVER (PARTITION BY d.cislo_vkladu) = 1
                THEN rv.ruian_podlahova_plocha END AS pl_ruian,
           p.citatel, p.jmenovatel, p.pomer, p.zlomek_text,
           rv.ruian_podlahova_plocha AS pp, rv.ruian_pocet_bytu AS bytu, s.skala,
           CASE WHEN rv.ruian_pocet_bytu > 0
                THEN CAST(rv.ruian_podlahova_plocha * 1.0 / rv.ruian_pocet_bytu AS decimal(14,2)) END AS na_jednotku,
           ISNULL(ds.valuo_presahuje, CAST(0 AS bit)) AS svedek_soucet,
           CASE WHEN p.pomer > 0 AND rv.ruian_podlahova_plocha > 0
                THEN CAST(p.pomer * rv.ruian_podlahova_plocha AS decimal(14,2)) END AS pl_podil,
           CASE WHEN s.skala IS NOT NULL AND p.citatel > 0
                THEN CAST(p.citatel / s.skala AS decimal(14,2)) END AS pl_citatel,
           MIN(ISNULL(t.priorita, 99)) OVER (PARTITION BY d.cislo_vkladu) AS nosna_priorita,
           CAST(NULL AS varchar(24))   AS zdroj_volby,
           CAST(NULL AS decimal(14,2)) AS plocha_volby,
           CAST(0 AS bit) AS nalez_dum, CAST(0 AS bit) AS prepsat_dum,
           CAST(0 AS bit) AS nalez_skala, CAST(0 AS bit) AS prepsat_skala
    INTO #radek
    FROM dbo.Valuo_data d
    LEFT JOIN dbo.CIS_nemovitost_typ t ON t.nemovitost = d.nemovitost AND t.typ = d.typ
    LEFT JOIN dbo.Valuo_podil_jednotky p ON p.id = d.id
    LEFT JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = d.cislo_vkladu
    LEFT JOIN #skala s ON s.jmenovatel = p.jmenovatel
    LEFT JOIN #dom_soucet ds ON ds.jmenovatel = p.jmenovatel
    WHERE d.nemovitost IN ('jednotka', 'budova', '---');
    CREATE UNIQUE CLUSTERED INDEX IX_radek ON #radek (id);
    CREATE NONCLUSTERED INDEX IX_radek_vklad ON #radek (cislo_vkladu, priorita);

    UPDATE #radek SET nalez_dum = 1
    WHERE nemovitost = 'jednotka' AND pp > 0 AND pl_valuo IS NOT NULL
      AND ABS(pl_valuo - pp) <= @dum_shoda * pp
      AND bytu >= 2 AND pomer > 0 AND pl_podil > 0;

    UPDATE #radek SET prepsat_dum = 1
    WHERE nalez_dum = 1 AND pl_podil BETWEEN pl_min AND pl_max;

    UPDATE #radek SET nalez_skala = 1
    WHERE pl_citatel > 0 AND pl_valuo > 0 AND nalez_dum = 0
      AND pl_citatel BETWEEN pl_min AND pl_max
      AND (ABS(pl_citatel - pl_valuo * 10)  <= @rad_tol
        OR ABS(pl_citatel - pl_valuo * 100) <= @rad_tol
        OR ABS(pl_citatel * 10  - pl_valuo) <= @rad_tol
        OR ABS(pl_citatel * 100 - pl_valuo) <= @rad_tol);

    UPDATE #radek SET prepsat_skala = 1
    WHERE nalez_skala = 1 AND priorita = nosna_priorita
      AND ((na_jednotku BETWEEN @nabyt_min AND @nabyt_max
            AND ABS(LOG10(pl_citatel / na_jednotku))
                < ABS(LOG10(pl_valuo / na_jednotku)) - @svedek)
        OR (svedek_soucet = 1
            AND (na_jednotku IS NULL OR na_jednotku NOT BETWEEN @nabyt_min AND @nabyt_max)));

    /* --- 4. volba plochy řádku ------------------------------------------ */
    UPDATE #radek
    SET zdroj_volby = CASE WHEN prepsat_dum = 1   THEN 'PODIL_RADEK'
                           WHEN prepsat_skala = 1 THEN 'CITATEL_SKALA'
                           WHEN pl_valuo > 0      THEN 'VALUO_RADEK'
                           WHEN pl_ruian > 0      THEN 'RUIAN_PP'
                           WHEN pl_podil > 0      THEN 'PODIL_RADEK'
                           WHEN pl_citatel > 0    THEN 'CITATEL_SKALA'
                      END,
        plocha_volby = CASE WHEN prepsat_dum = 1   THEN pl_podil
                            WHEN prepsat_skala = 1 THEN pl_citatel
                            WHEN pl_valuo > 0      THEN pl_valuo
                            WHEN pl_ruian > 0      THEN pl_ruian
                            WHEN pl_podil > 0      THEN pl_podil
                            WHEN pl_citatel > 0    THEN pl_citatel
                       END;

    /* --- 5. registr ploch ----------------------------------------------- */

    DELETE FROM dbo.Valuo_plochy;

    INSERT INTO dbo.Valuo_plochy (cislo_vkladu, id, zdroj, plocha, platny, pouzito, poznamka, kdy)
    SELECT cislo_vkladu, id, zdroj, plocha, platny, pouzito, poznamka, @t0 FROM (
        SELECT r.cislo_vkladu, r.id, 'VALUO_RADEK' AS zdroj, r.pl_valuo AS plocha,
               CAST(1 AS bit) AS platny,
               CAST(CASE WHEN r.zdroj_volby = 'VALUO_RADEK' THEN 1 ELSE 0 END AS bit) AS pouzito,
               CASE WHEN r.prepsat_dum = 1
                      THEN N'rovná se podlahové ploše domu dle RÚIAN, není to plocha jednotky'
                    WHEN r.nalez_dum = 1
                      THEN N'rovná se ploše celého domu, ale podíl nedává věrohodnou náhradu — ponechána Valuova'
                    WHEN r.prepsat_skala = 1
                      THEN CONCAT(N'chybná škála — čitatel ', CAST(CAST(r.citatel AS bigint) AS varchar(20)),
                                  N' dělený ', CAST(CAST(r.skala AS int) AS varchar(10)),
                                  N' dává ', REPLACE(CAST(r.pl_citatel AS varchar(20)), '.', ','),
                                  N' m²; doklad: ',
                                  CASE WHEN r.na_jednotku BETWEEN @nabyt_min AND @nabyt_max
                                       THEN N'plocha domu na jednotku dle RÚIAN'
                                       ELSE N'součet Valuových ploch přesahuje plochu jednotek domu' END)
                    WHEN r.nalez_skala = 1
                      THEN N'rozpor se škálou domu o řád, ale chybí nezávislý doklad, která plocha je správná — ponechána Valuova'
                    WHEN r.zdroj_volby = 'VALUO_RADEK' THEN N'výchozí zdroj'
               END AS poznamka
        FROM #radek r WHERE r.pl_valuo > 0
        UNION ALL
        SELECT r.cislo_vkladu, r.id, 'RUIAN_PP', r.pl_ruian, CAST(1 AS bit),
               CAST(CASE WHEN r.zdroj_volby = 'RUIAN_PP' THEN 1 ELSE 0 END AS bit),
               N'Valuo podlahovou plochu neuvádí (v poli plocha má výměru parcely); RÚIAN u budovy popisuje tu správnou stavbu'
        FROM #radek r WHERE r.pl_ruian > 0
        UNION ALL
        SELECT r.cislo_vkladu, r.id, 'PODIL_RADEK', r.pl_podil, CAST(1 AS bit),
               CAST(CASE WHEN r.zdroj_volby = 'PODIL_RADEK' THEN 1 ELSE 0 END AS bit),
               CASE WHEN r.nalez_dum = 1
                      THEN CONCAT(N'podíl ', r.zlomek_text, N' z podlahové plochy domu ',
                                  CAST(CAST(r.pp AS bigint) AS varchar(20)), N' m² dle RÚIAN',
                                  CASE WHEN r.prepsat_dum = 0
                                       THEN N'; mimo věrohodné rozmezí typu, nepoužito' END)
                    WHEN r.skala IS NULL AND r.jmenovatel > 1000
                      THEN N'dopočet z poměru podílu; škálu domu nelze určit, hodnota je proto jen orientační'
                    WHEN r.skala IS NOT NULL AND r.pp > 0 AND r.jmenovatel / r.skala < 0.95 * r.pp
                      THEN N'dopočet z poměru podílu; jmenovatel je součet ploch jednotek, takže o společné prostory domu plochu podhodnocuje'
                    ELSE N'dopočet z poměru podílu'
               END
        FROM #radek r WHERE r.pl_podil > 0
        UNION ALL
        SELECT r.cislo_vkladu, r.id, 'CITATEL_SKALA', r.pl_citatel, CAST(1 AS bit),
               CAST(CASE WHEN r.zdroj_volby = 'CITATEL_SKALA' THEN 1 ELSE 0 END AS bit),
               CONCAT(N'čitatel ', CAST(CAST(r.citatel AS bigint) AS varchar(20)),
                      N' dělený škálou domu ', CAST(CAST(r.skala AS int) AS varchar(10)),
                      CASE WHEN r.nalez_skala = 1 AND r.prepsat_skala = 0
                           THEN N'; v rozporu s Valuem o řád, bez nezávislého dokladu se nepřepisuje' END)
        FROM #radek r WHERE r.pl_citatel > 0
        UNION ALL
        SELECT r.cislo_vkladu, 0, 'RUCNE', r.plocha_rucne, CAST(1 AS bit), CAST(1 AS bit),
               r.plocha_rucne_zdroj
        FROM dbo.Valuo_vklad_rucne r WHERE r.plocha_rucne > 0
        UNION ALL
        /* Vkladový RÚIAN zůstává jen u vkladu s jednotkou, kde popisuje
           celý dům a k ceně se nepoužívá. U budovy je nově po řádcích. */
        SELECT rv.cislo_vkladu, 0, 'RUIAN_PP', rv.ruian_podlahova_plocha, CAST(0 AS bit), CAST(0 AS bit),
               N'popisuje celý dům, ne prodávanou jednotku'
        FROM dbo.RUIAN_vzorek rv
        WHERE rv.ruian_podlahova_plocha > 0
          AND EXISTS (SELECT 1 FROM #radek q WHERE q.cislo_vkladu = rv.cislo_vkladu
                        AND q.nemovitost = 'jednotka')
        UNION ALL
        SELECT rv.cislo_vkladu, 0, 'RUIAN_NA_BYT',
               CAST(rv.ruian_podlahova_plocha * 1.0 / rv.ruian_pocet_bytu AS decimal(14,2)),
               CAST(0 AS bit), CAST(0 AS bit),
               CASE WHEN rv.ruian_podlahova_plocha * 1.0 / rv.ruian_pocet_bytu
                         NOT BETWEEN @nabyt_min AND @nabyt_max
                    THEN N'nedůvěryhodné — počet bytů v RÚIAN nesedí k ploše domu'
                    ELSE N'jen kontrola řádu' END
        FROM dbo.RUIAN_vzorek rv
        WHERE rv.ruian_podlahova_plocha > 0 AND rv.ruian_pocet_bytu > 0
          AND EXISTS (SELECT 1 FROM #radek q WHERE q.cislo_vkladu = rv.cislo_vkladu
                        AND q.nemovitost = 'jednotka')
    ) x WHERE x.plocha > 0;

    /* --- 6. nosná nemovitost a plocha vkladu ---------------------------- */

    IF OBJECT_ID('tempdb..#nosna') IS NOT NULL DROP TABLE #nosna;
    SELECT cislo_vkladu, nemovitost, skupina AS nosna_skupina, typ AS nosny_typ
    INTO #nosna
    FROM (SELECT r.cislo_vkladu, r.nemovitost, r.skupina, r.typ,
                 ROW_NUMBER() OVER (PARTITION BY r.cislo_vkladu
                                    ORDER BY ISNULL(r.plocha_volby, 0) DESC, r.id) AS rn
          FROM #radek r WHERE r.priorita = r.nosna_priorita) z
    WHERE rn = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_nosna ON #nosna (cislo_vkladu);

    /* Nosná výměra pozemků: výhradní parcely, které nejsou tvar pásu ani
       druh komunikace. Není-li žádná, je to balík pozemků a nosná se
       nevybírá. Výměra podílu je doplňující údaj — co kupující dostal
       nad nosnou parcelu, přepočtené počtem vkladů s tou parcelou. */
    IF OBJECT_ID('tempdb..#poz') IS NOT NULL DROP TABLE #poz;
    SELECT kp.cislo_vkladu,
        CAST(SUM(CASE WHEN kp.vlastnictvi = N'výhradní' AND ISNULL(kp.tvar_cesty, 0) = 0
                       AND ISNULL(kp.je_druh_komunikace, 0) = 0
                      THEN kp.vymera_m2 END) AS decimal(14,2)) AS vymera_nosna,
        SUM(CASE WHEN kp.vlastnictvi = N'výhradní' AND ISNULL(kp.tvar_cesty, 0) = 0
                  AND ISNULL(kp.je_druh_komunikace, 0) = 0 THEN 1 ELSE 0 END) AS parcel_nosnych,
        CAST(SUM(CASE WHEN NOT (kp.vlastnictvi = N'výhradní' AND ISNULL(kp.tvar_cesty, 0) = 0
                                AND ISNULL(kp.je_druh_komunikace, 0) = 0)
                      THEN kp.vymera_m2 / NULLIF(kp.vkladu_s_parcelou, 0) END) AS decimal(14,2)) AS vymera_podilu
    INTO #poz
    FROM dbo.Valuo_karta_parcely kp
    GROUP BY kp.cislo_vkladu;
    CREATE UNIQUE CLUSTERED INDEX IX_poz ON #poz (cislo_vkladu);

    DELETE FROM dbo.Valuo_vklad_plocha;

    INSERT INTO dbo.Valuo_vklad_plocha (cislo_vkladu, nemovitost, nosna_priorita, nosna_skupina,
        nosny_typ, radku_nosnych, radku_mimo, plocha, plocha_zdroje, rozpusteno, nalezu,
        nalez_dum, nalez_skala, nalez_vice_nosnych, nalez_bez_plochy, kdy)
    SELECT r.cislo_vkladu, n.nemovitost, MIN(r.nosna_priorita), n.nosna_skupina, n.nosny_typ,
        SUM(CASE WHEN r.priorita = r.nosna_priorita AND r.skupina = n.nosna_skupina THEN 1 ELSE 0 END),
        SUM(CASE WHEN r.priorita = r.nosna_priorita AND r.skupina = n.nosna_skupina THEN 0 ELSE 1 END),
        /* Součet jen tehdy, má-li plochu KAŽDÁ nosná. Jinak NULL. */
        CASE WHEN SUM(CASE WHEN r.priorita = r.nosna_priorita AND r.skupina = n.nosna_skupina
                            AND r.plocha_volby IS NULL THEN 1 ELSE 0 END) = 0
             THEN SUM(CASE WHEN r.priorita = r.nosna_priorita AND r.skupina = n.nosna_skupina
                           THEN r.plocha_volby END) END,
        (SELECT STRING_AGG(CAST(z.nazev AS nvarchar(max)), N' + ') WITHIN GROUP (ORDER BY z.poradi)
         FROM (SELECT DISTINCT c.nazev, c.poradi FROM #radek q
               JOIN dbo.CIS_plochy_zdroje c ON c.kod = q.zdroj_volby
               WHERE q.cislo_vkladu = r.cislo_vkladu
                 AND q.priorita = q.nosna_priorita AND q.skupina = n.nosna_skupina) z),
        (SELECT STRING_AGG(CAST(CONCAT(z.typ, N' ', z.kolik) AS nvarchar(max)), N', ')
         FROM (SELECT q.typ, COUNT(*) AS kolik FROM #radek q
               WHERE q.cislo_vkladu = r.cislo_vkladu
                 AND NOT (q.priorita = q.nosna_priorita AND q.skupina = n.nosna_skupina)
               GROUP BY q.typ) z),
        SUM(CASE WHEN r.nalez_dum = 1 OR r.nalez_skala = 1 THEN 1 ELSE 0 END),
        MAX(CASE WHEN r.nalez_dum = 1   AND r.priorita = r.nosna_priorita THEN 1 ELSE 0 END),
        MAX(CASE WHEN r.nalez_skala = 1 AND r.priorita = r.nosna_priorita THEN 1 ELSE 0 END),
        CASE WHEN SUM(CASE WHEN r.priorita = r.nosna_priorita AND r.skupina = n.nosna_skupina
                           THEN 1 ELSE 0 END) >= 2 THEN 1 ELSE 0 END,
        CASE WHEN SUM(CASE WHEN r.priorita = r.nosna_priorita AND r.skupina = n.nosna_skupina
                            AND r.plocha_volby IS NULL THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END,
        @t0
    FROM #radek r
    JOIN #nosna n ON n.cislo_vkladu = r.cislo_vkladu
    GROUP BY r.cislo_vkladu, n.nemovitost, n.nosna_skupina, n.nosny_typ;

    /* Pozemkové vklady: žádná jednotka ani budova, jen parcely. */
    INSERT INTO dbo.Valuo_vklad_plocha (cislo_vkladu, nemovitost, nosna_priorita, nosna_skupina,
        nosny_typ, radku_nosnych, radku_mimo, nalezu, kdy)
    SELECT p.cislo_vkladu, 'parcela', 40, N'pozemek', NULL,
           ISNULL(p.parcel_nosnych, 0), 0, 0, @t0
    FROM #poz p
    WHERE NOT EXISTS (SELECT 1 FROM #radek r WHERE r.cislo_vkladu = p.cislo_vkladu);

    UPDATE vp SET vp.vymera_nosna = p.vymera_nosna,
                  vp.parcel_nosnych = p.parcel_nosnych,
                  vp.vymera_podilu = p.vymera_podilu
    FROM dbo.Valuo_vklad_plocha vp JOIN #poz p ON p.cislo_vkladu = vp.cislo_vkladu;

    /* --- 6b. medián Kč/m² v k.ú. a skupině -----------------------------
       U jednotky a budovy z podlahové plochy, u pozemku z nosné výměry.
       Jen z vkladů bez nálezu, aby vadné vzorky medián netáhly. */

    IF OBJECT_ID('tempdb..#cena') IS NOT NULL DROP TABLE #cena;
    SELECT d.cislo_vkladu, MIN(d.kod_ku) AS kod_ku, MAX(d.cena_Kc) AS cena_Kc
    INTO #cena FROM dbo.Valuo_data d GROUP BY d.cislo_vkladu;
    CREATE UNIQUE CLUSTERED INDEX IX_cena ON #cena (cislo_vkladu);

    DELETE FROM dbo.CIS_ku_median_jc;

    INSERT INTO dbo.CIS_ku_median_jc (kod_ku, nosna_skupina, vzorku, median_jc, kdy)
    SELECT c.kod_ku, v.nosna_skupina, COUNT(*),
           CAST(APPROX_PERCENTILE_CONT(0.5) WITHIN GROUP
                (ORDER BY c.cena_Kc / COALESCE(v.plocha, v.vymera_nosna)) AS decimal(14,2)), @t0
    FROM dbo.Valuo_vklad_plocha v
    JOIN #cena c ON c.cislo_vkladu = v.cislo_vkladu
    WHERE COALESCE(v.plocha, v.vymera_nosna) > 0 AND c.cena_Kc > 0
      AND v.nalezu = 0 AND v.nalez_vice_nosnych = 0 AND c.kod_ku IS NOT NULL
    GROUP BY c.kod_ku, v.nosna_skupina
    HAVING COUNT(*) >= @min_vzorku;

    /* --- 7. mapa se odsud NEPLNÍ --------------------------------------
       Do kroku 46 si tahle procedura dolepovala vlastní příznaky do
       Valuo_mapa a běžela až za sp_prepocet_mapy. Tím se mapa rozešla sama
       se sebou: u V-23039/2026-101 (nalezl znalec 25. 10. 2026) byla plocha
       40,50 m² z nového přepočtu vedle ceny 7 793 Kč/m² ze starého a druh
       „bytový dům" u bytové jednotky. Zasaženo 7 915 řádků v ceně, 11 093
       v ploše a 2 789 v druhu.

       Od kroku 46 je jediným vlastníkem Valuo_mapa procedura
       sp_prepocet_mapy a běží jako POSLEDNÍ, až za touto. Čte všechno
       z pohledu v jednom MERGE, takže se mapa rozejít nemůže.

       Pořadí v 38_prepocty.py: okolí → karty → tvar → PLOCHY → MAPA. */

    /* --- 8. hlášení ----------------------------------------------------- */

    SELECT @novych_zlomku AS novych_zlomku,
        (SELECT COUNT(*) FROM dbo.Valuo_plochy)                    AS radku_registru,
        (SELECT COUNT(*) FROM dbo.Valuo_plochy WHERE pouzito = 1)   AS radku_pouzitych,
        (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha)              AS vkladu,
        (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE nemovitost = 'jednotka') AS jednotkovych,
        (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE nemovitost = 'budova')   AS budovovych,
        (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE nemovitost = 'parcela')  AS pozemkovych,
        (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE plocha > 0)             AS ma_podlahovou,
        (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE vymera_nosna > 0)       AS ma_nosnou_vymeru,
        (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE nalez_vice_nosnych = 1)  AS vice_nosnych,
        (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE nalez_bez_plochy = 1)    AS nosna_bez_plochy,
        (SELECT COUNT(*) FROM #radek WHERE nalez_dum = 1)          AS nalezu_cely_dum,
        (SELECT COUNT(*) FROM #radek WHERE prepsat_dum = 1)        AS dum_prepsano,
        (SELECT COUNT(*) FROM #radek WHERE nalez_skala = 1)        AS nalezu_skala,
        (SELECT COUNT(*) FROM #radek WHERE prepsat_skala = 1)      AS skala_prepsano,
        (SELECT COUNT(*) FROM dbo.CIS_ku_median_jc)                AS medianu_ku,
        (SELECT COUNT(DISTINCT CONCAT(d.nemovitost, '|', d.typ))
         FROM dbo.Valuo_data d
         WHERE d.nemovitost IN ('jednotka', 'budova', '---')
           AND NOT EXISTS (SELECT 1 FROM dbo.CIS_nemovitost_typ t
                           WHERE t.nemovitost = d.nemovitost AND t.typ = d.typ))
                                                                  AS typu_mimo_ciselnik,
        DATEDIFF(s, @t0, SYSDATETIME()) AS sekund;
END

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_prahu
   změněno 2026-10-23 19:59
   ------------------------------------------------------------------------ */

CREATE   PROCEDURE dbo.sp_prepocet_prahu
AS
BEGIN
    SET NOCOUNT ON;

    /* ========================================================================
       Meze spočítané z dat. Od kroku 28b i podle pásma stáří a pro
       metriku M3 (Kč/m3).

       PAMĚŤ (krok 29b). PERCENTILE_CONT je okenní funkce a drží celý
       oddíl v paměti. Po zavedení pásem a metriky M3 se vstupní sada
       zdvojnásobila a u krajské úrovně má oddíl pražských bytů přes
       sedmnáct tisíc řádků — procedura pak spadla na Msg 701
       (insufficient system memory). Proto se počítá v cyklu po
       klasifikacích: výsledek je BITOVĚ STEJNÝ, jen špička paměti
       je zhruba čtvrtinová.

       Nepoužívej APPROX_PERCENTILE_CONT — je levnější, ale přibližná,
       a mediány z této tabulky slouží i jako kontrolní čísla.
       ======================================================================== */

    DECLARE @mez_default decimal(14,0) =
        (SELECT mez_Kc FROM dbo.CIS_mez_podilu WHERE kraj = N'*');

    IF OBJECT_ID('tempdb..#d0') IS NOT NULL DROP TABLE #d0;
    IF OBJECT_ID('tempdb..#d')  IS NOT NULL DROP TABLE #d;
    IF OBJECT_ID('tempdb..#k')  IS NOT NULL DROP TABLE #k;

    SELECT  q.kod_ku, c.ku_nazev,
            COALESCE(c.okres_nazev, c.kraj_nazev) AS okres,
            c.kraj_nazev, q.klasifikace,
            CASE WHEN q.metrika = 'JC' THEN 'JC' ELSE 'CENA' END AS metrika_zakl,
            CASE WHEN q.klasifikace = 'JC_PARCELY'
                  AND f.skupina IS NOT NULL
                  AND c.kraj_nazev = N'Hlavní město Praha'
                 THEN N'FVU:' + f.skupina + N'|' + v.pasmo
                 ELSE N'DRUH:' + ISNULL(q.druh, '?') END AS klic,
            CASE WHEN q.klasifikace = 'JC_PARCELY'
                  AND f.skupina IS NOT NULL
                  AND c.kraj_nazev = N'Hlavní město Praha'
                 THEN 1 ELSE 0 END AS jen_kraj,
            t.k_faktor, t.min_bodu_prah, t.max_nasobek,
            CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                 ELSE q.cena_Kc END AS hodnota_zakl,
            CASE WHEN q.klasifikace = 'CELEK_BUDOVA'
                  AND ru.ruian_zdroj = N'budova'
                  AND ru.ruian_obestaveny_prostor > 0
                 THEN q.cena_Kc / ru.ruian_obestaveny_prostor END AS hodnota_m3,
            CASE WHEN q.klasifikace IN ('JC_JEDNOTKA','CELEK_BUDOVA')
                 THEN ru.ruian_pasmo END AS pasmo_vkladu
    INTO #d0
    FROM dbo.v_Valuo_vzorek_q q
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod      = q.kod_ku
    JOIN dbo.CIS_prahy_ceny        t ON t.klasifikace = q.klasifikace
    LEFT JOIN dbo.CIS_FVU_skupiny  f ON f.fvu_kod     = q.fvu_kod
    LEFT JOIN dbo.CIS_velikost_pozemku v
           ON q.plocha_parcel_m2 >= v.od_m2 AND q.plocha_parcel_m2 < v.do_m2
    LEFT JOIN dbo.CIS_mez_podilu   mz ON mz.kraj      = c.kraj_nazev
    LEFT JOIN dbo.RUIAN_vzorek     ru ON ru.cislo_vkladu = q.cislo_vkladu
    WHERE ISNULL(q.mena, 'CZK') = 'CZK'
      AND q.typ_prevodu = 'KUPNI_SMLOUVA'
      AND q.hromadny_prevod = 0
      AND ISNULL(q.prodeju_tehoz_objektu, 0) < 5
      AND q.rok >= YEAR(GETDATE()) - 5
      AND (CASE WHEN q.metrika = 'JC' THEN q.jedn_cena_Kc_m2
                ELSE q.cena_Kc END) > 0
      AND (q.klasifikace <> 'JC_PARCELY'
           OR q.cena_Kc >= ISNULL(mz.mez_Kc, @mez_default));

    SELECT  d.kod_ku, d.ku_nazev, d.okres, d.kraj_nazev, d.klasifikace,
            d.klic, d.jen_kraj, d.k_faktor, d.min_bodu_prah, d.max_nasobek,
            m.metrika, pz.pasmo, LOG(m.hodnota) AS lg
    INTO #d
    FROM #d0 d
    CROSS APPLY (VALUES (d.metrika_zakl, d.hodnota_zakl),
                        ('M3',           d.hodnota_m3)) m(metrika, hodnota)
    CROSS APPLY (VALUES (CAST('' AS varchar(20))),
                        (CAST(d.pasmo_vkladu AS varchar(20)))) pz(pasmo)
    WHERE m.hodnota > 0 AND pz.pasmo IS NOT NULL;

    DROP TABLE #d0;
    CREATE INDEX IX_d ON #d (klasifikace, klic, metrika, pasmo, kod_ku);

    DELETE FROM dbo.Valuo_prahy;

    /* ---- cyklus po klasifikacích: drží špičku paměti nízko ---- */
    SELECT DISTINCT klasifikace INTO #k FROM #d;
    DECLARE @kl varchar(15);

    WHILE EXISTS (SELECT 1 FROM #k)
    BEGIN
        SELECT TOP 1 @kl = klasifikace FROM #k;

        INSERT INTO dbo.Valuo_prahy
            (klasifikace, klic, metrika, pasmo, uroven, uzemi, n, median, p75,
             sigma, prah_dolni, prah_horni, datum_vypoctu)
        SELECT DISTINCT klasifikace, klic, metrika, pasmo, N'k.ú.', ku_nazev, n,
               CAST(EXP(p50) AS decimal(18,2)), CAST(EXP(p75) AS decimal(18,2)),
               CAST(sig AS decimal(8,4)),
               CAST(GREATEST(EXP(p50 - k_faktor*sig), EXP(p50)/max_nasobek) AS decimal(18,2)),
               CAST(LEAST   (EXP(p50 + k_faktor*sig), EXP(p50)*max_nasobek) AS decimal(18,2)),
               GETDATE()
        FROM (
            SELECT DISTINCT klasifikace, klic, metrika, pasmo, ku_nazev, k_faktor,
                   max_nasobek,
                   COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kod_ku) AS n,
                   p50, p75, (p75 - p50)/0.6745 AS sig, min_bodu_prah
            FROM (
                SELECT klasifikace, klic, metrika, pasmo, ku_nazev, kod_ku,
                       k_faktor, min_bodu_prah, max_nasobek,
                       PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kod_ku) AS p50,
                       PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kod_ku) AS p75
                FROM #d WHERE jen_kraj = 0 AND klasifikace = @kl
            ) a
        ) b
        WHERE n >= min_bodu_prah AND p75 > p50;

        INSERT INTO dbo.Valuo_prahy
            (klasifikace, klic, metrika, pasmo, uroven, uzemi, n, median, p75,
             sigma, prah_dolni, prah_horni, datum_vypoctu)
        SELECT DISTINCT klasifikace, klic, metrika, pasmo, N'okres', okres, n,
               CAST(EXP(p50) AS decimal(18,2)), CAST(EXP(p75) AS decimal(18,2)),
               CAST(sig AS decimal(8,4)),
               CAST(GREATEST(EXP(p50 - k_faktor*sig), EXP(p50)/max_nasobek) AS decimal(18,2)),
               CAST(LEAST   (EXP(p50 + k_faktor*sig), EXP(p50)*max_nasobek) AS decimal(18,2)),
               GETDATE()
        FROM (
            SELECT DISTINCT klasifikace, klic, metrika, pasmo, okres, k_faktor,
                   max_nasobek,
                   COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika, pasmo, okres) AS n,
                   p50, p75, (p75 - p50)/0.6745 AS sig, min_bodu_prah
            FROM (
                SELECT klasifikace, klic, metrika, pasmo, okres, k_faktor,
                       min_bodu_prah, max_nasobek,
                       PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, okres) AS p50,
                       PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, okres) AS p75
                FROM #d WHERE jen_kraj = 0 AND klasifikace = @kl
            ) a
        ) b
        WHERE n >= min_bodu_prah AND p75 > p50;

        INSERT INTO dbo.Valuo_prahy
            (klasifikace, klic, metrika, pasmo, uroven, uzemi, n, median, p75,
             sigma, prah_dolni, prah_horni, datum_vypoctu)
        SELECT DISTINCT klasifikace, klic, metrika, pasmo, N'kraj', kraj_nazev, n,
               CAST(EXP(p50) AS decimal(18,2)), CAST(EXP(p75) AS decimal(18,2)),
               CAST(sig AS decimal(8,4)),
               CAST(GREATEST(EXP(p50 - k_faktor*sig), EXP(p50)/max_nasobek) AS decimal(18,2)),
               CAST(LEAST   (EXP(p50 + k_faktor*sig), EXP(p50)*max_nasobek) AS decimal(18,2)),
               GETDATE()
        FROM (
            SELECT DISTINCT klasifikace, klic, metrika, pasmo, kraj_nazev, k_faktor,
                   max_nasobek,
                   COUNT(*) OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kraj_nazev) AS n,
                   p50, p75, (p75 - p50)/0.6745 AS sig, min_bodu_prah
            FROM (
                SELECT klasifikace, klic, metrika, pasmo, kraj_nazev, k_faktor,
                       min_bodu_prah, max_nasobek,
                       PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kraj_nazev) AS p50,
                       PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lg)
                           OVER (PARTITION BY klasifikace, klic, metrika, pasmo, kraj_nazev) AS p75
                FROM #d WHERE klasifikace = @kl
            ) a
        ) b
        WHERE n >= min_bodu_prah AND p75 > p50;

        DELETE FROM #k WHERE klasifikace = @kl;
    END

    DROP TABLE #d;
    DROP TABLE #k;
END;

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_ruian_vzorku
   změněno 2026-10-23 18:34
   ------------------------------------------------------------------------ */

CREATE   PROCEDURE dbo.sp_prepocet_ruian_vzorku
AS
BEGIN
    SET NOCOUNT ON;
    /* DELETE, ne TRUNCATE — TRUNCATE potřebuje výhradní zámek tabulky
       a v krátkém spojení kvůli tomu celá procedura padá na timeout. */
    DELETE FROM dbo.RUIAN_vzorek;

    DECLARE @pp_min decimal(10,4) = (SELECT hodnota FROM dbo.CIS_RUIAN_parametry WHERE parametr='pomer_pp_op_min');
    DECLARE @pp_max decimal(10,4) = (SELECT hodnota FROM dbo.CIS_RUIAN_parametry WHERE parametr='pomer_pp_op_max');

    ;WITH vaz AS (
        SELECT v.cislo_vkladu, r.kod_so,
               MAX(CASE WHEN v.nemovitost='budova' THEN 1 ELSE 0 END) AS je_budova,
               MAX(CASE WHEN v.nemovitost='jednotka' THEN 1 ELSE 0 END) AS je_jednotka
        FROM dbo.Valuo_data v
        JOIN dbo.KN_parcel_data p ON p.id_valuo = v.id
        JOIN dbo.RUIAN_stavebni_objekty r ON r.gml_id = p.gml_id
        WHERE v.nemovitost IN ('budova','jednotka')
        GROUP BY v.cislo_vkladu, r.kod_so
    ),
    a AS (
        SELECT u.cislo_vkladu, COUNT(*) AS objektu,
               MAX(u.je_budova) AS ma_budovu, MAX(u.je_jednotka) AS ma_jednotku,
               MIN(YEAR(r.dokonceni)) AS rok_od, MAX(YEAR(r.dokonceni)) AS rok_do,
               MIN(CASE WHEN r.dokonceni IS NULL THEN NULL
                        WHEN (MONTH(r.dokonceni)=12 AND DAY(r.dokonceni)=31)
                          OR DAY(r.dokonceni)=1 THEN 0 ELSE 1 END) AS rok_presny,
               SUM(r.zastavena_plocha) AS zp, SUM(r.podlahova_plocha) AS pp,
               SUM(r.obestaveny_prostor) AS op, SUM(r.pocet_bytu) AS bytu,
               MAX(r.pocet_podlazi) AS podlazi, MIN(r.pomer_pp_op) AS pomer,
               MIN(r.druh_konstrukce_kod) AS kon, MIN(r.zpusob_vytapeni_kod) AS vyt,
               MIN(r.vybaveni_vytahem_kod) AS vth, MIN(r.pripojeni_vodovod_kod) AS vod,
               MIN(r.pripojeni_kanalizace_kod) AS kan, MIN(r.pripojeni_plyn_kod) AS plyn,
               MAX(r.soubor_datum) AS stav_k
        FROM vaz u JOIN dbo.RUIAN_stavebni_objekty r ON r.kod_so = u.kod_so
        GROUP BY u.cislo_vkladu
    )
    INSERT INTO dbo.RUIAN_vzorek (cislo_vkladu, ruian_objektu, ruian_zdroj, ruian_stav_k,
        ruian_rok, ruian_rok_nejnovejsi, ruian_rok_presny, ruian_pasmo, ruian_stari_let,
        ruian_zastavena_plocha, ruian_podlahova_plocha, ruian_obestaveny_prostor,
        ruian_pocet_podlazi, ruian_pocet_bytu, ruian_pomer_pp_op, ruian_plocha_podezrela,
        ruian_jedn_cena_Kc_m3, ruian_jedn_cena_Kc_m2, ruian_druh_konstrukce,
        ruian_vytapeni, ruian_vytah, pripojeni_vodovod_kod, pripojeni_kanalizace_kod,
        pripojeni_plyn_kod, prepocteno)
    SELECT a.cislo_vkladu, a.objektu,
           CASE WHEN a.ma_budovu=1 AND a.ma_jednotku=1 THEN N'obojí'
                WHEN a.ma_budovu=1 THEN N'budova' ELSE N'jednotka' END,
           a.stav_k, a.rok_od, CASE WHEN a.rok_do<>a.rok_od THEN a.rok_do END,
           CAST(a.rok_presny AS bit), s.pasmo,
           CASE WHEN a.rok_od IS NOT NULL THEN YEAR(GETDATE())-a.rok_od END,
           a.zp, a.pp, a.op, a.podlazi, a.bytu, a.pomer,
           CAST(CASE WHEN a.pomer IS NULL THEN NULL
                     WHEN a.pomer < @pp_min OR a.pomer > @pp_max THEN 1 ELSE 0 END AS bit),
           CASE WHEN a.ma_budovu=1 AND a.op>0 THEN CAST(c.cena_Kc/a.op AS decimal(18,2)) END,
           CASE WHEN a.ma_budovu=1 AND a.pp>0 THEN CAST(c.cena_Kc/a.pp AS decimal(18,2)) END,
           ck.nazev, cv.nazev, cx.nazev, a.vod, a.kan, a.plyn, SYSDATETIME()
    FROM a
    LEFT JOIN (SELECT cislo_vkladu, MAX(cena_Kc) AS cena_Kc FROM dbo.Valuo_data GROUP BY cislo_vkladu) c
           ON c.cislo_vkladu = a.cislo_vkladu
    LEFT JOIN dbo.CIS_stari_stavby s ON a.rok_od BETWEEN s.rok_od AND s.rok_do
    LEFT JOIN dbo.CIS_RUIAN ck ON ck.ciselnik='DruhKonstrukce'  AND ck.kod=a.kon
    LEFT JOIN dbo.CIS_RUIAN cv ON cv.ciselnik='ZpusobVytapeni'  AND cv.kod=a.vyt
    LEFT JOIN dbo.CIS_RUIAN cx ON cx.ciselnik='VybaveniVytahem' AND cx.kod=a.vth;
END;

GO

/* ------------------------------------------------------------------------
   SQL_STORED_PROCEDURE  dbo.sp_prepocet_typu_prevodu
   změněno 2026-10-22 21:23
   ------------------------------------------------------------------------ */


CREATE   PROCEDURE dbo.sp_prepocet_typu_prevodu
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Valuo_data
    SET typ_prevodu =
        CASE
            WHEN CAST(listina AS varchar(500)) LIKE '%dražb%'
              OR CAST(listina AS varchar(500)) LIKE '%příklep%'
              OR CAST(listina AS varchar(500)) LIKE '%exekutor%'
                 THEN 'DRAZBA'
            WHEN CAST(listina AS varchar(500)) LIKE '%311/2013%'
                 THEN 'PREVOD_Z_DRUZSTVA'
            WHEN CAST(listina AS varchar(500)) LIKE '%směnná%'
                 THEN 'SMENA'
            WHEN CAST(listina AS varchar(500)) LIKE '%darovací%'
                 THEN 'DAROVANI'
            WHEN CAST(listina AS varchar(500)) LIKE '%vklad do základního kapitálu%'
              OR CAST(listina AS varchar(500)) LIKE '%nepeněžit%'
                 THEN 'VKLAD_DO_KAPITALU'
            WHEN CAST(listina AS varchar(500)) LIKE '%dědic%'
              OR CAST(listina AS varchar(500)) LIKE '%pozůstalost%'
                 THEN 'DEDICTVI'
            ELSE 'KUPNI_SMLOUVA'
        END;
END;

GO

/* ------------------------------------------------------------------------
   VIEW  dbo.v_cenove_hladiny
   změněno 2026-10-23 10:00
   ------------------------------------------------------------------------ */



/* ---------- 23b.4 HLADINY S PRÁVEM VETA --------------------
   Proti kroku 23 se mění jen to, že skupina zatříděná jako TRH
   zůstává ve výpočtu mediánu.                                */

CREATE   VIEW dbo.v_cenove_hladiny
AS
WITH zaklad AS (
    SELECT  q.kod_ku,
            c.okres_nazev,
            c.kraj_nazev,
            q.klasifikace,
            t.prah_bodu,
            CASE WHEN q.klasifikace = 'JC_PARCELY'
                  AND up.fvu_kod IS NOT NULL THEN N'FVU:'  + up.fvu_kod
                 ELSE                              N'DRUH:' + ISNULL(q.druh, '?')
            END                 AS klic,
            q.jedn_cena_Kc_m2   AS jc
    FROM dbo.v_Valuo_vzorek q
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod      = q.kod_ku
    JOIN dbo.CIS_prahy_ceny        t ON t.klasifikace = q.klasifikace
    LEFT JOIN dbo.v_vklad_UP      up ON up.cislo_vkladu = q.cislo_vkladu
    WHERE q.jedn_cena_Kc_m2 > 0
      AND q.cena_Kc >= t.cena_min
      AND ISNULL(q.mena, 'CZK') = 'CZK'
      AND q.typ_prevodu         = 'KUPNI_SMLOUVA'
      AND ISNULL(q.prodeju_tehoz_objektu, 0) < 5
      AND q.rok >= YEAR(GETDATE()) - 5
      AND NOT EXISTS (
            SELECT 1
            FROM dbo.Valuo_hromadne_prevody h
            LEFT JOIN dbo.CIS_typy_hromadneho_prevodu y
                   ON y.typ_jevu = h.typ_jevu
            WHERE h.klasifikace     = q.klasifikace
              AND h.kat_uzemi       = q.kat_uzemi
              AND h.druh            = ISNULL(q.druh, '?')
              AND h.jedn_cena_Kc_m2 = q.jedn_cena_Kc_m2
              AND ISNULL(y.do_medianu, 0) = 0)   /* TRH se nevyřazuje */
),
u_ku AS (
    SELECT DISTINCT kod_ku, klasifikace, klic, prah_bodu,
           COUNT(*) OVER (PARTITION BY kod_ku, klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY kod_ku, klasifikace, klic) AS med
    FROM zaklad
),
u_okres AS (
    SELECT DISTINCT COALESCE(okres_nazev, kraj_nazev) AS okres,
           klasifikace, klic, prah_bodu,
           COUNT(*) OVER (PARTITION BY COALESCE(okres_nazev, kraj_nazev),
                                       klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY COALESCE(okres_nazev, kraj_nazev),
                                  klasifikace, klic) AS med
    FROM zaklad
),
u_kraj AS (
    SELECT DISTINCT kraj_nazev, klasifikace, klic, prah_bodu,
           COUNT(*) OVER (PARTITION BY kraj_nazev, klasifikace, klic) AS n,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY jc)
               OVER (PARTITION BY kraj_nazev, klasifikace, klic) AS med
    FROM zaklad
)
SELECT DISTINCT
        z.kod_ku,
        z.klasifikace,
        z.klic,
        CAST(COALESCE(a.med, b.med, c.med) AS decimal(14,2)) AS median,
        COALESCE(a.n, b.n, c.n)                              AS bodu,
        CASE WHEN a.med IS NOT NULL THEN N'k.ú.'
             WHEN b.med IS NOT NULL THEN N'okres'
             WHEN c.med IS NOT NULL THEN N'kraj'
             ELSE N'—' END                                   AS uroven
FROM zaklad z
LEFT JOIN u_ku    a ON a.kod_ku = z.kod_ku
                   AND a.klasifikace = z.klasifikace
                   AND a.klic = z.klic AND a.n >= z.prah_bodu
LEFT JOIN u_okres b ON b.okres = COALESCE(z.okres_nazev, z.kraj_nazev)
                   AND b.klasifikace = z.klasifikace
                   AND b.klic = z.klic AND b.n >= z.prah_bodu
LEFT JOIN u_kraj  c ON c.kraj_nazev = z.kraj_nazev
                   AND c.klasifikace = z.klasifikace
                   AND c.klic = z.klic AND c.n >= z.prah_bodu;

GO

/* ------------------------------------------------------------------------
   VIEW  dbo.v_KN_parcely
   změněno 2026-10-22 15:58
   ------------------------------------------------------------------------ */



/* ============================================================
   10.7  NÁZEV ÚZEMÍ SE NOVĚ BERE Z ČÍSELNÍKU
   ------------------------------------------------------------
   Kde jsi dřív psal k.kat_uzemi, napiš JOIN na číselník.
   Pohled níž to dělá za tebe.
   ============================================================ */

CREATE   VIEW dbo.v_KN_parcely
AS
SELECT  k.id,
        k.id_valuo,
        k.gml_id,
        k.kod_ku,
        c.ku_nazev                              AS kat_uzemi,
        c.obec_nazev                            AS obec,
        COALESCE(c.okres_nazev, c.kraj_nazev)   AS okres,
        c.kraj_nazev                            AS kraj,
        k.parcel_number,
        k.areaValue_m2,
        k.beginLifespanVersion                  AS zapsano_od,
        k.refPoint_x,
        k.refPoint_y,
        k.refPoint_lon,
        k.refPoint_lat,
        k.geo_bod,
        k.geo_plocha,
        k.id_UP_FVU_data,
        u.fvu_kod,
        u.mira_vyuziti,
        u.podil_pct                             AS podil_v_ploche_pct
FROM dbo.KN_parcel_data k
LEFT JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
LEFT JOIN dbo.KN_parcel_UP           u ON u.kn_id = k.id AND u.poradi = 1;

GO

/* ------------------------------------------------------------------------
   VIEW  dbo.v_RUIAN_budovy
   změněno 2026-10-23 18:24
   ------------------------------------------------------------------------ */


/* ---------------------------------------------------------------------------
   1. v_RUIAN_budovy — zrušený příznak nahrazen poměrem

   ruian_pomer_pp_op = 3 x podlahová plocha / obestavěný prostor.
   Hodnota je data, mez je parametr v CIS_RUIAN_parametry — proto se
   příznak ruian_plocha_podezrela počítá až tady v pohledu.
   --------------------------------------------------------------------------- */
CREATE   VIEW dbo.v_RUIAN_budovy AS
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

/* ------------------------------------------------------------------------
   VIEW  dbo.v_RUIAN_jednotky
   změněno 2026-10-23 17:29
   ------------------------------------------------------------------------ */


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

/* ------------------------------------------------------------------------
   VIEW  dbo.v_RUIAN_vzorek
   změněno 2026-10-23 18:24
   ------------------------------------------------------------------------ */


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
CREATE   VIEW dbo.v_RUIAN_vzorek AS
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

/* ------------------------------------------------------------------------
   VIEW  dbo.v_Valuo
   změněno 2026-10-22 11:23
   ------------------------------------------------------------------------ */

CREATE   VIEW dbo.v_Valuo
AS
SELECT  v.id,
        v.cislo_vkladu,
        v.datum_podani,
        v.datum_zplatneni,
        v.rok,
        v.mesic,

        /* ověřená územní identifikace z číselníku ČÚZK */
        v.kod_ku,
        c.ku_nazev                              AS kat_uzemi,
        c.obec_nazev                            AS obec,
        COALESCE(c.okres_nazev, c.kraj_nazev)   AS okres,
        c.kraj_nazev                            AS kraj,

        /* předmět a cena */
        v.nemovitost,
        v.typ,
        v.typ_plochy,
        v.popis,
        v.adresa,
        v.plocha                                AS vymera_m2,
        v.cenovy_udaj                           AS cena_Kc,
        v.mena,
        CAST(v.cenovy_udaj / NULLIF(v.plocha, 0)
             AS decimal(14,2))                  AS jedn_cena_Kc_m2,

        /* prostorové údaje */
        v.geo_bod,
        v.LAT,
        v.LON,
        v.geo_zdroj,

        /* původní, neověřené hodnoty — pro dohledání */
        v.kat_uzemi                             AS kat_uzemi_puvodni,
        v.okres                                 AS okres_puvodni
FROM dbo.Valuo_data v
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku
WHERE v.geo_zdroj = 'KN_refPoint';

GO

/* ------------------------------------------------------------------------
   VIEW  dbo.v_Valuo_karta_vkladu
   změněno 2026-10-25 15:41
   ------------------------------------------------------------------------ */

CREATE   VIEW dbo.v_Valuo_karta_vkladu
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
                 ROW_NUMBER() OVER (PARTITION BY d.cislo_vkladu
                     ORDER BY ISNULL(t.priorita, 99), ISNULL(d.plocha, 0) DESC, d.id) AS rn
          FROM dbo.Valuo_data d
          LEFT JOIN dbo.CIS_nemovitost_typ t ON t.nemovitost = d.nemovitost AND t.typ = d.typ
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
reg AS (
    SELECT p.cislo_vkladu,
        MAX(CASE WHEN p.zdroj = 'RUIAN_NA_BYT' THEN p.plocha END) AS plocha_na_byt,
        MAX(CASE WHEN p.zdroj = 'RUIAN_NA_BYT'
                  AND p.poznamka LIKE N'nedůvěryhodné%' THEN 1 ELSE 0 END) AS na_byt_neduveryhodne,
        SUM(CASE WHEN p.zdroj = 'PODIL_RADEK' AND p.id > 0 THEN p.plocha END) AS plocha_z_podilu,
        COUNT(CASE WHEN p.id > 0 THEN 1 END) AS kandidatu_radku
    FROM dbo.Valuo_plochy p GROUP BY p.cislo_vkladu
),
alt AS (
    SELECT y.cislo_vkladu, y.plocha AS plocha_navrh, c.nazev AS plocha_navrh_zdroj
    FROM (SELECT p.cislo_vkladu, p.plocha, p.zdroj,
                 ROW_NUMBER() OVER (PARTITION BY p.cislo_vkladu ORDER BY z.poradi) AS rn
          FROM dbo.Valuo_plochy p
          JOIN dbo.CIS_plochy_zdroje z ON z.kod = p.zdroj
          JOIN dbo.Valuo_vklad_plocha vp ON vp.cislo_vkladu = p.cislo_vkladu
          WHERE p.id > 0 AND p.pouzito = 0 AND p.platny = 1 AND z.pro_cenu = 1
            AND p.plocha > 0 AND vp.radku_nosnych = 1 AND vp.radku_mimo = 0
            AND EXISTS (SELECT 1 FROM dbo.Valuo_plochy u
                        WHERE u.cislo_vkladu = p.cislo_vkladu AND u.id = p.id
                          AND u.pouzito = 1 AND u.zdroj = 'VALUO_RADEK')) y
    JOIN dbo.CIS_plochy_zdroje c ON c.kod = y.zdroj
    WHERE y.rn = 1
),
prm AS (
    SELECT MAX(CASE WHEN parametr = 'nabyt_pomer_max' THEN hodnota END) AS nabyt_max,
           MAX(CASE WHEN parametr = 'jc_pasmo_nasobek' THEN hodnota END) AS jc_pasmo
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
    /* --- plocha a výměra nosné nemovitosti (krok 46) --------------------
       Ruční zjištění znalce má přednost vždy. Jinak plochu i výměru drží
       Valuo_vklad_plocha, které od kroku 46 pokrývá všechny tři kategorie:
       jednotku, budovu i soubor pozemků. Nemá-li podlahovou plochu každá
       nosná nemovitost, `plocha` je prázdná a nic se nedělí — uvádí se jen
       celková cena (pokyn znalce 25. 10. 2026). */
    CASE WHEN r.plocha_rucne > 0 THEN r.plocha_rucne ELSE vp.plocha END AS plocha_podlahova_karty,
    CASE WHEN r.plocha_rucne > 0 THEN N'ověřeno znalcem' ELSE vp.plocha_zdroje END AS plocha_podlahova_zdroj,
    vp.nemovitost AS nosna_nemovitost, vp.nosna_skupina, vp.nosny_typ, vp.nosna_priorita,
    vp.radku_nosnych, vp.radku_mimo, vp.rozpusteno, vp.nalezu AS nalezu_plochy,
    vp.vymera_nosna, vp.parcel_nosnych, vp.vymera_podilu,
    rg.kandidatu_radku, rg.plocha_z_podilu, rg.plocha_na_byt,
    ISNULL(vp.nalez_dum, 0)          AS nalez_plocha_cely_dum,
    ISNULL(vp.nalez_skala, 0)        AS nalez_skala,
    ISNULL(vp.nalez_vice_nosnych, 0) AS nalez_vice_nosnych,
    ISNULL(vp.nalez_bez_plochy, 0)   AS nalez_bez_plochy,
    a.plocha_navrh, a.plocha_navrh_zdroj,
    CAST(NULL AS decimal(18,4)) AS podil_nasobek,
    CAST(NULL AS int)           AS posun_radu,
    CAST(0 AS bit)              AS nalez_plocha_posun,
    CASE WHEN rg.plocha_na_byt > 0 AND rg.na_byt_neduveryhodne = 0
              AND vp.plocha > 0
              AND (vp.plocha / rg.plocha_na_byt > prm.nabyt_max
                OR rg.plocha_na_byt / vp.plocha > prm.nabyt_max)
         THEN 1 ELSE 0 END AS nalez_plocha_mimo_ocekavani,
    mj.median_jc AS jc_median_ku, mj.vzorku AS jc_vzorku_ku,
    CASE WHEN mj.median_jc IS NULL THEN 'neověřeno'
         WHEN v.cena_Kc > 0 AND COALESCE(NULLIF(r.plocha_rucne, 0), vp.plocha, vp.vymera_nosna) > 0
              AND v.cena_Kc / COALESCE(NULLIF(r.plocha_rucne, 0), vp.plocha, vp.vymera_nosna)
                  BETWEEN mj.median_jc / prm.jc_pasmo AND mj.median_jc * prm.jc_pasmo
         THEN 'v pásmu'
         WHEN v.cena_Kc > 0 AND COALESCE(NULLIF(r.plocha_rucne, 0), vp.plocha, vp.vymera_nosna) > 0
         THEN 'k prověření'
    END AS jc_verdikt,
    rv.ruian_podlahova_plocha, rv.ruian_zastavena_plocha, rv.ruian_obestaveny_prostor,
    rv.ruian_pocet_podlazi, rv.ruian_pocet_bytu, rv.ruian_rok, rv.ruian_rok_presny,
    rv.ruian_pasmo, rv.ruian_druh_konstrukce, rv.ruian_vytapeni, rv.ruian_vytah,
    rv.pripojeni_vodovod_kod, rv.pripojeni_kanalizace_kod, rv.pripojeni_plyn_kod,
    rv.ruian_pomer_pp_op, rv.ruian_plocha_podezrela,
    kv.pp_index_celku, kv.plocha_celku_m2, kv.obvod_celku_m, kv.casti_celku,
    kv.pp_index_vse, kv.plocha_vse_m2, kv.obvod_vse_m, kv.casti_vse,
    r.pouzitelnost, r.pouzitelnost_duvod, r.plocha_rucne, r.plocha_rucne_zdroj,
    r.kdy AS rucne_kdy,
    ISNULL(ha.plocha_z_podilu, 0) AS nalez_plocha_z_podilu,
    (SELECT COUNT(*) FROM dbo.Valuo_vklad_nalezy n
     WHERE n.cislo_vkladu = v.cislo_vkladu) AS nalezu_rucne,
    (SELECT COUNT(*) FROM dbo.Valuo_poznamky p
     WHERE p.cislo_vkladu = v.cislo_vkladu) AS poznamek,
    CASE WHEN COALESCE(NULLIF(r.plocha_rucne, 0), vp.plocha) > 0
         THEN CAST(v.cena_Kc / COALESCE(NULLIF(r.plocha_rucne, 0), vp.plocha) AS decimal(14,2))
    END AS jc_Kc_m2_podlahova,
    /* Kč/m² nosné výměry — u pozemkového vkladu hlavní metrika, u vkladu
       se stavbou doplňující. Nosná výměra jsou výhradní parcely bez tvaru
       pásu a bez druhu komunikace; není-li žádná, je to balík a výměra
       zůstane prázdná. */
    CASE WHEN vp.vymera_nosna > 0
         THEN CAST(v.cena_Kc / vp.vymera_nosna AS decimal(14,2)) END AS jc_Kc_m2_nosne_vymery,
    CASE WHEN vp.vymera_nosna > 0 AND vp.vymera_podilu > 0
         THEN CAST(v.cena_Kc / (vp.vymera_nosna + vp.vymera_podilu) AS decimal(14,2))
    END AS jc_Kc_m2_s_podilem,
    CASE WHEN v.pocet_jednotek = 0 AND k.vymera_vyhradni_celek > 0
         THEN CAST(v.cena_Kc / k.vymera_vyhradni_celek AS decimal(14,2)) END AS jc_Kc_m2_vyhradni_celek,
    CASE WHEN v.pocet_jednotek = 0 AND k.vymera_pozemku_vse > 0
         THEN CAST(v.cena_Kc / k.vymera_pozemku_vse AS decimal(14,2)) END AS jc_Kc_m2_vsech_pozemku,
    CASE WHEN v.pocet_jednotek = 0 AND rv.ruian_obestaveny_prostor > 0
         THEN CAST(v.cena_Kc / rv.ruian_obestaveny_prostor AS decimal(14,2)) END AS jc_Kc_m3
FROM vklad v
LEFT JOIN hlavni h ON h.cislo_vkladu = v.cislo_vkladu
LEFT JOIN hlavni_agr ha ON ha.cislo_vkladu = v.cislo_vkladu
LEFT JOIN druhy d ON d.cislo_vkladu = v.cislo_vkladu
LEFT JOIN karta k ON k.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.Valuo_vklad_plocha vp ON vp.cislo_vkladu = v.cislo_vkladu
LEFT JOIN reg rg ON rg.cislo_vkladu = v.cislo_vkladu
LEFT JOIN alt a ON a.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_ku_median_jc mj ON mj.kod_ku = v.kod_ku
                                 AND mj.nosna_skupina = vp.nosna_skupina
CROSS JOIN prm
LEFT JOIN dbo.Valuo_karta_vklad kv ON kv.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.RUIAN_vzorek rv ON rv.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.Valuo_vklad_rucne r ON r.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku;

GO

/* ------------------------------------------------------------------------
   VIEW  dbo.v_Valuo_parcela_z_popisu
   změněno 2026-10-22 21:45
   ------------------------------------------------------------------------ */


/* ---------- 22a.1 POMOCNÝ POHLED S PŘÍZNAKEM --------------- */

CREATE   VIEW dbo.v_Valuo_parcela_z_popisu
AS
SELECT  id,
        cislo_vkladu,
        nemovitost,
        vklad_klasifikace,
        je_stavebni,
        je_soucasti_pozemku,
        LTRIM(RTRIM(bez_zavorek)) AS parcela_s_uzemim
FROM (
    SELECT id, cislo_vkladu, nemovitost, vklad_klasifikace,
           je_stavebni, je_soucasti_pozemku,
           CASE WHEN CHARINDEX(N' (', za_prefixem) > 0
                THEN LEFT(za_prefixem, CHARINDEX(N' (', za_prefixem) - 1)
                ELSE za_prefixem END AS bez_zavorek
    FROM (
        SELECT id, cislo_vkladu, nemovitost, vklad_klasifikace,
               CASE WHEN popis LIKE N'stavební č. %' THEN 1 ELSE 0 END AS je_stavebni,
               CASE WHEN popis LIKE N'%součástí je stavba%' THEN 1 ELSE 0 END
                                                                AS je_soucasti_pozemku,
               CASE WHEN popis LIKE N'stavební č. %' THEN SUBSTRING(popis, 13, 400)
                    WHEN popis LIKE N'č. %'          THEN SUBSTRING(popis,  4, 400)
               END AS za_prefixem
        FROM dbo.Valuo_data
    ) a
    WHERE za_prefixem IS NOT NULL
) b;

GO

/* ------------------------------------------------------------------------
   VIEW  dbo.v_Valuo_vzorek
   změněno 2026-10-22 21:45
   ------------------------------------------------------------------------ */



/* ---------- 22a.3 ZÁKLADNÍ POHLED -------------------------- */

CREATE   VIEW dbo.v_Valuo_vzorek
AS
WITH opakovani AS (
    SELECT  popis, plocha,
            COUNT(DISTINCT cislo_vkladu) AS prodeju
    FROM dbo.Valuo_data
    WHERE nemovitost = N'budova' AND plocha > 0
    GROUP BY popis, plocha
),
parcely_ve_vkladu AS (
    SELECT DISTINCT cislo_vkladu
    FROM dbo.v_Valuo_parcela_z_popisu
    WHERE nemovitost = N'parcela'
),
stavba_vs_pozemek AS (
    /* 0 jen při obou podmínkách zároveň: stavba je samostatná
       věc A parcela pod ní se neprodává, přesto se ve vkladu
       jiné parcely prodávají.                                */
    SELECT  b.cislo_vkladu,
            MIN(CASE WHEN b.je_soucasti_pozemku = 1    THEN 1
                     WHEN pod.cislo_vkladu IS NOT NULL THEN 1
                     WHEN pv.cislo_vkladu IS NULL      THEN 1
                     ELSE 0 END) AS cena_patri_stavbe
    FROM dbo.v_Valuo_parcela_z_popisu b
    LEFT JOIN parcely_ve_vkladu pv
           ON pv.cislo_vkladu = b.cislo_vkladu
    LEFT JOIN dbo.v_Valuo_parcela_z_popisu pod
           ON pod.cislo_vkladu     = b.cislo_vkladu
          AND pod.nemovitost       = N'parcela'
          AND pod.parcela_s_uzemim = b.parcela_s_uzemim
    WHERE b.nemovitost = N'budova'
    GROUP BY b.cislo_vkladu
),
vklad AS (
    SELECT  v.cislo_vkladu,
            MIN(v.id)                      AS id_prvni,
            MIN(v.datum_zplatneni)         AS datum_zplatneni,
            MIN(v.rok)                     AS rok,
            MIN(v.mesic)                   AS mesic,
            MIN(v.kod_ku)                  AS kod_ku,
            MAX(v.cena_Kc)                 AS cena,
            MAX(v.cenovy_udaj)             AS cena_v_mene,
            MIN(v.mena)                    AS mena,
            MIN(v.kurz_pouzity)            AS kurz_pouzity,
            MIN(v.kurz_datum)              AS kurz_datum,
            MIN(v.typ_prevodu)             AS typ_prevodu,
            MIN(v.vklad_klasifikace)       AS klasifikace,
            MIN(v.vklad_duvod)             AS duvod,
            MIN(v.vklad_nemovitosti)       AS nemovitosti,
            MIN(v.vklad_duplicit)          AS duplicit,
            MIN(v.vklad_plocha_parcel)     AS plocha_parcel,
            MIN(v.vklad_plocha_jednotky)   AS plocha_jednotky,
            MIN(v.vklad_plocha_budovy)     AS plocha_budovy,

            MAX(CASE WHEN v.popis LIKE N'%součástí je stavba%'
                     THEN 1 ELSE 0 END)    AS na_pozemku_stavba,

            /* stavba zapsaná jako samostatná nemovitost */
            MAX(CASE WHEN v.nemovitost = N'budova'
                      AND v.popis NOT LIKE N'%součástí je stavba%'
                     THEN 1 ELSE 0 END)    AS stavba_samostatna,

            MIN(CASE WHEN v.nemovitost = N'budova'
                     THEN v.typ_plochy END) AS typ_plochy_stavby,

            MAX(CASE WHEN v.nemovitost = N'budova'
                     THEN o.prodeju END)    AS prodeju_tehoz_objektu,

            MIN(CASE WHEN v.vklad_klasifikace = 'JC_JEDNOTKA'
                      AND v.nemovitost = N'jednotka' THEN v.typ
                     WHEN v.vklad_klasifikace = 'CELEK_BUDOVA'
                      AND v.nemovitost = N'budova'   THEN v.typ
                     WHEN v.vklad_klasifikace = 'JC_PARCELY'
                      AND v.nemovitost = N'parcela'  THEN v.typ
                END)                       AS druh,
            COUNT(DISTINCT v.typ)          AS ruznych_druhu
    FROM dbo.Valuo_data v
    LEFT JOIN opakovani o ON o.popis = v.popis AND o.plocha = v.plocha
                         AND v.nemovitost = N'budova'
    WHERE v.geo_zdroj   = 'KN_refPoint'
      AND v.cenovy_udaj > 0
    GROUP BY v.cislo_vkladu
)
SELECT  k.cislo_vkladu,
        k.datum_zplatneni,
        k.rok,
        k.mesic,

        k.kod_ku,
        c.ku_nazev                              AS kat_uzemi,
        c.obec_nazev                            AS obec,
        COALESCE(c.okres_nazev, c.kraj_nazev)   AS okres,
        c.kraj_nazev                            AS kraj,

        k.klasifikace,
        k.duvod,
        k.typ_prevodu,
        k.druh,
        k.ruznych_druhu,
        k.nemovitosti                           AS nemovitosti_ve_vkladu,
        k.duplicit                              AS duplicitnich_radku,
        k.na_pozemku_stavba,
        k.stavba_samostatna,
        k.typ_plochy_stavby,
        k.prodeju_tehoz_objektu,
        ISNULL(sp.cena_patri_stavbe, 1)         AS cena_patri_stavbe,

        k.plocha_parcel                         AS plocha_parcel_m2,
        k.plocha_jednotky                       AS plocha_jednotky_m2,
        k.plocha_budovy                         AS plocha_budovy_m2,

        CASE WHEN k.typ_plochy_stavby = N'Podlahová plocha'
             THEN k.plocha_budovy END           AS plocha_podlahova_m2,

        k.cena                                  AS cena_Kc,
        k.mena,
        k.cena_v_mene,
        k.kurz_pouzity,
        k.kurz_datum,

        CASE
            WHEN k.klasifikace = 'JC_PARCELY' AND k.na_pozemku_stavba = 1
                 THEN NULL
            WHEN k.klasifikace = 'JC_PARCELY'
                 THEN CAST(k.cena / NULLIF(k.plocha_parcel, 0) AS decimal(14,2))
            WHEN k.klasifikace = 'JC_JEDNOTKA'
                 THEN CAST(k.cena / NULLIF(k.plocha_jednotky, 0) AS decimal(14,2))
            WHEN k.klasifikace = 'CELEK_BUDOVA'
             AND k.typ_plochy_stavby = N'Podlahová plocha'
             AND ISNULL(sp.cena_patri_stavbe, 1) = 1
                 THEN CAST(k.cena / NULLIF(k.plocha_budovy, 0) AS decimal(14,2))
            ELSE NULL
        END                                     AS jedn_cena_Kc_m2,

        p.geo_bod,
        p.LAT,
        p.LON
FROM vklad k
JOIN dbo.Valuo_data p            ON p.id     = k.id_prvni
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
LEFT JOIN stavba_vs_pozemek sp   ON sp.cislo_vkladu = k.cislo_vkladu;

GO

/* ------------------------------------------------------------------------
   VIEW  dbo.v_Valuo_vzorek_q
   změněno 2026-10-24 13:55
   ------------------------------------------------------------------------ */

CREATE VIEW dbo.v_Valuo_vzorek_q
AS
WITH hlavni AS (
    SELECT  v.cislo_vkladu,
            MIN(v.nemovitost) AS nemovitost,
            MIN(v.typ)        AS typ,
            MIN(v.typ_plochy) AS typ_plochy,
            MIN(CASE WHEN CHARINDEX(N'domu a pozemku ', v.popis) > 0
                     THEN TRY_CONVERT(decimal(18,2),
                            SUBSTRING(v.popis,
                              CHARINDEX(N'domu a pozemku ', v.popis) + 15,
                              NULLIF(CHARINDEX(N'/', v.popis,
                                       CHARINDEX(N'domu a pozemku ',
                                                 v.popis) + 15), 0)
                              - CHARINDEX(N'domu a pozemku ', v.popis) - 15))
                END)          AS citatel_podilu
    FROM dbo.Valuo_data v
    WHERE (v.vklad_klasifikace = 'JC_JEDNOTKA'  AND v.nemovitost = N'jednotka')
       OR (v.vklad_klasifikace = 'CELEK_BUDOVA' AND v.nemovitost = N'budova')
       OR (v.vklad_klasifikace = 'JC_PARCELY'   AND v.nemovitost = N'parcela')
    GROUP BY v.cislo_vkladu
),
metrika AS (
    SELECT  v.cislo_vkladu,
            ISNULL(m.metrika,
                   CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                        ELSE 'CELEK' END)            AS metrika_dle_ciselniku,
            m.mez_vuci_kraji                         AS mez_druh,
            CASE
                WHEN v.klasifikace = 'JC_PARCELY'
                 AND v.na_pozemku_stavba = 1                 THEN 'CELEK'
                WHEN v.klasifikace = 'CELEK_BUDOVA'
                 AND v.cena_patri_stavbe = 0                 THEN 'CELEK'
                WHEN v.klasifikace = 'CELEK_BUDOVA'
                 AND ISNULL(v.prodeju_tehoz_objektu, 0) >= 5 THEN 'CELEK'
                WHEN ISNULL(m.metrika, '') = 'JC_PODLAHOVA'
                 AND v.plocha_podlahova_m2 > 0               THEN 'JC'
                WHEN ISNULL(m.metrika, '') = 'JC_PODLAHOVA'  THEN 'CELEK'
                ELSE ISNULL(m.metrika,
                       CASE WHEN v.klasifikace = 'JC_PARCELY' THEN 'JC'
                            ELSE 'CELEK' END)
            END                                              AS metrika
    FROM dbo.v_Valuo_vzorek v
    LEFT JOIN hlavni p ON p.cislo_vkladu = v.cislo_vkladu
    LEFT JOIN dbo.CIS_metrika_ceny m
           ON m.nemovitost = p.nemovitost AND m.typ = p.typ
)
SELECT  v.cislo_vkladu, v.datum_zplatneni, v.rok, v.mesic, v.kod_ku,
        v.kat_uzemi, v.obec, v.okres, v.kraj, v.klasifikace, v.duvod,
        v.typ_prevodu, v.druh, v.ruznych_druhu, v.nemovitosti_ve_vkladu,
        v.duplicitnich_radku, v.plocha_parcel_m2, v.plocha_jednotky_m2,
        v.plocha_budovy_m2, v.plocha_podlahova_m2, v.typ_plochy_stavby,
        v.prodeju_tehoz_objektu, v.cena_patri_stavbe, v.stavba_samostatna,
        v.cena_Kc, v.mena, v.cena_v_mene, v.kurz_pouzity, v.kurz_datum,

        CASE WHEN hp.jedn_cena_Kc_m2 IS NOT NULL
               OR hc.cena_skupiny_Kc IS NOT NULL THEN 1 ELSE 0 END AS hromadny_prevod,
        COALESCE(hp.vkladu, hc.vkladu)              AS hromadne_vkladu,
        COALESCE(hp.typ_jevu, hc.typ_jevu)          AS typ_jevu,
        COALESCE(hp.poznamka, hc.poznamka)          AS hromadna_poznamka,
        CASE WHEN hp.jedn_cena_Kc_m2 IS NOT NULL THEN 'JC'
             WHEN hc.cena_skupiny_Kc IS NOT NULL THEN 'CENA' END AS hromadny_detektor,

        mt.metrika,
        CASE WHEN mt.metrika = 'JC' THEN v.jedn_cena_Kc_m2 END AS jedn_cena_Kc_m2,

        up.fvu_kod, up.mira_vyuziti, fs.skupina AS fvu_skupina,
        vp.pasmo AS velikostni_pasmo,

        h.hodnota AS porovnavana_hodnota,

        CAST(p.median     AS decimal(18,2)) AS median_Kc,
        CAST(p.prah_dolni AS decimal(18,2)) AS mez_zdola,
        CAST(p.prah_horni AS decimal(18,2)) AS mez_shora,
        p.n AS bodu_v_mezi,
        p.uroven AS uroven_meze,
        CASE WHEN p.median > 0
             THEN CAST(h.hodnota / p.median AS decimal(10,3)) END AS pomer_k_medianu,

        CAST(kr.median AS decimal(18,2))            AS median_kraj,
        CAST(kr.median * NULLIF(COALESCE(mt.mez_druh, t.mez_vuci_kraji), 0)
             AS decimal(18,2))                      AS mez_trzni_hladina,

        CASE
            WHEN ISNULL(v.mena, 'CZK') <> 'CZK'
             AND v.kurz_pouzity IS NULL              THEN N'cizí měna bez kurzu'
            WHEN v.typ_prevodu <> 'KUPNI_SMLOUVA'    THEN N'nestandardní převod'
            WHEN v.klasifikace = 'PRAVO_STAVBY'       THEN N'právo stavby'
            WHEN hp.jedn_cena_Kc_m2 IS NOT NULL
             AND ISNULL(y.do_medianu, 0) = 0         THEN N'hromadný převod'
            WHEN hc.cena_skupiny_Kc IS NOT NULL
             AND ISNULL(yc.do_medianu, 0) = 0        THEN N'hromadný převod'
            WHEN v.klasifikace = 'JC_PARCELY'
             AND v.cena_Kc < ISNULL(mzk.mez_Kc, mzg.mez_Kc)
                                                     THEN N'podíl nebo symbolický převod'
            WHEN v.klasifikace = 'CELEK_BUDOVA'
             AND v.cena_patri_stavbe = 0              THEN N'oddělené vlastnictví'
            WHEN v.klasifikace = 'CELEK_BUDOVA'
             AND ISNULL(v.prodeju_tehoz_objektu, 0) >= 5
                                                     THEN N'podíl na budově'
            WHEN mt.metrika_dle_ciselniku = 'JC_PODLAHOVA'
             AND ISNULL(v.plocha_podlahova_m2, 0) = 0
                                                     THEN N'chybí podlahová plocha'
            WHEN v.klasifikace = 'JC_PARCELY'
             AND v.na_pozemku_stavba = 1              THEN N'chybí podlahová plocha'
            WHEN mt.metrika = 'JC'
             AND ISNULL(v.jedn_cena_Kc_m2, 0) <= 0    THEN N'bez JC'
            WHEN ISNULL(h.hodnota, 0) <= 0            THEN N'bez ceny'

            /* Cena řádově pod krajskou hladinou není tržní, ať už jde
               o cokoli. Testuje se PŘED mezí z Valuo_prahy, protože ta
               je v kontaminovaném území stažená pod sebe.
               Podíl bere CIS_prahy_ceny podle klasifikace; konkrétní
               druh ho může přepsat v CIS_metrika_ceny, kde 0 znamená
               neuplatňovat (např. jiný nebytový prostor, kde se v jednom
               druhu míchají kanceláře se sklepy).                       */
            WHEN mt.metrika = 'JC'
             AND kr.median IS NOT NULL
             AND COALESCE(mt.mez_druh, t.mez_vuci_kraji) > 0
             AND v.jedn_cena_Kc_m2
                 < kr.median * COALESCE(mt.mez_druh, t.mez_vuci_kraji)
                                                     THEN N'pod tržní hladinou'

            WHEN v.klasifikace = 'NELZE'
             AND v.cena_Kc < ISNULL(NULLIF(t.cena_min, 0), mzg.mez_Kc)
                                                     THEN N'symbolická cena'
            WHEN v.klasifikace = 'NELZE'              THEN N'nelze porovnat'
            WHEN p.median IS NULL
             AND v.cena_Kc < ISNULL(NULLIF(t.cena_min, 0), mzg.mez_Kc)
                                                     THEN N'symbolická cena'
            WHEN p.median IS NULL                     THEN N'bez srovnání'
            WHEN h.hodnota < p.prah_dolni             THEN N'pod mezí'
            WHEN h.hodnota > p.prah_horni             THEN N'nad mezí'
            ELSE                                           N'bez výhrad'
        END                                         AS hodnoceni_ceny,

        CASE WHEN v.klasifikace = 'JC_PARCELY' AND v.na_pozemku_stavba = 1
             THEN N'stavba je součástí pozemku' ELSE N'—' END AS pozemek_se_stavbou,

        CASE WHEN ISNULL(v.mena, 'CZK') = 'CZK' THEN N'—'
             WHEN v.kurz_pouzity IS NULL        THEN N'bez kurzu'
             ELSE v.mena + N' kurzem ČNB k '
                  + CONVERT(varchar(10), v.kurz_datum, 104) END AS prepocet_meny,

        CASE
            WHEN r.nemovitost IS NULL                THEN N'bez pravidla'
            WHEN r.plocha_max = 0                    THEN N'nevhodný zdroj plochy'
            WHEN COALESCE(v.plocha_jednotky_m2, v.plocha_budovy_m2,
                          v.plocha_parcel_m2)
                 BETWEEN r.plocha_min AND r.plocha_max THEN N'v rozsahu'
            ELSE                                          N'mimo rozsah'
        END                                         AS hodnoceni_plochy,

        CASE
            WHEN v.klasifikace <> 'JC_JEDNOTKA'      THEN N'—'
            WHEN pd.citatel_podilu IS NULL           THEN N'nenačteno'
            WHEN pd.citatel_podilu < 100             THEN N'malý čitatel - podezřelý'
            ELSE                                          N'plošný zlomek'
        END                                         AS hodnoceni_podilu,

        CASE WHEN v.duplicitnich_radku > 0 THEN N'ano' ELSE N'ne' END
                                                    AS obsahuje_duplicity,

        v.geo_bod, v.LAT, v.LON,

        ru.ruian_rok, ru.ruian_pasmo, ru.ruian_rok_presny, ru.ruian_stari_let,
        ru.ruian_zastavena_plocha, ru.ruian_podlahova_plocha,
        ru.ruian_obestaveny_prostor, ru.ruian_pocet_podlazi,
        ru.ruian_pomer_pp_op, ru.ruian_plocha_podezrela,
        ru.ruian_druh_konstrukce, ru.ruian_vytapeni, ru.ruian_vytah,
        ru.ruian_zdroj, ru.ruian_stav_k,
        ISNULL(p.pasmo, N'') AS pasmo_meze,

        CASE WHEN v.klasifikace = 'CELEK_BUDOVA'
              AND ru.ruian_zdroj = N'budova'
              AND ru.ruian_obestaveny_prostor > 0
             THEN CAST(v.cena_Kc / ru.ruian_obestaveny_prostor AS decimal(18,2))
        END                                         AS jedn_cena_Kc_m3,
        CAST(m3.median     AS decimal(18,2))        AS median_Kc_m3,
        CAST(m3.prah_dolni AS decimal(18,2))        AS mez_m3_zdola,
        CAST(m3.prah_horni AS decimal(18,2))        AS mez_m3_shora,
        m3.n                                        AS bodu_v_mezi_m3,
        m3.uroven                                   AS uroven_meze_m3

FROM dbo.v_Valuo_vzorek v
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku
LEFT JOIN hlavni  pd ON pd.cislo_vkladu = v.cislo_vkladu
LEFT JOIN metrika mt ON mt.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.RUIAN_vzorek ru ON ru.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.Valuo_hromadne_prevody hp
       ON hp.klasifikace     = v.klasifikace
      AND hp.kat_uzemi       = v.kat_uzemi
      AND hp.druh            = ISNULL(v.druh, '?')
      AND hp.detektor        = 'JC'
      AND hp.jedn_cena_Kc_m2 = v.jedn_cena_Kc_m2
LEFT JOIN dbo.CIS_typy_hromadneho_prevodu y ON y.typ_jevu = hp.typ_jevu
LEFT JOIN dbo.Valuo_hromadne_prevody hc
       ON hc.klasifikace     = v.klasifikace
      AND hc.kat_uzemi       = v.kat_uzemi
      AND hc.druh            = ISNULL(v.druh, '?')
      AND hc.detektor        = 'CENA'
      AND hc.cena_skupiny_Kc = v.cena_Kc
      AND hc.rok             = v.rok
LEFT JOIN dbo.CIS_typy_hromadneho_prevodu yc ON yc.typ_jevu = hc.typ_jevu
LEFT JOIN dbo.v_vklad_UP      up ON up.cislo_vkladu = v.cislo_vkladu
LEFT JOIN dbo.CIS_FVU_skupiny fs ON fs.fvu_kod      = up.fvu_kod
LEFT JOIN dbo.CIS_velikost_pozemku vp
       ON v.plocha_parcel_m2 >= vp.od_m2 AND v.plocha_parcel_m2 < vp.do_m2
LEFT JOIN dbo.CIS_prahy_ceny   t  ON t.klasifikace = v.klasifikace
LEFT JOIN dbo.CIS_mez_podilu  mzk ON mzk.kraj      = c.kraj_nazev
LEFT JOIN dbo.CIS_mez_podilu  mzg ON mzg.kraj      = N'*'
LEFT JOIN dbo.CIS_rozsahy_ploch r
       ON r.nemovitost = pd.nemovitost
      AND r.typ        = pd.typ
      AND r.typ_plochy = pd.typ_plochy

CROSS APPLY (
    SELECT hodnota = CASE WHEN mt.metrika = 'JC' THEN v.jedn_cena_Kc_m2
                          ELSE v.cena_Kc END
) h

OUTER APPLY (
    SELECT TOP 1 pr.median, pr.prah_dolni, pr.prah_horni, pr.n, pr.uroven, pr.pasmo
    FROM dbo.Valuo_prahy pr
    WHERE pr.klasifikace = v.klasifikace
      AND v.klasifikace <> 'NELZE'
      AND pr.metrika = CASE WHEN mt.metrika = 'JC' THEN 'JC' ELSE 'CENA' END
      AND pr.klic = CASE
            WHEN v.klasifikace = 'JC_PARCELY'
             AND fs.skupina IS NOT NULL
             AND c.kraj_nazev = N'Hlavní město Praha'
            THEN N'FVU:' + CAST(fs.skupina AS nvarchar(20))
                 + N'|'  + CAST(vp.pasmo   AS nvarchar(12))
            ELSE N'DRUH:' + CAST(ISNULL(v.druh, '?') AS nvarchar(100)) END
      AND (pr.pasmo = ''
           OR (v.klasifikace IN ('JC_JEDNOTKA','CELEK_BUDOVA')
               AND pr.pasmo = ISNULL(ru.ruian_pasmo, '###')))
      AND (   (pr.uroven = N'k.ú.'  AND pr.uzemi = c.ku_nazev)
           OR (pr.uroven = N'okres' AND pr.uzemi =
                   COALESCE(c.okres_nazev, c.kraj_nazev))
           OR (pr.uroven = N'kraj'  AND pr.uzemi = c.kraj_nazev))
    ORDER BY CASE pr.uroven WHEN N'k.ú.'  THEN 1
                            WHEN N'okres' THEN 2 ELSE 3 END,
             CASE WHEN pr.pasmo <> '' THEN 0 ELSE 1 END
) p

OUTER APPLY (
    SELECT TOP 1 pr.median
    FROM dbo.Valuo_prahy pr
    WHERE pr.klasifikace = v.klasifikace
      AND v.klasifikace IN ('JC_JEDNOTKA', 'CELEK_BUDOVA')
      AND pr.metrika = 'JC'
      AND pr.pasmo   = ''
      AND pr.uroven  = N'kraj'
      AND pr.uzemi   = c.kraj_nazev
      AND pr.klic    = N'DRUH:' + CAST(ISNULL(v.druh, '?') AS nvarchar(100))
) kr

OUTER APPLY (
    SELECT TOP 1 pr.median, pr.prah_dolni, pr.prah_horni, pr.n, pr.uroven
    FROM dbo.Valuo_prahy pr
    WHERE pr.klasifikace = v.klasifikace
      AND v.klasifikace = 'CELEK_BUDOVA'
      AND pr.metrika = 'M3'
      AND pr.klic = N'DRUH:' + CAST(ISNULL(v.druh, '?') AS nvarchar(100))
      AND (pr.pasmo = '' OR pr.pasmo = ISNULL(ru.ruian_pasmo, '###'))
      AND (   (pr.uroven = N'k.ú.'  AND pr.uzemi = c.ku_nazev)
           OR (pr.uroven = N'okres' AND pr.uzemi =
                   COALESCE(c.okres_nazev, c.kraj_nazev))
           OR (pr.uroven = N'kraj'  AND pr.uzemi = c.kraj_nazev))
    ORDER BY CASE pr.uroven WHEN N'k.ú.'  THEN 1
                            WHEN N'okres' THEN 2 ELSE 3 END,
             CASE WHEN pr.pasmo <> '' THEN 0 ELSE 1 END
) m3;

GO

/* ------------------------------------------------------------------------
   VIEW  dbo.v_vklad_UP
   změněno 2026-10-23 15:40
   ------------------------------------------------------------------------ */



/* ---------- 24e.2 OPRAVENÝ POHLED --------------------------
   Logika beze změny, jen správný zdroj. KN_parcel_UP má vazbu
   M:N, proto se uvnitř parcely bere polygon s pořadím 1, tedy
   s největším podílem plochy.                                */

CREATE   VIEW dbo.v_vklad_UP
AS
WITH hlavni_parcela AS (
    SELECT  k.id_valuo,
            u.fvu_kod,
            u.mira_vyuziti,
            ROW_NUMBER() OVER (PARTITION BY k.id_valuo
                               ORDER BY k.areaValue_m2 DESC, k.id) AS poradi
    FROM dbo.KN_parcel_data k
    JOIN dbo.KN_parcel_UP  u ON u.kn_id = k.id AND u.poradi = 1
)
SELECT  v.cislo_vkladu,
        MIN(h.fvu_kod)      AS fvu_kod,
        MIN(h.mira_vyuziti) AS mira_vyuziti
FROM dbo.Valuo_data v
JOIN hlavni_parcela h ON h.id_valuo = v.id AND h.poradi = 1
GROUP BY v.cislo_vkladu;

GO
