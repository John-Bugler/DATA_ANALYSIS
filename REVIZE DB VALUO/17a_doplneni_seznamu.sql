/* ============================================================
   VALUO — KROK 17a: DOPLNĚNÍ SEZNAMU K PŘETAŽENÍ

   Do dat nezasahuje, jen rozšiřuje seznam v KN_k_pretazeni.
   Spusť celé najednou.

   ------------------------------------------------------------
   PROČ
   ------------------------------------------------------------
   Seznam z kroku 16 stál na třech kritériích: bez parcely,
   nesedící okres, nesedící výměra. Analýza odhalila dvě další
   kategorie prokazatelně špatných vazeb, které tím propadly.

   a) CIZI_UZEMI — 342 záznamů (105 nových)
      Název k.ú. dotažené parcely není v popisu obsažen,
      takže parcela pochází z jiného území, než popis uvádí.

      Příklad: záznam 117315 má popis "č. 453 Hlivice"
      a výměru 11 451 m2. Dotažena byla parcela 453
      v k.ú. Nupaky o 233 m2.

   b) STAVEBNI_NESOULAD — 329 záznamů (29 nových)
      Popis uvádí pozemkovou parcelu ("č. 373"), ale navázána
      je stavební ("st. 373"). Jde o dvě různé parcely, které
      se jen shodně číslují.

      Příčinou je řádek 51 původního skriptu:
        is_stavebni = bool(re.search(
            r"\bstavební\b|\bstavba\b|\bč\.\s*\d+", popis, ...))
      Výraz \bč\.\s*\d+ vyhoví každému popisu s "č. 373",
      tedy i pozemkové parcele, a \bstavba\b vyhoví textu
      "(součástí je stavba č.p. 1388)", který má u budov
      téměř každý záznam.

   ------------------------------------------------------------
   POZNÁMKA K PK A GP PARCELÁM
   ------------------------------------------------------------
   14 záznamů má popis "PK č. 4203 Poděbrady" nebo
   "GP č. 527 Kobylí Hlava" — parcely pozemkové knihy
   a grafického přídělu. V katastru nemovitostí pod tímto
   číslem neexistují a hledat je jako běžné parcely by znovu
   dotáhlo cizí parcelu. Python je přeskakuje a zapisuje
   do logu; sem se nedoplňují.
   ============================================================ */

USE VALUO;
GO

/* ---------- 17a.1 CIZÍ ÚZEMÍ ------------------------------- */

INSERT INTO dbo.KN_k_pretazeni
    (id_valuo, duvod, adresa, popis, okres, kat_uzemi, nemovitost)
SELECT DISTINCT
        v.id, 'CIZI_UZEMI', v.adresa, v.popis, v.okres,
        v.kat_uzemi, v.nemovitost
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data        k ON k.id_valuo = v.id
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod   = k.kod_ku
WHERE v.popis IS NOT NULL
  AND CHARINDEX(c.ku_nazev, v.popis) = 0
  AND NOT EXISTS (SELECT 1 FROM dbo.KN_k_pretazeni p WHERE p.id_valuo = v.id);
GO
SELECT @@ROWCOUNT AS doplneno_cizi_uzemi;
GO

/* ---------- 17a.2 STAVEBNÍ / POZEMKOVÁ --------------------- */

INSERT INTO dbo.KN_k_pretazeni
    (id_valuo, duvod, adresa, popis, okres, kat_uzemi, nemovitost)
SELECT DISTINCT
        v.id, 'STAVEBNI_NESOULAD', v.adresa, v.popis, v.okres,
        v.kat_uzemi, v.nemovitost
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data k ON k.id_valuo = v.id
WHERE v.popis LIKE N'č. %'
  AND k.parcel_number LIKE 'st.%'
  AND NOT EXISTS (SELECT 1 FROM dbo.KN_k_pretazeni p WHERE p.id_valuo = v.id);
GO
SELECT @@ROWCOUNT AS doplneno_stavebni;
GO


/* ---------- 17a.3 PLOCHA PRO ROZHODOVÁNÍ -------------------
   Python používá plochu z Valuo jako kontrolu: u pozemkových
   parcel se výměra z katastru shoduje na metr (ověřeno
   u 41 782 ze 42 635 parcel, kde území sedí).              */

IF COL_LENGTH('dbo.KN_k_pretazeni', 'plocha') IS NULL
    ALTER TABLE dbo.KN_k_pretazeni ADD plocha decimal(18,2) NULL;
GO

UPDATE p
SET    p.plocha = v.plocha
FROM   dbo.KN_k_pretazeni p
JOIN   dbo.Valuo_data     v ON v.id = p.id_valuo;
GO


/* ---------- 17a.4 PŘEHLED ---------------------------------- */

SELECT duvod, COUNT(*) AS zaznamu
FROM dbo.KN_k_pretazeni
GROUP BY duvod
ORDER BY COUNT(*) DESC;
GO

SELECT COUNT(*) AS celkem, SUM(CAST(zpracovano AS int)) AS zpracovano
FROM dbo.KN_k_pretazeni;
GO
