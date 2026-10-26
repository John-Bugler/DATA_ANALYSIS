/* ============================================================
   VALUO — KROK 23e: ČÍSLO POPISNÉ A ČÍSLO JEDNOTKY

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Druhá verze. První selhala, viz níž. Spusť celé najednou.

   ============================================================
   FORMÁT KÓDU JEDNOTKY
   ============================================================
   Popis jednotky začíná

       jednotka č. 7260105, byt v budově č.p. 726, část obce …

   a kód se skládá z čísla popisného a čísla jednotky doplněného
   nulami zleva na ČTYŘI pozice:

       7260105   -> č.p.  726, jednotka  105
       3180011   -> č.p.  318, jednotka   11
       6220004   -> č.p.  622, jednotka    4
       29191000  -> č.p. 2919, jednotka 1000   (garáž)

   Nuly uprostřed nejsou oddělovač a jejich počet neříká nic
   o počtu čísel popisných budovy — jen vyplňují ty čtyři
   pozice. Případ 29191000 ukazuje, že se formát využívá naplno.

   ------------------------------------------------------------
   JAK JE TO OVĚŘENÉ
   ------------------------------------------------------------
   U každého popisu odebrány poslední čtyři cifry a zbytek
   hledán mezi čísly popisnými uvedenými v tomtéž popisu:

   | délka kódu | případů | prefix sedí na č.p. |
   |------------|---------|---------------------|
   |          5 |     129 |                 129 |
   |          6 |     584 |                 584 |
   |          7 |  14 258 |              14 258 |
   |          8 |  34 037 |              34 035 |

   Dvě odchylky u délky 8 odchylky nejsou — jejich seznam čísel
   popisných je delší než okno 120 znaků, na které byl text při
   kontrole obřezán. Pravidlo platí na všech 49 008 případech,
   kde se dalo ověřit.

   ------------------------------------------------------------
   PROČ SE ROZHODUJE PODLE DÉLKY KÓDU
   ------------------------------------------------------------
   Kód do čtyř cifer včetně prefix nemá — jednotka je v budově
   bez čísla popisného i evidenčního:

       442 případů s kódem 1-3 cifry: garáže, stavby občanského
           vybavení, rozestavěné jednotky
         9 případů s kódem 4 cifry: rozestavěné jednotky na
           parcele 160/16 Stodůlky, kódy 5023 až 5124

   Naopak 26 jednotek má kód NAD čtyři cifry, ale v popisu nemá
   č.p. ani č.e.:

       jednotka č. 8390402, byt v budově s roz.jed budova,
       na parcele 523/427 Horní Měcholupy

   Budova je vedená jako rozestavěná, takže č.p. 839 v popisu
   ještě není, ale v kódu jednotky už je. Rozhodování podle
   přítomnosti č.p. v popisu by u nich rozklad vynechalo,
   rozhodnutí podle délky je zachytí.

   Dalších 15 jednotek má evidenční číslo místo popisného;
   rozkládají se stejně.

   ------------------------------------------------------------
   CO SELHALO V PRVNÍ VERZI
   ------------------------------------------------------------
   Měl jsem jednotka_kod jako počítaný sloupec a ostatní tři
   z něj odvozené. SQL Server to nedovolí:

       Msg 1759 — Computed column 'jednotka_kod' in table
       'Valuo_data' is not allowed to be used in another
       computed-column definition.

   Každý počítaný sloupec proto nese celý výraz. Aby se
   neopakoval šestkrát, nepočítá se mezivýsledek SUBSTRING,
   ale POZICE ČÁRKY za kódem:

       CHARINDEX(',', popis, 13)

   Dvanáct znaků je 'jednotka č. ', takže kód začíná na pozici
   13 a končí před tou čárkou. Z její pozice se spočítá všechno
   jedním odečtením:

       kód      SUBSTRING(popis, 13, carka - 13)
       č.p.     SUBSTRING(popis, 13, carka - 17)
       jednotka SUBSTRING(popis, carka - 4, 4)

   Chybí-li čárka, CHARINDEX vrátí 0, podmínka neprojde a
   sloupce zůstanou NULL.

   ------------------------------------------------------------
   PROČ POČÍTANÉ SLOUPCE A NE UPDATE
   ------------------------------------------------------------
   Výrazy jsou deterministické, takže mohou být PERSISTED —
   hodnota se fyzicky uloží a dá se indexovat, ale SQL Server ji
   vyhodnotí sám při každém vložení nebo změně řádku.

   DO IMPORTU NENÍ TŘEBA PŘIDÁVAT NIC. Nová data dostanou čísla
   jednotek automaticky.

   POZOR na jednu věc: do počítaného sloupce se nedá zapsat.
   Importuje-li se příkazem INSERT INTO dbo.Valuo_data VALUES
   (…) bez seznamu sloupců, po tomto kroku selže. Import musí
   sloupce vyjmenovat. Kontrola v oddílu 23e.6 to ověří
   vložením zkušebního řádku, který se hned zahodí.
   ============================================================ */

