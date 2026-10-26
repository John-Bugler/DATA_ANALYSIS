/* ================================================================
   VALUO — KROK 31: PRÁVO STAVBY JAKO SAMOSTATNÁ KATEGORIE

   PROČ
   Právo stavby (nemovitost = '---', popis „účel …, k parcele …")
   klasifikace vůbec nepočítala. Vklad jen s právem stavby skončil
   v NELZE jako „nezařazená nemovitost", ale vklad s právem stavby
   a parcelou dostal JC_PARCELY a s budovou CELEK_BUDOVA. Stav
   24. 10. 2026 (48 vkladů):

       NELZE         nelze porovnat          42
       CELEK_BUDOVA  oddělené vlastnictví     2
       CELEK_BUDOVA  bez výhrad               2   ← kontaminace
       JC_PARCELY    bez výhrad               2   ← kontaminace

   Rozhodnutí znalce 24. 10. 2026: právo stavby je samostatná
   kategorie, porovnává se jen mezi sebou, dál se nečlení.
   Je to 38 rodinných domů (z toho ~30 jeden projekt v Horních
   Počernicích) a 10 víceúčelových staveb v Dejvicích.

   CO SE MĚNÍ
   1) sp_prepocet_jednotkovych_cen: obsahuje-li vklad právo stavby,
      dostane klasifikaci PRAVO_STAVBY — přebije všechny ostatní.
   2) v_Valuo_vzorek_q: hodnocení „právo stavby", hned po cizí měně
      a nestandardním převodu (dar nebo směna práva stavby zůstává
      nestandardním převodem).

   CO SE NEMĚNÍ
   Meze: sp_prepocet_prahu se k CIS_prahy_ceny připojuje vnitřním
   spojením přes klasifikaci, PRAVO_STAVBY v něm není, takže do mezí
   nevstupuje. Pohled se připojuje vnějším spojením, takže vklady
   z něj nevypadnou.

   ZÁLOHA
   Definice obou objektů před změnou jsou v tabulce
   dbo.zaloha_definice (krok = 'pred 31').

   PO NĚM
   python 30_import_valuo.py --prepocty
   ================================================================ */

ALTER PROCEDURE dbo.sp_prepocet_jednotkovych_cen
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

/* ---------- 31.2 HODNOCENÍ V POHLEDU -----------------------------
   Pohled má 13 877 znaků, proto se nepřepisuje celý: vloží se jeden
   řádek za jediný výskyt „nestandardní převod". Kontroluje se, že
   výskyt je právě jeden a že změna ještě neproběhla.              */

DECLARE @d nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID('dbo.v_Valuo_vzorek_q'));
DECLARE @hledat nvarchar(200) = N'THEN N''nestandardní převod''';
DECLARE @vlozit nvarchar(300) = @hledat + NCHAR(10)
    + N'            WHEN v.klasifikace = ''PRAVO_STAVBY''       THEN N''právo stavby''';

IF (LEN(@d) - LEN(REPLACE(@d, @hledat, N''))) / LEN(@hledat) <> 1
    THROW 50001, N'Řetězec pro vložení není v pohledu právě jednou — nic se nemění.', 1;
IF CHARINDEX(N'PRAVO_STAVBY', @d) > 0
    THROW 50002, N'Pohled už PRAVO_STAVBY obsahuje — krok 31 už proběhl.', 1;

SET @d = REPLACE(@d, @hledat, @vlozit);
SET @d = STUFF(@d, CHARINDEX(N'CREATE   VIEW', @d), LEN(N'CREATE   VIEW'), N'ALTER VIEW');
EXEC sp_executesql @d;
GO

/* ---------- 31.3 PŘEPOČET KLASIFIKACE A KONTROLA ----------------- */

EXEC dbo.sp_prepocet_jednotkovych_cen;
GO

-- čeká se: PRAVO_STAVBY / právo stavby 48 (resp. menší počet, pokud
-- je některý dar nebo směna — ty zůstávají „nestandardní převod")
SELECT q.klasifikace, q.hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q q
WHERE q.cislo_vkladu IN (SELECT cislo_vkladu FROM dbo.Valuo_data WHERE nemovitost = '---')
GROUP BY q.klasifikace, q.hodnoceni_ceny;
GO
