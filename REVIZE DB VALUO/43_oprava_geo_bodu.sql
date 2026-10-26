-- =============================================================================
-- 43_oprava_geo_bodu.sql — bod vkladu neleží u jeho vlastní parcely
-- =============================================================================
-- Databáze: VALUO        Krok: 43        Datum: 25. 10. 2026
-- NESPOUŠTĚT NAJEDNOU. Části 1 a 2 jsou měření, část 3 mění data.
--
-- PROVEDENO 25. 10. 2026 na pokyn znalce
-- ---------------------------------------
--   část 3 — záloha `zaloha_43_geo_bod` (8 428 řádků / 6 152 vkladů / 36 k. ú.),
--            bod přepsán u 8 428 řádků, kontrola: 0 vadných řádků.
--            Pouštělo se po jednotlivých příkazech, ne celým blokem —
--            spojení asistenta si volání balí do vlastní transakce a blok
--            s vlastním COMMIT/ROLLBACK by zrušila celý (ověřeno).
--   část 6 — podmínka v `30_import_valuo.py` přepsána, verze 30.4,
--            záloha souboru `30_import_valuo.py.bak_303`.
--            První běh nového znění změnil **dalších 380 řádků**, které
--            stará podmínka přeskakovala a část 3 nepokryla: jejich `kod_ku`
--            nepocházel z největší parcely řádku. Ověřeno na vzorcích, že
--            jde o opravy — „Na Topolce, Podolí“ bylo vedeno v Nuslích,
--            „Milevská, Krč“ v Nuslích, „Pod strání, Strašnice“ v Hostivaři,
--            parcela v Byškovicích v Býškovicích (záměna jedné délky).
--            Území vkladu se tím skutečně změnilo u 2 vkladů; u dalších 57
--            jde o artefakt měření — ty leží v několika k. ú. a žádné jedno
--            „to správné“ nemají.
--            **Záloha těch 380 řádků neexistuje** — spustil jsem to jako
--            test nového znění a předobraz jsem si neodložil. Staré území
--            a bod na úrovni vkladu zůstaly ve `zaloha_43_mapa_pred`
--            (49 692 řádků, snapshot `Valuo_mapa` před přepočtem).
--   část 4 — přepočet mapy, pouští znalec.
--   část 5 — provedeno na pokyn znalce: 55 řádků přeznačeno na 'BEZ_PARCELY',
--            záloha `zaloha_43_bez_parcely`. Vzorek 49 689 → 49 647.
--            Ubylo **42 vkladů, ne 54**: dalších 12 dotčených vkladů má ještě
--            jiný řádek, jehož bod parcela doopravdy podkládá, a ve vzorku
--            tedy zůstávají správně. Lživých štítků 'KN_refPoint' bez parcely
--            je po zásahu 0.
--
-- Co se našlo
-- -----------
-- Znalec si v mapě rozklikl shluk ve Stodůlkách: 460 vkladů na jednom bodě,
-- a karty u nich ukazovaly nemovitosti na úplně jiných místech. Měřením se
-- ukázalo, že nejde o shluk, ale o jeden sdílený bod:
--
--   8 442 řádků (6 166 vkladů) má geo_bod, který NEODPOVÍDÁ vztažnému
--   bodu žádné z jejich vlastních parcel. Z toho:
--     8 428 řádků / 6 152 vkladů ve 36 k. ú. se hlásí jako 'KN_refPoint'
--                  a opravit se dají — ty řeší část 3
--        14 řádků /    14 vkladů je 'API_NEOVERENO' a jejich parcely
--                  vztažný bod vůbec nemají; opravit je nelze a ve vzorku
--                  nejsou, protože ten bere jen 'KN_refPoint'
--   Všech 8 428 opravitelných řádků přitom sedí na pouhých 43 různých
--   bodech, tedy zhruba jeden bod na katastrální území.
--
--   odchylka od vlastní parcely:  průměr 1 150 m, maximum 3 672 m
--                                 nad 200 m  8 329 řádků
--                                 nad 1 km   4 688 řádků
--
--   nejhorší:  Nusle 3 185 řádků na 2 bodech, Libeň 1 188 na 1 bodě,
--              Kunratice 910 na 1, Troja 856 na 2, Holešovice 583 na 1,
--              Stodůlky 523 na 1
--
-- Příklad: V-10172/2021-101, byt Neustupného 1839/8 ve Stodůlkách. Jeho
-- jediná parcela 2160/85 má vztažný bod 50,043936 / 14,321700. Ve
-- `Valuo_data` je ale 50,049157 / 14,313554 — o 900 m vedle, a týž bod
-- má dalších 486 vkladů ve 223 různých adresách. Ten bod není vztažným
-- bodem žádné parcely v databázi (v okruhu 50 m žádná není), takže
-- nevznikl z katastru.
--
-- Proč to nespravil běžný import
-- ------------------------------
-- `SQL_DOPLN_VALUO` v `30_import_valuo.py` promítá bod největší parcely
-- řádku, ale jen tam, kde:
--
--     WHERE v.geo_zdroj IS NULL OR v.geo_zdroj <> 'KN_refPoint'
--        OR v.kod_ku IS NULL OR v.id IN (fronta IMPORT30)
--
-- Všech 8 428 řádků má `geo_zdroj = 'KN_refPoint'` i `kod_ku`, takže
-- podmínka je přeskočí. **Štítek „z katastru“ si nesou, aniž by ten bod
-- z katastru byl** — pravděpodobně pozůstatek starého geokódování podle
-- adresy, které pozdější hromadný UPDATE přeznačil. Oprava proto musí
-- jít proti obsahu, ne proti štítku.
--
-- Co to NEOVLIVNILO
-- -----------------
-- `kod_ku` je u všech 8 442 řádků správný — ověřeno proti parcelám, nula
-- rozporů. `v_Valuo_vzorek` se k území připojuje přes `kod_ku`, takže
-- **vzorek ani porovnání po katastrálních územích tím netrpí**. Vadné je
-- všechno, co pracuje se vzdáleností: mapa (6 166 z 49 692 bodů, 12,4 %)
-- a jakýkoli dotaz „bod plus okruh“.
--
-- Karta vkladu je v pořádku — kreslí se z geometrie parcel, ne z geo_bod.
-- =============================================================================
GO

