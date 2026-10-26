/* ============================================================================
   KROK 46 — nosná nemovitost u budov a pozemků

   Proč krok vznikl
   ----------------
   Krok 45 počítal plochu po řádcích, ale jen u vkladů s JEDNOTKOU
   (`#radek` měl `WHERE d.nemovitost = 'jednotka'`). Znalec na to přišel
   dotazem 25. 10. 2026: „to se týkalo vkladů kde jsou jednotky, jestli se
   nepletu". Netýkalo se jen jich — tím, že view bralo plochu výhradně
   z `Valuo_vklad_plocha`, přišlo **1 682 vkladů s budovou** o podlahovou
   plochu i o Kč/m². To se opravilo hned (kontrola 8.8 v souboru kroku 45)
   a tenhle krok princip nosné nemovitosti na budovy a pozemky rozšiřuje.

   Zadání znalce
   -------------
   „podobný princip s hlavní nemovitostí v rámci vkladu kde je budova jde
   nějak nastavit taky, například vklad V-45754/2024-101 kde je více řádků
   hlavní je evidentně rodinný dům… pro nastavení nějaké logiky je třeba
   nastavit hlavní typy nemovitosti u budov, stejně tak by to mohlo jít i
   pro pozemky ale tam je to už výrazně komplikovanější."

   „u skupiny pozemků se těžko zjistí ta nosná nemovitost… buď pozemky
   různých druhů polí a podobně a tam není nosného nic… anebo skupina
   pozemků může obsahovat jednu stavební parcelu a k tomu podíly na
   sousedních komunikacích… tam by ta nosná nemovitost byla ta hlavní
   stavební parcela."

   „tam kde u budov např. RD není podlahová plocha tam samozřejmě nic
   nedělit a bude jen celková cena."

   „vklad se 2 rodinnými domy dělený podlahovou plochou obou RD ale
   upozornit na to."

   ČÁST 1 — číselník typů nemovitostí
   ----------------------------------
   `CIS_nemovitost_typ` s klíčem **(nemovitost, typ)**, ne jen typ.
   Důvod je v datech: `garáž` existuje jako jednotka (6 346 řádků, medián
   plochy 75,2 m² — bývá zapsaná za celou halu) i jako budova (2 458 řádků,
   medián 19,0 m² — jedna garáž), a `Neznámé` ve všech třech kategoriích.
   Krok 45 měl klíč jen na typu a tím obojí mísil; `CIS_jednotka_typ` se
   proto ruší, aby dvě verze téhož číselníku nežily vedle sebe.

   Priorita: jednotky 1 až 6, budovy 11 až 21, právo stavby 30. Pásma jsou
   oddělená, takže u vkladu s bytem i garážovou budovou vyhraje byt.
   33 typů v 18 skupinách; žádný typ z dat v číselníku nechybí.

   ČÁST 2 — nálezy a sloupce
   -------------------------
   Dva nové nálezy v `CIS_nalezy`:
   - `VICE_NOSNYCH` (1 287 vkladů) — několik nemovitostí téhož druhu a žádná
     hlavní; cena se dělí součtem jejich ploch, takže jednotková cena je
     průměr. Vzorek to nevyřazuje.
   - `NOSNA_BEZ_PLOCHY` (5 922 vkladů) — aspoň jedna nosná nemovitost plochu
     nemá, proto se nedělí vůbec a uvádí se jen celková cena.

   Nález `PLOCHA_POSUN_CARKY` z kroku 44 se už nehledá (viz krok 45).

   ČÁST 3 — budovy
   ---------------
   U JEDNOTKY je pole `plocha` vždy plocha jednotky. U BUDOVY jen tam, kde
   to `typ_plochy` říká — jinak je v něm **výměra parcely** a dělit se jí
   nesmí. Změřeno: u rodinných domů má podlahovou plochu 848 z 2 960 řádků,
   u bytových domů 338 ze 4 051, u garáží 281 z 2 458.

   Chybí-li Valuova podlahová plocha a je-li ve vkladu jediná budova,
   nastoupí RÚIAN. U více budov RÚIAN popisuje jednu z nich a rozdělit ho
   nelze, takže plocha zůstane neznámá a nedělí se.

   Rozsah: u 82 % vkladů s budovou žádná podlahová plocha neexistuje
   (7 459 z 9 060 vkladů s jedinou budovou). Proto má u budov hlavní váhu
   Kč/m² pozemku, ne Kč/m² podlahové plochy.

   ČÁST 4 — pozemky
   ----------------
   **Nosná výměra = výhradní parcely, které nejsou tvar pásu ani druh
   komunikace.** Není-li žádná, je to balík pozemků a nosná se nevybírá.

   Žádný nový detektor nebyl potřeba — detektory karty z kroku 34 to už
   rozdělily správně. Chyběla jen agregace: bez budovy není kotva, takže
   všechny parcely dostanou roli „bez kotvy" a `vymera_vyhradni_celek`
   zůstane prázdná.

   Doloženo na Písnici (14 vkladů z roku 2025, developerský projekt):

   | parcely | ve vkladech | vlastnictví | tvar pásu | kompaktnost | šířka |
   |---|---|---|---|---|---|
   | 845/107, 845/108, 846/1 | 14 ze 14 | neověřeno | ANO | 0,04–0,18 | 4,4–6,0 m |
   | 845/358–368, 845/112, 845/113, 846/15 | 1 | výhradní | ne | 0,58–0,82 | 11,1–14,2 m |

   Výsledek: 11 z 15 vkladů padne na **přesně 15 000 Kč/m²** nosné výměry,
   jeden na 14 938. To je ceník developera. Dosavadní metrika „Kč/m² všech
   pozemků" z nich dělala rozptyl 1 614 až 3 146 Kč/m², protože je tři
   sdílené komunikace rozmělnily. Nezávislé potvrzení: jednoparcelní vklady
   ve stejném k. ú. a čase `V-29788/2025-101` na 15 500 Kč/m² a
   `V-35425/2025-101` na 18 451 Kč/m². Medián skupiny `pozemek` v Písnici
   je 15 000 Kč/m² z 52 vzorků a všech 15 vkladů je „v pásmu".

   Rozsah na celé databázi (5 222 pozemkových vkladů):

   | | vkladů | Kč/m² dnes | Kč/m² nosné |
   |---|---|---|---|
   | vše je nosné, metrika beze změny | 2 307 | 2 193 | 2 200 |
   | nosná není nic → balík | 2 205 | 275 | — |
   | odloupne se nad 50 % výměry | 244 | 1 414 | 9 842 |
   | odloupne se 10 až 50 % | 227 | 931 | 1 292 |
   | odloupne se do 10 % | 283 | 308 | 340 |

   Těch 2 205 balíků s mediánem 275 Kč/m² je přesně to, co znalec popsal
   jako „soubor komunikací nebo soubor orných půd" — pravidlo si tam nosnou
   odmítne vybrat a je to správně.

   `vymera_podilu` je doplňující údaj: co kupující dostal nad nosnou parcelu,
   přepočtené počtem vkladů s tou parcelou. U V-32320/2025-101 je to 231 m²
   a Kč/m² včetně podílu pak 11 033 místo 15 000. Hlavní metrika je nosná
   parcela — pro ni mluví ta jedenáctka přesných 15 000; podíl se vypisuje
   vedle (rozhodnutí znalce).

   Past, na kterou se narazilo
   ---------------------------
   `Valuo_karta_parcely.kn_id` je identita **řádku**, ne parcely. Pro všech
   14 písnických vkladů je jiné (41538, 41721, 41576, …), zatímco `gml_id`
   je u všech stejné (`CP.3285023101`). Seskupení podle `kn_id` dá na otázku
   „v kolika vkladech ta parcela je" vždy jedničku. Identita parcely je
   `gml_id`; `vkladu_s_parcelou` je na něm počítané správně.

   Pořadí nasazení
   ---------------
   1. tento soubor, části 1 a 2
   2. `CREATE OR ALTER VIEW dbo.v_Valuo_karta_vkladu`
   3. `CREATE OR ALTER PROCEDURE dbo.sp_prepocet_ploch`
   4. `EXEC dbo.sp_prepocet_ploch @prepocitat = 1` (11 s)
   5. část 5 — zrušení `CIS_jednotka_typ`
   6. `42_export_definic.py`

   Krok 2 musí být před krokem 3 (poučení z kroku 45): procedura ve své
   části 7 jmenuje sloupce view, a odložená vazba v SQL Serveru platí pro
   chybějící objekty, ne pro chybějící sloupce objektu, který existuje.

   Text procedury a view je v `_definice\definice_RRRRMMDD.sql`, který
   vyrábí `42_export_definic.py` přímo z `sys.sql_modules`.
   ============================================================================ */

