/* ============================================================
   VALUO — KROK 16: DEDUPLIKACE Valuo_data A PŘÍPRAVA OPRAVY

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.

   ------------------------------------------------------------
   PROČ JSOU V DATECH DUPLICITY
   ------------------------------------------------------------
   Valuo prodává data po balíčcích "katastrální území + měsíc".
   Obsahuje-li vklad nemovitosti ve více územích, objeví se
   CELÝ vklad v balíčku každého z nich. Koupí-li se oba
   balíčky, je tentýž záznam v databázi dvakrát.

   Ověřeno na 2 336 duplicitních skupinách (3 307 nadbytečných
   řádků):
       1 354 skupin pochází z RŮZNÝCH balíčků (křížová duplicita)
         982 skupin ze stejného balíčku (opakovaný import)

   Obojí je tentýž záznam a jeden z nich je nadbytečný.

   ------------------------------------------------------------
   JAK SE POZNÁ TÝŽ ZÁZNAM
   ------------------------------------------------------------
   Shodou pětice: číslo vkladu, adresa, nemovitost, typ, plocha.
   Adresa u parcely nese katastrální území a parcelní číslo,
   takže dvě různé parcely téhož vkladu se nespletou.

   Sloupec kat_uzemi se do porovnání NEZAHRNUJE — je to území
   balíčku, ne nemovitosti, a u křížových duplicit se právě
   proto liší.

   ------------------------------------------------------------
   POSTUP
   ------------------------------------------------------------
   Z každé skupiny zůstává řádek s nejnižším id. Navázané
   parcely nadbytečných řádků se mažou — u ponechaného řádku
   zůstávají jeho vlastní, a co chybí, se přetáhne znovu
   opraveným skriptem.
   ============================================================ */

USE VALUO;
GO

/* ---------- 16.1 OZNAČENÍ NADBYTEČNÝCH ŘÁDKŮ --------------- */

IF OBJECT_ID('dbo.zaloha_valuo_duplicity_20261022') IS NOT NULL
    DROP TABLE dbo.zaloha_valuo_duplicity_20261022;
GO

WITH poradi AS (
    SELECT  id,
            ROW_NUMBER() OVER (
                PARTITION BY cislo_vkladu, adresa, nemovitost, typ, plocha
                ORDER BY id
            ) AS poradi_ve_skupine
    FROM dbo.Valuo_data
)
SELECT  v.*,
        GETDATE() AS datum_zalohy
INTO dbo.zaloha_valuo_duplicity_20261022
FROM dbo.Valuo_data v
JOIN poradi p ON p.id = v.id
WHERE p.poradi_ve_skupine > 1;
GO

CREATE CLUSTERED INDEX IX_zaloha_valuo_dupl_id
    ON dbo.zaloha_valuo_duplicity_20261022 (id);
GO

SELECT COUNT(*) AS ke_smazani FROM dbo.zaloha_valuo_duplicity_20261022;
GO

/* Očekávání: 3 307. Pokud výrazně nesedí, zastav se. */


/* ---------- 16.2 SMAZÁNÍ NAVÁZANÝCH DAT -------------------- */

DELETE u
FROM dbo.KN_parcel_UP u
JOIN dbo.KN_parcel_data k ON k.id = u.kn_id
JOIN dbo.zaloha_valuo_duplicity_20261022 z ON z.id = k.id_valuo;
GO
SELECT @@ROWCOUNT AS smazano_vazeb_na_UP;
GO

DELETE k
FROM dbo.KN_parcel_data k
JOIN dbo.zaloha_valuo_duplicity_20261022 z ON z.id = k.id_valuo;
GO
SELECT @@ROWCOUNT AS smazano_parcel;
GO


/* ---------- 16.3 SMAZÁNÍ DUPLICITNÍCH ZÁZNAMŮ -------------- */

DELETE v
FROM dbo.Valuo_data v
JOIN dbo.zaloha_valuo_duplicity_20261022 z ON z.id = v.id;
GO
SELECT @@ROWCOUNT AS smazano_zaznamu;
GO


/* ---------- 16.4 KONTROLA ---------------------------------- */

SELECT  COUNT(*)                        AS zaznamu,
        COUNT(DISTINCT cislo_vkladu)    AS vkladu
FROM dbo.Valuo_data;
GO

SELECT COUNT(*) AS zbyvajicich_duplicit
FROM (
    SELECT cislo_vkladu, adresa, nemovitost, typ, plocha
    FROM dbo.Valuo_data
    GROUP BY cislo_vkladu, adresa, nemovitost, typ, plocha
    HAVING COUNT(*) > 1
) x;
GO