-- ČÁST 1: změřit rozsah ------------------------------------------------------
-- Definice vady: žádná z vlastních parcel řádku nemá tenhle vztažný bod.

WITH r AS (
    SELECT v.id, v.cislo_vkladu, v.kod_ku,
           v.geo_bod.Lat AS la, v.geo_bod.Long AS lo
    FROM dbo.Valuo_data v WHERE v.geo_bod IS NOT NULL
), m AS (
    SELECT r.id, r.cislo_vkladu, r.kod_ku,
           MAX(CASE WHEN ABS(k.refPoint_lat - r.la) < 0.000001
                     AND ABS(k.refPoint_lon - r.lo) < 0.000001
                    THEN 1 ELSE 0 END) AS sedi,
           MIN(SQRT(POWER((k.refPoint_lat - r.la) * 111320, 2)
                  + POWER((k.refPoint_lon - r.lo) * 71500, 2))) AS vzdal_m
    FROM r JOIN dbo.KN_parcel_data k ON k.id_valuo = r.id
    WHERE k.refPoint_lat IS NOT NULL
    GROUP BY r.id, r.cislo_vkladu, r.kod_ku
)
SELECT COUNT(*) AS vadnych_radku,
       COUNT(DISTINCT cislo_vkladu) AS vadnych_vkladu,
       COUNT(DISTINCT kod_ku) AS katastralnich_uzemi,
       CAST(AVG(vzdal_m) AS int) AS prumerna_odchylka_m,
       CAST(MAX(vzdal_m) AS int) AS nejvetsi_odchylka_m
FROM m WHERE sedi = 0;
-- Čekáno 25. 10. 2026: 8 428 / 6 152 / 36 / 1 150 / 3 672
GO

-- ČÁST 2: druhý, menší nález -------------------------------------------------
-- Řádky, které se hlásí jako 'KN_refPoint', ale parcelu nemají vůbec.
-- Bod u nich nejde ověřit ani opravit, a přesto vstupují do vzorku,
-- protože `v_Valuo_vzorek` filtruje právě podle `geo_zdroj`.

SELECT COUNT(*) AS radku, COUNT(DISTINCT v.cislo_vkladu) AS vkladu
FROM dbo.Valuo_data v
WHERE v.geo_zdroj = 'KN_refPoint'
  AND NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data k WHERE k.id_valuo = v.id);
-- Čekáno 25. 10. 2026: 55 řádků, 54 vkladů
GO

-- ČÁST 3: oprava -------------------------------------------------------------
-- MĚNÍ `Valuo_data`. Pustit teprve na pokyn znalce, celou část jako jeden
-- blok — záloha, oprava a kontrola patří k sobě.