SET XACT_ABORT ON;
SET NOCOUNT ON;

/* ---------------------------------------------------------------------------
   ČÁST 1 — číselník typů nemovitostí
   --------------------------------------------------------------------------- */

IF OBJECT_ID('dbo.CIS_nemovitost_typ') IS NULL
CREATE TABLE dbo.CIS_nemovitost_typ (
    nemovitost varchar(20)   NOT NULL,
    typ        nvarchar(100) NOT NULL,
    priorita   int           NOT NULL,
    skupina    nvarchar(40)  NOT NULL,
    plocha_min decimal(14,2) NULL,
    plocha_max decimal(14,2) NULL,
    popis      nvarchar(400) NULL,
    CONSTRAINT PK_CIS_nemovitost_typ PRIMARY KEY CLUSTERED (nemovitost, typ)
);

MERGE dbo.CIS_nemovitost_typ AS c
USING (VALUES
 ('jednotka', N'byt', 1, N'byt', 10.00, 400.00,
  N'Nosná nemovitost vkladu. Medián plochy v databázi 58,3 m².'),
 ('jednotka', N'skupina bytů', 1, N'byt', 10.00, 1000.00,
  N'Více bytů zapsaných jako jedna jednotka.'),
 ('jednotka', N'skupina bytů a nebytových prostorů', 1, N'byt', 10.00, 1000.00,
  N'Více jednotek zapsaných jako jedna. Cena v sobě nese i nebytovou část.'),
 ('jednotka', N'rozestavěná jednotka', 1, N'rozestavěná', 10.00, 400.00,
  N'Nosná jako byt, ale cena se nesrovnává s dokončenými — vlastní skupina.'),
 ('jednotka', N'ateliér', 2, N'ateliér', 10.00, 400.00,
  N'Medián plochy 41,5 m². Do pásma mediánu bytů padne v 74,9 % případů.'),
 ('jednotka', N'dílna nebo provozovna', 3, N'dílna', 10.00, 1000.00,
  N'Do pásma mediánu bytů padne v 37,2 % případů, vlastní skupina je nutná.'),
 ('jednotka', N'jiný nebytový prostor', 4, N'nebyt', 2.00, 1000.00,
  N'Sklep, sklad, kancelář. Nosná je jen tam, kde ve vkladu nic vyššího není — například dokup sklepa.'),
 ('jednotka', N'garáž', 5, N'garáž jednotka', 5.00, 3000.00,
  N'Garážová jednotka bývá zapsaná za celou halu, proto horní mez 3 000 m² a medián plochy 75,2 m². Do pásma mediánu bytů padne ve 4,9 % případů.'),
 ('jednotka', N'Neznámé', 6, N'ostatní', NULL, NULL,
  N'Valuo typ neuvedlo. Priorita nejnižší, aby nepřebila skutečný typ.'),
 ('budova', N'rodinný dům', 11, N'rodinný dům', 20.00, 2000.00,
  N'Medián podlahové plochy 165,0 m². Podlahovou plochu má Valuo jen u 848 z 2 960 řádků — u ostatních je v poli plocha výměra parcely a dělit se nesmí.'),
 ('budova', N'objekt k bydlení', 11, N'rodinný dům', 20.00, 2000.00,
  N'Starší zápis rodinného domu; stejná skupina.'),
 ('budova', N'bytový dům', 12, N'bytový dům', 50.00, 20000.00,
  N'Celý dům, ne jednotka. Podlahovou plochu má Valuo jen u 338 ze 4 051 řádků.'),
 ('budova', N'stavba pro rodinnou rekreaci', 13, N'rekreace', 10.00, 1000.00,
  N'Chata nebo rekreační domek. Medián plochy 40,0 m².'),
 ('budova', N'zemědělská usedlost', 13, N'rekreace', 20.00, 5000.00,
  N'Jen 2 řádky; skupina podle charakteru užívání.'),
 ('budova', N'víceúčelová stavba', 14, N'komerční', 20.00, 20000.00,
  N'Komerční stavby jedna skupina — vzorků je na dělení málo.'),
 ('budova', N'stavba pro administrativu', 14, N'komerční', 20.00, 20000.00, NULL),
 ('budova', N'stavba občanského vybavení', 14, N'komerční', 20.00, 20000.00, NULL),
 ('budova', N'objekt občanské vybavenosti', 14, N'komerční', 20.00, 20000.00, NULL),
 ('budova', N'stavba pro obchod', 14, N'komerční', 20.00, 20000.00, NULL),
 ('budova', N'stavba ubytovacího zařízení', 14, N'komerční', 20.00, 20000.00, NULL),
 ('budova', N'stavba pro shromažďování většího počtu osob', 14, N'komerční', 20.00, 20000.00, NULL),
 ('budova', N'stavba pro výrobu a skladování', 15, N'výrobní', 20.00, 50000.00, NULL),
 ('budova', N'průmyslový objekt', 15, N'výrobní', 20.00, 50000.00, NULL),
 ('budova', N'zemědělská stavba', 16, N'zemědělská', 10.00, 20000.00, NULL),
 ('budova', N'objekt lesního hospodářství', 16, N'zemědělská', 10.00, 20000.00, NULL),
 ('budova', N'stavba technického vybavení', 17, N'technická', 1.00, 20000.00,
  N'Trafostanice, vodojem. Cena se s bydlením nesrovnává.'),
 ('budova', N'stavba pro dopravu', 17, N'technická', 1.00, 20000.00, NULL),
 ('budova', N'budova s číslem popisným', 18, N'nespecifikovaná', 20.00, 20000.00,
  N'Valuo druh neuvedlo, jen že budova číslo popisné má. Vlastní skupina, aby se nemíchala s bydlením.'),
 ('budova', N'budova s číslem evidenčním', 18, N'nespecifikovaná', 5.00, 20000.00, NULL),
 ('budova', N'jiná stavba', 19, N'jiná stavba', 1.00, 20000.00,
  N'Kolna, přístavek, vedlejší stavba. Nosná je jen tam, kde ve vkladu nic vyššího není.'),
 ('budova', N'garáž', 20, N'garáž budova', 5.00, 3000.00,
  N'Samostatná garáž jako stavba, medián plochy 19,0 m² — proti garážové JEDNOTCE (medián 75,2 m²) je to jiná věc, proto jiná skupina.'),
 ('budova', N'Neznámé', 21, N'ostatní', NULL, NULL, N'Valuo typ neuvedlo.'),
 ('---', N'Neznámé', 30, N'právo stavby', NULL, NULL,
  N'Právo stavby se porovnává jen mezi sebou a dál se nečlení (rozhodnutí znalce, krok 31).')
) AS v (nemovitost, typ, priorita, skupina, plocha_min, plocha_max, popis)
ON c.nemovitost = v.nemovitost AND c.typ = v.typ
WHEN MATCHED THEN UPDATE SET c.priorita = v.priorita, c.skupina = v.skupina,
     c.plocha_min = v.plocha_min, c.plocha_max = v.plocha_max, c.popis = v.popis
WHEN NOT MATCHED BY TARGET THEN
     INSERT (nemovitost, typ, priorita, skupina, plocha_min, plocha_max, popis)
     VALUES (v.nemovitost, v.typ, v.priorita, v.skupina, v.plocha_min, v.plocha_max, v.popis);

/* ---------------------------------------------------------------------------
   ČÁST 2 — nálezy a sloupce
   --------------------------------------------------------------------------- */