USE VALUO;
GO

/* ---------- 23e.1 ÚKLID PO PRVNÍ VERZI ---------------------
   jednotka_kod se v první verzi vytvořit stihl, než skript
   spadl na dalším příkazu. Má jiný výraz, tak jde pryč.      */

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Valuo_data_jednotka')
    DROP INDEX IX_Valuo_data_jednotka ON dbo.Valuo_data;
GO

IF COL_LENGTH('dbo.Valuo_data', 'jednotka_oznaceni') IS NOT NULL
    ALTER TABLE dbo.Valuo_data DROP COLUMN jednotka_oznaceni;
GO
IF COL_LENGTH('dbo.Valuo_data', 'jednotka_cislo') IS NOT NULL
    ALTER TABLE dbo.Valuo_data DROP COLUMN jednotka_cislo;
GO
IF COL_LENGTH('dbo.Valuo_data', 'jednotka_cp') IS NOT NULL
    ALTER TABLE dbo.Valuo_data DROP COLUMN jednotka_cp;
GO
IF COL_LENGTH('dbo.Valuo_data', 'jednotka_kod') IS NOT NULL
    ALTER TABLE dbo.Valuo_data DROP COLUMN jednotka_kod;
GO


/* ---------- 23e.2 KÓD JEDNOTKY ----------------------------- */

ALTER TABLE dbo.Valuo_data ADD jednotka_kod AS (
    CASE WHEN nemovitost = 'jednotka'
          AND popis LIKE N'jednotka č. %'
          AND CHARINDEX(',', popis, 13) > 13
         THEN SUBSTRING(popis, 13, CHARINDEX(',', popis, 13) - 13)
    END) PERSISTED;
GO


/* ---------- 23e.3 ČÍSLO POPISNÉ ----------------------------
   NULL u budov bez č.p. i č.e., tedy u kódu do 4 cifr.       */

ALTER TABLE dbo.Valuo_data ADD jednotka_cp AS (
    CASE WHEN nemovitost = 'jednotka'
          AND popis LIKE N'jednotka č. %'
          AND CHARINDEX(',', popis, 13) > 17
         THEN SUBSTRING(popis, 13, CHARINDEX(',', popis, 13) - 17)
    END) PERSISTED;
GO


/* ---------- 23e.4 ČÍSLO JEDNOTKY ---------------------------
   U kódu nad 4 cifry poslední čtyřka bez vedoucích nul,
   u kratšího celý kód.                                       */

ALTER TABLE dbo.Valuo_data ADD jednotka_cislo AS (
    CASE WHEN nemovitost <> 'jednotka'
           OR popis NOT LIKE N'jednotka č. %'
           OR CHARINDEX(',', popis, 13) <= 13 THEN NULL
         WHEN CHARINDEX(',', popis, 13) > 17
         THEN CAST(TRY_CAST(SUBSTRING(popis, CHARINDEX(',', popis, 13) - 4, 4)
                            AS int) AS nvarchar(10))
         ELSE SUBSTRING(popis, 13, CHARINDEX(',', popis, 13) - 13)
    END) PERSISTED;
GO


/* ---------- 23e.5 OZNAČENÍ V TVARU KATASTRU ----------------- */

ALTER TABLE dbo.Valuo_data ADD jednotka_oznaceni AS (
    CASE WHEN nemovitost <> 'jednotka'
           OR popis NOT LIKE N'jednotka č. %'
           OR CHARINDEX(',', popis, 13) <= 13 THEN NULL
         WHEN CHARINDEX(',', popis, 13) > 17
         THEN SUBSTRING(popis, 13, CHARINDEX(',', popis, 13) - 17) + N'/'
              + CAST(TRY_CAST(SUBSTRING(popis,
                       CHARINDEX(',', popis, 13) - 4, 4) AS int)
                     AS nvarchar(10))
         ELSE SUBSTRING(popis, 13, CHARINDEX(',', popis, 13) - 13)
    END) PERSISTED;