SELECT COUNT(*) AS osirelych_parcel
FROM dbo.KN_parcel_data k
LEFT JOIN dbo.Valuo_data v ON v.id = k.id_valuo
WHERE v.id IS NULL;
GO


/* ---------- 16.5 PREVENCE OPAKOVÁNÍ ------------------------
   Unikátní index zabrání tomu, aby příští import tentýž
   záznam vložil podruhé — ať už z jiného balíčku, nebo
   opakovaným během.                                          */

CREATE UNIQUE NONCLUSTERED INDEX UQ_Valuo_zaznam
    ON dbo.Valuo_data (cislo_vkladu, adresa, nemovitost, typ, plocha)
    WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO


/* ============================================================
   16.6  SEZNAM ZÁZNAMŮ K PŘETAŽENÍ Z KATASTRU
   ------------------------------------------------------------
   Tabulka pro opravný Python skript. Obsahuje tři skupiny:

     BEZ_PARCELY    záznam nemá navázanou žádnou parcelu —
                    nejspíš se hledalo ve špatném území
     OKRES_NESEDI   okres parcely se liší od okresu ve Valuo
     VYMERA_NESEDI  výměra se liší a parcela se od prodeje
                    nezměnila, takže časový posun to nevysvětlí
   ============================================================ */

IF OBJECT_ID('dbo.KN_k_pretazeni') IS NOT NULL
    DROP TABLE dbo.KN_k_pretazeni;
GO

CREATE TABLE dbo.KN_k_pretazeni (
    id_valuo     int           NOT NULL,
    duvod        varchar(20)   NOT NULL,
    adresa       varchar(400)  NULL,
    popis        varchar(800)  NULL,
    okres        varchar(100)  NULL,
    kat_uzemi    varchar(100)  NULL,
    nemovitost   varchar(50)   NULL,
    zpracovano   bit           NOT NULL
        CONSTRAINT DF_KN_k_pretazeni_zpracovano DEFAULT 0,
    CONSTRAINT PK_KN_k_pretazeni PRIMARY KEY CLUSTERED (id_valuo)
);
GO

/* a) záznamy bez navázané parcely */
INSERT INTO dbo.KN_k_pretazeni
    (id_valuo, duvod, adresa, popis, okres, kat_uzemi, nemovitost)
SELECT  v.id, 'BEZ_PARCELY', v.adresa, v.popis, v.okres,
        v.kat_uzemi, v.nemovitost
FROM dbo.Valuo_data v
WHERE NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data k WHERE k.id_valuo = v.id);
GO

/* b) okres parcely nesedí */
INSERT INTO dbo.KN_k_pretazeni
    (id_valuo, duvod, adresa, popis, okres, kat_uzemi, nemovitost)
SELECT DISTINCT
        v.id, 'OKRES_NESEDI', v.adresa, v.popis, v.okres,
        v.kat_uzemi, v.nemovitost
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data k        ON k.id_valuo = v.id
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod   = k.kod_ku
WHERE v.okres <> COALESCE(c.okres_nazev, c.kraj_nazev)
  AND NOT EXISTS (SELECT 1 FROM dbo.KN_k_pretazeni p WHERE p.id_valuo = v.id);
GO

/* c) výměra nesedí a parcela se nezměnila */
INSERT INTO dbo.KN_k_pretazeni
    (id_valuo, duvod, adresa, popis, okres, kat_uzemi, nemovitost)
SELECT DISTINCT
        v.id, 'VYMERA_NESEDI', v.adresa, v.popis, v.okres,
        v.kat_uzemi, v.nemovitost
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data k ON k.id_valuo = v.id
WHERE v.nemovitost = N'parcela'
  AND v.plocha > 0
  AND k.areaValue_m2 > 0
  AND ABS(v.plocha - k.areaValue_m2) >= 1
  AND k.beginLifespanVersion <= v.datum_zplatneni
  AND NOT EXISTS (SELECT 1 FROM dbo.KN_k_pretazeni p WHERE p.id_valuo = v.id);
GO


/* ---------- 16.7 PŘEHLED ----------------------------------- */

SELECT duvod, COUNT(*) AS zaznamu
FROM dbo.KN_k_pretazeni
GROUP BY duvod
ORDER BY COUNT(*) DESC;
GO

SELECT COUNT(*) AS celkem_k_pretazeni FROM dbo.KN_k_pretazeni;
GO