MERGE dbo.CIS_nalezy AS c
USING (VALUES
 ('VICE_NOSNYCH', 'plocha', 42, CAST(1 AS bit), CAST(0 AS bit),
  N'Více nosných nemovitostí stejného druhu',
  N'Ve vkladu je několik nemovitostí téhož druhu a žádná z nich není hlavní — například dva rodinné domy nebo dva byty. Cena vkladu se dělí součtem jejich ploch, takže jednotková cena je průměr za obě a ne cena jedné z nich. Vzorek to nevyřazuje, ale do porovnání se hodí jen tam, kde je ten průměr smysluplný.'),
 ('NOSNA_BEZ_PLOCHY', 'plocha', 48, CAST(1 AS bit), CAST(0 AS bit),
  N'Nosná nemovitost nemá podlahovou plochu',
  N'Aspoň jedna nosná nemovitost vkladu podlahovou plochu nemá, a proto se nic nedělí — uvádí se jen celková cena. U budov je to běžné: Valuo dává do pole plocha výměru parcely (u rodinných domů u 2 076 z 2 960 řádků) a RÚIAN tu stavbu často nezná. Dělit součtem jen těch ploch, které známe, by jednotkovou cenu nadhodnotilo.')
) AS v (kod, skupina, poradi, automaticky, vyrazuje_vzorek, nazev, popis)
ON c.kod = v.kod
WHEN MATCHED THEN UPDATE SET c.skupina = v.skupina, c.poradi = v.poradi,
     c.automaticky = v.automaticky, c.vyrazuje_vzorek = v.vyrazuje_vzorek,
     c.nazev = v.nazev, c.popis = v.popis
WHEN NOT MATCHED BY TARGET THEN
     INSERT (kod, skupina, poradi, automaticky, vyrazuje_vzorek, nazev, popis)
     VALUES (v.kod, v.skupina, v.poradi, v.automaticky, v.vyrazuje_vzorek, v.nazev, v.popis);

UPDATE dbo.CIS_nalezy
SET automaticky = 0,
    popis = N'NEPOUŽÍVÁ SE od 25. 10. 2026, krok 45. Histogram násobku plochy z podílu proti použité ploše nemá na hodnotě 10 žádný vrchol, takže posun desetinné čárky jako jev v datech neexistuje. Nahrazuje to nález rozporu ve škále čitatele podílu, který se zapisuje do Valuo_vklad_plocha.nalez_skala.'
