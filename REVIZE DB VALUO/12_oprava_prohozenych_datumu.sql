/* ============================================================
   VALUO — KROK 12: OPRAVA PROHOZENÝCH DNŮ A MĚSÍCŮ

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.

   ------------------------------------------------------------
   NÁLEZ
   ------------------------------------------------------------
   U importů z pěti dnů mezi 17. 9. a 12. 10. 2026 byl den
   a měsíc prohozen — parser četl americký formát MM/DD jako
   český DD/MM.

       2026-10-12   1 349 záznamů, 63,4 % prohozených
       2026-09-30     720 záznamů, 53,1 %
       2026-10-01   2 856 záznamů, 36,0 %
       2026-09-17   1 111 záznamů, 35,6 %
       2026-10-05   1 052 záznamů, 35,2 %
       ostatní    ~100 000 záznamů, 0,00 %

   Podíl není stoprocentní proto, že prohodit lze jen datum,
   kde je den i měsíc nejvýše 12. U 20. července parser
   prohodit nemohl, takže zůstalo správně.

   ------------------------------------------------------------
   JAK SE TO POZNALO
   ------------------------------------------------------------
   Sloupec mesic pochází ze zdrojových dat a prohozením
   neprošel. U 3 152 záznamů neodpovídá měsíci v
   datum_zplatneni — a vždy odpovídá DNI. To je jednoznačný
   podpis záměny.

   U datum_podani žádný takový kontrolní údaj není, proto se
   oprava odvozuje z příslušnosti k dotčeným dávkám.

   Ověření: v těchto dávkách mělo 2 097 záznamů podání později
   než zplatnění, což je nemožné. Po opravě jich zbývá 73.

   ------------------------------------------------------------
   SLOUPEC mesic NERUŠIT
   ------------------------------------------------------------
   Vypadá jako duplicita datum_zplatneni, ale je to jediná
   kontrola správnosti datumů. Bez něj by tuhle chybu nešlo
   odhalit. Totéž platí pro budoucí importy — po každém
   importu stojí za to spustit kontrolu z bloku 12.5.
   ============================================================ */

USE VALUO;
GO

/* ---------- 12.1 ZÁLOHA PŮVODNÍCH DATUMŮ ------------------- */

IF OBJECT_ID('dbo.zaloha_datumy_20261022') IS NOT NULL
    DROP TABLE dbo.zaloha_datumy_20261022;
GO

SELECT  id,
        cislo_vkladu,
        [timestamp]       AS import,
        datum_podani      AS podani_puvodni,
        datum_zplatneni   AS zplatneni_puvodni,
        rok, mesic,
        GETDATE()         AS datum_zalohy
INTO dbo.zaloha_datumy_20261022
FROM dbo.Valuo_data;
GO

CREATE CLUSTERED INDEX IX_zaloha_datumy_id
    ON dbo.zaloha_datumy_20261022 (id);
GO

SELECT COUNT(*) AS zalohovano FROM dbo.zaloha_datumy_20261022;
GO


/* ---------- 12.2 SEZNAM DOTČENÝCH DÁVEK -------------------- */

IF OBJECT_ID('tempdb..#davky') IS NOT NULL DROP TABLE #davky;

SELECT DISTINCT CAST([timestamp] AS date) AS den
INTO #davky
FROM dbo.Valuo_data
WHERE MONTH(datum_zplatneni) <> mesic;

SELECT den AS dotcena_davka FROM #davky ORDER BY den;
GO


/* ---------- 12.3 OPRAVA datum_zplatneni --------------------
   Opravují se jen ty, kde měsíc neodpovídá kontrolnímu
   sloupci. Čas (hodiny, minuty, sekundy) zůstává.           */

UPDATE dbo.Valuo_data
SET datum_zplatneni = DATETIMEFROMPARTS(
        YEAR(datum_zplatneni),
        DAY(datum_zplatneni),      -- den se stává měsícem
        MONTH(datum_zplatneni),    -- měsíc se stává dnem
        DATEPART(hour,   datum_zplatneni),
        DATEPART(minute, datum_zplatneni),
        DATEPART(second, datum_zplatneni),
        0)
WHERE MONTH(datum_zplatneni) <> mesic;
GO

SELECT @@ROWCOUNT AS opraveno_zplatneni;
GO


/* ---------- 12.4 OPRAVA datum_podani -----------------------
   V dotčených dávkách se prohazují všechna data, kde je den
   i měsíc nejvýše 12 — tam parser prohodit mohl, a protože
   šel stejný parser přes celou dávku, prohodil.

   Data s dnem nad 12 zůstávají beze změny, ta prohodit nešla.  */

UPDATE v
SET datum_podani = DATETIMEFROMPARTS(
        YEAR(datum_podani),
        DAY(datum_podani),
        MONTH(datum_podani),
        DATEPART(hour,   datum_podani),
        DATEPART(minute, datum_podani),
        DATEPART(second, datum_podani),
        0)
FROM dbo.Valuo_data v
JOIN #davky d ON d.den = CAST(v.[timestamp] AS date)
WHERE DAY(v.datum_podani)   <= 12
  AND MONTH(v.datum_podani) <= 12;
GO

SELECT @@ROWCOUNT AS opraveno_podani;
GO


/* ---------- 12.5 KONTROLA ----------------------------------
   Tahle kontrola patří i za každý budoucí import.           */

SELECT  COUNT(*)                                            AS zaznamu,
        SUM(CASE WHEN MONTH(datum_zplatneni) <> mesic
                 THEN 1 ELSE 0 END)                         AS mesic_nesedi,
        SUM(CASE WHEN YEAR(datum_zplatneni) <> rok
                 THEN 1 ELSE 0 END)                         AS rok_nesedi,
        SUM(CASE WHEN datum_podani > datum_zplatneni
                 THEN 1 ELSE 0 END)                         AS podani_po_zplatneni
FROM dbo.Valuo_data;
GO

/* Očekávání:
     mesic_nesedi         0
     rok_nesedi           0
     podani_po_zplatneni  řádově desítky (před opravou 2 099)  */


/* ---------- 12.6 ZBYLÉ NELOGICKÉ ZÁZNAMY ------------------- */

SELECT TOP 30
        v.cislo_vkladu,
        v.datum_podani,
        v.datum_zplatneni,
        v.mesic,
        CAST(v.[timestamp] AS date) AS import,
        z.podani_puvodni,
        z.zplatneni_puvodni
FROM dbo.Valuo_data v
JOIN dbo.zaloha_datumy_20261022 z ON z.id = v.id
WHERE v.datum_podani > v.datum_zplatneni
ORDER BY v.cislo_vkladu;
GO


/* ---------- 12.7 KDYBY BYLO TŘEBA SE VRÁTIT ----------------
   Spouštět jen vědomě.                                       */

-- UPDATE v
-- SET v.datum_podani    = z.podani_puvodni,
--     v.datum_zplatneni = z.zplatneni_puvodni
-- FROM dbo.Valuo_data v
-- JOIN dbo.zaloha_datumy_20261022 z ON z.id = v.id;
-- GO