BEGIN TRY
BEGIN TRANSACTION;

    -- 3.1 záloha vadných řádků
    IF OBJECT_ID('dbo.zaloha_43_geo_bod', 'U') IS NOT NULL
        DROP TABLE dbo.zaloha_43_geo_bod;

    WITH r AS (
        SELECT v.id, v.geo_bod.Lat AS la, v.geo_bod.Long AS lo
        FROM dbo.Valuo_data v WHERE v.geo_bod IS NOT NULL
    ), m AS (
        SELECT r.id,
               MAX(CASE WHEN ABS(k.refPoint_lat - r.la) < 0.000001
                         AND ABS(k.refPoint_lon - r.lo) < 0.000001
                        THEN 1 ELSE 0 END) AS sedi
        FROM r JOIN dbo.KN_parcel_data k ON k.id_valuo = r.id
        WHERE k.refPoint_lat IS NOT NULL
        GROUP BY r.id
    )
    SELECT v.id, v.cislo_vkladu, v.adresa, v.kod_ku, v.geo_zdroj,
           v.geo_bod.Lat  AS lat_pred,
           v.geo_bod.Long AS lon_pred,
           SYSDATETIME() AS zalohovano
    INTO dbo.zaloha_43_geo_bod
    FROM dbo.Valuo_data v
    JOIN m ON m.id = v.id AND m.sedi = 0;

    DECLARE @zalohovano int = @@ROWCOUNT;

    -- 3.2 oprava: bod největší vlastní parcely řádku.
    --     Ověřeno 25. 10. 2026: všech 8 428 vadných řádků má aspoň jednu
    --     parcelu se vztažným bodem v rozsahu ČR, takže se opraví všechny
    --     a přísná kontrola níže (opraveno = zálohováno) musí vyjít.
    WITH nejvetsi AS (
        SELECT k.id_valuo, k.refPoint_lat, k.refPoint_lon,
               ROW_NUMBER() OVER (PARTITION BY k.id_valuo
                                  ORDER BY k.areaValue_m2 DESC, k.id) AS poradi
        FROM dbo.KN_parcel_data k
        WHERE k.refPoint_lat BETWEEN 48.5 AND 51.1
          AND k.refPoint_lon BETWEEN 12.0 AND 18.9
    )
    UPDATE v
    SET v.geo_bod = geography::Point(p.refPoint_lat, p.refPoint_lon, 4326)
    FROM dbo.Valuo_data v
    JOIN dbo.zaloha_43_geo_bod z ON z.id = v.id
    JOIN nejvetsi p ON p.id_valuo = v.id AND p.poradi = 1;

    DECLARE @opraveno int = @@ROWCOUNT;

    -- 3.3 kontrola: po opravě nesmí zbýt ani jeden vadný řádek
    DECLARE @zbyva int;
    WITH r AS (
        SELECT v.id, v.geo_bod.Lat AS la, v.geo_bod.Long AS lo
        FROM dbo.Valuo_data v WHERE v.geo_bod IS NOT NULL
    ), m AS (
        SELECT r.id,
               MAX(CASE WHEN ABS(k.refPoint_lat - r.la) < 0.000001
                         AND ABS(k.refPoint_lon - r.lo) < 0.000001
                        THEN 1 ELSE 0 END) AS sedi
        FROM r JOIN dbo.KN_parcel_data k ON k.id_valuo = r.id
        WHERE k.refPoint_lat IS NOT NULL
        GROUP BY r.id
    )
    SELECT @zbyva = COUNT(*) FROM m WHERE sedi = 0;

    PRINT CONCAT('zálohováno ', @zalohovano, ' řádků, opraveno ', @opraveno,
                 ', zbývá vadných ', @zbyva);

    IF @zbyva > 0 OR @opraveno <> @zalohovano
    BEGIN
        ROLLBACK TRANSACTION;
        PRINT 'KONTROLA NESOUHLASÍ — vráceno zpět, nic se nezměnilo.';
    END
    ELSE
    BEGIN
        COMMIT TRANSACTION;
        PRINT 'Hotovo. Záloha zůstává v dbo.zaloha_43_geo_bod.';
    END
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT CONCAT('CHYBA ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
    PRINT 'Nic se nezměnilo.';
END CATCH
GO

-- Vrácení zpět, kdyby se oprava ukázala jako špatná:
/*
UPDATE v SET v.geo_bod = geography::Point(z.lat_pred, z.lon_pred, 4326)
FROM dbo.Valuo_data v JOIN dbo.zaloha_43_geo_bod z ON z.id = v.id;
*/

-- ČÁST 4: po opravě přepočítat mapu ------------------------------------------
-- Bod vkladu se do `Valuo_mapa` bere z `Valuo_data`, takže mapa se musí
-- naplnit znovu. Karty ani okolí se nepřepočítávají — ty stojí na geometrii
-- parcel, kterou tahle oprava nemění.
--
--     python 38_prepocty.py --krok mapa --prepocitat
--
GO

-- ČÁST 5: řádky se štítkem, který nemá o co se opřít -------------------------
-- PROVEDENO 25. 10. 2026 na pokyn znalce („pokud má vklad takovýto nedostatek
-- a je jich jen 54, tak je přeznač“).
-- Těch 55 řádků z části 2 (54 vkladů) se hlásí jako 'KN_refPoint', ale
-- parcelu nemají. Bod u nich nejde ověřit — a přesto jsou ve vzorku, protože
-- `v_Valuo_vzorek` filtruje podle `geo_zdroj`. Přeznačením vypadnou ze vzorku,
-- což je 54 vkladů méně. Proto to nechávám na rozhodnutí.
-- 5.1 záloha
IF OBJECT_ID('dbo.zaloha_43_bez_parcely', 'U') IS NOT NULL
    DROP TABLE dbo.zaloha_43_bez_parcely;
SELECT v.id, v.cislo_vkladu, v.nemovitost, v.typ, v.adresa, v.kod_ku,
       v.geo_zdroj AS geo_zdroj_pred,
       v.geo_bod.Lat AS lat_pred, v.geo_bod.Long AS lon_pred,
       SYSDATETIME() AS zalohovano
INTO dbo.zaloha_43_bez_parcely
FROM dbo.Valuo_data v
WHERE v.geo_zdroj = 'KN_refPoint'
  AND NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data k WHERE k.id_valuo = v.id);
