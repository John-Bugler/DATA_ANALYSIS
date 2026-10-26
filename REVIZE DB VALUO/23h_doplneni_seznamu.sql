/* ============================================================
   VALUO — KROK 23h: DOPLNĚNÍ SEZNAMU K PŘETAŽENÍ

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Plní jen pracovní tabulku KN_k_pretazeni, do dat nezasahuje.
   Spusť po 23g, před opraveným krokem 17.

   ============================================================
   PROČ
   ============================================================
   Krok 23g smazal 13 040 vazeb na cizí parcely a 2 675 z nich
   bylo osamělých, takže ty řádky teď nemají parcelu žádnou:

       budova     2 723
       parcela      828
       jednotka      60
       celkem     3 611

   Správné parcely jsou v popisu a dají se dotáhnout z katastru
   krokem 17. Ten ale čte ze seznamu KN_k_pretazeni, kde je
   všech 9 936 záznamů z minulého běhu označeno jako zpracované.

   ------------------------------------------------------------
   CO SE DĚLÁ
   ------------------------------------------------------------
   1  Záznamy, které v seznamu už jsou a dosud nemají parcelu,
      se vrátí na zpracovano = 0. Opravený parser u nich může
      uspět tam, kde ten původní selhal.

   2  Řádky bez parcely, které v seznamu nejsou, se doplní
      s důvodem PO_23G.

   ------------------------------------------------------------
   PROČ SE VYPLATÍ ZKUSIT ZNOVU I STARÉ ZÁZNAMY
   ------------------------------------------------------------
   Parser kroku 17 měl u seznamů parcel dvě chyby:

       "č. 2342/504, 2342/505, 2342/506 Stodůlky"
           vzor se vzorem \S+? sebral i čárku, takže hledal
           parcelu "2342/504," v území "2342/505, 2342/506
           Stodůlky" — katastr pochopitelně nic nenašel

       "na parcele 1340, 1341 Nusle"
           název území se dědil dopředu, takže parcela 1340
           zůstala bez území a zahodila se; vrátila se jen 1341

   Název území se přitom uvádí ZA poslední parcelou, ke které
   patří, takže se musí dědit od konce. Opravená verze je
   ověřená na 15 tvarech popisu.

   Část těch 953 parcel, které jsme po minulém běhu odepsali
   jako „v katastru dnes neexistují", proto může být jen
   nedoparsovaná.
   ============================================================ */

USE VALUO;
GO

/* ---------- 23h.1 STAV PŘED ------------------------------- */

SELECT duvod, zpracovano, COUNT(*) AS radku
FROM dbo.KN_k_pretazeni GROUP BY duvod, zpracovano ORDER BY duvod;
GO

SELECT v.nemovitost, COUNT(*) AS bez_parcely
FROM dbo.Valuo_data v
WHERE NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data k
                  WHERE k.id_valuo = v.id)
GROUP BY v.nemovitost ORDER BY COUNT(*) DESC;
GO


/* ---------- 23h.2 RESET STARÝCH ZÁZNAMŮ -------------------
   Jen těch, které parcelu pořád nemají. Záznamy, kterým krok 17
   parcelu úspěšně dotáhl, zůstanou zpracované.               */

UPDATE k SET zpracovano = 0
FROM dbo.KN_k_pretazeni k
WHERE k.zpracovano = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data p
                  WHERE p.id_valuo = k.id_valuo);
GO

PRINT N'resetováno starých záznamů: ' + CAST(@@ROWCOUNT AS varchar);
GO


/* ---------- 23h.3 DOPLNĚNÍ NOVÝCH ------------------------- */

INSERT INTO dbo.KN_k_pretazeni
    (id_valuo, duvod, adresa, popis, okres, kat_uzemi, nemovitost,
     zpracovano, plocha)
SELECT  v.id, 'PO_23G', v.adresa, v.popis, v.okres, v.kat_uzemi,
        v.nemovitost, 0, v.plocha
FROM dbo.Valuo_data v
WHERE NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data p
                  WHERE p.id_valuo = v.id)
  AND NOT EXISTS (SELECT 1 FROM dbo.KN_k_pretazeni z
                  WHERE z.id_valuo = v.id);
GO

PRINT N'doplněno nových záznamů: ' + CAST(@@ROWCOUNT AS varchar);
GO


/* ---------- 23h.4 KONTROLA -------------------------------- */

/* Kolik krok 17 dostane ke zpracování */
SELECT duvod, zpracovano, COUNT(*) AS radku
FROM dbo.KN_k_pretazeni GROUP BY duvod, zpracovano
ORDER BY zpracovano, duvod;
GO

SELECT COUNT(*) AS ke_zpracovani
FROM dbo.KN_k_pretazeni WHERE zpracovano = 0;
GO

/* Musí se rovnat počtu řádků bez parcely — jinak je v seznamu
   někdo, kdo parcelu má, nebo naopak chybí                   */
SELECT
  (SELECT COUNT(*) FROM dbo.KN_k_pretazeni WHERE zpracovano = 0)
      AS ke_zpracovani,
  (SELECT COUNT(*) FROM dbo.Valuo_data v
   WHERE NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data k
                     WHERE k.id_valuo = v.id))
      AS bez_parcely;
GO

/* Podle typu popisu, ať je vidět, co parser dostane */
SELECT nemovitost,
  SUM(CASE WHEN popis LIKE N'%na parcele %' THEN 1 ELSE 0 END) AS tvar_na_parcele,
  SUM(CASE WHEN popis NOT LIKE N'%na parcele %'
            AND popis LIKE N'%č. %' THEN 1 ELSE 0 END)         AS tvar_c,
  COUNT(*) AS celkem
FROM dbo.KN_k_pretazeni WHERE zpracovano = 0
GROUP BY nemovitost ORDER BY COUNT(*) DESC;
GO