WHERE kod = 'PLOCHA_POSUN_CARKY';

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_vklad_plocha') AND name = 'vymera_nosna')
BEGIN
    EXEC('ALTER TABLE dbo.Valuo_vklad_plocha ADD vymera_nosna decimal(14,2) NULL');
    EXEC('ALTER TABLE dbo.Valuo_vklad_plocha ADD parcel_nosnych int NULL');
    EXEC('ALTER TABLE dbo.Valuo_vklad_plocha ADD vymera_podilu decimal(14,2) NULL');
    EXEC('ALTER TABLE dbo.Valuo_vklad_plocha ADD nalez_vice_nosnych bit NOT NULL
              CONSTRAINT DF_Valuo_vklad_plocha_vice DEFAULT 0');
    EXEC('ALTER TABLE dbo.Valuo_vklad_plocha ADD nalez_bez_plochy bit NOT NULL
              CONSTRAINT DF_Valuo_vklad_plocha_bezpl DEFAULT 0');
    EXEC('ALTER TABLE dbo.Valuo_vklad_plocha ADD nemovitost varchar(20) NULL');
END;

/* Mapa je plochý výtah kvůli rychlosti (pohled nad 49 788 vklady trvá přes
   minutu), takže příznaky pro filtry musí být fyzicky v ní. */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_mapa') AND name = 'nalez_vice_nosnych')
    EXEC('ALTER TABLE dbo.Valuo_mapa ADD nalez_vice_nosnych bit NULL');
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_mapa') AND name = 'nalez_bez_plochy')
    EXEC('ALTER TABLE dbo.Valuo_mapa ADD nalez_bez_plochy bit NULL');
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Valuo_mapa') AND name = 'vymera_nosna')
    EXEC('ALTER TABLE dbo.Valuo_mapa ADD vymera_nosna decimal(14,2) NULL');

/* ---------------------------------------------------------------------------
   ČÁST 3 a 4 — procedura a view
   Text je v `_definice\definice_RRRRMMDD.sql` (viz 42_export_definic.py).
   Pořadí: view, potom procedura, potom EXEC.
   --------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
   ČÁST 5 — zrušení číselníku z kroku 45
   Spouští se až po úspěšném běhu procedury.
   --------------------------------------------------------------------------- */

IF OBJECT_ID('dbo.CIS_jednotka_typ') IS NOT NULL
BEGIN
    DECLARE @odkazy int = (
        SELECT COUNT(*) FROM sys.sql_expression_dependencies d
        WHERE d.referenced_entity_name = 'CIS_jednotka_typ');
    IF @odkazy = 0 DROP TABLE dbo.CIS_jednotka_typ;
    ELSE THROW 51047, 'Na CIS_jednotka_typ se ještě odkazuje objekt v databázi.', 1;
END;

/* ---------------------------------------------------------------------------
   ČÁST 6 — kontroly
   --------------------------------------------------------------------------- */

/* 6.1 Šest vkladů z kroku 45 musí vyjít beze změny, k nim tři z kroku 46:
       V-45754/2024-101  rodinný dům, 171 m² → 108 220 Kč/m² podlahové
       V-32320/2025-101  pozemky, nosná 643 m² → 15 000 Kč/m², s podílem 11 033
       V-29788/2025-101  jedna parcela 1 116 m² → 15 500 Kč/m²               */
SELECT v.cislo_vkladu, v.nosna_nemovitost, v.nosna_skupina, v.nosny_typ,
    v.radku_nosnych, v.parcel_nosnych, v.plocha_podlahova_karty, v.vymera_nosna,
    v.vymera_podilu,
    CAST(v.jc_Kc_m2_podlahova AS decimal(12,0))     AS jc_podlahova,
    CAST(v.jc_Kc_m2_nosne_vymery AS decimal(12,0))  AS jc_nosne,
    CAST(v.jc_Kc_m2_s_podilem AS decimal(12,0))     AS jc_s_podilem,
    v.nalez_vice_nosnych, v.nalez_bez_plochy, v.jc_verdikt
FROM dbo.v_Valuo_karta_vkladu v
WHERE v.cislo_vkladu IN ('V-3012/2026-101', 'V-31790/2024-101', 'V-1000/2025-202',
    'V-10032/2026-101', 'V-23003/2024-101', 'V-46661/2026-101',
    'V-45754/2024-101', 'V-32320/2025-101', 'V-29788/2025-101')
ORDER BY v.nosna_nemovitost, v.cislo_vkladu;

/* 6.2 Písnice: medián skupiny pozemek 15 000 Kč/m² z 52 vzorků a všech
       15 developerských vkladů „v pásmu". */
SELECT v.cislo_vkladu, v.parcel_celkem, v.parcel_nosnych, v.vymera_pozemku_vse,
    v.vymera_nosna, CAST(v.jc_Kc_m2_vsech_pozemku AS decimal(12,0)) AS jc_vse,
    CAST(v.jc_Kc_m2_nosne_vymery AS decimal(12,0)) AS jc_nosne,
    v.jc_verdikt, v.jc_median_ku, v.jc_vzorku_ku
FROM dbo.v_Valuo_karta_vkladu v
WHERE v.kat_uzemi = N'Písnice' AND v.nosna_nemovitost = 'parcela'
  AND v.rok = 2025 AND v.parcel_celkem >= 4
ORDER BY v.cislo_vkladu;

/* 6.3 Rozsah podle kategorie. Změřeno 25. 10. 2026:
       jednotka 37 340, budova 7 101, parcela 5 222, právo stavby 44;
       podlahovou plochu má 38 563 vkladů, nosnou výměru 13 236. */
SELECT v.nosna_nemovitost AS kategorie, v.nosna_skupina, COUNT(*) AS vkladu,
    SUM(CASE WHEN v.jc_Kc_m2_podlahova IS NOT NULL THEN 1 ELSE 0 END)    AS ma_jc_podlahove,
    SUM(CASE WHEN v.jc_Kc_m2_nosne_vymery IS NOT NULL THEN 1 ELSE 0 END) AS ma_jc_nosne,
    SUM(CASE WHEN v.jc_verdikt = 'v pásmu' THEN 1 ELSE 0 END)            AS v_pasmu,
    SUM(CASE WHEN v.jc_verdikt = 'k prověření' THEN 1 ELSE 0 END)        AS k_proverení,
    SUM(CASE WHEN v.nalez_vice_nosnych = 1 THEN 1 ELSE 0 END)            AS vice_nosnych,
    SUM(CASE WHEN v.nalez_bez_plochy = 1 THEN 1 ELSE 0 END)              AS bez_plochy
FROM dbo.v_Valuo_karta_vkladu v
WHERE v.nosna_nemovitost IS NOT NULL
GROUP BY v.nosna_nemovitost, v.nosna_skupina
ORDER BY v.nosna_nemovitost, COUNT(*) DESC;

/* 6.4 Žádný typ v datech nesmí v číselníku chybět — musí být 0. */
SELECT COUNT(DISTINCT CONCAT(d.nemovitost, '|', d.typ)) AS chybi_v_ciselniku
FROM dbo.Valuo_data d
WHERE d.nemovitost IN ('jednotka', 'budova', '---')
  AND NOT EXISTS (SELECT 1 FROM dbo.CIS_nemovitost_typ t
                  WHERE t.nemovitost = d.nemovitost AND t.typ = d.typ);

/* 6.5 Nemá-li plochu každá nosná nemovitost, nesmí být plocha vkladu
       vyplněná — jinak by se dělilo částečným součtem. Musí být 0 řádků. */
SELECT vp.cislo_vkladu, vp.nosna_skupina, vp.radku_nosnych, vp.plocha
FROM dbo.Valuo_vklad_plocha vp
WHERE vp.nalez_bez_plochy = 1 AND vp.plocha IS NOT NULL;

/* 6.6 Mapa musí mít příznaky naplněné stejně jako pohled. Musí být 0. */
SELECT COUNT(*) AS rozdilu
FROM dbo.Valuo_mapa m
JOIN dbo.v_Valuo_karta_vkladu v ON v.cislo_vkladu = m.cislo_vkladu
WHERE ISNULL(m.nalez_vice_nosnych, 0) <> ISNULL(v.nalez_vice_nosnych, 0)
   OR ISNULL(m.nalez_bez_plochy, 0)   <> ISNULL(v.nalez_bez_plochy, 0);

/* ======================================================================
   7. OPRAVA: jeden vlastník Valuo_mapa                     25. 10. 2026
   ======================================================================

   Co našel znalec
   ---------------
   V mapové aplikaci u vkladu V-23039/2026-101 (bytová jednotka 1156/13,
   Štúrova, k. ú. Krč) byl rozpor. Karta vpravo: cena vkladu 5 300 000 Kč,
   podlahová plocha jednotky 40,50 m², 130 864 Kč/m² — správně. Soupis
   položek v domě u téhož vkladu: druh „bytový dům" místo „byt"
   a 7 793 Kč/m². U jiného domu vedle byl druh správně „byt".

   Příčina
   -------
   Tabulku Valuo_mapa plnily DVĚ procedury. sp_prepocet_mapy psala bod,
   druh, kategorii a cenu. sp_prepocet_ploch si na konci (její část 7)
   dolepovala plochu a příznaky nálezů. Pořadí kroků bylo mapa (4),
   teprve pak plochy (5) — v jednom řádku mapy tak stála plocha z nového
   přepočtu vedle ceny a druhu ze starého. Řádek se rozešel sám se sebou.

   Těch 7 793 Kč/m² je 5 300 000 / 680,10 — cena dělená součtem ploch
   všech položek vkladu včetně podílů na nebytových prostorech, jak se
   počítala před krokem 45. Nová plocha 40,50 m² byla vedle ní jen
   zapsaná, do ceny už se nedostala.

   Rozsah před opravou: ze 49 692 řádků mapy mělo 2 789 jiný druh,
   7 915 jinou cenu a 11 093 jinou plochu, než říkal pohled.

   Oprava
   ------
   a) Část 7 z sp_prepocet_ploch odstraněna. Do Valuo_mapa zapisuje
      jedině sp_prepocet_mapy.
   b) sp_prepocet_mapy přepsána: všechny příznaky kroku 45 a 46 bere
      přímo z pohledu, druh a prioritu hlavní nemovitosti řídí
      CIS_nemovitost_typ (dřív vlastní výčet typů, který se s pohledem
      mohl rozejít — a rozešel), cena je
      COALESCE(jc_Kc_m2_podlahova, jc_Kc_m2_nosne_vymery,
               jc_Kc_m2_vsech_pozemku)
      a plocha
      COALESCE(plocha_podlahova_karty, vymera_nosna, vymera_pozemku_vse).
   c) Pořadí v 38_prepocty.py obráceno: plochy [4/5], mapa [5/5].
   d) Fronta dostala třetí podmínku: do přepočtu jde i k. ú., kde je
      zdroj novější než řádek mapy (vp.kdy > m.prepocteno). Bez ní se
      po změně pohledu nebo po přepočtu ploch mapa nepřepočítala vůbec,
      protože všechny vklady v ní už byly, a stará chyba by zůstala.
   e) Nový volitelný parametr @kod_ku_jen pro cílený přepočet jednoho
      k. ú. Filtr je nad celým řetězcem OR, v závorkách — bez nich by se
      AND přivěsil jen k poslednímu EXISTS a fronta by brala i cizí k. ú.

   Poučení
   -------
   Odvozenou tabulku smí plnit jen JEDNA procedura. Dolepení „ještě pár
   sloupců" z druhého místa nerozbije nic hned. Rozbije se to teprve ve
   chvíli, kdy se obě místa pustí v jiném pořadí nebo jen jedno z nich —
   a neprojeví se to jako chyba, nýbrž jako nesmyslná cena v mapě. Tedy
   to najde znalec, ne skript. Proto kontrola 7.1.

   f) Ukazatel zbyva_ku se vyhodnocoval dvakrát. Tatáž korelovaná
      podmínka běžela ve frontě i v závěrečném COUNT. Ve frontě to
      nevadilo (TOP (n) se zkratkuje), v COUNT ano — ten musí projít
      všechna k. ú., a čím víc řádků bylo přepočtených, tím déle to
      trvalo. Procedura byla pomalejší s každou dávkou. Nyní se čekající
      k. ú. počítají jedním průchodem do #ceka a slouží frontě i ukazateli.
      POUČENÍ: ukazatel „zbývá" musí být nejen správný, ale i levný.

   Dávkování rebuildu
   ------------------
   Smyčka kontroluje @max_sekund až MEZI katastrálními územími, takže
   jedno těžké k. ú. strop přetáhne a žádná hodnota @max_sekund to
   neobejde. Měřeno: k. ú. 602868 má 1 346 vkladů, Krč 2 306, největší
   k. ú. 7 222, průměr je 131. Celý přepočet proto patří do skriptu
   (python 38_prepocty.py --krok mapa, @max_sekund = 600), ne do krátké
   obálky jednoho dotazu.
   ====================================================================== */

/* 7.1 Mapa se nesmí v ničem, co bere z pohledu, rozcházet s pohledem.
       Všechny tři počty musí být 0. Tohle je kontrola, která by chybu
       u V-23039/2026-101 našla sama. */
SELECT COUNT(*) AS radku_mapy,
    SUM(CASE WHEN ISNULL(m.druh, '') <> ISNULL(v.hlavni_druh, '')
             THEN 1 ELSE 0 END) AS druh_nesedi,
    SUM(CASE WHEN ABS(ISNULL(m.cena_m2, -1)
                    - ISNULL(COALESCE(v.jc_Kc_m2_podlahova, v.jc_Kc_m2_nosne_vymery,
                                      v.jc_Kc_m2_vsech_pozemku), -1)) > 1
             THEN 1 ELSE 0 END) AS cena_nesedi,
    SUM(CASE WHEN ABS(ISNULL(m.plocha, -1)
                    - ISNULL(COALESCE(v.plocha_podlahova_karty, v.vymera_nosna,
                                      v.vymera_pozemku_vse), -1)) > 0.02
             THEN 1 ELSE 0 END) AS plocha_nesedi
FROM dbo.Valuo_mapa m
JOIN dbo.v_Valuo_karta_vkladu v ON v.cislo_vkladu = m.cislo_vkladu;

/* 7.2 Vklad, na kterém se to našlo. Po přepočtu musí být druh „byt",
       jednotka 1156/13, plocha 40,50 m² a 130 864,20 Kč/m². */
SELECT m.cislo_vkladu, m.druh, m.kategorie, m.jednotka_oznaceni,
       m.plocha, m.cena_m2, m.zaklad_ceny, m.prepocteno
FROM dbo.Valuo_mapa m
WHERE m.cislo_vkladu = N'V-23039/2026-101';

/* 7.3 Po dokončení přepočtu musí být fronta prázdná: zbyva_ku = 0.
       Pouštěj ze skriptu, ne jedním dotazem — viz dávkování výše. */
-- python 38_prepocty.py --krok mapa

/* 7.4 Cílený přepočet jednoho k. ú. (ověření parametru z bodu e). */
-- EXEC dbo.sp_prepocet_mapy @prepocitat = 1, @limit_ku = 1, @kod_ku_jen = 727598;

/* 7.5 ŠÍŘE zaklad_ceny. Krok 45 zavedl složené popisy základu ceny až
       o 67 znacích; sloupec měl nvarchar(40) a první běh přepočtu spadl
       na „String or binary data would be truncated", čímž odrolovalo
       celé k. ú. (k. ú. 602868, vklad V-2107/2026-202). Rozšířeno na 100
       a opraveno i v 39_mapa_data.sql, odkud tabulka vzniká — jinak by se
       úzký sloupec vrátil při jejím znovuzaložení.

       ALTER TABLE dbo.Valuo_mapa ALTER COLUMN zaklad_ceny nvarchar(100) NULL;

       Kontrola: nejdelší popis se musí vejít. Musí být 0. */
SELECT COUNT(*) AS nevejde_se
FROM dbo.Valuo_vklad_plocha vp
WHERE LEN(vp.plocha_zdroje) > (SELECT c.max_length / 2 FROM sys.columns c
                               WHERE c.object_id = OBJECT_ID('dbo.Valuo_mapa')
                                 AND c.name = 'zaklad_ceny');

/* 7.6 Ostatní textové sloupce mapy proti jejich zdrojům (změřeno
       25. 10. 2026): nosna_skupina nvarchar(40) proti maximu 15,
       jc_verdikt varchar(20), druh varchar(100), kategorie varchar(20),
       konstrukce nvarchar(80), jednotka_oznaceni nvarchar(50) — rezerva
       je všude. Přidá-li se do mapy další popisný sloupec, změřit zdroj
       PŘED prvním během; truncation neodrolne jen řádek, ale celé k. ú. */

/* ======================================================================
   8. DVĚ OSY: co to je a šlo to spočítat                   25. 10. 2026
   ======================================================================

   Proč
   ----
   Sloupec Valuo_mapa.kategorie odpovídal na dvě otázky zároveň: „co to
   je" a „šla z toho spočítat jednotková cena" (JC_JEDNOTKA = byt A ZÁROVEŇ
   spočitatelné). Výsledek: 8 905 bytů a 1 034 jiných jednotek leželo
   v kategorii „jine" jen proto, že klasifikace nebyla JC_JEDNOTKA —
   typicky když se s bytem prodávaly podíly na nebytových prostorech.
   Ve filtru „byty" chybělo 28 % všech bytů.

   Co se změnilo
   -------------
   a) kategorie = CO TO JE, řídí ji nosná skupina z kroku 46. Větev
      nosna_nemovitost = ''jednotka'' je obecná schválně, aby pokryla
      i typy jednotek, které do CIS_nemovitost_typ teprve přibudou.
   b) klasifikace = ŠLO TO SPOČÍTAT, nový sloupec:

      ALTER TABLE dbo.Valuo_mapa ADD klasifikace varchar(20) NULL;

      V mapě dosud vůbec nebyla; kategorie byla jejím jediným nositelem,
      takže bez tohoto sloupce by se přepnutím informace ztratila.
   c) Nový parametr @od. Vynucený přepočet bral pořád stejných prvních
      @limit_ku k. ú. podle kod_ku; skript po prvním kole přepnul na
      @prepocitat = 0, nenašel nic a ohlásil „mapa hotová" — 426 k. ú.
      zůstalo se starými hodnotami. S @od se bere jen k. ú., které
      v tomhle běhu ještě neprošlo.
      POUČENÍ: „znovu všechno" a „jen co chybí" musí být dvě různé fronty
      a ukazatel hotového musí počítat tu, která se právě používá.

   Validita ceny
   -------------
   Nerozhoduje ji ani jeden z těch dvou popisků, nýbrž JMENOVATEL. Pro
   srovnávací vzorek platí:

       zaklad_ceny IN (N''plocha jednotky dle Valuo'', N''ověřeno znalcem'')
       AND nalez_vice_nosnych = 0 AND nalez_bez_plochy = 0

   a jc_verdikt proti mediánu k. ú. jako nezávislá kontrola. Odvozené
   jmenovatele (426 vkladů) jsou vodítko, ne vzorek.

   klasifikace = ''NELZE'' NENÍ důvod vzorek zahodit. Rozpad 10 881 vkladů
   podle Valuo_data.vklad_duvod: více jednotek 7 591 (čistý jmenovatel
   7 528, více nosných 974), budova i jednotka 2 291 (2 255, 0), více
   budov 999 (272, 313). Všechny tři důvody jsou strukturální, tedy právě
   to, co kroky 45 a 46 řeší. Z podmnožiny s čistým jmenovatelem a bez
   nálezů má 8 135 vkladů cenu v pásmu mediánu k. ú., 731 je k prověření,
   152 nelze zkontrolovat. Tržnost: z 10 876 NELZE ve vzorku je 10 794
   kupních smluv, zbytek 37 dražeb, 31 převodů z družstva, 7 směn,
   7 darování.

   v_Valuo_vzorek se NEMĚNÍ — jen označuje, nefiltruje (vrací všech
   49 692 řádků). Filtrovat je věc místa použití, ne pohledu.
   ====================================================================== */

/* 8.1 Kategorie musí odpovídat nosné skupině. Musí být 0.

       Kontrola jde PŘES POHLED, protože potřebuje nosna_nemovitost, kterou
       mapa nenese. Výčtem skupin ji nahradit nelze: skupina „ostatní"
       existuje u jednotky i u budovy, takže sama o sobě neurčí kategorii.
       Verze s výčtem hlásila 56 falešných rozdílů (jednotky se skupinou
       „ostatní", kterým procedura správně dává jednotka_jina). */
SELECT COUNT(*) AS kategorie_nesedi
FROM dbo.Valuo_mapa m
JOIN dbo.v_Valuo_karta_vkladu v ON v.cislo_vkladu = m.cislo_vkladu
WHERE v.nosna_skupina IS NOT NULL
  AND m.kategorie <> CASE
        WHEN v.nosna_skupina = N'byt'                         THEN 'byt'
        WHEN v.nosna_skupina = N'bytový dům'                  THEN 'bytovy_dum'
        WHEN v.nosna_skupina IN (N'rodinný dům', N'rekreace') THEN 'rodinny_dum'
        WHEN v.nosna_skupina = N'pozemek'                     THEN 'pozemek'
        WHEN v.nosna_nemovitost = 'jednotka'                  THEN 'jednotka_jina'
        ELSE 'jine' END;

/* 8.2 Klasifikace musí být vyplněná všude, kde ji má Valuo_data.
       Musí být 0. */
SELECT COUNT(*) AS bez_klasifikace
FROM dbo.Valuo_mapa m
WHERE m.klasifikace IS NULL
  AND EXISTS (SELECT 1 FROM dbo.Valuo_data d
              WHERE d.cislo_vkladu = m.cislo_vkladu
                AND d.vklad_klasifikace IS NOT NULL);

/* 8.3 Žádný byt už nesmí ležet v kategorii „jine". Musí být 0. */
SELECT COUNT(*) AS bytu_v_jine
FROM dbo.Valuo_mapa m
WHERE m.kategorie = 'jine' AND m.nosna_skupina = N'byt';

/* 8.4 Srovnávací vzorek podle jmenovatele — kontrolní součet po
       kategoriích. Nejde o nulu, jde o to vidět, kolik je čistých. */
SELECT m.kategorie,
       COUNT(*) AS radku,
       SUM(CASE WHEN m.zaklad_ceny IN (N'plocha jednotky dle Valuo',
                                       N'ověřeno znalcem')
                 AND ISNULL(m.nalez_vice_nosnych, 0) = 0
                 AND ISNULL(m.nalez_bez_plochy, 0) = 0
                THEN 1 ELSE 0 END) AS cistych,
       SUM(CASE WHEN m.jc_verdikt = 'v pásmu' THEN 1 ELSE 0 END) AS v_pasmu
FROM dbo.Valuo_mapa m
GROUP BY m.kategorie
ORDER BY COUNT(*) DESC;

/* 8.5 Vynucený přepočet musí projít všechna k. ú., KTERÁ V MAPĚ JSOU.
       Po doběhnutí `python 38_prepocty.py --krok mapa --prepocitat` musí
       být 0.

       Pozor na jmenovatel té kontroly: v Valuo_data je 826 k. ú., ale
       řádky v mapě má jen 310. Zbylých 516 žádné nemá a mít nebude, jejich
       vklady nemají souřadnice. Verze, která je do fronty brala, se
       zacyklila — nevyloučily se nikdy, protože nemají prepocteno, které
       by se dalo posunout, a TOP (@limit_ku) se k posledním nedostal.
       Skript hlásil „hotovo 3200 k. ú." při 826 existujících. */
SELECT COUNT(*) AS ku_nepreposctenych
FROM (SELECT DISTINCT kod_ku FROM dbo.Valuo_mapa WHERE kod_ku IS NOT NULL) d
WHERE NOT EXISTS (SELECT 1 FROM dbo.Valuo_mapa m
                  WHERE m.kod_ku = d.kod_ku
                    AND m.prepocteno > DATEADD(HOUR, -1, SYSDATETIME()));

/* 8.6 JEDNA KATEGORIE MÍCHÁ DVĚ METRIKY. Měřeno 25. 10. 2026:
       rodinny_dum má 852 řádků s cenou na podlahovou plochu a 2 537 na
       výměru pozemku; bytovy_dum 241 proti 381. Kč/m² podlahové plochy
       a Kč/m² pozemku jsou různé věci a do jednoho vzorku nepatří.
       Rozlišuje je zaklad_ceny — proto je on tou osou validity, ne
       kategorie. Filtrovat podle zamýšlené metriky:

         podlahová plocha:  zaklad_ceny IN (N'plocha jednotky dle Valuo',
                                            N'ověřeno znalcem')
         výměra pozemku:    zaklad_ceny =  N'nosná výměra pozemku'

       a vždy AND nalez_vice_nosnych = 0 AND nalez_bez_plochy = 0.

       `výměra pozemků` (2 201 pozemkových, 732 u bytových domů, 93 u RD)
       je rozmělněná podíly na komunikacích: vzniká tam, kde se žádná
       parcela nekvalifikovala jako nosná. Vodítko, ne vzorek. Rozsah to
       ukazuje sám — od 0 do 1 152 580 Kč/m² při průměru 5 415.
       POZOR: NEargumentovat tím, že „ani jeden není v pásmu". Ty vklady
       verdikt vůbec nedostanou (2 597 bez verdiktu, 625 „neověřeno"),
       takže „v pásmu" tam nemůže být z definice. Nepřítomnost verdiktu
       není neúspěšný verdikt.

       Barevná škála mapy počítá kvintily v rámci kategorie, takže u RD
       a bytových domů míchá obě metriky. Otevřený bod: škálovat podle
       (kategorie, zaklad_ceny). */
SELECT m.kategorie, ISNULL(m.zaklad_ceny, N'(bez ceny)') AS zaklad_ceny,
       COUNT(*) AS radku,
       SUM(CASE WHEN m.jc_verdikt = 'v pásmu' THEN 1 ELSE 0 END) AS v_pasmu
FROM dbo.Valuo_mapa m
GROUP BY m.kategorie, m.zaklad_ceny
ORDER BY m.kategorie, COUNT(*) DESC;

/* ======================================================================
   9. JEDNOTKOVÁ CENA JEDINĚ NA PODLAHOVOU PLOCHU         25. 10. 2026
   ======================================================================

   Rozhodnutí znalce
   -----------------
   1) „Dělej to na podlahovou plochu metr čtvereční. U těch, který nemají
      podlahovou plochu z nějakého důvodu, cenu na výměru pozemku
      neuvádět. To se nepoužívá, je to zavádějící. Tam nech pouze celkovou
      cenu jako celku." Platí pro byty, rodinné domy i podílem, bytové
      domy — pro vše, co je stavba nebo jednotka.
   2) U nerozklíčovatelných balíků pozemků cenu PONECHAT a označit:
      „jako nějaký čistě orientační přehled, že se prodal takovýhle balík
      pozemků v průměru za takovouhle cenu."

   Jak je to postaveno
   -------------------
   a) cena_m2 je Kč/m² podlahové plochy u všeho, co obsahuje budovu nebo
      jednotku. Na výměru pozemku se dělí POUZE vklad bez budovy i bez
      jednotky (ma_budovu = 0 AND ma_jednotku = 0). Test jde přes tyto
      příznaky, ne přes kategorii — vyjadřuje přímo to pravidlo.
   b) plocha drží TÝŽ jmenovatel jako cena. Neuvádí-li se cena, neuvádí se
      ani plocha; jinak by u stavby svítila výměra pozemku jako základ,
      kterým se vědomě nedělí.
   c) Nový sloupec:

      ALTER TABLE dbo.Valuo_mapa ADD jc_orientacni bit NULL;

      Je 1 u čistého souboru pozemků, kde se žádná parcela nekvalifikovala
      jako nosná. Popis základu je „orientačně: výměra všech pozemků
      včetně podílů". V mapě se zobrazuje, ale nevstupuje do kvintilů
      barevné škály (SQL_MEZE v 40_aplikace.py je vylučuje) a zůstává bez
      barvy. Rozsah 0 až 1 152 580 Kč/m² by škálu roztáhl.
   d) Karta čte výslednou cenu Z MAPY (SQL_ZJISTENI má LEFT JOIN
      dbo.Valuo_mapa). Karta má vysvětlovat právě to číslo, které znalec
      vidí; dvě místa, každé s vlastním výpočtem, se rozejdou.

   Dopad měřený před přepočtem: 5 534 řádků přišlo o jednotkovou cenu
   tímto rozhodnutím (2 521 rodinných domů, 1 557 jiných staveb,
   1 111 bytových domů, 155 ostatních). Celá skupina bez ceny na podlahovou
   plochu je 5 831; zbylé tři stovky neměly cenu ani předtím. Z nich
   5 690 nemá podlahovou plochu v žádném zdroji a 141 ji nemá u každé nosné
   nemovitosti, takže se nedělí kvůli pravidlu o částečném součtu.
   5 303 čistých pozemkových si cenu ponechalo, z toho 2 215 jako
   orientační.

   Čím to padlo: otevřený bod „barevná škála míchá dvě metriky" vyřešilo
   rozhodnutí 1 samo. Po něm má každá kategorie jedinou metriku, takže
   kvintily v rámci kategorie jsou korektní bez zásahu do škály.
   ====================================================================== */

/* 9.1 Stavba ani jednotka nesmí mít cenu na výměru pozemku. Musí být 0. */
SELECT COUNT(*) AS staveb_s_cenou_na_pozemek
FROM dbo.Valuo_mapa m
WHERE (m.ma_budovu = 1 OR m.ma_jednotku = 1)
  AND m.zaklad_ceny LIKE N'%výměra%';

/* 9.2 Cena a plocha musí být vyplněné nebo prázdné SPOLU. Musí být 0.

       První verze této kontroly byla NEPLATNÁ: `(m.cena_m2 IS NULL) <>
       (m.plocha IS NULL)`. T-SQL nemá booleovský typ jako hodnotu, takže
       to není výraz, ale syntaktická chyba — dotaz vůbec neproběhl.
       Predikát se musí převést na čísla přes CASE. */
SELECT COUNT(*) AS rozpor_cena_plocha
FROM dbo.Valuo_mapa m
WHERE (CASE WHEN m.cena_m2 IS NULL THEN 1 ELSE 0 END)
   <> (CASE WHEN m.plocha  IS NULL THEN 1 ELSE 0 END);

/* 9.3 Orientační příznak smí být 1 jedině u čistého souboru pozemků
       s popisem „orientačně…". Musí být 0. */
SELECT COUNT(*) AS orientacni_jinde
FROM dbo.Valuo_mapa m
WHERE m.jc_orientacni = 1
  AND (m.ma_budovu = 1 OR m.ma_jednotku = 1
    OR m.zaklad_ceny NOT LIKE N'orientačně:%');

/* 9.4 Přehled po přepočtu: kolik vkladů má jakou metriku a kolik jich
       zůstalo jen s celkovou cenou. Nejde o nulu, jde o kontrolní čísla —
       čekej 5 831 bez jednotkové ceny a 2 215 orientačních. */
SELECT CASE WHEN m.cena_m2 IS NULL                 THEN N'jen celková cena'
            WHEN m.jc_orientacni = 1               THEN N'orientační (balík pozemků)'
            WHEN m.zaklad_ceny = N'nosná výměra pozemku'
                                                   THEN N'Kč/m² výměry pozemku'
            ELSE N'Kč/m² podlahové plochy' END AS metrika,
       COUNT(*) AS vkladu
FROM dbo.Valuo_mapa m
GROUP BY CASE WHEN m.cena_m2 IS NULL                 THEN N'jen celková cena'
              WHEN m.jc_orientacni = 1               THEN N'orientační (balík pozemků)'
              WHEN m.zaklad_ceny = N'nosná výměra pozemku'
                                                     THEN N'Kč/m² výměry pozemku'
              ELSE N'Kč/m² podlahové plochy' END
ORDER BY COUNT(*) DESC;

/* ======================================================================
   10. ZNAČKA NA STAVBĚ, NE NA DEFINIČNÍM BODĚ PARCELY     25. 10. 2026
   ======================================================================

   Bod jednotek a budov se bere ze středu obálky polygonu stavebního
   objektu z RÚIANu (1 182 378 objektů z 1 193 394 má geometrii), a to té
   stavby, která je NEJBLIŽŠÍ dnešnímu bodu.

   Proč nejbližší a ne stavba na kotevní parcele karty: kotva karty a bod
   mapy si hlavní nemovitost vybírají každý jinak. Ve vkladu
   V-81105/2020-101 (Smíchov) jsou tři domy na parcelách 344, 811 a 2415,
   kilometry od sebe; karta zakotvila 344, bod mapy mířil na dům na 2415
   a stavba na kotvě byla 1 225,6 m daleko. Varianta „stavba na kotvě"
   dávala průměrný posun 33,7 m s maximem 230 692 m; varianta „nejbližší
   stavba" dává 11,7 m s 89 % vkladů do 25 m.

   Mez CIS_karta_parametry.bod_stavba_do_m = 100 m. Nad ní se bod
   nepřesouvá a vyznačí se nález nalez_bod_daleko. Rozdělení posunů:
   do 10 m 30 567, 10-25 m 8 218, 25-50 m 3 889, 50-100 m 727,
   100-500 m 50, nad 500 m 1 — mez leží v tom zlomu o řád.

   Vklad bez budovy i bez jednotky se nepřesouvá: u souboru pozemků by se
   značka mohla usadit na cizí stavbu stojící na některé z parcel.
   ====================================================================== */

/* Parametr do číselníku, ať ho má i čistá instalace. Procedura má zálohu
   ISNULL(..., 100), takže bez něj nespadne — ale nebyl by vidět ani
   nastavitelný. */
MERGE dbo.CIS_karta_parametry AS c
USING (VALUES
 ('bod_stavba_do_m', 100.00,
  N'Do kolika metrů od definičního bodu se značka přesune na stavbu dle RÚIAN. Posuny 25. 10. 2026: do 10 m 30 567, 10-25 m 8 218, 25-50 m 3 889, 50-100 m 727, nad 100 m 51. Mez je v přirozeném zlomu o řád; nad ní je spárování podezřelé a bod zůstane na definičním bodě s nálezem.')
) AS z (parametr, hodnota, popis) ON c.parametr = z.parametr
WHEN MATCHED THEN UPDATE SET c.hodnota = z.hodnota, c.popis = z.popis
WHEN NOT MATCHED THEN INSERT (parametr, hodnota, popis)
     VALUES (z.parametr, z.hodnota, z.popis);

/* 10.1 Přehled po přepočtu. Čekej asi 43 400 „stavba RÚIAN" a 51 nálezů. */
SELECT ISNULL(m.bod_zdroj, N'(nepřepočteno)') AS bod_zdroj,
       COUNT(*) AS vkladu,
       CAST(AVG(m.bod_posun_m) AS decimal(8,1)) AS prum_posun_m,
       CAST(MAX(m.bod_posun_m) AS decimal(8,1)) AS max_posun_m,
       SUM(CASE WHEN m.nalez_bod_daleko = 1 THEN 1 ELSE 0 END) AS nalezu
FROM dbo.Valuo_mapa m
GROUP BY m.bod_zdroj
ORDER BY COUNT(*) DESC;

/* 10.2 Posun nad mezí se nesmí nikde provést. Musí být 0. */
SELECT COUNT(*) AS posun_nad_mezi
FROM dbo.Valuo_mapa m
WHERE m.bod_posun_m > (SELECT p.hodnota FROM dbo.CIS_karta_parametry p
                       WHERE p.parametr = 'bod_stavba_do_m');

/* 10.3 Vklad bez budovy i bez jednotky nesmí mít bod ze stavby. Musí být 0.

        Tahle kontrola si zasloužila existenci hned: při prvním běhu našla
        394 vkladů v 19 k. ú. Pojistka v proceduře se dívala na celý vklad,
        zatímco ma_budovu a ma_jednotku se počítají jen z řádků v právě
        zpracovávaném k. ú. U vkladů s řádky ve dvou k. ú. se to rozešlo.
        Opraveno doplněním d2.kod_ku = @ku do pojistky. */
SELECT COUNT(*) AS pozemek_na_stavbe
FROM dbo.Valuo_mapa m
WHERE m.bod_zdroj = N'stavba RÚIAN'
  AND ISNULL(m.ma_budovu, 0) = 0 AND ISNULL(m.ma_jednotku, 0) = 0;

/* 10.4 Kotevní parcela z jiného k. ú., než je vklad — 564 vkladů
        k 25. 10. 2026. Není to vada mapy, ale karty: ovlivňuje výměry
        i Kč/m² pozemku. Otevřený bod, viz data/ROZHODNUTI.md. */
SELECT TOP 20 m.cislo_vkladu, m.kat_uzemi, m.kod_ku AS ku_vkladu,
       kp.kod_ku AS ku_kotvy, kp.parcel_number, kp.vymera_m2
FROM dbo.Valuo_mapa m
JOIN dbo.Valuo_karta_parcely kp ON kp.cislo_vkladu = m.cislo_vkladu
                               AND kp.je_kotva = 1
WHERE kp.kod_ku <> m.kod_ku
ORDER BY m.cislo_vkladu;

/* ======================================================================
   11. RODINNÝ DŮM + VEDLEJŠÍ STAVBA                       25. 10. 2026
   ======================================================================

   Pokyn znalce: připustit do porovnání, má-li rodinný dům podlahovou
   plochu, jsou-li ostatní parametry v pořádku a NENÍ-LI vedlejší stavba
   větší než rodinný dům, pokud se to dá zjistit. Jednotková cena = cena
   celého vkladu dělená podlahovou plochou rodinného domu.

   ZJIŠTĚNÍ: první dvě podmínky už plní krok 46 sám. Priorita typů dává
   rodinnému domu 11 a vedlejším stavbám 19 až 21, takže nosnou je dům
   a cena se dělí jeho podlahovou plochou. Měřeno 25. 10. 2026 na 419
   vkladech s dvěma a více budovami, z nichž aspoň jedna je rodinný dům:

     66  nosná rodinný dům, cena na jeho podlahovou plochu — funguje
         (průměr 87 108 Kč/m², rozsah 4 831 až 280 303)
     347 nález „nosná bez podlahové plochy" — dům plochu nemá v žádném
         zdroji, takže se nedělí. To je podmínka 1 znalce, ne závada.
     6   nosnou je BYT, do jehož ceny se rozpustil celý dům (viz 11.2)

   U řádku nemovitost = 'budova' je ve Valuu v poli plocha VÝMĚRA PARCELY,
   ne podlahová plocha. Velikost vedlejší stavby jde proto posoudit jen ze
   zastavěné plochy v RÚIANu.

   PODMÍNKA 3 je zjistitelná u 76 vkladů ze 419 a porušená u 6, z nichž 3
   mají cenu. Na tak malý počet se nebuduje výpočet; slouží kontrola 11.1.
   ====================================================================== */

/* 11.1 Vklady, kde je vedlejší stavba VĚTŠÍ než rodinný dům (zastavěná
        plocha dle RÚIANu). Podmínka 3 znalce — do porovnání nepatří.
        Čekej 6 vkladů, z toho 3 s cenou. */
WITH skupina AS (
    SELECT d.cislo_vkladu
    FROM dbo.Valuo_data d
    GROUP BY d.cislo_vkladu
    HAVING SUM(CASE WHEN d.nemovitost = 'budova' THEN 1 ELSE 0 END) >= 2
       AND SUM(CASE WHEN d.typ = N'rodinný dům' THEN 1 ELSE 0 END) >= 1
), radky AS (
    SELECT s.cislo_vkladu, d.id,
           CASE WHEN d.typ = N'rodinný dům' THEN 1 ELSE 0 END AS je_rd,
           MAX(so.zastavena_plocha) AS zp
    FROM skupina s
    JOIN dbo.Valuo_data d ON d.cislo_vkladu = s.cislo_vkladu AND d.nemovitost = 'budova'
    JOIN dbo.v_Valuo_parcela_z_popisu p ON p.cislo_vkladu = d.cislo_vkladu AND p.id = d.id
    JOIN dbo.Valuo_karta_parcely kp ON kp.cislo_vkladu = d.cislo_vkladu
                                   AND p.parcela_s_uzemim LIKE kp.parcel_number + ' %'
    JOIN dbo.RUIAN_parcely rp ON rp.gml_id = kp.gml_id AND rp.kod_ku = kp.kod_ku
    JOIN dbo.RUIAN_stavebni_objekty so ON so.parcela_id = rp.kod_parcely
    WHERE so.zastavena_plocha > 0
    GROUP BY s.cislo_vkladu, d.id, CASE WHEN d.typ = N'rodinný dům' THEN 1 ELSE 0 END
), souhrn AS (
    SELECT r.cislo_vkladu,
           MAX(CASE WHEN r.je_rd = 1 THEN r.zp END) AS rd_zp,
           MAX(CASE WHEN r.je_rd = 0 THEN r.zp END) AS vedlejsi_zp
    FROM radky r GROUP BY r.cislo_vkladu
)
SELECT m.cislo_vkladu, m.kat_uzemi, s.rd_zp, s.vedlejsi_zp,
       m.plocha AS podlahova_rd, m.cena_Kc, m.cena_m2
FROM souhrn s
JOIN dbo.Valuo_mapa m ON m.cislo_vkladu = s.cislo_vkladu
WHERE s.rd_zp IS NOT NULL AND s.vedlejsi_zp > s.rd_zp
ORDER BY m.cena_m2 DESC;

/* 11.2 CELÁ CIZÍ STAVBA ROZPUŠTĚNÁ DO CENY JEDNOTKY — otevřený bod.
        Nosnou je jednotka (priorita 1 až 6 přebíjí budovu 11 až 21), ale
        ve vkladu je navíc celá budova, která NENÍ skořápkou té jednotky.

        Rozpuštěný „bytový dům" je v pořádku: s bytem se vždy kupuje podíl
        na domě, v němž ten byt je (1 962 vkladů, průměr 97 471 Kč/m²).
        Rozpuštěný rodinný dům, objekt k bydlení, průmyslový objekt nebo
        stavba pro administrativu v pořádku není — cena celého balíku se
        dělí plochou samotné jednotky.

        Měřeno 25. 10. 2026: 51 takových vkladů, z toho 33 má verdikt
        „v pásmu", takže kontrolou proti mediánu PROJDOU (průměr
        144 255 Kč/m², maximum 395 176). Mediánová kontrola je neuvidí,
        protože 144 tisíc za m² bytu v Praze je věrohodné číslo.
        Nejhorší případy: 900 332 Kč/m² („jiná stavba 1, rodinný dům 3"),
        853 502 („garáž 1, jiný nebytový prostor 3, objekt k bydlení 1,
        rodinný dům 1"), 3 700 000 ve skupině „k prověření".

        K ROZHODNUTÍ ZNALCE: které typy budov jsou skořápkou jednotky
        (bytový dům, budova s číslem popisným) a které jsou samostatným
        majetkem. Pak lze zavést nález a ty vklady z porovnání vyřadit. */
SELECT ISNULL(m.jc_verdikt, '(nic)') AS verdikt, v.rozpusteno,
       COUNT(*) AS vkladu, CAST(MAX(m.cena_m2) AS decimal(12,0)) AS max_jc
FROM dbo.v_Valuo_karta_vkladu v
JOIN dbo.Valuo_mapa m ON m.cislo_vkladu = v.cislo_vkladu
WHERE v.nosna_nemovitost = 'jednotka'
  AND (v.rozpusteno LIKE N'%rodinný dům%' OR v.rozpusteno LIKE N'%objekt k bydlení%'
    OR v.rozpusteno LIKE N'%průmyslový objekt%' OR v.rozpusteno LIKE N'%administrativu%'
    OR v.rozpusteno LIKE N'%usedlost%' OR v.rozpusteno LIKE N'%výrobu%')
GROUP BY m.jc_verdikt, v.rozpusteno
ORDER BY MAX(m.cena_m2) DESC;

/* 11.3 ROZSAH PŘÍZNAKŮ ma_budovu A ma_jednotku — otevřený bod.
        Počítají se jen z řádků v právě zpracovávaném k. ú.
        (slozeni: WHERE d.kod_ku = @ku), zatímco nosná nemovitost se počítá
        z celého vkladu. U vkladů s řádky ve dvou k. ú. se to rozchází
        a projevilo se to dnes třikrát:
          1. značka na stavbě u 394 vkladů bez budovy (opraveno srovnáním
             rozsahu pojistky na @ku),
          2. 4 vklady s rodinným domem dostaly orientační cenu na výměru
             pozemků 90 až 150 Kč/m², protože mapa u nich hlásí
             ma_budovu = 0,
          3. výsledek navíc ZÁVISÍ NA TOM, které k. ú. přepočet spustilo,
             protože řádek mapy je jeden na vklad.
        Správný rozsah je celý vklad — příznaky mají podle své vlastní
        dokumentace popisovat, co vklad OBSAHUJE. Změna ale posune ceny
        u vkladů podle bodu 2, takže patří znalci. */
SELECT m.cislo_vkladu, m.kat_uzemi, m.kategorie, m.nosna_skupina,
       m.ma_budovu, m.ma_jednotku, m.zaklad_ceny, m.cena_m2
FROM dbo.Valuo_mapa m
WHERE m.nosna_skupina IN (N'rodinný dům', N'bytový dům', N'rekreace')
  AND ISNULL(m.ma_budovu, 0) = 0
ORDER BY m.cena_m2;