GO

/* Index jen tehdy, když se sloupec uložil fyzicky */
IF EXISTS (SELECT 1 FROM sys.computed_columns
           WHERE object_id = OBJECT_ID('dbo.Valuo_data')
             AND name = 'jednotka_oznaceni' AND is_persisted = 1)
    CREATE NONCLUSTERED INDEX IX_Valuo_data_jednotka
        ON dbo.Valuo_data (jednotka_oznaceni)
        INCLUDE (cislo_vkladu, kat_uzemi, typ)
        WHERE jednotka_oznaceni IS NOT NULL;
GO

SELECT name, is_persisted, definition
FROM sys.computed_columns
WHERE object_id = OBJECT_ID('dbo.Valuo_data') ORDER BY column_id;
GO


/* ---------- 23e.6 KONTROLA ZÁPISU DO TABULKY ---------------
   Vyjmenované jsou všechny sloupce NOT NULL bez defaultu plus
   popis. Řádek se hned zahodí v ROLLBACK.                    */

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @id int = (SELECT MAX(id) + 1000000 FROM dbo.Valuo_data);

    INSERT INTO dbo.Valuo_data
        (id, cislo_vkladu, datum_podani, datum_zplatneni, nemovitost,
         typ, adresa, cenovy_udaj, mena, okres, kat_uzemi, rok, mesic,
         popis)
    VALUES
        (@id, 'TEST-23e', '2026-01-01', '2026-01-01', 'jednotka',
         'byt', '', 1, 'CZK', 'TEST', 'TEST', 2026, 1,
         N'jednotka č. 1230007, byt v budově č.p. 123, část obce Test');

    SELECT N'zápis funguje, čeká se 123/7' AS kontrola,
           jednotka_kod, jednotka_cp, jednotka_cislo, jednotka_oznaceni
    FROM dbo.Valuo_data WHERE id = @id;

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    SELECT N'POZOR: zkušební zápis selhal' AS kontrola,
           ERROR_MESSAGE() AS chyba;
END CATCH
GO


/* ---------- 23e.7 KONTROLA ROZKLADU ------------------------ */

/* Pokrytí — jednotek je 49 491 */
SELECT  COUNT(*) AS jednotek,
        SUM(CASE WHEN jednotka_kod      IS NOT NULL THEN 1 ELSE 0 END) AS s_kodem,
        SUM(CASE WHEN jednotka_cp       IS NOT NULL THEN 1 ELSE 0 END) AS s_cp,
        SUM(CASE WHEN jednotka_oznaceni IS NOT NULL THEN 1 ELSE 0 END) AS s_oznacenim
FROM dbo.Valuo_data WHERE nemovitost = 'jednotka';
GO

/* Rozdělení podle délky kódu — srovnej s tabulkou v hlavičce.
   Čekej 1-3 cifry 442, 4 cifry 9, 5 cifr 129, 6 cifr 584,
   7 cifr 14 284, 8 cifr 34 052.                              */
SELECT LEN(jednotka_kod) AS delka_kodu, COUNT(*) AS pocet,
       MIN(jednotka_oznaceni) AS prvni, MAX(jednotka_oznaceni) AS posledni
FROM dbo.Valuo_data WHERE jednotka_kod IS NOT NULL
GROUP BY LEN(jednotka_kod) ORDER BY delka_kodu;
GO

/* Nejvyšší čísla jednotek — kontrola, že se čtyřka nepřetéká */
SELECT TOP 10 jednotka_oznaceni, typ, kat_uzemi
FROM dbo.Valuo_data
WHERE jednotka_cislo IS NOT NULL
ORDER BY TRY_CAST(jednotka_cislo AS int) DESC;
GO

/* Jednotky, kterým kód nevznikl — popis má jiný tvar */
SELECT TOP 10 typ, LEFT(popis, 110) AS popis
FROM dbo.Valuo_data
WHERE nemovitost = 'jednotka' AND jednotka_kod IS NULL;
GO

/* Vzorky rozkladu */
SELECT TOP 12 cislo_vkladu, kat_uzemi, jednotka_oznaceni,
       jednotka_cp, jednotka_cislo, plocha, cenovy_udaj
FROM dbo.Valuo_data
WHERE kat_uzemi IN ('Kobylisy', 'Žižkov')
  AND jednotka_oznaceni IS NOT NULL
ORDER BY kat_uzemi, TRY_CAST(jednotka_cp AS int),
         TRY_CAST(jednotka_cislo AS int);
GO