GO

-- 5.2 přeznačení
UPDATE v SET v.geo_zdroj = 'BEZ_PARCELY'
FROM dbo.Valuo_data v
JOIN dbo.zaloha_43_bez_parcely z ON z.id = v.id
WHERE v.geo_zdroj = 'KN_refPoint';
GO

-- 5.3 kontrola
SELECT (SELECT COUNT(*) FROM dbo.v_Valuo_vzorek) AS vzorek_po,
       (SELECT COUNT(*) FROM dbo.Valuo_data v WHERE v.geo_zdroj = 'KN_refPoint'
          AND NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data k WHERE k.id_valuo = v.id))
         AS zbyva_lzivych_stitku;
-- Ověřeno 25. 10. 2026: vzorek 49 647 (z 49 689), lživých štítků 0.
GO

-- Vrácení zpět:
/*
UPDATE v SET v.geo_zdroj = z.geo_zdroj_pred
FROM dbo.Valuo_data v JOIN dbo.zaloha_43_bez_parcely z ON z.id = v.id;
*/

-- ČÁST 6: trvalá oprava v `30_import_valuo.py` -------------------------------
-- Jednorázová oprava sama nestačí. Dokud podmínka v `SQL_DOPLN_VALUO`
-- přeskakuje řádky, které už mají štítek 'KN_refPoint', vrátí se ta samá
-- vada u každého dalšího zestárnutí bodu — třeba když se parcely vkladu
-- přetáhnou znovu a vyjdou jiné.
--
-- Nahradit v `30_import_valuo.py` (verze 30.3 → 30.4) WHERE v SQL_DOPLN_VALUO:
--
--   PŮVODNÍ
--     WHERE v.geo_zdroj IS NULL
--        OR v.geo_zdroj <> 'KN_refPoint'
--        OR v.kod_ku IS NULL
--        OR v.id IN (SELECT id_valuo FROM dbo.KN_k_pretazeni
--                    WHERE duvod = 'IMPORT30');
--
--   NOVÉ — rozhoduje obsah, ne štítek
--     WHERE v.geo_zdroj IS NULL
--        OR v.geo_zdroj <> 'KN_refPoint'
--        OR v.kod_ku IS NULL
--        OR v.kod_ku <> p.kod_ku
--        OR v.geo_bod IS NULL
--        OR ABS(v.geo_bod.Lat  - p.refPoint_lat) > 0.000001
--        OR ABS(v.geo_bod.Long - p.refPoint_lon) > 0.000001;
--
-- Vlastnosti nového znění:
--   * samo se hojí — kdykoli bod neodpovídá největší parcele řádku, přepíše se
--   * zůstává idempotentní: podruhé nezmění ani řádek
--   * počet změněných řádků v logu je nově užitečný signál („kolik bodů se
--     posunulo“), ne jen „kolik řádků prošlo podmínkou“
--   * podmínka na frontu IMPORT30 už není potřeba — srovnání souřadnic
--     ji pokrývá a navíc nezávisí na tom, co ve frontě zůstalo
--
-- Pozor na budoucnost: kdyby se někdy zavedl ruční bod od znalce (po vzoru
-- `plocha_rucne`), musí se do podmínky přidat výjimka, jinak ho přepočet
-- přepíše. Dnes žádný takový mechanismus není.
