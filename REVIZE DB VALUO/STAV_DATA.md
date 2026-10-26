# DB_VALUO — stav databáze cenových dat

Referenční dokument k databázi `VALUO` (MS SQL, Developer Edition 2022,
lokální instance `RYZEN9` na pracovní stanici znalce). Čti ho na začátku
každého chatu, který se týká této databáze, jejího vývoje nebo napojení
na Claude. Rozhodnutí a jejich důvody jsou v `data/ROZHODNUTI.md`, návod
k importu v `data/POSTUP_import.md`.

Zdrojem pravdy je tento dokument v Kontextu; záložní kopii ukládá Claude
na disk jako `E:\DATA_ANALYSIS\REVIZE DB VALUO\STAV_DATA.md`.

Poslední revize: 25. 10. 2026 večer — **kroky 1 až 44 hotové. Import dat Valuo
stojí na jednom skriptu (`30_import_valuo.py`, verze 30.3), import RÚIANu na
`27_ruian_import.py` (verze 27.7). Vzorek má 49 689 vkladů, 0 duplicit klíčem
totožnosti (krok 30b), práva stavby vlastní kategorii (krok 31). Kroky 32 a 33
přinesly geometrii parcel: 4 699 350 parcel z 687 obcí v `RUIAN_parcely`.**

**Krok 34 postavil kartu vkladu** — tabulky, procedury i pohled
`v_Valuo_karta_vkladu`. Platí pro všechny vklady, nejen pro rodinné domy.
Kroky 35 až 38 přidaly export do Wordu, HTML kartu z databáze a dávkové
přepočty; **karta je dopočítaná pro 49 650 vkladů ze 49 788**. Kroky 39 a 40
postavily **mapovou aplikaci** nad `Valuo_mapa` (49 692 bodů), krok 41
**vrstvu ručních zjištění znalce** — ověřená plocha má přednost přede všemi
ostatními zdroji. Podrobnosti v `data/ROZHODNUTI.md`, oddíly *Karta vkladu*,
*Mapová aplikace* a *Ruční zjištění znalce — jak je postaveno*.

Krok 43 opravil **bod vkladu** (8 428 řádků sedělo na cizích bodech,
průměrně 1 150 m vedle) a krok 44 postavil **registr zdrojů plochy**
s kontrolou posunu desetinné čárky v podílu. Import je ve verzi 30.6 —
`--vse` projde celý řetězec včetně karet, mapy a registru.

**Nejbližší úkoly:** potvrdit 1 807 návrhů na posun desetinné čárky, umístit
značku na stavbu místo na definiční bod parcely, prověřit vybočující
jednotkové ceny a doplnit `typ_jevu` u 121 skupin hromadných převodů.
Roční mediány zůstávají odložené (oddíl 8.2).

---

## 0. Čím se Claude do databáze připojuje

Účtem **`claude_reader`**. Od 23. 10. 2026 má v databázi `VALUO`
`VIEW DEFINITION`, `db_datareader`, `db_datawriter`, `CREATE VIEW /
PROCEDURE / TABLE / FUNCTION` a `ALTER ON SCHEMA::dbo`. **Nemá
`db_owner`** — nemůže měnit oprávnění, nastavení serveru ani zahodit
databázi. Název účtu už neodpovídá jeho roli.

**NEMÁ ale `EXECUTE` na procedury** (zjištěno 24. 10. 2026 při kroku 34).
Smí je vytvořit a změnit, ale ne spustit; pokus vrátí Msg 229. Procedury
proto pouští `30_import_valuo.py` pod účtem Windows nebo SSMS. Má-li je
spouštět asistent, stačí jednou v SSMS:

```sql
GRANT EXECUTE ON SCHEMA::dbo TO claude_reader;
```

Python skripty se připojují pod **účtem Windows** (`Trusted_Connection`).

### Pravidla, která Claude při zápisu drží

- Zálohu databáze před každou sérií zápisů.
- `DELETE`, `UPDATE` ani `DROP` nad `Valuo_data` a `KN_parcel_data` jen
  na výslovný pokyn znalce. *(24. 10. 2026 porušeno jednou — viz
  `data/ROZHODNUTI.md`, záznam o verzi 30.1.)*
- Co se změní v databázi, jde zároveň jako očíslovaný skript do
  `E:\DATA_ANALYSIS\REVIZE DB VALUO`. Databáze a disk musí zůstat
  v souladu.
- **Na disk ukládá Claude sám — znalec nic nestahuje ani nekopíruje**
  (rozhodnutí znalce 24. 10. 2026). Do `E:\DATA_ANALYSIS\REVIZE DB VALUO`
  patří:

  | co | kam | kdy |
  |---|---|---|
  | skript, který mění databázi | `NN_popis.sql` / `.py` v kořeni, očíslovaný | před spuštěním |
  | úplné definice všech pohledů a procedur | `_definice\definice_RRRRMMDD.sql` (export z `sys.sql_modules`) | po každé změně pohledu nebo procedury |
  | kopie `data/ROZHODNUTI.md` | `ROZHODNUTI_DATA.md` | po každém zápisu do Kontextu |
  | kopie `data/STAV.md` | `STAV_DATA.md` | po každém zápisu do Kontextu |
  | návod k importu | `30_POSTUP_IMPORTU.md` — **zdroj pravdy je disk**, do Kontextu se kopíruje | se změnou postupu |

  Export definic se dělá dotazem na `sys.sql_modules` přes MCP a ověřuje
  se součtem délek proti databázi. Starší exporty se nemažou — jsou
  historií.
- **Podmínky:** chat musí být propojený s počítačem znalce (otevřený
  v desktopové aplikaci) — přes to vede databáze i složka. O přístup ke
  složce `REVIZE DB VALUO` požádá Claude **hned na začátku chatu**; znalec
  jen jednou potvrdí. Není-li chat propojený, Claude to řekne hned
  a neodkládá zápis na „někdy".
- U zásahů do `v_Valuo_vzorek_q`, `sp_prepocet_prahu` a `Valuo_prahy`:
  nejdřív změřit, pak změnit, pak porovnat se zálohou.

### Nastavení serveru

`max server memory` je od 23. 10. 2026 **16 384 MB** z 32 GB fyzické
paměti. Předtím byla na výchozí hodnotě 2147483647 MB (bez omezení) a
`sp_prepocet_prahu` kvůli tomu spadla na Msg 701 — SQL Server si bral,
co mohl, a na Windows spolu s VS Code, prohlížečem a Pythonem nad
gigabajtovými XML nezbylo.

**Režim obnovy je od 24. 10. 2026 SIMPLE.** Předtím byla databáze ve FULL bez
zálohování logu: log narostl na 14 024 MB proti 1 864 MB dat a nemohl se
recyklovat (`log_reuse_wait = LOG_BACKUP`). Před importem 687 obcí přepnuto
na SIMPLE a log zmenšen na 2 GB. Databáze se dá znovu postavit z importních
skriptů, takže obnova k bodu v čase tu nemá co chránit.

**Edice je Developer (16.0.1210.3)** — zdarma, s funkcemi Enterprise, ale
licencovaná jen pro vývoj a testování, ne pro produkci. Viz
`data/ROZHODNUTI.md`, záznam změn k 24. 10. 2026.

### Omezení nástroje MCP

**Linuxový pomocník nedosáhne na SQL Server.** Asistent má na stanici znalce
shell v odděleném linuxovém VM; SQL Server poslouchá na windowsovém localhostu,
který odtud není vidět, a `pyodbc` tam není. Do databáze se chodí **výhradně
nástrojem MCP**. Co je potřeba udělat s plnou šířkou spojení — třeba export
definic — musí pustit znalec (`42_export_definic.py`).


- **Časový limit 60 s.** Dotaz nad celým `v_Valuo_vzorek_q` se do něj
  vejde, ale těsně. **Přepočtové procedury se přes MCP nepouštějí** —
  detektor podle jednotkové ceny sám trvá kolem 50 s. Pouští je
  `python 30_import_valuo.py --prepocty` pod účtem Windows; celý řetězec
  sedmi procedur tam trvá 1 až 2 minuty. Při timeoutu v MCP se transakce
  vrátí, takže se nic nepoškodí — jen se nic nestane.
- **`MERGE` je dražší než `INSERT`.** Detekce 118 skupin trvá zlomek
  sekundy, `MERGE` téhož výsledku timeuje. Jde-li o první naplnění
  prázdné sady, použij `INSERT`.
- **Neunese složitý dotaz.** Několik `CROSS APPLY` nad okenními funkcemi,
  vnořené agregace, korelované poddotazy uvnitř `SUM(CASE …)` nebo
  `PERCENT_RANK` s `CASE` v agregaci selžou bez hlášení. Řešení: rozdělit
  na menší dotazy.

### Poučení z chyb, které se opakovaly

| Co | Následek |
|---|---|
| **Počítaný sloupec nesmí odkazovat na jiný počítaný sloupec** | Msg 1759. Výraz se musí vypsat celý v každém sloupci. |
| **Filtrovaný index nesmí mít počítaný sloupec ve `WHERE`** | Msg 10609. Filtr se musí postavit na skutečném sloupci. |
| **`SELECT * INTO` zkopíruje i vlastnost IDENTITY** | Záloha pak nejde plnit zpět. Obchází se `UNION ALL` dvou prázdných selectů. |
| **Typy sloupců ověřit před psaním joinu** | `druh` a `kat_uzemi` jsou `varchar`, nikoli `nvarchar`. |
| **Metrika musí být v `PARTITION BY`, ne jen v klíči** | Jinak se percentily počítají ze smíchaných veličin, a to **bez chybové hlášky**. |
| **`PERCENTILE_CONT` je okenní funkce a drží celý oddíl v paměti** | Po přidání pásem a metriky M3 se vstup zdvojnásobil a procedura spadla na Msg 701. Řešení: cyklus po klasifikacích (krok 29b). `APPROX_PERCENTILE_CONT` je levnější, ale přibližná — na mediány, které slouží i jako kontrolní čísla, se nehodí. |
| **Zrušení sloupce rozbije pohledy, které ho vybírají** | Pohledy nejsou schema-bound, takže `ALTER TABLE` projde a pohled se stane neplatným až za běhu (krok 28). Před rušením projdi `sys.sql_expression_dependencies`. |
| **`TRUNCATE` v proceduře ji shodí na timeout** | Potřebuje výhradní zámek. V procedurách plněných z MCP je proto `DELETE`. |
| **`MERGE ... NOT MATCHED BY SOURCE` sáhne na CELOU cílovou tabulku** | Detektor podle jednotkové ceny by smazal skupiny detektoru podle celkové ceny. Obě sady musí mít ve všech klauzulích `AND t.detektor = '…'` (krok 29). |
| **`{*}` v názvu prvku XML chytá i jiné jmenné prostory** | `tag='{*}StavebniObjekt'` dalo o 123 584 falešných záznamů víc. |
| **`iterparse` s filtrem `tag=` neuvolňuje nevyhovující prvky** | U souboru velikosti Prahy 3,4 GB místo 75 MB. |
| **Číslo popisné není v rámci obce jednoznačné** | V Praze č. p. 40 odpovídá 116 objektům; párování podle něj dalo 36,3 objektu na jednotku (krok 27a). |
| **`COUNT(DISTINCT …)` schová rozmnožené párování** | Kontroluj poměr `COUNT(*)` ku `COUNT(DISTINCT …)`; má být kolem 1,0. |
| **Lokální mez neodhalí kontaminaci, která ji sama tvoří** | Ve Stodůlkách stáhlo 318 privatizací `mez_zdola` na 645 Kč/m². Záchyt musí stát na úrovni, kterou kontaminace neunese (krok 29a). |
| **Windows dovolí dvěma procesům poslouchat na jednom portu** | V `23c_mapa_prevodu.py` je proto `allow_reuse_address = False`. |
| **Plocha nepatří do klíče totožnosti záznamu** | Valuo uvádí u téže nemovitosti plochu různě (0 × NULL, 53,6 × 536). Ranní import 24. 10. vložil 862 duplicit (krok 30). |
| **Kontrolní dotaz nesmí mít tutéž slepou skvrnu jako kontrolovaný proces** | Kontrola duplicit pěticí s plochou ukázala nulu, protože hledala stejně jako import. Kontroluj jiným klíčem, než kterým se zapisuje. |
| **Přepočet bez změny vzorku je přepočet naprázdno** | 24. 10. v 11:31 proběhly procedury za minutu a vzorek zůstal na 48 066 — nové řádky neměly `geo_zdroj`. Po importu vždy porovnej počet vkladů ve vzorku. |
| **Batch více příkazů z Pythonu potřebuje `SET NOCOUNT ON`** | Jinak ovladač vrátí počet řádků z prvního `INSERT` a `.scalar()` spadne; na konci `SET NOCOUNT OFF`, jinak zůstane na spojení z poolu. |
| **Skupina shodná v klíči ještě není duplicita** | „33 skupin duplicit" bylo 25 dvojic různých nemovitostí (stavba + parcela se stavbou jako součástí, obě jako budova) a 8 duplicit. Před smazáním vždy vypsat řádky a porovnat popis (krok 30b). |
| **Prostorový join a korelovaný `EXISTS` v jednom dotazu** | Sousední parcely přes `STIntersects` najde prostorový index okamžitě, ale přidaný `EXISTS (… WHERE parcela_id = r.kod_parcely)` dotaz zabije. Dělej to na dva kroky: nejdřív sousedy, pak stavby na nich (ověřeno 24. 10. 2026 na parcele 3942/1 v Úvalech: 10 sousedů, z toho 1 se stavbou). |
| **`claude_reader` nemá EXECUTE** | Procedury lze vytvořit, ale ne spustit (Msg 229). Nástroj asistenta chybu skryje a vrátí jen obecné selhání — příčinu ukáže až `BEGIN TRY … CATCH` s `ERROR_MESSAGE()`. |
| **Nástroj asistenta balí volání do transakce** | Timeout po minutě vrátí i to, co už proběhlo. Dlouhé smyčky v proceduře proto potřebují vlastní časový strop, který je ukončí dřív a vrátí stav. |
| **Řetězení sousednosti přes podílovou parcelu** | Slilo stání za společnou cestou s domem. Komponenty počítej jen přes výhradní parcely (krok 34). |
| **Skupina vrstev ve WMS ČÚZK není název pro požadavek** | `KN/rst_kmd` vrací ServiceException, `KN` vrátí obrázek. Názvy jsou ploché; ověř je v `GetCapabilities`, ne v tabulce dokumentace. |
| **Kešovaná mapová služba v S-JTSK nevydá dlaždice ve Web Mercatoru** | Přehledová i cenová mapa mlčely, dokud se žádaly s `bboxSR=102100`. Služba s `capabilities: Map` umí `export` na libovolný výřez, ale v `TilesOnly` (Metropolitní plán) to nejde vůbec. |
| **Řádek „budova" nemusí být stavba** | Valuo vede parcelu, jejíž součástí je stavba, jako budovu a jako plochu uvádí výměru parcely. Výměra pozemku pak ve vzorku chybí, i když ji katastr má (518 rodinných domů). |
| **Na Windows `write_text()` překládá „\n“ na „\r\n“** | Definice, které CRLF už obsahují (vytvořené v SSMS), se v souboru rozpadnou na „\r\r\n“ a zpětná kontrola je nenajde, i když je export v pořádku — 25. 10. 2026 u 11 z 23 objektů. Zápis i čtení textu, který má zůstat beze změny, dělej s `newline=""`. |
| **`SystemExit` není `Exception`** | `sys.exit()` v obslužném vlákně serveru proletí přes `except Exception`, vlákno zhasne a prohlížeč dostane prázdnou odpověď bez jakékoli hlášky. Ve vláknech odchytávej `SystemExit` zvlášť a vrať stránku s chybou. |
| **`device_commit_files` ohlásí úspěch, a na disku zůstane stará verze** | Stalo se dvakrát. Po každém nahrání zkontroluj soubor na disku — velikost a výskyt něčeho nového v obsahu, ne jen hlášení nástroje. |
| **Fronta, z níž se nedá nic vzít, se protáčí naprázdno** | 138 vkladů bez parcely z katastru nikdy neopustilo frontu a dávka běžela 9,4 hodiny bez jediného přírůstku. Fronta musí vyžadovat existenci vstupu a řídicí skript se zastavit, přestane-li počet zbývajících klesat. |
| **Ukazatel „zbývá" musí počítat totéž, co si vezme fronta** | V kroku mapa počítal katastrální území chybějící ve `Valuo_mapa`, zatímco `kod_ku` se plní z pohledu — ukazoval práci, která se nikdy neudělá. |
| **`MIN(Lat)` a `MIN(Long)` přes více řádků dají bod, který neleží nikde** | Souřadnice se berou z jednoho řádku vybraného podle priority, ne po složkách. |
| **Úplné znění pohledu se do skriptu neopisuje bez kontroly** | Porovnej délky jednotlivých řádků proti `sys.sql_modules` (`STRING_SPLIT(definition, CHAR(10), 1)`). Celková délka záměnu znaku neodhalí, délky řádků ano. U kroku 41 to dalo 158 řádků a 9 602 znaků shodně. |
| **Rozhodovat podle štítku místo podle obsahu** | Podmínka „už má geo_zdroj = KN_refPoint, přeskoč“ konzervovala 8 428 řádků se špatným bodem. Štítek může lhát; srovnávej hodnoty. |
| **`SET PARSEONLY ON` přes spojení asistenta nic nezaručí** | Nástroj to nerespektoval a dávku spustil; změnu zadržela až jeho vlastní transakce. Syntaxi kontroluj vlastní transakcí, kterou vrátíš zpět. |
| **Zálohu dřív než zápis, i u „testu“** | Nové znění podmínky se pustilo jako zkouška a změnilo 380 řádků bez předobrazu. |
| **Hromadná záměna v souboru se smíšeným jazykem** | `37_karta_html.py` obsahuje python i javascript; záměna `cis(` → `kc(` by rozbila vykreslování parcel. Vynuť si u každé náhrady právě jeden výskyt. |
| **Podklad se stahuje ve výřezu té vrstvy, do které se dokresluje** | Katastr se do Metropolitního plánu bral z výřezu územního plánu; s různými výřezy by se hranice rozešly s plánem. |
| **Dvě kopie téhož dokumentu se rozejdou** | Návod k importu byl na disku ve verzi 30.2 a v Kontextu 30.3. Při změně postupu přepisuj obojí najednou. |
| **Číslo, které se zobrazuje znalci, se před zápisem přeměří** | Popis nálezu `PLOCHA_CHYBI` nesl „1 423 bytů bez plochy“ z dřívějšího, jinak vymezeného počtu; správně je 1 581 vkladů s jednotkou z 37 340. |

**Tento dokument nelze upravit po částech** — nástroj na projektové
dokumenty neumí dílčí změnu, takže každá úprava znamená poslat celý text
znovu. Drobnosti je proto lepší nasbírat a zapsat najednou.

---

## 1. Co databáze obsahuje

Stav k 24. 10. 2026 po krocích 30, 30b a 31.

| Tabulka | Řádků | Obsah |
|---|---|---|
| `RUIAN_parcely` | 4 699 350 | parcely z VFR UKSH, 687 obcí: výměra, druh pozemku, definiční bod, **hranice** (krok 32) |
| `RUIAN_parcely_bpej` | 2 686 626 | bonitované díly zemědělské půdy (BPEJ) |
| `RUIAN_stavebni_objekty` | 1 193 394 | TEA z RÚIAN, 688 obcí, stav k 30. 9. 2026; u obcí v UKSH i půdorys (`geo_plocha`) |
| `RUIAN_so_cisla_domovni` | 844 208 | čísla popisná a evidenční |
| `KN_parcel_data` | 133 387 | parcely z katastru (INSPIRE) |
| `KN_parcel_UP` | 126 518 | zatřídění 107 929 parcel do ploch ÚP včetně podílů |
| `Valuo_data` | 109 754 | cenové údaje z 49 788 vkladů, 5/2014 – 9/2026 |
| `KN_parcel_UP_stav` | 107 929 | evidence parcel, které prošly zatříděním do ÚP (krok 30) |
| `UP_FVU_data` | 15 542 | funkční využití ploch dle ÚP, pouze Praha |
| `KN_k_pretazeni` | 14 963 | fronta dotahování parcel — krok 17 a import 30, celá zpracována |
| `CIS_kurzy_CNB` | 13 575 | denní kurzy ČNB 1/2016 – 22. 10. 2026, 5 měn |
| `CIS_katastralni_uzemi` | 13 074 | číselník ČÚZK, názvy **unikátní** |
| `RUIAN_vzorek` | 43 893 | materializovaný RÚIAN na úrovni vkladu |
| `Valuo_soubory` | 2 727 | evidence zpracovaných excelů podle otisku SHA-256 (krok 30) |
| `Valuo_prahy` | 626 | meze, z toho 40 pro kubaturu |
| `Valuo_hromadne_prevody` | 187 | 66 skupin detektoru `JC`, 121 detektoru `CENA` |
| `CIS_RUIAN` | 108 | číselníky RÚIAN |
| `RUIAN_obce_stav` | 151 | která obec, z jakého data, kolik objektů |
| `RUIAN_k_pretazeni` | 0 | obce k dotažení z RÚIANu (krok 30) — nic nechybí |
| `Valuo_staging` | 0 | pracovní tabulka importu |
| `Valuo_karta_parcely` | 102 029 | karta po parcelách (krok 34); **dopočteno pro 49 650 vkladů ze 49 788** |
| `Valuo_mapa` | 49 692 | plochý podklad mapové aplikace (krok 39); od 25. 10. 2026 ji plní **jedině** `sp_prepocet_mapy`, nese dvě osy (`kategorie` = co to je podle nosné skupiny z kroku 46, `klasifikace` = šlo to podle starých pravidel spočítat), `cena_m2` je **výhradně Kč/m² podlahové plochy** kromě čistých souborů pozemků, `jc_orientacni` značí nerozklíčovatelné balíky pozemků a **bod leží u jednotek a budov na stavbě dle RÚIANu** (`bod_zdroj`, `bod_posun_m`, `nalez_bod_daleko`) |
| `Valuo_karta_vklad` | 49 650 | kompaktnost a výměra sloučeného celku |
| `Valuo_karta_okoli` | 40 329 | sousedi a cizí stavby v okolí; **hotovo celé — 826 k. ú.** |
| `Valuo_parcely_role` | 10 068 | trvalá zjištění o parcele, klíč `gml_id` |
| `Valuo_plochy` | 116 863 | registr zdrojů plochy **po řádcích**, klíč `(vklad, id jednotky, zdroj)`; `id` = 0 je údaj za celý vklad — krok 45 |
| `Valuo_vklad_plocha` | 49 707 | nosná nemovitost vkladu, plocha nebo nosná výměra, co je rozpuštěné v ceně, nálezy — kroky 45 a 46; pokrývá jednotky (37 340), budovy (7 101), pozemky (5 222) i právo stavby (44) |
| `Valuo_podil_jednotky` | 47 729 | zlomek podílu na společných částech z popisu (krok 44) |
| `CIS_nalezy` | 13 | číselník nálezů znalce (krok 41), k ruční úpravě |
| `CIS_plochy_zdroje` | 9 | zdroje plochy a jejich pořadí přednosti (krok 44, rozšířeno krokem 45 o řádkové zdroje) |
| `CIS_nemovitost_typ` | 33 | klíč (nemovitost, typ) → priorita nosné nemovitosti, skupina pro srovnání ceny, věrohodné rozmezí plochy (krok 46; nahradil `CIS_jednotka_typ` z kroku 45, který mísil garáž jako jednotku s garáží jako budovou) |
| `CIS_ku_median_jc` | 369 | medián Kč/m² po katastrálním území a skupině; u jednotky a budovy z podlahové plochy, u pozemku z nosné výměry. Kontrola, nikoli volič plochy (kroky 45 a 46) |
| `CIS_karta_parametry` | 20 | prahy vodítek karty a kontroly ploch, k ruční úpravě |
| `Valuo_vklad_rucne` | 0 | použitelnost a ověřená plocha od znalce (krok 41) |
| `Valuo_vklad_nalezy` | 0 | nálezy ke vkladu (krok 41) |
| `Valuo_poznamky` | 0 | poznámky ke vkladu (krok 41) |

Vazba: `Valuo_data.id` → `KN_parcel_data.id_valuo`,
`KN_parcel_data.id` → `KN_parcel_UP.kn_id` → `UP_FVU_data.id`,
`KN_parcel_data.gml_id` → `RUIAN_stavebni_objekty.gml_id`,
`Valuo_data.cislo_vkladu` → `RUIAN_vzorek.cislo_vkladu`.
Cizí klíče nejsou, integrita stojí na importních skriptech. Audit
(krok 25) prověřil pět vazeb a osiřelý záznam nenašel ani jeden; po kroku
30a ověřeno znovu — nula osiřelých parcel i vazeb na ÚP. Krok 30b mazal
navázané tabulky stejně (parcely, vazby na ÚP, evidence ÚP, fronta).

**Data nejsou plošná.** John je dokupuje podle zakázek — vždy v okruhu
oceňované nemovitosti a za poslední rok či dva. K 23. 10. 2026 bylo 78 % dat
z Prahy a objemy rostou od roku 2023; druhá dávka kroku 30 byla celá
pražská. Vkladů starších pěti let bylo 2 351 (4,9 %).

---

## 2. Jak se data kupují — příčina většiny chyb v nich

Valuo prodává data po **balíčcích „katastrální území + měsíc"**, jeden
balíček za 10 Kč. Z toho plynou čtyři následky:

**1. Sloupec `kat_uzemi` je území balíčku, ne nemovitosti.** Ověřeno:
12,9 % parcel leží v jiném území, než říká balíček. Totéž platí o sloupci
`okres`.

**Skutečné území nemovitosti je v `popis`.** Ověřeno: všech 57 314 názvů
vytažených z popisu je platný název k. ú. podle číselníku ČÚZK.

**2. Křížové duplicity.** Tentýž vklad je v balíčku každého dotčeného
území. Z 2 336 duplicitních skupin pocházelo 1 354 z různých balíčků
a 982 z opakovaného importu téhož souboru (krok 16).

**3. Chybné párování parcel.** Skript dotahování z katastru hledal
parcelu podle `kat_uzemi`, tedy podle balíčku — viz oddíl 4.

**4. Tatáž nemovitost v různé podobě.** Valuo ji v různých balíčcích nebo
v různém čase uvádí s jinou plochou (chybějící jako 0 nebo prázdná;
plocha jednotky z podílu přepočtená jinak) nebo s jiným formátem popisu.
Proto se totožnost záznamu od kroku 30 určuje **bez plochy**, ale
**s popisem** (od verze 30.3 u všech řádků) — viz `data/ROZHODNUTI.md`,
oddíl *Totožnost záznamu*.

### Formát popisu

| Vzor | Tvar | Záznamů |
|---|---|---|
| číslo na začátku | `č. 2442/1 Chodov`, `stavební č. 147/7 Osov` | 56 574 |
| seznam za slovem parcele | `… na parcele 330/20 Třebonice` | 50 829 |

(počty k 23. 10. 2026)

Prefix `stavební` rozlišuje stavební parcelu (`st. 147/7`) od pozemkové —
jsou to **dvě různé parcely se stejným číslem**.

Text **„součástí je stavba"** znamená, že stavba není samostatnou
nemovitostí. Jeho absence u budovy naopak znamená samostatně zapsanou
stavbu, tedy možné oddělené vlastnictví stavby a pozemku (oddíl 3).

Pozor na záznamy s popisem `PK č. 4203 Poděbrady` nebo
`GP č. 527 Kobylí Hlava`: parcely pozemkové knihy a grafického přídělu,
které v katastru nemovitostí pod tímto číslem neexistují.

Závorky mohou stát i uprostřed seznamu:
`na parcele st. 235 Labská (k.. Labská), st. 903 Hořejší Vrchlabí`,
a mohou být **vnořené**:
`… na parcele 546/5 Satalice (součástí je stavba … (~)) (~)`.
Parser je proto odstraňuje opakovaně, dokud se text mění (krok 30).

**Název území v seznamu platí pro parcely PŘED sebou, ne za sebou.**
Tohle byla chyba první verze parseru, kvůli které se do databáze dostaly
cizí parcely (krok 23g). Parser proto prochází segmenty **od konce**
a dědí poslední viděný název dozadu:

```python
vysledek, posledni = [], None
for cislo, uzemi in reversed(segmenty):
    if uzemi: posledni = uzemi
    if posledni: vysledek.append((posledni, cislo))
vysledek.reverse()
```

Parsování je hotové na dvou místech: v Pythonu funkce
`parcely_z_popisu` v `30_import_valuo.py` (převzatá z kroku 17, doplněná
o vnořené závorky), v SQL pohled `v_Valuo_parcela_z_popisu`.

### Zdrojové soubory

`C:\Users\ijttr\OneDrive\Dokumenty\OCEŇOVÁNÍ\_GEO_DATA_VALUE_MAPS\VALUO\data_strukturovana`
— k 24. 10. 2026 **2 727 souborů** v číslovaných podsložkách, evidovaných
v `Valuo_soubory`. Názvy `cadastre_report_MM_YYYY.xlsx`, ale na názvu
nezáleží (dva soubory se tvaru vymykají, opakované názvy s „(1)" jsou různé
balíčky). Dvě varianty hlavičky: 16 sloupců, nebo 17 (navíc
`Plocha pozemku (v m2)` na pozici 11). Ověřeno, že se tento sloupec nikdy
neliší od `Plocha` (6 807 případů, nulový rozdíl).

Datumy jsou ve zdroji **text v ISO formátu**, takže prohození dne
a měsíce vzniklo při importu, ne u Valua.

**Zdrojová složka není nadmnožinou databáze** — v databázi je o 713 vkladů
víc, než je ve složce. Import proto nikdy nemaže.

---

## 3. Jak data vypadají — co je nutné vědět

### Cena je vždy za celý vklad

Vklad je jedno katastrální řízení a může obsahovat 1 až N nemovitostí.
`cenovy_udaj` je u všech položek stejný a představuje cenu za všechny
dohromady. Rozpad na jednotlivé nemovitosti v datech není.

**Datový bod pro porovnávací metodu je vklad, ne řádek.**

**Jednotková cena je proto cena celého vkladu dělená plochou jedné
nemovitosti.** U rodinného domu tedy zahrnuje i pozemky, které jsou ve
vkladu. Proto je ve vzorku `plocha_parcel_m2` vedle
`plocha_podlahova_m2`; bez pohledu na oba nelze JC u domů srovnávat.

**Proto je duplicita řádku zákeřná:** vklad s nemovitostí dvakrát dostane
klasifikaci `NELZE` a z porovnání vypadne. Ranní import 24. 10. 2026 tak
na chvíli vyřadil 673 vkladů.

### Sloupec `nemovitost` je základnější než `typ`

| `nemovitost` | Příklady `typ` |
|---|---|
| jednotka | byt, jiný nebytový prostor, garáž, ateliér |
| parcela | orná půda, zahrada, zastavěná plocha |
| budova | bytový dům, rodinný dům, garáž, jiná stavba |
| `---` | právo stavby (48 vkladů, popis začíná „účel …"); od kroku 31 klasifikace `PRAVO_STAVBY` |

Garáž je 2 440× budova (řadová) a 6 279× jednotka (k 23. 10. 2026).

### Čísla jednotek jsou v popisu a jsou vytažená (krok 23e)

`Valuo_data` má čtyři počítané sloupce `PERSISTED`:
`jednotka_oznaceni` (`1234/5`), `jednotka_cp`, `jednotka_cislo`
a `jednotka_kod`. **Všech 49 491 jednotek má označení vyplněné**
(k 23. 10. 2026).

`jednotka_oznaceni` je od kroku 30 součástí klíče totožnosti záznamu;
`Valuo_staging` má proto tentýž počítaný sloupec se shodným výrazem.

**`jednotka_cp` se nehodí k párování na stavební objekt** — viz oddíl 4c.

### `typ_plochy` rozhoduje o tom, zda lze počítat jednotkovou cenu

| `typ` | `typ_plochy` | Řádků | Co to je |
|---|---|---|---|
| parcela | Výměra parcely | vše | výměra parcely |
| byt | Plocha z podílu na budově | 96,8 % | podlahová plocha bytu |
| byt | Výměra parcely | 1 022 | pozemek, ne byt |
| rodinný dům | Výměra parcely | 2 006 | parcela, jmenovatel chybí |
| rodinný dům | **Podlahová plocha** | **848** | skutečná podlahová plocha |
| bytový dům | Podlahová plocha | 338 | **plocha celé budovy** |

**Podlahová plocha ve Valuu pochází z RÚIAN.** Doloženo v kroku 28:
u rodinných domů se shoduje do 5 % v 833 z 842 případů, u bytových domů
v 335 z 336. Proto ji má jen 848 rodinných domů — přesně tam, kde ji
RÚIAN má.

Plocha jednotky je dopočtená z čitatele podílu na společných částech.
Je-li zlomek v katastru normalizovaný, je nesmyslná plocha i zlomek
zároveň — poznávacím znamením je malý čitatel. **Tentýž výpočet dá
v různých balíčcích různý výsledek** — u téže jednotky 53,6 i 536 m².

**Parser toho čitatele nefungoval od svého zavedení** (krok 23f): hledal
lomítko od začátku popisu, ne za frází „domu a pozemku", takže
u 15 178 řádků vycházela negativní délka podřetězce a pohled padal
na Msg 537.

### U bytových domů je podlahová plocha plochou celé budovy

Doložený případ — dvanáct vkladů na téže parcele `č. 496/77 Střížkov`,
u všech plocha 28 000 m², jednotková cena 89 až 286 Kč/m². Jde o prodeje
spoluvlastnických podílů na domě nerozděleném na jednotky.

Rozlišení je v opakování — táž stavba se v datech prodává opakovaně:

| druh stavby | skupin s 5+ prodeji | vkladů |
|---|---|---|
| bytový dům | 203 | 2 289 |
| garáž | 51 | 299 |
| jiná stavba | 16 | 174 |
| rodinný dům | 2 | 11 |

Pohled proto počítá jednotkovou cenu jen tam, kde se táž stavba prodává
méně než pětkrát; ostatní dostanou `podíl na budově`.

### Oddělené vlastnictví stavby a pozemku

V developerských projektech se vlastnictví stavby a pozemku odděluje
a obojí se prodává zvlášť. Doložený případ — V-28897/2023-101, Horní
Počernice: budova (118 m² podlahová, parcela 4037/539) plus dvě orné
parcely o 82 a 46 m². Cena 733 650 Kč dělená 128 m² pozemků dává
5 732 Kč/m²; dělená podlahovou plochou domu 6 217 Kč/m², zatímco trh
je kolem 100 000.

**Příznak stojí na dvou podmínkách zároveň:** stavba není součástí
pozemku **a** ve vkladu se prodávají parcely, ale ta pod stavbou mezi
nimi není:

| Stav | Komu cena patří | Vkladů |
|---|---|---|
| stavba je součástí pozemku | celku | 4 447 |
| samostatná, parcela pod ní se prodává nebo žádná není | celku, resp. stavbě | 548 |
| **samostatná, prodávají se jiné parcely** | **nejisté** | **512** |

**Jedna podmínka nestačí.** Je-li stavba součástí pozemku, není ten
pozemek samostatnou nemovitostí a jako samostatná parcela se ve vkladu
neuvádí vůbec.

Dopad: medián rodinných domů v Horních Počernicích se posunul
z 31 254 Kč/m² (69 bodů) na 60 952 Kč/m² (40 bodů).

### Výměra ve `Valuo_data` a v `KN_parcel_data` jsou dva různé okamžiky

1. `Valuo_data.plocha` — výměra ke dni vkladu
2. `KN_parcel_data.areaValue_m2` a `geo_plocha` — stav ke dni dotažení
   z katastru; **oba z téhož stažení**
3. dnešní stav katastru

Pro posudek ber výměru z katastru (`areaValue_m2`), ne z geometrie.

### Sloupec `adresa` u parcel není adresa

Je to název katastrálního území plus parcelní číslo („Horní Heršpice
873/129"). U budov a jednotek je naopak `adresa` poštovní a parcelní
číslo v ní **není**. Chybí-li, je v ní náhrada `Neznámá adresa`.

### Cizí měny

247 vkladů má cenu v cizí měně (k 23. 10. 2026). Přepočteno kurzem ČNB
ke dni podání návrhu na vklad — cena byla sjednána v kupní smlouvě, která
je starší než vklad, a datum podání je k ní nejblíž (průměrně 27 dní před
zplatněním).

| Měna | Vkladů | Roky | Použitý kurz |
|---|---|---|---|
| EUR | 228 | 2016–2026 | 23,425–27,055 |
| USD | 12 | 2021–2025 | 21,172–24,301 |
| CHF | 3 | 2020–2025 | 23,422–26,304 |
| GBP | 2 | 2025 | 29,082–29,437 |
| AUD | 1 | 2021 | 15,880 |
| ANG | 1 | 2025 | ČNB nekotuje |

**Dva vklady mají pravděpodobně chybně vyplněnou měnu:**

| Vklad | Měna | Cena | JC s přepočtem | JC jako koruny | Medián |
|---|---|---|---|---|---|
| V-86065/2019-101 | CHF | 4 273 500 | 2 459 310 | 105 000 | 119 268 |
| V-26440/2025-101 | EUR | 2 493 440 | 2 034 272 | 81 485 | 173 143 |

Neopraveno — bez kupní smlouvy to potvrdit nelze.

### Pozemek se stavbou jako součástí

Je-li stavba součástí pozemku, obsahuje vklad jen parcely a klasifikace
mu dá `JC_PARCELY`. Cena zahrnuje i tu stavbu, ale dělí se výměrou
pozemků:

| vklady JC_PARCELY | vkladů | řádově vysoká JC | podíl |
|---|---|---|---|
| jen pozemky | 3 572 | 162 | 4,54 % |
| na pozemku je stavba | 46 | 20 | 43,48 % |

Takový vklad dostane hodnocení `chybí podlahová plocha`.

**Opačný případ — parcela se stavbou jako součástí vedená jako „budova".**
Valuo často uvádí parcelu, jejíž součástí je rodinný dům
(„č. 1253/5 Ruzyně (součástí je stavba č.p. 1185 …)"), jako
`nemovitost = 'budova'`, `typ = 'rodinný dům'`, a jako plochu někdy
podlahovou plochu z RÚIAN, jindy výměru parcely. Vklad pak dostane
`CELEK_BUDOVA`, ale `plocha_parcel_m2` ve vzorku zůstane prázdná, protože
sčítá jen řádky `nemovitost = 'parcela'`. **Výměra je přitom
v `KN_parcel_data`** (u V-34546/2024-101 parcela 1253/5 o 282 m²).
Týká se **518 vkladů rodinného domu** (24. 10. 2026). Řešením je karta
vkladu (oddíl 8.1).

Někdy Valuo uvede v jednom vkladu **obojí** — stavbu i parcelu se stavbou
jako součástí, obě jako „budova" se stejnou adresou; liší se jen popisem.
Ve starých datech 25 vkladů. Nejsou to duplicity (krok 30b), vklad ale
dostane `NELZE`, protože má dvě budovy.

### U pozemků rozhoduje funkční využití, ne druh

Mediány v Praze od 2022 (Kč/m²): SMJ 28 609, SV 15 069, OV 10 973,
OB 10 779, IZ 3 236, ZMK 2 625, NL 764, LR 691.

Číselník `CIS_FVU_skupiny` slučuje kódy do pěti skupin podle cenové
hladiny:

| skupina | kódů | kódy |
|---|---|---|
| `JADRO` | 1 | SMJ |
| `OBYTNE` | 9 | OB, DGP, OV, S4, SV, VN, VOP, VV, ZVO |
| `SMISENE` | 10 | VS, ZKC, ZMK, SP, S2, PZA, PZO, DU, DH, DL |
| `ZELEN` | 13 | DP, OP, DZ, IZ, PS, S1, SO, TI, TVE, TVO, TVV, ZOB, ZP |
| `LES_LOUKY` | 6 | SD, TEP, SUP, VVA, LR, NL |

Skupina se ještě dělí podle `CIS_velikost_pozemku`: do 100, 100–300,
300–600, 600–1 500 a nad 1 500 m². Klíč má tvar `FVU:OBYTNE|600-1500`.

**Funkční využití se používá jen v Praze.**

### Cenové hladiny, které v datech nejsou (od znalce)

Údaje, které se z databáze nedají odvodit a slouží ke kontrole:

- **Nebytové prostory pro komerční účel v Praze: 50–120 tis. Kč/m²**
  podle lokality a stavu. Pod 50 tis. jde o sklepy, sklady, případně
  garáž zapsanou jako jiný nebytový prostor. Druh `jiný nebytový
  prostor` tedy míchá dvě různé komodity, ne dvě ceny — proto má
  v `CIS_metrika_ceny` vypnutý záchyt na krajské hladině (oddíl 4e).
- **Byty v Praze, realizované ceny z katastru, duben–září 2026**
  (CenaOdhad.cz): medián Prahy **152 000 Kč/m²**, polovina prodejů mezi
  132 000 a 175 000. Nejdražší Praha 1 (201 000), nejlevnější Praha 10
  (131 000); nejlevnější čtvrť Hostivař 123 000.

---

## 4. Co bylo provedeno

### Struktura

- `KN_parcel_data` dostala `id IDENTITY` jako primární klíč (dřív heap)
- textové sloupce zmenšeny z `varchar(max)` na konkrétní délky
- zrušeno 12 sloupců bez informační hodnoty (oddíl 5)
- `Valuo_data`: `typ_prevodu`, `LAT`/`LON` jako počítané sloupce,
  `cena_Kc`, `kurz_pouzity`, `kurz_datum`, čtyři sloupce s označením
  jednotky (krok 23e)
- unikátní indexy proti opakování duplicit:
  `UQ_KN_parcela_nemovitost (id_valuo, gml_id)`,
  `UQ_Valuo_zaznam (cislo_vkladu, adresa, nemovitost, typ, plocha)` —
  **ten druhý nechrání před duplicitou v jiné podobě**, protože obsahuje
  plochu; to zajišťuje importní skript klíčem bez plochy (krok 30);
  duplicit je po kroku 30b nula, přestavba indexu je otevřená (oddíl 8.1)
- krok 30: tabulky `Valuo_soubory`, `Valuo_staging`, `RUIAN_k_pretazeni`,
  `KN_parcel_UP_stav`
- krok 31: tabulka `zaloha_definice` (definice pohledů a procedur před
  změnou)

### Souřadnice a geometrie

Geokódování adres bylo nepoužitelné — jen 51 % bodů do 500 m od skutečné
parcely, maximální odchylka 344 km. Nahrazeno referenčním bodem parcely
z katastru.

| Zdroj souřadnic | Před revizí | Po revizi (23. 10.) | Po kroku 30 (24. 10.) |
|---|---|---|---|
| referenční bod z katastru | 99 320 (92,5 %) | 106 456 (99,12 %) | **108 814 (99,14 %)** |
| neověřený geokodér | 6 402 | 836 (0,78 %) | 836 (0,76 %) |
| bez souřadnic | 1 681 | 111 (0,10 %) | 112 (0,10 %) |

Souřadnice vkladu je referenční bod **největší parcely** vkladu, v rozsahu
souřadnic ČR. Od kroku 30 ji spolu s `kod_ku` promítá do `Valuo_data`
importní skript (dřív krok 18).

Audit (krok 25) ověřil, že `LAT`/`LON` souhlasí s `geo_bod` u všech
107 403 tehdejších řádků; jsou to počítané sloupce z `geo_bod`.

**Poučení k orientaci ringů:** typ `geography` vyžaduje vnější ring proti
směru hodinových ručiček; u obráceného polygonu vrátí `STArea()`
510 065 621 710 996 m². V kroku 03b byla orientace počítána na
souřadnicích v S-JTSK a teprve pak se transformovalo — osy obou systémů
jsou orientované různě, takže výsledek byl obrácený u všech 148 404
polygonů. **Orientaci počítej teprve po transformaci, na dvojicích
(lon, lat).** Importní skript to tak dělá a po vložení ještě kontroluje.

### Územní identifikace

**Všech 13 074 názvů k. ú. v číselníku je unikátních** — proto rozlišovací
přívlastky. Název určuje kód jednoznačně a dotaz `GetZoningByName`
na katastr je zbytečný.

**`Valuo_data.kod_ku` je kód území největší parcely vkladu**, ne balíčku
(shoda ve starých datech 98 901 z 99 281 řádků). Chybí jen u 933 řádků
bez parcely. Do 24. 10. 2026 chyběl i u 7 134 řádků s parcelou — byly to
přesně řádky kroku 17, kterým krok 18 doplnil souřadnice, ale ne `kod_ku`;
604 vkladů proto vypadávalo ze vzorku. Doplněno v kroku 30.

**Pořadí spolehlivosti filtrů: prostorově → `kod_ku` → název.**

### Prohozené datumy (krok 12)

Pět dávek importu ze 17. 9. – 12. 10. 2026 mělo prohozený den a měsíc
u `datum_zplatneni`.

**Blok 12.4 toho skriptu napáchal škodu** — vycházel z domněnky, že
v dotčené dávce parser prohodil všechno, což neplatilo: zkazil
`datum_podani` u 52 záznamů a u 1 745 je změnil s neznámým dopadem.
Napraveno skriptem `12b`.

### Odstraněné duplicity

| Krok | Co | Řádků | Záloha |
|---|---|---|---|
| 14 | táž parcela v téže nemovitosti | 11 962 | (v DB už není) |
| 16 | tentýž záznam Valuo | 3 307 | (v DB už není) |
| 23g | **cizí parcela navázaná na vklad** | **13 040** | `KN_parcel_data_zaloha_23g` |
| 30a | **ranní import 24. 10. — tatáž nemovitost v jiné podobě** | **862** (+ 938 parcel) | `zaloha_30a_*` (5 tabulek) |
| 30b | tatáž položka ze dvou starších importů s jinou plochou | 8 (+ 8 parcel) | `zaloha_30b_valuo`, `zaloha_30b_kn_parcel` |

**Totožnost záznamu Valuo se od kroku 30 posuzuje klíčem bez plochy:**
`cislo_vkladu`, `nemovitost`, `typ`, `adresa`, `jednotka_oznaceni`
a **`popis`** (od verze 30.3 u všech řádků; ve verzi 30.2 jen u řádků
s `Neznámá adresa`). **`kat_uzemi` se do porovnání nezahrnuje.** Dřívější
pětice s plochou (kroky 16 a 25) přehlédla duplicity, u nichž Valuo uvedlo
plochu jinak.

Klíč 30.2 (popis jen u `Neznámá adresa`) našel ve starých datech 33 skupin. **Duplicit z nich
bylo jen 8** (typ B — tatáž položka se shodným popisem, jiná plocha);
odstraněny krokem 30b, ponechán řádek s podlahovou plochou. Zbylých 25
(typ A) jsou dvě různé nemovitosti téhož vkladu (oddíl 3, *Pozemek se
stavbou jako součástí*) a v databázi zůstávají. **Klíčem 30.3 je dnes
v databázi 0 kolizí.**

### Cizí parcely navázané na vklady (krok 23g)

Nález znalce v Novém Městě: vklad měl navázanou parcelu č. 2, která
v tom území existuje, ale jde o jinou nemovitost — podle popisu tam měla
být parcela 824. **Vetřelci byly převážně parcely s nízkými čísly.**
Smazáno 13 040 vazeb, jen tam, kde parser v popisu našel aspoň jednu
parcelu.

### Zatřídění do územního plánu — dvě nalezené chyby a přepis

**První (krok 9):** skript zapisoval `UPDATE ... WHERE parcel_number =
:parc_num`. Parcelní číslo není unikátní — 3 953 čísel se vyskytuje ve
více územích, dotčeno 51 484 parcel (34,7 %). Důkaz: ze 2 752 čísel
ležících ve více územích mělo **všech 2 752 shodné `id_UP_FVU_data`**.

**Druhá (krok 24e): v databázi byla dvě různá přiřazení a pohled čtel to
starší a zasolené.**

| Zdroj | Co to je |
|---|---|
| `KN_parcel_data.id_UP_FVU_data` | starší sloupec, jeden polygon na parcelu |
| `KN_parcel_UP` | tabulka z kroku 09, vazba M:N s podíly a pořadím |

Starý sloupec obsahoval pražské funkční využití i u 1 569 parcel mimo
Prahu. `v_vklad_UP` teď čte z `KN_parcel_UP`. **Starý sloupec zůstává,
ale nepoužívá se** (importní skript do něj dominantní plochu doplňuje).

**Přepis (krok 30):** `09_parcely_UP_kompletni.py` padal na filtru
`geometry IS NOT NULL` — sloupec je prázdný. Zatřídění teď počítá SQL
Server přímo nad `geo_plocha`, jen pro parcely, které ho ještě nemají.
Ověřeno proti výsledku kroku 09 na 300 parcelách: naprostá shoda.

### Dotahování parcel z katastru — čtyři chyby (krok 17)

Skript obsahoval **tři různé funkce na totéž parsování**.

**a) Funkce ignorovala svůj parametr** (řádek 310):

```python
def get_parcel_data(zoning_name, parcel_number):
    upper_zoning_id = get_zoning_code(
        zoning_name=row["kat_uzemi"], okres=row["okres"])
```

Následek: 8 067 záznamů bez parcely a 342 s cizí parcelou. Těm 8 067
krok 17 parcely dotáhl, ale `kod_ku` jim zůstal prázdný až do kroku 30.

**b) Záměna stavební a pozemkové parcely** (řádek 51):

```python
is_stavebni = bool(re.search(
    r"\bstavební\b|\bstavba\b|\bč\.\s*\d+", popis, re.IGNORECASE))
```

`\bč\.\s*\d+` vyhoví každému popisu s „č. 373"; `\bstavba\b` vyhoví textu
„(součástí je stavba č.p. 1388)". Následek: 329 záznamů.

**c) Dvojí stažení každého záznamu** (řádky 554–573): blok `else`
u `try/except` se provede vždy, když výjimka nenastala. Odtud 271
záznamů s oběma typy parcel.

**d) Fallback na cizí okres** (řádky 246–254).

**e) Dědění území špatným směrem** — nalezeno až v kroku 23g.

### Klasifikace vkladů

Stav ve vzorku k 24. 10. 2026 po kroku 31 (49 689 vkladů):

| Klasifikace | Vkladů | Pravidlo |
|---|---|---|
| `JC_JEDNOTKA` | 27 325 | právě jedna jednotka, parcel libovolně |
| `NELZE` | 10 877 | více jednotek, více budov, nebo obojí |
| `CELEK_BUDOVA` | 6 217 | právě jedna budova, parcel libovolně |
| `JC_PARCELY` | 5 222 | jen parcely |
| `PRAVO_STAVBY` | 48 | vklad obsahuje právo stavby (`nemovitost = '---'`); **testuje se jako první** |

`PRAVO_STAVBY` (krok 31, rozhodnutí znalce): porovnává se jen mezi sebou
a dál se nečlení — 38 rodinných domů a 10 víceúčelových staveb v Dejvicích.
Hodnocení je `právo stavby`. **Do mezí nevstupuje** — `sp_prepocet_prahu`
se k `CIS_prahy_ceny` připojuje vnitřním spojením přes klasifikaci a tam
jsou jen čtyři dosavadní.

### Metriky porovnání

Určuje číselník `CIS_metrika_ceny`, určený k ruční úpravě.

| Metrika | Jmenovatel | Druhy |
|---|---|---|
| `JC` | plocha z podílu na budově | byt, ateliér, jiný nebytový prostor, dílna, rozestavěná jednotka |
| `JC` | výměra parcel | pozemky |
| `JC_PODLAHOVA` | podlahová plocha stavby | rodinný dům, stavba pro rodinnou rekreaci, objekt k bydlení, budova s číslem popisným |
| `KUS` | — | garáž (budova i jednotka) |
| `CELEK` | — | bytový dům, jiná stavba, ostatní |

`JC_PODLAHOVA` znamená: počítej z podlahové plochy, je-li v datech.
Není-li, dostane vklad hodnocení `chybí podlahová plocha`.

**Bytový dům zůstává na `CELEK` záměrně.** Druhy, které v číselníku chybí
(stavba technického a občanského vybavení, budova s číslem evidenčním,
průmyslový objekt…), dostávají `CELEK` výchozí cestou — oddíl 8.1.

**Rodinný dům pro účely analýzy** (rozhodnutí znalce 24. 10. 2026) = druh
`rodinný dům` **a** `objekt k bydlení`. Stavba pro rodinnou rekreaci je
samostatná skupina.

Pohled mapuje hodnoty na tři skupiny: `JC` se poměřuje jednotkovou
cenou, `CELEK` a `KUS` celkovou cenou vkladu, `M3` kubaturou (krok 28b).

---

## 4b. Meze a mediány spočítané z dat (kroky 24, 26, 28b, 29b)

Hodnocení dřív stálo na čtyřech odhadnutých číslech
v `CIS_prahy_ceny.cena_min` a na mediánu z `v_cenove_hladiny`.
Nově je zdrojem **tabulka `Valuo_prahy`**, po kroku 30 626 kombinací,
plněná procedurou `sp_prepocet_prahu`.

### Jak se mez počítá

Ceny mají log-normální rozdělení, takže se počítá na logaritmu:

```
σ̂ = (P75 − medián) / 0,6745
mez zdola = max( exp(p50 − k·σ̂) , exp(p50) / max_nasobek )
mez shora = min( exp(p50 + k·σ̂) , exp(p50) · max_nasobek )
```

Parametry jsou v `CIS_prahy_ceny`: `k_faktor` 3,00, `min_bodu_prah` 30,
`max_nasobek` 10,00. Strop na desetinásobku mediánu brání tomu, aby se
z rozptýlené skupiny stala mez bez vypovídací hodnoty.

### Čtyři pokusy, než to fungovalo

| pokus | proč selhal |
|---|---|
| MAD nebo IQR | V Kobylisích byla kontaminace nad 25 %, tedy nad bodem zhroucení obou odhadů. |
| odhad z horní poloviny rozdělení | Fungoval pro byty, ale u pozemků dosahovala kontaminace 70–80 %. |
| seskupení FVU podle P90 | Nestačilo. Smíchalo OB s mediánem 1 679 Kč/m² a SV se 169 Kč/m². |
| **mez na celkové ceně vkladu** | **Funguje.** Netržní převody mají nízkou celkovou cenu nezávisle na ploše. |

Proto má `CIS_mez_podilu` hodnotu 100 000 Kč pro `*` a pro Prahu.

### Kruh se neuzavírá

`sp_prepocet_prahu` čte z `v_Valuo_vzorek_q` a ten čte z `Valuo_prahy`.
Drží to proto, že:

1. procedura naplní `#d0` z pohledu **dřív**, než tabulku vyprázdní
2. **procedura nefiltruje podle `hodnoceni_ceny`.** Filtruje podle měny,
   typu převodu, hromadného převodu, roku a meze podílu — podle věcí,
   které na mezi nezávisí.

**Kdyby brala jen vklady „bez výhrad", meze by se při každém přepočtu
stahovaly k mediánu, až by nakonec vyřadily všechno kromě středu.**

### Propadávání — šest úrovní (krok 28b)

```
k. ú. + stáří → k. ú. → okres + stáří → okres → kraj + stáří → kraj
```

**Dosavadní stav je tím podlahou.** Ověřeno: po zavedení stáří se
u starých kombinací **nezměnil ani jeden medián a nezmizela ani jedna
kombinace**.

Sloupce `uroven_meze`, `pasmo_meze` a `bodu_v_mezi` říkají, odkud mez
je a na kolika vkladech stojí.

**Klíče `FVU:` existují jen na úrovni kraje.**

### Paměť (krok 29b)

`PERCENTILE_CONT` je okenní funkce a drží celý oddíl v paměti. Po
zavedení pásem a metriky `M3` se vstup zdvojnásobil a procedura spadla
na **Msg 701**. Nově se počítá **v cyklu po klasifikacích** — čtyři
průchody nad čtvrtinou dat; výsledek je bitově stejný, špička paměti
zhruba čtvrtinová. Po kroku 30 trvá celá procedura kolem 5 sekund.

### Pořadí podmínek v hodnocení je věcné rozhodnutí

Nález z kroku 26: starý pohled testoval absolutní mez **dřív** než
`oddělené vlastnictví` a `podíl na budově`, takže takové vklady pod
200 000 Kč spadly do `symbolická cena`. Po přerovnání vyskočilo oddělené
vlastnictví ze 136 na 509 a podíl na budově ze 68 na 521.

**Totéž platí pro `pod tržní hladinou` (krok 29a): testuje se PŘED mezí
z `Valuo_prahy`**, jinak by v kontaminovaném území rozhodla stažená
lokální mez.

### Čím se meze neřídí

- **vklady s klasifikací `NELZE` se mezí nehodnotí.**
- **pro pozemky neexistují meze na celkové ceně**, jen jednotkové.
- **pozemky nedostávají pásmo stáří**, i když na nich stavba stojí.
- Do výpočtu nevstupují cizí měny, nestandardní převody, hromadné
  převody mimo typ `TRH`, opakovaně prodávané stavby a vklady starší
  pěti let.

### Co meze neumějí

**Meze stojí na posledních pěti letech, hodnotí se jimi ale i vklady
starší.** Starších vkladů je 2 351 (4,9 %). **Pro posudek je deflace
na datum ocenění nutná** — oddíl 8.2.

Meze slouží **výhradně k odhalení odchylek, ne k popisu trhu ani
k ocenění.**

**Pozor na percentily jako detektor chyb** — P05/P95 označí z definice
10 % záznamů vždy.

### Kontrolní mediány

Pražské byty podle stáří (Kč/m², úroveň k. ú., stav 23. 10. 2026 — po
kroku 30 nepřepočítáno):

| k. ú. | do 1945 | 1946–1990 | 1991–2010 | 2011+ |
|---|---|---|---|---|
| Nové Město | 155 180 | — | 184 048 | 194 982 |
| Smíchov | 125 000 | 110 555 | 140 845 | 162 369 |
| Žižkov | 132 101 | 109 093 | 137 432 | 156 151 |
| Stodůlky | — | 85 116 | 114 310 | 131 145 |
| Modřany | — | 102 198 | — | 146 129 |

**Poválečná a socialistická zástavba je nejlevnější ze všech epoch** —
pod prvorepublikovou i pod novostavbami.

Rodinné domy (bez rozlišení stáří): Dejvice 170 193 (7 bodů), Kunratice
145 506 (29), Stodůlky 117 448 (38), Beroun 94 975 (27), Květnice
86 713 (59), Štěrboholy 85 860 (40), Úvaly u Prahy 71 382 (38), Horní
Počernice 60 952 (40), Rumburk 16 533 (12), Varnsdorf 11 470 (7).

---

## 4c. Technickoekonomické atributy z RÚIAN (krok 27)

**Pro 81,7 % vkladů přestalo platit, že data neobsahují stáří ani
konstrukci** (k 23. 10. 2026). Z 985 nových vkladů s budovou nebo jednotkou
v kroku 30 se na RÚIAN napojilo 982.

### Odkud se data berou

Výměnný formát RÚIAN (VFR), soubory po obcích. URL je předvídatelná:

```
https://vdp.cuzk.gov.cz/vymenny_format/soucasna/<YYYYMMDD>_OB_<kod>_UZSZ.xml.zip
```

Soubory se generují jednou měsíčně. **Stahuje se jednou, pak už se síť
nepotřebuje.**

**Varianta `UZSZ` a `UKSH` dávají pro stavební objekty identická data.**
Ověřeno na Praze: 152 432 objektů, 119 521 čísel domovních, shodné
vyplněnosti do jednotky. Velikost: 48,0 MB proti 119,7 MB.

**To ale platí jen pro TEA.** Základní sada `UZSZ` nese u parcel i staveb
**pouze definiční bod, žádné hranice** — ověřeno 24. 10. 2026 na obci Kostelec
(3 196 parcel, nula polygonů). Rozdíl velikosti je právě grafika. **Od kroku 32
se stahuje `UKSH`**, která má hranice parcel i půdorysy staveb; podrobnosti
v `data/ROZHODNUTI.md`, oddíl *Geometrie parcel okolí z RÚIAN*.

### Dotazovatelná služba existuje, ale nestačí

INSPIRE Budovy (BU), `https://services.cuzk.cz/wfs/inspire-bu-wfs.asp`,
WFS 2.0.0, profil Buildings Extended 2D. Ověřeno na SO.26177137:

| Údaj | VFR | WFS INSPIRE |
|---|---|---|
| zastavěná plocha | 785 | ✅ `officialArea` / constructedArea |
| datum dokončení | 2007-01-01 | ✅ `dateOfConstruction` |
| vazba na parcelu | `pai:Id` 1267091210 | ✅ `cadastralParcel` → `CP.1267091210` |
| kód SO / ISKN budova | 26177137 / 370614210 | ✅ `externalReference` |
| připojení sítí | 1/1/1 | ✅ v BuildingPart, navíc elektřina |
| druh konstrukce | kód 10 | ⚠️ `materialOfStructure`, hrubší |
| vytápění | kód 1 | ⚠️ `heatingSystem`, hrubší |
| **podlahová plocha** | 190 | ❌ není |
| **obestavěný prostor** | 831 | ❌ není |
| **počet podlaží** | 5 | ❌ nil / Unpopulated |
| **počet bytů** | 39 | ❌ `numberOfBuildingUnits` = vchody |
| **výtah** | 1 | ❌ není |

**Z WFS se nedají dostat tři nejdůležitější údaje.** Zůstává VFR. Služba
ale potvrdila, že `cadastralParcel` vrací `CP.1267091210`, tedy přesně
tvar `gml_id` — párování přes parcelu je tím ověřené z druhé strany.

### Dvě pasti ve struktuře VFR

**1. `IdentifikacniParcela` nese `pai:Id`, ne `pai:Kod`.**

**2. `tag='{*}StavebniObjekt'` chytá i `<ami:StavebniObjekt>`**, což je
odkaz uvnitř adresního místa ve tvaru
`<ami:StavebniObjekt><soi:Kod>155804758</soi:Kod></ami:StavebniObjekt>`.
Na testu to dalo **123 584 falešných záznamů navíc**.

### Gigabajt u Prahy není problém velikosti

ZIP má 48 MB a **nikdy se nerozbaluje** — XML se čte proudem přímo
z archivu. Problém byl jinde: **parcely jsou v souboru PŘED stavebními
objekty**, a `iterparse` s filtrem `tag=` neuvolňuje prvky, které filtru
nevyhoví.

Měřeno na souboru o velikosti Prahy (1,05 GB XML, 167 066 objektů):

| | první objekt | vrchol paměti | nalezeno |
|---|---|---|---|
| naivní parser | po 36,6 s | **3 423 MB** | 290 650 ❌ |
| opravený | po 10,4 s | **75 MB** | 167 066 ✅ |

### `DetailniTEA` je k ničemu

Má jen **9 z 1 687 objektů (0,5 %)** a **neobsahuje žádnou plochu**.
Navíc jsou vnitřně rozporné: u SO.26177137 mají vchody `PocetPodlazi`
1, 1, 5, 5, 1.

### Vyplněnost atributů

| Údaj | Dobřichovice | Praha |
|---|---|---|
| identifikační parcela | 100 % | 99,9 % |
| zastavěná plocha | 76,5 % | 78,5 % |
| počet bytů | 74,2 % | 78,0 % |
| počet podlaží | 62,2 % | 74,9 % |
| **datum dokončení** | 73,4 % | **71,7 %** |
| druh konstrukce | 60,6 % | 73,0 % |
| obestavěný prostor | 20,5 % | 22,1 % |
| **podlahová plocha** | 17,5 % | **20,2 %** |

### Podlahová plocha z RÚIAN není nový údaj

**Valuo ji z RÚIANu bere.** Z 1 973 budov s plochou v RÚIANu jich
**1 645 už ji od Valua má; nových je 328.**

**Kubatura chybějící plochu nevyřeší** — RÚIAN plní zastavěnou plochu,
podlahovou plochu i obestavěný prostor pospolu. Z 1 827 rodinných domů
bez jakékoli plochy má kubaturu jen 76.

### Věrohodnost podlahové plochy

Podlahová plocha bývá plochou jednoho bytu nebo vchodu, ne celé budovy.
Doložený případ SO.26177137: bytový dům, 39 bytů, 5 podlaží, zastavěná
plocha 785 m², ale podlahová plocha 190 m² a obestavěný prostor 831 m³.

**Příznak se počítá z obestavěného prostoru, ne z počtu podlaží.**
Podle definice RÚIAN se u podsklepené budovy počítají i podzemní podlaží
a obyvatelné podkroví se počítá jako samostatné nadzemní podlaží. Běžný
rodinný dům se sklepem a podkrovím má tedy 3 podlaží, přestože sklep
i podkroví mají menší užitnou plochu — výraz
`zastavěná plocha × podlaží` je proto systematicky nadsazený.

Rozdělení poměru `3 × PP / OP` (104 427 objektů):

| pásmo | objektů | podíl |
|---|---|---|
| pod 0,20 | 584 | 0,6 % |
| 0,20–0,35 | 2 530 | 2,4 % |
| 0,35–0,50 | 10 455 | 10,0 % |
| **0,50–1,00** | **77 345** | **74,0 %** |
| 1,00–1,50 | 12 501 | 12,0 % |
| nad 1,50 | 1 012 | 1,0 % |

Meze 0,35 a 1,50 v `CIS_RUIAN_parametry` označí 4,0 % objektů.

### Definice z RÚIAN

- **Zastavěná plocha** — plocha ohraničená pravoúhlými průměty vnějšího
  líce obvodových konstrukcí všech nadzemních i podzemních podlaží do
  vodorovné roviny; započítávají se lodžie a arkýře. **Je to atribut
  stavebního objektu, ne parcely** — s výměrou stavební parcely se
  shoduje jen u 48,8 % případů a u 32,7 % je parcela o víc než desetinu
  větší.
- **Podlahová plocha** — celková využitelná plocha budovy včetně půdy,
  bez nosných a dělicích konstrukcí; obvykle odpovídá ploše užitné.
  **Garáž jako součást hmoty domu se započítává** a je v zastavěné
  i podlahové ploše zároveň, takže poměr nezkresluje.
- **Počet podlaží** — součet všech podlaží včetně podzemních; obyvatelné
  podkroví se počítá jako samostatné nadzemní podlaží.

### TEA jsou deklarovaný údaj, ne měření

`PlatiOd` ukazuje dávkový původ: v Dobřichovicích má 953 z 1 687 objektů
`PlatiOd` v roce 2023 a dalších 368 v roce 2011. ČÚZK aktualizoval TEA
u téměř 2,5 milionu objektů podle výsledků sčítání lidu.

**Datum dokončení je navíc zpravidla jen rok:**

| Tvar data | objektů | podíl |
|---|---|---|
| 31. prosince | 215 159 | **61,2 %** |
| konkrétní datum | 121 882 | 34,7 % |
| první den jiného měsíce | 10 945 | 3,1 % |
| 1. ledna | 3 654 | 1,0 % |

Sloupec `ruian_rok_presny` to rozlišuje.

**U staveb po rekonstrukci se údaj aktualizuje**, takže rok nemusí být
rokem původní výstavby. Pro ocenění to vadí málo — stav stavby odpovídá
spíš té rekonstrukci. **Proto se tomu údaji říká „rok dokončení dle
RÚIAN", nikoli „stáří stavby".**

### Chyba v párování jednotek (krok 27a)

První verze pohledu párovala jednotku podle **čísla popisného v rámci
obce**. V Praze se ale čísla popisná číslují po katastrálních územích —
**č. p. 40 odpovídá v Praze 116 různým stavebním objektům.**

| Cesta | jednotek | objektů na jednotku |
|---|---|---|
| přes č. p. v obci | 44 621 | **36,30** ❌ |
| přes parcelu | 44 626 | **1,05** ✅ |

Opraveno: jednotka se páruje přes parcelu stejně jako budova — vklad na
byt obsahuje i podíl na pozemku pod domem. Číslo popisné zůstalo jako
**kontrola** (sloupec `cp_souhlasi`, shoda **95,1 %**).

### Výsledek kroku 27

| | nemovitostí | z celku v DB | násobnost |
|---|---|---|---|
| budovy | 11 692 | 11 890 → **98,3 %** | 1,00 |
| jednotky | 49 039 | 49 472 → **99,1 %** | 1,04 |

**Celkem 54 963 nemovitostí a 39 941 z 48 863 vkladů (81,7 %) mělo rok
výstavby** (k 23. 10. 2026).

---

## 4d. Stáří a kubatura ve vzorku (krok 28)

### Materializace byla nutná, ne elegance

`v_RUIAN_vzorek` agreguje přes 557 tisíc objektů a `v_Valuo_vzorek_q`
je sám na hranici 60 s. Proto tabulka **`RUIAN_vzorek`** (43 893 vkladů
po kroku 30) plněná procedurou `sp_prepocet_ruian_vzorku`, která jde
rovnou na tabulky — oba pohledy dělaly tentýž join dvakrát.

### Pásma stáří

Číselník `CIS_stari_stavby`, určený k ruční úpravě. Rozložení
k 23. 10. 2026:

| pásmo | vkladů | podíl |
|---|---|---|
| do 1945 | 10 101 | 23,5 % |
| 1946–1990 | 10 938 | 25,4 % |
| 1991–2010 | 5 837 | 13,6 % |
| 2011+ | 13 065 | 30,4 % |
| bez roku | 3 086 | 7,2 % |

### Co zavedení stáří udělalo

| úroveň | druh meze | vkladů | průměr bodů |
|---|---|---|---|
| k. ú. | **se stářím** | **22 173** | 357 |
| k. ú. | bez stáří | 4 761 | 166 |
| okres | se stářím | 3 171 | 499 |
| okres | bez stáří | 2 088 | 266 |
| kraj | se stářím | 202 | 107 |
| kraj | bez stáří | 3 104 | 143 |

**72 % vkladů s mezí se poměřuje proti své stavební epoše**, a skupiny
se stářím stojí v průměru na víc vkladech než ty bez něj.

Změna hodnocení: bez výhrad +79, pod mezí −316, nad mezí +237.
Ostatních jedenáct kategorií beze změny.

### Metrika `M3` — porovnání přes kubaturu

Cena vkladu dělená obestavěným prostorem. **Je paralelní: do
`hodnoceni_ceny` nevstupuje.** Sloupce `jedn_cena_Kc_m3`,
`median_Kc_m3`, `mez_m3_zdola`, `mez_m3_shora`, `bodu_v_mezi_m3`,
`uroven_meze_m3`.

Zatím tenká — po kroku 30 40 kombinací mezí.

### Co se nezměnilo

**Do `Valuo_data` ani `KN_parcel_data` se nezapsal jediný údaj z RÚIANu.**
Pohled nese údaje z RÚIAN vedle vlastních, ne místo nich — v kapitole 7
posudku tak jde u každého čísla uvést zdroj. Starší skript znalce je
přeléval do stejných sloupců (`combine_first`), čímž se informace o zdroji
ztrácela.

---

## 4e. Tři vrstvy záchytu netržních převodů (krok 29)

### Nález, který to vyvolal

Při přípravě ročních mediánů vyšlo najevo, že **Stodůlky, byty, 2023
mají medián 6 436 Kč/m² u 318 vkladů, a všechny procházejí jako „bez
výhrad"** — proti 125 376 Kč/m² o rok později.

```
JC Kč/m²   vkladů   cena od    cena do    různých ploch
5 699,80       46   251 361    251 361        1
6 442,53       42   493 433    493 433        1
6 160,70       35   275 137    275 137        1
```

Družstevní privatizace. **Detektor z kroku 23 ji minul**, protože
klíčuje podle jednotkové ceny a vyžaduje tři a více různých ploch —
tady má každá cena plochu jedinou. **A mez ji nezachytila taky:**
`mez_zdola` byla 645 Kč/m², protože těch 318 převodů tvořilo většinu
skupiny, ze které se mez počítá, a stáhly si ji samy pod sebe.

### Vrstva 1 — struktura transakce

Dva detektory, oba plní `Valuo_hromadne_prevody` rozlišenou sloupcem
`detektor` (po kroku 30: 66 skupin `JC`, 121 skupin `CENA`):

| detektor | klíč | podmínka | skupin (23. 10.) | vkladů |
|---|---|---|---|---|
| `JC` (krok 23) | jednotková cena | 5+ vkladů, 3+ různých ploch | 66 | 891 |
| `CENA` (krok 29) | celková cena vkladu, území, druh, rok | 5+ vkladů a zároveň (plochy se opakují **nebo** cena není kulatá na 1 000 Kč) | **118** | **1 757** |

Druhá podmínka u `CENA` odděluje trh od transakce. Měřeno:

| cena | plochy | skupin | vkladů | procházelo |
|---|---|---|---|---|
| kulatá | různé | 121 | 713 | 654 ← **trh, nechat** |
| nekulatá | opakují se | 91 | 1 410 | 421 |
| kulatá | opakují se | 18 | 278 | 246 |
| nekulatá | různé | 11 | 99 | 9 |

Pět bytů za kulatých pět milionů s pěti různými plochami je náhoda, ne
jedna smlouva.

**`sp_detekce_hromadnych_prevodu` bylo nutné upravit** — měla
`WHEN NOT MATCHED BY SOURCE … THEN DELETE` bez omezení na detektor
a při každém běhu by smazala skupiny druhého detektoru.

### Vrstva 2 — absolutní hladina (krok 29a)

Znalec k tomu řekl podstatnou věc: **že byt v Praze za 5 000 Kč/m² není
tržní prodej, je zjištění, ne hypotéza.** K vyřazení z mediánu to stačí
samo o sobě; druh převodu je až popis do posudku.

Pravidlo proto míří přímo na cenu a stojí na **krajském mediánu, který
kontaminace neunese** — pražské byty mají 17 409 vkladů a medián
127 013 Kč/m² (k 23. 10. 2026).

**Hranice vyšla z dat, ne z odhadu.** Pražské byty od 2022, tehdy „bez
výhrad":

| pásmo Kč/m² | vkladů |
|---|---|
| do 10 tis. | 91 |
| 10–20 tis. | 20 |
| 20–30 tis. | 8 |
| **30–40 tis.** | **5** ← prázdná zóna |
| 40–50 tis. | 40 |
| 50–60 tis. | 59 |
| 60–80 tis. | 304 |
| nad 80 tis. | 13 904 |

Mezi 20 a 40 tisíci je prakticky prázdno. **30 % krajského mediánu dává
38 104 Kč/m²**, tedy doprostřed mezery.

Parametr je dvoustupňový:

| kde | platí pro | hodnota |
|---|---|---|
| `CIS_prahy_ceny.mez_vuci_kraji` | klasifikaci | 0,300 pro jednotky a budovy, `NULL` pro pozemky |
| `CIS_metrika_ceny.mez_vuci_kraji` | **druh** | přepíše výchozí; **0 = neuplatňovat** |

**Pozemky jsou vynechané.** Cena pozemku téhož druhu se uvnitř kraje
legitimně liší i desetinásobně — 30 % by tam vyřadilo 13 % vzorku. Pro
pozemky slouží `CIS_mez_podilu` na celkové ceně vkladu.

**Jiný nebytový prostor má nulu.** Druh míchá komerční prostory
(Praha 50–120 tis. Kč/m²) se sklepy, sklady a garážovými stáními pod
50 tis. Jedna mez to rozlišit neumí; mez 23 900 vyřadila 596 legitimních
sklepů.

Mez se škáluje sama — v Liberci 13 660, v Praze 38 104 — a s přepočtem
se posouvá s trhem.

### Vrstva 3 — statistická odchylka

Meze z `Valuo_prahy` podle území, druhu a stáří (oddíl 4b).

**První dvě vrstvy nestojí na lokálních datech, takže je kontaminované
území nedokáže obejít.** To byla přesně ta díra ve Stodůlkách.

### Výsledek

Stodůlky, byty, 2023 — nejlevnější vklad s hodnocením „bez výhrad" má
teď **40 000 Kč/m²** (k 23. 10. 2026):

| hodnocení | vkladů | JC od | JC do |
|---|---|---|---|
| hromadný převod | 164 | 3 260 | 10 395 |
| pod tržní hladinou | 77 | 1 922 | 36 044 |
| bez výhrad | 82 | **40 000** | 185 633 |
| nad mezí | 46 | 64 904 | 156 857 |

A mez v tom území po přepočtu:

| pásmo | vkladů | medián | mez zdola |
|---|---|---|---|
| bez stáří | 710 | 108 313 | **46 112** |
| 1946–1990 | 284 | 85 116 | 39 656 |
| 1991–2010 | 158 | 114 310 | 65 641 |
| 2011+ | 265 | 131 145 | 85 707 |

**`mez_zdola` byla ráno 645 Kč/m², po vyčištění je 46 112** — sedmdesátinásobek.

### Zatřídění skupin není povinnost

Nezatříděná skupina se bere jako hromadný převod a je vyřazená. To je
správná výchozí pozice. Zatřídění (`typ_jevu` z
`CIS_typy_hromadneho_prevodu`) má smysl jen ve třech případech:

- **`TRH`** — ukázalo se, že to prodej byl; jen tento typ se vrací do
  mediánu. Kandidátem jsou garáže od developera za kulatou cenu
  (Ruzyně 2023, 136 stání po 300 000 Kč).
- **`VYKUP_LINIOVY`** — aby je šlo najít jako podklad pro posudky na
  výkupy.
- popis do kapitoly 7, až na konkrétní skupinu dojde.

**Mapa `23c_mapa_prevodu.py` o detektoru `CENA` neví** — zapisuje podle
starého klíče, takže nové skupiny v ní nejsou vidět. Buď ji upravit,
nebo zatřiďovat příkazem `UPDATE` (vzor v oddílu 29.6 skriptu).

---

## 5. Struktura `KN_parcel_data` po úklidu

15 sloupců (dřív 27), tabulka zmenšena z 88,2 MB.

| Skupina | Sloupce |
|---|---|
| Identifikace | `id`, `gml_id`, `kod_ku` (int, NOT NULL), `parcel_number` |
| Údaje | `areaValue_m2`, `beginLifespanVersion` |
| Geometrie | `geometry` (**prázdný**), `refPoint_x/y`, `refPoint_lon/lat`, `geo_bod`, `geo_plocha` |
| Vazby | `id_valuo`, `id_UP_FVU_data` (**nepoužívá se**, viz krok 24e) |

`gml_id` zůstal jako identifikátor používaný ČÚZK — vystupuje v URL
dálkového přístupu do katastru a **je klíčem k napojení na RÚIAN.**

**Sloupec `geometry` je NULL u všech parcel** (zjištěno 23. 10. 2026; dřívější
údaj o 52,6 MB surové geometrie neplatil). Nositelem geometrie je
`geo_plocha`. Nemá sloupec s datem vložení — nové parcely se poznají
přes frontu `KN_k_pretazeni`.

**Pro import:** `kod_ku`, `geo_bod` i `geo_plocha` plní importní skript
`30_import_valuo.py` rovnou z odpovědi katastru. Krok `17b_geografie.py`
odpadá.

---

## 6. Objekty v databázi

### Číselníky — určené k ruční úpravě

| Objekt | Řádků | Co obsahuje |
|---|---|---|
| `CIS_katastralni_uzemi` | 13 074 | číselník ČÚZK |
| `CIS_kurzy_CNB` | 13 575 | denní kurzy ČNB |
| `CIS_RUIAN` | 118 | číselníky RÚIAN; od 25. 10. 2026 i `DruhPozemku` (10 kódů, ověřeno proti textům Valua) |
| `CIS_FVU_skupiny` | 39 | kód FVU → cenová skupina |
| `CIS_nalezy` | 13 | číselník nálezů znalce (krok 41); **popis je celá věta a bere ho aplikace**, ne kód |
| `CIS_plochy_zdroje` | 9 | zdroje plochy, `poradi` drží přednost, `pro_cenu = 0` je jen kontrola (krok 44, rozšířeno 45) |
| `CIS_nemovitost_typ` | 33 | klíč (nemovitost, typ) → `priorita` (nosná nemovitost), `skupina` (srovnání ceny), `plocha_min`/`plocha_max` (krok 46) |
| `CIS_metrika_ceny` | 13 | metrika podle druhu; **`mez_vuci_kraji` přepisuje záchyt pro druh, 0 = vypnuto**; `poznamka` je `nvarchar(400)`, tedy 200 znaků |
| `CIS_rozsahy_ploch` | 11 | meze plausibility ploch |
| `CIS_typy_hromadneho_prevodu` | 7 | typ jevu a příznak `do_medianu` |
| `CIS_velikost_pozemku` | 5 | velikostní pásma pozemků |
| `CIS_stari_stavby` | 4 | pásma stáří pro meze |
| `CIS_prahy_ceny` | 4 | `cena_min`, `prah_bodu`, `k_faktor`, `min_bodu_prah`, `max_nasobek`, **`mez_vuci_kraji`** |
| `CIS_RUIAN_parametry` | 3 | meze věrohodnosti podlahové plochy, výška podlaží |
| `CIS_mez_podilu` | 2 | minimální cena vkladu u pozemků; `*` platí pro kraje bez vlastního řádku |

### Odvozené tabulky

| Objekt | Řádků | Co obsahuje |
|---|---|---|
| `RUIAN_parcely` | 4 699 350 | parcely z UKSH; `gml_id` je počítaný `'CP.' + kod_parcely`, `geo_plocha` hranice, `geo_bod` definiční bod, `geo_plocha_m2` kontrolní plocha |
| `RUIAN_parcely_bpej` | 2 686 626 | bonitované díly, klíč (parcela, BPEJ); výměry dílů se při importu sčítají |
| `RUIAN_stavebni_objekty` | 1 193 394 | TEA; `gml_id` je počítaný sloupec `'CP.' + parcela_id`, `pomer_pp_op` poměr PP ku OP, `geo_plocha` půdorys u obcí v UKSH; index `IX_RUIAN_so_parcela` na `parcela_id` kvůli hledání staveb na sousedních parcelách |
| `RUIAN_so_cisla_domovni` | 844 208 | čísla popisná |
| `RUIAN_vzorek` | 43 893 | materializovaný RÚIAN na úrovni vkladu |
| `RUIAN_obce_stav` | 688 | evidence stažených obcí, sloupce `varianta` a `pocet_parcel` |
| `Valuo_prahy` | 626 | meze pro klasifikaci × klíč × metrika × pásmo × úroveň × území |
| `Valuo_hromadne_prevody` | 187 | skupiny obou detektorů, rozlišené sloupcem `detektor` |

### Tabulky importu (krok 30)

| Objekt | Řádků | Co obsahuje |
|---|---|---|
| `Valuo_soubory` | 2 727 | evidence excelů: otisk SHA-256, cesta, řádků, vloženo, odmítnuto, vyřazeno |
| `Valuo_staging` | 0 | pracovní; počítaný sloupec `jednotka_oznaceni` shodný s `Valuo_data` |
| `KN_parcel_UP_stav` | 107 929 | které parcely prošly zatříděním do ÚP, i bez průniku |
| `RUIAN_k_pretazeni` | 0 | obce k dotažení z RÚIANu |
| `KN_k_pretazeni` | 14 963 | fronta katastru; `duvod = 'IMPORT30'` pro položky z kroku 30 |

### Tabulky ručních zjištění (krok 41)

Zjištění znalce **nikdy nejdou do `Valuo_data`** ani do ničeho, co přišlo
z Valua. Pohled je upřednostní, takže v posudku je vždy dohledatelné, co je
údaj z katastru a co znalcův závěr.

| Objekt | Co obsahuje | Kam to píše aplikace |
|---|---|---|
| `CIS_nalezy` | číselník 11 nálezů v 5 skupinách; `vyrazuje_vzorek` vyřadí vzorek z porovnání, `automaticky` označuje nálezy, které umí najít databáze sama | — (jen čte) |
| `Valuo_vklad_rucne` | jeden řádek na vklad: `pouzitelnost` (vhodny / s_vyhradou / nepouzitelny), `pouzitelnost_duvod`, **`plocha_rucne`**, `plocha_rucne_zdroj`, `kdo`, `kdy` | záložka „Co jsem zjistil“ |
| `Valuo_vklad_nalezy` | nálezy ke vkladu, cizí klíč `nalez_kod` → `CIS_nalezy.kod` | zaškrtávátka nálezů |
| `Valuo_poznamky` | poznámky, **přidávají se, nepřepisují**; index na `(cislo_vkladu, kdy DESC)` | časová osa poznámek |

**`plocha_rucne` je první v pořadí přednosti** před plochou jednotky z Valua,
podlahovou plochou z Valua i z RÚIANu. Pohled vrací použitou hodnotu
v `plocha_podlahova_karty` a původ v `plocha_podlahova_zdroj` („ověřeno
znalcem“).

Ve `Valuo_mapa` k tomu přibyly příznaky `nalez_plocha_cely_dum`
a `nalez_plocha_z_podilu`, aby šlo filtrovat „jen k doplnění“ bez dotazu
do pomalého pohledu. Od opravy 25. 10. 2026 je do mapy **nezapisuje**
`sp_prepocet_ploch`, nýbrž `sp_prepocet_mapy`, která je jediným vlastníkem
tabulky a běží jako poslední — viz `data/ROZHODNUTI.md`, „Jeden vlastník
`Valuo_mapa`".

### Validita jednotkové ceny stojí na jmenovateli

Ne na popisku. Od rozhodnutí znalce 25. 10. 2026 je `cena_m2` v mapě
**Kč/m² podlahové plochy** u všeho, co obsahuje budovu nebo jednotku;
na výměru pozemku se dělí **jen vklad bez budovy i bez jednotky**. Stavba
bez podlahové plochy tedy jednotkovou cenu nemá vůbec a uvádí se jen cena
celková (**5 831 vkladů**, z nichž 5 690 nemá podlahovou plochu v žádném
zdroji a 141 ji nemá u každé nosné nemovitosti). Každá kategorie tak nese
jedinou metriku.

Filtr srovnávacího vzorku:

| co | filtr |
|---|---|
| stavby a jednotky | `zaklad_ceny IN (N'plocha jednotky dle Valuo', N'ověřeno znalcem')` |
| pozemky | `zaklad_ceny = N'nosná výměra pozemku'` |
| vždy | `AND ISNULL(jc_orientacni, 0) = 0 AND nalez_vice_nosnych = 0 AND nalez_bez_plochy = 0` |

s `jc_verdikt` proti mediánu k. ú. jako nezávislou kontrolou. Odvozené
jmenovatele (426 vkladů: RÚIAN, podíl × plocha domu, čitatel dělený škálou,
složené popisy) jsou vodítko, ne vzorek. Totéž platí o **orientačních
cenách** (`jc_orientacni = 1`, 2 215 vkladů): nerozklíčovatelné balíky
pozemků, kde se žádná parcela nekvalifikovala jako nosná, takže se cena
dělí součtem výměr všech parcel včetně podílů na komunikacích. Rozsah 0 až
1 152 580 Kč/m²; verdikt proti mediánu se u nich nepočítá. V mapě jsou
vidět, ale bez barvy a mimo kvintily škály.

`klasifikace = 'NELZE'` **není** důvod vzorek zahodit: všech 10 881 má
důvod strukturální (více jednotek, budova i jednotka, více budov), což
řeší kroky 45 a 46. Z podmnožiny s čistým jmenovatelem a bez nálezů má
8 135 vkladů cenu v pásmu mediánu k. ú. a 10 794 z nich jsou kupní
smlouvy. Podrobný rozpad v `data/ROZHODNUTI.md`, „Dvě osy".

### Tabulky registru ploch (krok 44)

Čtyři zdroje plochy vedle sebe, nic se nepřepisuje. **Ruční plocha má
přednost; dopočet z podílu se použije, jen když Valuo plochu nemá.**

| Objekt | Co obsahuje |
|---|---|
| `CIS_plochy_zdroje` | devět zdrojů s pořadím přednosti; `pro_cenu = 0` je zdroj, který se k ceně nikdy nepoužije a slouží jen ke kontrole |
| `Valuo_podil_jednotky` | zlomek podílu na společných částech vytažený z popisu — `citatel`, `jmenovatel`, počítaný `pomer` |
| `Valuo_plochy` | jeden řádek na (vklad, jednotku, zdroj) s hodnotou, platností, příznakem `pouzito` a poznámkou, proč se ta plocha použila nebo nepoužila |
| `Valuo_vklad_plocha` | nosná nemovitost vkladu, počet nosných a ostatních řádků, součet plochy, seznam použitých zdrojů a text `rozpusteno` s tím, co je v ceně ale ne v ploše. Od kroku 46 i `vymera_nosna` (výhradní parcely bez tvaru pásu a bez druhu komunikace), `vymera_podilu` jako doplňující údaj a nálezy `nalez_vice_nosnych` a `nalez_bez_plochy` |
| `CIS_ku_median_jc` | medián Kč/m² po k.ú. a skupině jednotek, počítaný jen z vkladů bez nálezu; slouží výhradně ke kontrole |

Plní je `sp_prepocet_ploch` (pátý krok `38_prepocty.py`, 6 sekund).
**Parsování zlomku je součástí téže procedury** — kdyby běželo zvlášť, po
importu nových jednotek by se obojí rozešlo a nové vzorky by tiše neměly
kontrolu posunu desetinné čárky.

Karta i export do Wordu čtou řádek `RUCNE` **živě** z `Valuo_vklad_rucne`,
ne z registru; po zápisu ověřené plochy navíc aplikace registr pro ten jeden
vklad rovnou srovná jedním MERGE. Tím se nemůže stát, že znalec plochu zadá
a výstup ji neukáže.

### Pohledy

| Pohled | K čemu |
|---|---|
| `v_Valuo` | základní, ověřené území + souřadnice |
| `v_Valuo_vzorek` | jeden řádek = jeden vklad = jeden datový bod; **bere jen řádky s `geo_zdroj = 'KN_refPoint'`** a k číselníku území se připojuje přes `kod_ku` |
| `v_Valuo_vzorek_q` | **hlavní pracovní pohled** — vzorek s příznaky kvality a údaji z RÚIAN, 79 sloupců; od kroku 31 hodnocení `právo stavby` |
| `v_Valuo_karta_vkladu` | **karta vkladu — jeden řádek = jeden vklad**; od kroku 41 vrací i ruční zjištění znalce a příznaky nálezů. Počítá za běhu z pěti tabulek, proto je **pomalý** — mapa z něj nečte, čte z `Valuo_mapa` |
| `v_RUIAN_budovy` | budova Valuo → stavební objekt přes parcelu |
| `v_RUIAN_jednotky` | jednotka Valuo → dům přes parcelu, se sloupcem `cp_souhlasi` |
| `v_RUIAN_vzorek` | referenční definice pro `RUIAN_vzorek` |
| `v_Valuo_parcela_z_popisu` | parcelní číslo a území z popisu |
| `v_KN_parcely` | parcely s názvem území a funkčním využitím |
| `v_vklad_UP` | funkční využití vkladu dle ÚP (opraveno v kroku 24e) |
| `v_cenove_hladiny` | **už se nepoužívá**; ponechán pro výpisy |

### Procedury — spouští je importní skript

```
python 30_import_valuo.py --prepocty
```

pustí v závazném pořadí:

```sql
EXEC dbo.sp_prepocet_jednotkovych_cen;    -- klasifikace a plochy vkladu (od kroku 31 i PRAVO_STAVBY)
EXEC dbo.sp_prepocet_typu_prevodu;        -- dražba, dar, směna…
EXEC dbo.sp_prepocet_men;                 -- cena_Kc z kurzu ČNB
EXEC dbo.sp_detekce_hromadnych_prevodu;   -- detektor JC
EXEC dbo.sp_detekce_prevodu_dle_ceny;     -- detektor CENA
EXEC dbo.sp_prepocet_ruian_vzorku;        -- RÚIAN na úroveň vkladu
EXEC dbo.sp_prepocet_prahu;               -- až nakonec, čte vzorek
```

Přepočty karty a mapy zatím **běží zvlášť**, skriptem `38_prepocty.py`,
v závazném pořadí:

```sql
EXEC dbo.sp_prepocet_karty_okoli;   -- sousedi a cizí stavby (po k. ú.)
EXEC dbo.sp_prepocet_karet_davka;   -- karty po dávkách, přerušitelné
EXEC dbo.sp_prepocet_karty_tvar;    -- PP index sloučeného celku
EXEC dbo.sp_prepocet_ploch;         -- registr ploch po řádcích, nosná nemovitost
EXEC dbo.sp_prepocet_mapy;          -- plochý podklad mapy; JEDINÝ vlastník, poslední
```

Od verze 30.6 je spouští sám import: `30_import_valuo.py --dopocty`, nebo
`--vse`. Fázovat se dá přes `--krok` (okoli, karty, tvar, mapa, plochy).
Logika zůstala v `38_prepocty.py`, import volá jeho funkci `spust()`.

Předtím promítne souřadnice a `kod_ku` z parcel do `Valuo_data`.
Celý řetězec trvá 1 až 2 minuty. **Žádná procedura nepracuje
inkrementálně** — přepočítávají celou databázi. Postup celého importu
je v `data/POSTUP_import.md`.

**Import RÚIAN je samostatný a na tomhle řetězci nezávisí** — jiná
kadence (měsíční snapshot proti nákupu po zakázkách) i jiná granularita
(obec proti katastrálnímu území; Praha je 112 k. ú., ale jedna obec).

---

## 7. Jak se vzorek sestavuje

```sql
DECLARE @stred  geography = geography::Point(<LAT>, <LON>, 4326);  -- LAT první
DECLARE @radius int = 1500;

SELECT cislo_vkladu, datum_zplatneni, kat_uzemi, druh, fvu_kod, fvu_skupina,
       typ_prevodu, plocha_parcel_m2, plocha_podlahova_m2, cena_Kc,
       jedn_cena_Kc_m2, porovnavana_hodnota,
       median_Kc, mez_zdola, mez_shora, bodu_v_mezi, uroven_meze, pasmo_meze,
       median_kraj, mez_trzni_hladina,
       pomer_k_medianu, hodnoceni_ceny, prepocet_meny, pozemek_se_stavbou,
       stavba_samostatna, prodeju_tehoz_objektu, typ_jevu, hromadny_detektor,
       obsahuje_duplicity,
       ruian_rok, ruian_pasmo, ruian_rok_presny, ruian_druh_konstrukce,
       ruian_vytah, ruian_obestaveny_prostor, jedn_cena_Kc_m3,
       ruian_podlahova_plocha, ruian_pomer_pp_op, ruian_plocha_podezrela,
       CAST(geo_bod.STDistance(@stred) AS decimal(10,1)) AS vzdalenost_m
FROM dbo.v_Valuo_vzorek_q
WHERE klasifikace = 'JC_PARCELY'
  AND hodnoceni_ceny = N'bez výhrad'
  AND geo_bod.STDistance(@stred) <= @radius
  AND rok >= YEAR(GETDATE()) - 3
ORDER BY vzdalenost_m;
```

Příznaky jsou v pohledu vidět, nejsou schované ve filtru — vyřazení
záznamu ze vzorku musí být v posudku odůvodnitelné. U každého srovnání
hlásí `bodu_v_mezi`, `uroven_meze` a `pasmo_meze`, na kolika vkladech
a z jaké úrovně mez stojí.

**Pro pozemky pro liniovou výstavbu** jsou použitelné i vklady
s `typ_jevu = 'VYKUP_LINIOVY'`, které do mediánu nevstupují. Filtruj
`hodnoceni_ceny = N'hromadný převod' AND typ_jevu = 'VYKUP_LINIOVY'`.

**Pro porovnání přes kubaturu** použij `jedn_cena_Kc_m3` proti
`median_Kc_m3`.

### Stav vzorku (49 689 vkladů, 24. 10. 2026, po krocích 30b a 31)

| Hodnocení | 24. 10. odp. | 24. 10. po 30a | 23. 10. | Co to znamená |
|---|---|---|---|---|
| bez výhrad | **25 400** | 25 397 | 24 725 | použitelné pro srovnání |
| nelze porovnat | 10 548 | 10 598 | 10 265 | klasifikace `NELZE`, víc nemovitostí ve vkladu |
| chybí podlahová plocha | 2 374 | 2 374 | 2 081 | RÚIAN doplní jen zčásti |
| hromadný převod | 2 276 | 2 276 | 2 252 | zachyceno jedním z detektorů, do mediánu nevstupuje |
| pod mezí | 1 657 | 1 658 | 1 570 | pod spodní mezí z dat |
| **pod tržní hladinou** | **1 437** | 1 437 | 1 402 | **cena řádově pod krajským mediánem — nebyl to tržní prodej** |
| podíl nebo symbolický převod | 1 399 | 1 399 | 1 377 | pozemek s cenou vkladu pod mezí podílu |
| bez JC | 1 263 | 1 262 | 1 241 | metrika JC, ale jednotková cena chybí |
| bez srovnání | 1 157 | 1 156 | 1 142 | mez nevznikla ani na úrovni kraje |
| nad mezí | 581 | 581 | 535 | nad horní mezí z dat |
| podíl na budově | 553 | 553 | 502 | táž stavba se prodává 5× a víc |
| oddělené vlastnictví | 408 | 410 | 404 | cena nepatří stavbě |
| nestandardní převod | 340 | 340 | 320 | dražba, dar, směna |
| symbolická cena | 247 | 247 | 249 | bez meze a pod absolutním záchytem |
| **právo stavby** | **48** | — | — | **vlastní kategorie od kroku 31, porovnává se jen mezi sebou** |
| cizí měna bez kurzu | 1 | 1 | 1 | ANG, ČNB nekotuje |
| **celkem** | **49 689** | **49 689** | **48 066** | |

Přírůstek 1 623 vkladů = 925 nových vkladů z druhé dávky kroku 30
+ 604 vrácených doplněním `kod_ku` + 94 starých, které dostaly souřadnici.
Podíl „bez výhrad" stabilní (51,1 % proti 51,4 %).

Kroky 30b a 31 počet vkladů nezměnily, jen přesunuly hodnocení: 42 práv
stavby přešlo z „nelze porovnat" do vlastní kategorie, 6 rodinných domů
z kroku 30b je nyní „bez výhrad".

Rozdíl mezi `pod mezí` a `pod tržní hladinou` je věcný: první znamená
statistickou odchylku v rámci lokality, druhé znamená, že to nebyl
tržní prodej.

---

## 8. Co zbývá udělat — v tomto pořadí

> **Aktualizace 25. 10. 2026 večer — kroky 43 a 44.** Opraven bod vkladu,
> postaven registr zdrojů plochy, import zjednodušen na jeden příkaz
> a výstupy srovnány. Podrobnosti v oddílu 8.0c; starší stavy níže.

### 8.0c Stav k 25. 10. 2026 večer

| Vrstva | Objekt | Stav |
|---|---|---|
| Okolí parcel | `Valuo_karta_okoli` | hotovo — 40 329 parcel v 826 k. ú. |
| Karty vkladů | `Valuo_karta_parcely` | hotovo — 49 650 vkladů ze 49 788 |
| Tvar celku | `Valuo_karta_vklad` | hotovo |
| Podklad mapy | `Valuo_mapa` | hotovo — 49 692 bodů, přepočteno po kroku 43 |
| Registr ploch a nosná nemovitost | `Valuo_plochy`, `Valuo_vklad_plocha` | hotovo kroky 45 a 46 — 118 279 řádků registru, 51 962 použitých, 49 707 vkladů ve všech třech kategoriích; 393 nálezů celého domu (212 přepsáno), 2 571 nálezů škály (57 přepsáno), 1 287 více nosných, 5 922 nosná bez plochy. Podlahovou plochu má 38 563 vkladů, nosnou výměru 13 236. Posun desetinné čárky se nehledá, v datech neexistuje. |
| Ruční zjištění | `Valuo_vklad_rucne` a spol. | postaveno, prázdné |
| Vzorek | `v_Valuo_vzorek` | **49 647** (po přeznačení 55 řádků bez parcely) |

**Co je hotové z aplikace a výstupů**

| | |
|---|---|
| mapa, filtry, barevná škála, rozpad domu na jednotky | hotovo |
| srovnávací soubor a export do jednoho dokumentu | hotovo |
| ruční zjištění znalce | hotovo |
| registr zdrojů plochy a posun čárky | hotovo |
| odkazy do mapy.cz, Google Maps a Street View | hotovo |
| karta v HTML a export do Wordu nesou stejná data | hotovo, ověřeno porovnáním popisků |
| mapy mají spodní mez výřezu (400 / 700 / 1 000 m) | hotovo, ověřil znalec |
| druh pozemku z RÚIANu v rozpisu parcel | hotovo |

**Co zbývá**

1. potvrdit **1 807 návrhů** na posun desetinné čárky
2. **značka na stavbu** místo na definiční bod parcely — zbyly 3 sdílené body se 74 vklady
3. prověřit **vybočující jednotkové ceny** (953 z 3 838 bytových domů pod 1 000 Kč/m²)
4. **`typ_jevu`** u 121 skupin ze 187 — ovládání v aplikaci chybí
5. **ruční oprava role parcely** z aplikace — mechanismus existuje
6. **obrazovka s nastavením `CIS_karta_parametry`**
7. **138 vkladů bez parcely** — zkusit dotažení z katastru znovu

**Skripty kroků 43 a 44**

| Skript | K čemu |
|---|---|
| `43_oprava_geo_bodu.sql` | oprava bodu vkladu, zálohy, trvalá podmínka do importu |
| `44_plochy_zdroje.sql` | registr zdrojů plochy, zlomky podílu, dva nálezy, přepsaný pohled |
| `42_export_definic.py` | záloha definic pohledů a procedur; **pouští znalec** |

---

> **Aktualizace 25. 10. 2026 — krok 41 a dopočet dat.** Všechny čtyři
> přepočtové vrstvy jsou hotové a je postavená vrstva ručních zjištění
> znalce. Podrobnosti v oddílu 8.0b; starší stavy zůstávají níže.

### 8.0b Stav k 25. 10. 2026

| Vrstva | Objekt | Stav |
|---|---|---|
| Okolí parcel | `Valuo_karta_okoli` | **hotovo celé** — 40 329 parcel v 826 k. ú. |
| Karty vkladů | `Valuo_karta_parcely` | **hotovo** — 49 650 vkladů ze 49 788 |
| Tvar celku (PP index) | `Valuo_karta_vklad` | **hotovo** — `pp_index_vse` u 49 647, `pp_index_celku` u 9 757 z 9 766 vkladů, které výhradní celek vůbec mají |
| Podklad mapy | `Valuo_mapa` | **hotovo** — 49 692 bodů |
| Ruční zjištění | `Valuo_vklad_rucne` a spol. | **postaveno, prázdné** — čeká na procházení mapy |

**Zbývajících 138 vkladů kartu nemá a mít nemůže** — nemají ani jednu parcelu
dotaženou z katastru. Fronta přepočtu je proto nově nebere a řídicí skript
se zastaví, přestane-li počet zbývajících klesat (bez toho se dávka
protáčela 9,4 hodiny naprázdno).

Skripty kroku 41:

| Skript | K čemu |
|---|---|
| `41_rucni_zjisteni.sql` | `CIS_nalezy`, `Valuo_vklad_rucne`, `Valuo_vklad_nalezy`, `Valuo_poznamky`, přepsaný pohled |
| `37_karta_html.py` | + blok „Co zjistil znalec“, původ plochy u ceny |
| `35_export_word.py` | + blok „Co zjistil znalec“ do .docx |
| `40_aplikace.py` | + záložka „Co jsem zjistil“, zápis do databáze, filtr „jen k doplnění“, skrytí nepoužitelných |

### 8.1b Co zbývá

1. **umístit značku na stavbu**, ne na definiční bod parcely
2. **prověřit vybočující jednotkové ceny** — 953 z 3 838 bytových domů pod
   1 000 Kč/m²; nález `CENA_MIMO` je připravený, mez není nastavená
3. **`typ_jevu` u hromadných převodů** — 121 skupin ze 187 nevyplněných;
   ovládání v aplikaci zatím chybí
4. **ruční oprava role parcely z aplikace** — mechanismus existuje
5. **obrazovka s nastavením `CIS_karta_parametry`**
6. **138 vkladů bez parcely** — zkusit dotažení z katastru znovu
7. **zapojit přepočty karty do `30_import_valuo.py --prepocty`**

---

> **Aktualizace 24. 10. 2026 v noci — kroky 35 až 40.** Karta vkladu je
> hotová včetně exportu do Wordu, HTML generátoru nad databází a mapové
> aplikace. Běží dávkový přepočet karet. Podrobnosti níže v oddílu 8.0.

### 8.0 Stav k noci 24. 10. 2026

| Vrstva | Objekt | Stav |
|---|---|---|
| Okolí parcel | `Valuo_karta_okoli` | **hotovo celé** — 40 329 parcel v 826 k. ú. |
| Karty vkladů | `Valuo_karta_parcely` | **běží** — 3,6 vkladu/s, ze 49 788 |
| Tvar celku (PP index) | `Valuo_karta_vklad` | běží spolu s kartami |
| Podklad mapy | `Valuo_mapa` | **634 vkladů v 9 k. ú.** z částečného běhu |

Pořadí přepočtů je závazné:

```
python 38_prepocty.py                      # okolí, karty, tvar, mapa
python 38_prepocty.py --krok mapa --prepocitat   # po doběhnutí karet
```

**Nepouštět dva běhy souběžně** — oba sahají na pohled `v_Valuo_karta_vkladu`
a navzájem si překážejí až k vypršení dotazů.

Skripty kroků 35 až 40:

| Skript | K čemu |
|---|---|
| `35_export_word.py` | karta do .docx v šabloně posudku, mapy v tiskovém rozlišení |
| `36_oprava_view_a_tvar.sql` | oprava jednotkové ceny u jednotek, PP index, dávkovač |
| `37_karta_html.py` | karta jako HTML přímo z databáze |
| `38_prepocty.py` | dávkové plnění všech pěti kroků, přerušitelné; plochy [4/5], mapa [5/5] |
| `39_mapa_data.sql` | `Valuo_mapa` a `sp_prepocet_mapy` |
| `40_aplikace.py` | mapová aplikace — server a stránka |

Aplikace se spouští `python 40_aplikace.py`, otevře `http://localhost:8000/`.

### 8.1 Co zbývá

1. **dopočítat karty** — běží
2. **~~přepočítat `Valuo_mapa`~~ hotovo 25. 10. 2026** — 49 692 řádků,
   310 k. ú., všechna s klasifikací, kategorie sedí s nosnou skupinou.
   Pro příště: vynucený přepočet je `python 38_prepocty.py --krok mapa
   --prepocitat`, jede kolem dvou minut a bere 310 k. ú., která v mapě
   řádky mají (v `Valuo_data` je jich 826, zbytek nemá souřadnice). Přes
   spojení asistenta to neprojde, `@max_sekund` se kontroluje až mezi
   k. ú. a jedno velké k. ú. (Krč 2 306 vkladů) obálku přetáhne
3. **umístit značku na stavbu**, ne na definiční bod parcely
4. **příznak podezřelé plochy jednotky** (136 případů) a **původ plochy**
   v kartě
5. **tabulky pro ruční zjištění znalce** — `CIS_nalezy`,
   `Valuo_vklad_rucne`, `Valuo_vklad_nalezy`
6. **zapojit přepočty karty do `30_import_valuo.py --prepocty`**

Starší body oddílu 8 zůstávají níže beze změny.

### Starší znění oddílu 8


Import nových dat (dřívější úkol 8.1) je **hotový** — krok 30, skript
`30_import_valuo.py`, návod v `data/POSTUP_import.md`, rozhodnutí
v `data/ROZHODNUTI.md`. Duplicity (krok 30b) a práva stavby (krok 31)
jsou vyřízené.

### 1. Karta vkladu — hotová databázová vrstva (krok 34)

Objekty: `CIS_karta_parametry` (prahy vodítek), `Valuo_parcely_role` (trvalá
zjištění o parcele), `Valuo_karta_okoli` (sousedi a cizí stavby, inkrementální),
`Valuo_karta_parcely` (karta po parcelách), `Valuo_karta_vklad` (kompaktnost
sloučeného celku), procedury `sp_prepocet_karty_okoli` a `sp_prepocet_karty`,
pohled **`v_Valuo_karta_vkladu` — jeden řádek = jeden vklad**. Joinuje se na
`v_Valuo_vzorek_q` přes `cislo_vkladu`; vzorek záměrně nejoinuje sám, je na
hranici 60 s.

Karta platí pro **všechny vklady**, ne jen pro rodinné domy. Řeší zároveň
518 rodinných domů bez výměry pozemku i vklady `NELZE` (byt + stání + sklep).

Zbývá: **`GRANT EXECUTE ON SCHEMA::dbo TO claude_reader`**, dopočítat
`Valuo_karta_okoli` pro 822 zbývajících k. ú. a zapojit obě procedury na
konec `30_import_valuo.py --prepocty`.

**Vzorové karty** jsou ve složce `karty\`: Písnice (9 řadových domů, 13 parcel),
Štěrboholy (běžný dům), Jablonec (jeden z 518 bez výměry), Libuš (dům + garáž,
`NELZE`). Mapa běží v nativním S-JTSK, viz `data/ROZHODNUTI.md`.

### 1b. Drobnosti k vyřízení

| Co | Rozsah |
|---|---|
| **dvojice typu A (25 vkladů)** | stavba + parcela se stavbou jako součástí, obě jako „budova"; nejsou duplicity, vklad je `NELZE`. Znalec si přeje o nich dál jednat. |
| **`UQ_Valuo_zaznam` přestavět na klíč totožnosti** | duplicit je 0, index by šel založit; popis je dlouhý, index by stál na počítaném otisku popisu. Znalec si přeje dál jednat. |
| **mapa `23c_mapa_prevodu.py`** | neví o detektoru `CENA`, jeho 121 skupin v ní nejde zatřídit |
| **`CIS_metrika_ceny` nepokrývá všechny druhy budov** | stavba technického a občanského vybavení, budova s č. e., průmyslový objekt, stavba pro výrobu a skladování → výchozí `CELEK`; znalec si přeje dál jednat |
| chybějící skripty ve složce | `01`, `02`, `05`, `06`, `23` nejsou na disku |
| mez `pomer_pp_op` | výchozí 0,35 a 1,50 jsou odvozené z rozdělení, ne z praxe |
| garáže v detektoru `CENA` | Ruzyně 2023 — 136 stání po 300 000 Kč; developerský prodej, k rozhodnutí zda `TRH` |
| 113 vadných souřadnic | posazené na střed katastrálního území |
| zálohy | v DB jsou jen `KN_parcel_data_zaloha_23g`, `zaloha_prahy_pred_28`, pět `zaloha_30a_*`, dvě `zaloha_30b_*` a `zaloha_definice`; smazat, až bude revize potvrzená praxí |
| `geometry` v `KN_parcel_data` | prázdný sloupec, ke zrušení |
| 14 parcel bez geometrie | 4 v Krči mají `id_UP_FVU_data` ze staršího zpracování |
| kontrola skupin FVU proti ÚP | zatřídění dělal Claude podle cenových hladin |
| obnova RÚIANu | `RUIAN_obce_stav` drží datum u každé obce; `--ruian` hlásí obce starší 180 dní |
| kontrolní mediány (oddíl 4b) | přepočítat po kroku 30 |

### 2. Do budoucna

#### Roční mediány — odloženo 23. 10. 2026

Deflace vzorku na datum ocenění, pohled `v_mediany_rok` s mediánem pro
kombinaci rok × klíč × území. **Pro hodnocení to naléhavé není, pro
posudek je to metodicky nutné** — vzorek z roku 2022 nelze porovnat
s datem ocenění 2026 bez přepočtu.

**Důvody odkladu, na kterých se znalec a Claude shodli:**

1. **Veřejné indexy jsou pro posudek obhajitelnější než vlastní.** ČSÚ
   publikuje indexy realizovaných cen bytů čtvrtletně, k tomu Deloitte
   Real Index a HB Index. U soudu je odkaz na ČSÚ silnější pozice než
   vlastní výpočet, který by znalec musel obhajovat metodicky.
2. **Vlastní index má smysl jen tam, kam veřejné nedosáhnou** — konkrétní
   k. ú., konkrétní druh, konkrétní pásmo stáří. A na tuhle podrobnost
   data zatím nestačí: **kombinace rok × k. ú. projde práh 30 bodů jen
   u 8,4 %.** Vznikl by index v podrobnosti, jakou ČSÚ nabízí taky, jen
   hůř podložený.
3. **Dá se dopočítat kdykoliv a s víc daty bude lepší.** Je to čistě
   přírůstková věc, nic na ní nestojí.

**Kdy to pořadí přehodnotit:** jestli přijde zpětné ocenění rodinného
domu nebo pozemku k minulému datu. Tam veřejné indexy pokrývají trh
nejslaběji a vlastní by se vyplatil. Rozšíření vzorku ze tří na šest
let dělá u rodinných domů 1,48× bodů a u bytových domů 1,79×.

**Co se do té doby nesmí zapomenout:**

- Teprve po kroku 29 by to vyšlo správně — z neočištěných dat by index
  pro Stodůlky stál na mediánu 6 436 Kč/m² místo 108 313.
- S rokem dokončení z RÚIANu je nově možné oddělit **stáří stavby** od
  **data prodeje**; to veřejné indexy nenabízejí.
- **Cenový pohyb je jednotnější než cenová hladina** — naměřeno
  u pražských bytů 2023→2024: Smíchov 1,154, Žižkov 1,127, Modřany
  1,144. Index proto počítat na úrovni, kde jsou data, a hladinu brát
  lokálně.
- **Pozor na efekt skladby.** Medián Smíchova klesl z 158 413 (2024) na
  155 969 (2025); pravděpodobně se změnilo, co se prodávalo, ne cena.
  Index počítaný z mediánů to neumí odlišit.

#### Ostatní

| Téma | Co to vyžaduje |
|---|---|
| **Metropolitní plán Prahy** | `UP_FVU_data` obsahuje jen původní pražský ÚP z roku 1999 (PUP_2501), navázaný prostorově přes polygony. Stejným způsobem zapracovat i nový Metropolitní plán. Nejprve ověřit dostupnost podkladů. Územní plány mimo Prahu se řešit nebudou. |
| **Dotaz na podporu Valuo** | význam hodnot `typ_plochy`, plnění `adresa` u parcel, proč je u některých rodinných domů podlahová plocha a u jiných výměra parcely; **proč se plocha jednotky z podílu liší mezi balíčky** a proč se změnil formát popisu budov. |

### Nálezy, s nimiž už nic nejde dělat

| Téma | Rozsah |
|---|---|
| **989 řádků bez parcely** (0,9 %, 451 vkladů) | parcely v katastru dnes neexistují nebo jde o PK/GP |
| **Dva vklady s chybnou měnou** | V-86065/2019-101 a V-26440/2025-101 |
| **Spoluvlastnické podíly u jednotek** | 1 280 bytů s cenou pod 5 % mediánu; velikost podílu data neobsahují |
| **Medián „jiný nebytový prostor"** | druh míchá kanceláře se sklepy; záchyt na krajské hladině je u něj proto vypnutý (oddíl 4e) |
| **Domovní přípojky v DTM bývají prázdné** | není chyba zapojení: při témže výřezu vrátily sítě 52 647 B a přípojky 1 096 B, tedy průhledný obrázek. Obce a vlastníci tuto část DTM předali zatím nejméně. |

**Nenalezené parcely jsou parcely, které v katastru dnes neexistují.**
Doložený případ: ve Střížkově existuje parcela 802 o 3 434 m², ale parcely
803 až 814 (dvanáct po ~285 m², součet 3 420 m²) ne. Prodeje se
uskutečnily na parcelách vymezených geometrickým plánem pro novou
zástavbu. **U developerských projektů tedy data obsahují parcelní čísla,
která v katastru nedohledáš, a není to chyba dat ani skriptu.** U čerstvých
balíčků je jich málo — v druhé dávce kroku 30 jen 3 z 3 249.

### Známá omezení dat

- Katastr poskytuje **aktuální** stav parcel. U 21 595 vazeb (14,6 %) se
  parcela po prodeji změnila (průměrně o 550 dní).
- U 4 195 parcel (3,1 %) se plocha z geometrie liší od výměry v katastru
  o víc než 20 %. Odchylky tvoří U-křivku podle velikosti parcely: do
  50 m² 11,54 %, 50–200 m² 0,56 %, 200–1 000 m² 1,03 %, 1 000–5 000 m²
  2,99 %, nad 5 000 m² 11,35 %. Není to systematická chyba — proto se
  označuje, neopravuje.
- **Stav nemovitosti data neobsahují ani po krocích 27 a 28.** Stáří
  a konstrukci už ano u většiny vkladů, ale provedení, kvalita a stav
  chybí.
- Rodinné a bytové domy jsou v datech tenké: 3 506 záznamů na 130 území
  (k 23. 10. 2026).
- **Výměra pozemku u rodinných domů ve vzorku neúplná** — 518 vkladů ji
  nemá, protože Valuo vede parcelu se stavbou jako součástí jako budovu
  (oddíl 3). Do zavedení karty vkladu ji ber z `KN_parcel_data`.

---

## 9. Pracovní soubory

Skripty revize jsou ve složce `E:\DATA_ANALYSIS\REVIZE DB VALUO`.
Claude do ní má přístup a ukládá tam i to, co spustí sám.

| Krok | Soubor | Co dělá |
|---|---|---|
| 1 | `01_indexy.sql`, `01b_oprava_typu.sql` | PK, indexy, typy sloupců |
| 2 | `02_geografie.sql`, `02b_oprava_gps.sql`, `02c_prechod_na_katastr.sql`, `02d_kod_ku.sql`, `02e_oprava_UP_polygonu.sql` | souřadnice, `kod_ku`, polygony ÚP |
| 3 | `03b_kn_reprojekce.py`, `03d_oprava_orientace.sql` | reprojekce polygonů parcel |
| 4 | `04_import_ciselniku.py`, `04_ciselnik_napojeni.sql` | číselník ČÚZK |
| 5 | `05_jednotkova_cena.sql` | klasifikace vkladů |
| 6 | `06_kvalita_vzorku.sql` | rozsahy ploch, příznaky |
| 7 | `07_finalni_priznaky.sql`, `07a_oprava_meny.sql`, `07c_metrika_ceny.sql`, `07d_oprava_hladin.sql` | cenové hladiny a metriky |
| 9 | `09_parcely_UP_kompletni.py` | zatřídění parcel do ÚP s podíly — **nahrazeno krokem 30** |
| 10 | `10_uklid_KN_parcel_data.sql`, `10b_dokonceni_uklidu.sql`, `10c_slouceni_kod_ku.sql` | úklid struktury |
| 11 | `11_uklid_Valuo_data.sql` | `typ_prevodu`, `LAT`/`LON` |
| 12 | `12_oprava_prohozenych_datumu.sql`, `12b_oprava_podani.sql` | datumy |
| 13 | `13_typ_prevodu_do_vzorku.sql` | `typ_prevodu` do pohledů |
| 14 | `14_odstraneni_duplicit.sql` | duplicitní parcely |
| 15 | `15_priznak_vymery.sql` | příznak shody výměry |
| 16 | `16_deduplikace_valuo.sql` | duplicitní záznamy Valuo |
| 17 | `17a_doplneni_seznamu.sql`, `17_oprava_parcel.py`, `17b_geografie.py` | přetažení parcel ze správného území — **nahrazeno krokem 30** |
| 18 | `18_dokonceni_po_pretazeni.sql` | souřadnice z nových parcel — **převzato do kroku 30** |
| 19 | `19_kurzy_CNB.py`, `19b_prepocet_men.sql` | kurzy ČNB a přepočet měn |
| 20 | `20_metriky_staveb.sql`, `20a_oprava_ciselniku.sql` | jednotková cena staveb |
| 21 | `21_prah_hladin.sql`, `21a_oprava_hladin.sql` | práh hladin do číselníku |
| 22 | `22_oddelene_vlastnictvi.sql`, `22a_oprava_detektoru.sql` | oddělené vlastnictví |
| 23 | `23_hromadne_prevody.sql`, `23b_zatrideni_prevodu.sql`, `23h_doplneni_seznamu.sql`, `23i_oprava_zatrideni.sql` | detekce a zatřídění hromadných převodů |
| 23 | `23c_mapa_prevodu.py` | mapa pro zatřiďování |
| 23 | `23e_cisla_jednotek.sql`, `23e_oprava_indexu.sql` | označení jednotky z popisu |
| 23 | `23f_oprava_parseru_podilu.sql` | oprava parseru čitatele podílu |
| 23 | `23g_cizi_parcely.py` | odstranění cizích parcel |
| 24 | `24_prahy_vypocet.sql`, `24a_pozemky_granularita.sql`, `24c_mez_podilu.sql`, `24d_oprava_prahu.sql` | meze spočítané z dat |
| 24 | `24b_vypisy.sql`, `24e_oprava_vklad_UP.sql` | výpisy, oprava přiřazení ÚP |
| 25 | `25_audit_db.sql` | audit databáze |
| 26 | `26_zapojeni_prahu.sql` | hodnocení čte meze z `Valuo_prahy` |
| 27 | `27_ruian_tabulky.sql` | tabulky a pohledy pro RÚIAN |
| 27 | **`27_ruian_import.py` (verze 27.7)** | stažení, parsování a import TEA **i parcel s geometrií** |
| 27 | `27a_oprava_jednotek.sql` | oprava párování jednotek přes parcelu |
| 28 | `28_ruian_do_vzorku.sql` | pásma stáří, parametry, `v_RUIAN_vzorek` |
| 28 | `28a_oprava_pohledu.sql` | oprava `v_RUIAN_budovy` po zrušení sloupce |
| 28 | `28b_stari_a_kubatura.sql` | stáří do mezí, metrika `M3` |
| 29 | `29_detektor_dle_ceny.sql` | detektor podle celkové ceny vkladu |
| 29 | `29a_mez_trzni_hladina.sql` | záchytná mez vůči krajskému mediánu |
| 29 | `29b_pamet_prahu.sql` | limit paměti serveru, cyklus po klasifikacích |
| 29 | `29c_definice.sql` | **záloha definic z SSMS** — `v_Valuo_vzorek_q`, `sp_prepocet_prahu`, `v_RUIAN_vzorek`, `sp_prepocet_ruian_vzorku`, `v_RUIAN_budovy`, `v_RUIAN_jednotky`, oba detektory |
| **30** | **`30_import_valuo.py` (verze 30.3)** | **kompletní import: excely → katastr → ÚP → RÚIAN → přepočty** |
| 30 | `30_POSTUP_IMPORTU.md` | návod k importu — zdroj pravdy pro `data/POSTUP_import.md` |
| 30 | `30a_odstraneni_rannich_duplicit.sql` | odstranění 862 duplicit z ranního běhu 24. 10.; vzor pro vrácení dávky |
| 30 | `30b_odstraneni_starych_duplicit.sql` | odstranění 8 starých duplicit (typ B); vzor pro smazání jednotlivých řádků |
| 31 | `31_pravo_stavby.sql` | klasifikace `PRAVO_STAVBY` a hodnocení `právo stavby`; záloha definic do `zaloha_definice` |
| **32** | **`32_ruian_parcely.sql`** | **tabulky `RUIAN_parcely` a `RUIAN_parcely_bpej`, půdorysy staveb, evidence varianty; prostorové indexy jsou v oddílu 32.5 a zakládají se až po naplnění** |
| 33 | — (běh `27_ruian_import.py --import`) | import 687 obcí: 4 699 350 parcel, 2 686 626 dílů BPEJ, 1 193 394 staveb; log `27_geometrie_<datum>.csv` |
| — | `_definice\definice_20261025.sql` | **úplné definice všech 24 objektů po krocích 45 a 46 a po opravě mapy** (25. 10. 2026, 149 988 B) — aktuální stav; závazné znění `sp_prepocet_mapy` a `sp_prepocet_ploch` je zde, ne v `39_mapa_data.sql` |
| — | `_definice\definice_20261024.sql` | definice 10 pohledů a 7 procedur po kroku 31 — předchozí stav; nahradilo `29c_definice.sql` |
| **34** | **`34_karta_vkladu.sql`** | **karta vkladu: pět tabulek, dvě procedury, pohled `v_Valuo_karta_vkladu`** |
| 34 | `karty\karta_*.html` | čtyři vzorové karty; z nich vznikne šablona serveru |
| 35 | `35_export_word.py` | karta do .docx v `SABLONA_MASTER.docx`, mapy v tiskovém rozlišení, popisky parcel |
| 36 | `36_oprava_view_a_tvar.sql` | oprava jednotkové ceny u jednotek, `sp_prepocet_karty_tvar`, `sp_prepocet_karet_davka` |
| 37 | `37_karta_html.py` | karta jako HTML přímo z databáze; datovou vrstvu sdílí s krokem 35 |
| 38 | `38_prepocty.py` | dávkové plnění pěti kroků (okolí, karty, tvar, **plochy, mapa** — v tomto pořadí), přerušitelné, se zastavením při zacyklení |
| 39 | `39_mapa_data.sql` | `Valuo_mapa` a `sp_prepocet_mapy` |
| 40 | `40_aplikace.py` | mapová aplikace — server a stránka; `python 40_aplikace.py`, `http://localhost:8000/` |
| **41** | **`41_rucni_zjisteni.sql`** | **ruční zjištění znalce: `CIS_nalezy`, `Valuo_vklad_rucne`, `Valuo_vklad_nalezy`, `Valuo_poznamky`, přepsaný pohled s přednostní ruční plochou** |
| 42 | `42_export_definic.py` | záloha definic všech pohledů a procedur do `_definice\`; **pouští znalec**, viz `data/ROZHODNUTI.md` |
| **43** | **`43_oprava_geo_bodu.sql`** | **oprava bodu vkladu: 8 428 řádků ve 36 k. ú.; zálohy a trvalá podmínka do importu 30.4** |
| **44** | **`44_plochy_zdroje.sql`** | **registr zdrojů plochy, zlomky podílu, kontrola posunu desetinné čárky, přepsaný pohled** |
| **45** | **`45_plochy_po_radcich.sql`** | **registr ploch po řádcích (`pouzito`), `CIS_jednotka_typ`, `Valuo_vklad_plocha`, nosná nemovitost u jednotek, dva svědci přepisu škály, medián Kč/m² po k. ú. (`CIS_ku_median_jc`)** |
| **46** | **`46_nosna_nemovitost.sql`** | **`CIS_nemovitost_typ` (33 typů), nosná nemovitost u budov a pozemků, nosná výměra, nálezy „více nosných" a „nosná bez plochy"; oddíl 7 = oprava jediného vlastníka `Valuo_mapa`** |
| — | `30_POSTUP_IMPORTU.md` | návod k importu, verze 30.6; kopie v Kontextu jako `data/POSTUP_import.md` |
| — | `ROZHODNUTI_DATA.md`, `STAV_DATA.md` | záložní kopie dokumentů z Kontextu |

`30_import_valuo.py` má režimy `--inventura`, `--import`, `--parcely`,
`--up`, `--ruian`, `--prepocty`, `--vse` a přepínače `--slozka`,
`--server`, `--limit`, `--podrobne`, `--verze`. Je restartovatelný ve všech
etapách. Logy zakládá vedle sebe: `30_odmitnute_<datum>.csv`,
`30_katastr_<datum>.csv`, `30_ruian_obce_<datum>.csv`.

`23c_mapa_prevodu.py` má `--diagnostika <KU>`.

`27_ruian_import.py` (verze 27.7) se nekonfiguruje a k databázi se hlásí
účtem Windows. Soubory bere z `…\DATA_KN\RUIAN obce` z podsložky podle
varianty (`UZSZ`, `UKSH`); výchozí varianta je **UKSH**. Režimy:
`--seznam-obci`, `--rozpocet` (HEAD bez stahování), `--stahni auto`,
`--ciselnik`, `--test`, `--import`, `--parovani`, `--verze`. Výběr obcí:
`--kraj`, `--okres`, `--s-vklady`, `--vcetne-stazenych` (volby se sčítají
a platí i pro import). Další přepínače: `--slozka`, `--server`, `--obec`,
`--varianta`, `--bez-parcel`, `--jen-nove`, `--csv`.

Chyba jedné obce import nezastaví — obec se vrátí celá, zapíše se do logu
a dávka pokračuje; dohnat ji lze `--import --jen-nove` se stejným výběrem.

**Stažené soubory VFR nepatří do gitu** — jsou to desítky až stovky MB
a dají se kdykoli stáhnout znovu. Buď je stahuj mimo repozitář
(`--slozka`), nebo je dej do `.gitignore` **dřív**, než začneš stahovat.

**Objekty, které vznikly přes připojení Claude, nejsou na disku samy od
sebe.** Dokud se nevyexportují z SSMS (Tasks → Generate Scripts) do
očíslovaného skriptu, existují jen v databázi. Proto `29c_definice.sql`.
Krok 30 žádný pohled ani proceduru neměnil. **Krok 31 změnil
`sp_prepocet_jednotkovych_cen` a `v_Valuo_vzorek_q`**; definice před
změnou jsou v tabulce `zaloha_definice` (sloupce `objekt`, `krok`,
`definice`, `ulozeno`), změna sama v `31_pravo_stavby.sql`.

**Od 24. 10. 2026 exportuje definice Claude sám** — po každé změně
pohledu nebo procedury všechny najednou do `_definice\definice_RRRRMMDD.sql`
(oddíl 0). Ruční export z SSMS už není potřeba. První export:
`definice_20261024.sql`, 17 objektů, ověřeno součtem délek proti databázi
(38 783 + 27 073 znaků).

Nepoužívat (nahrazeny novějšími): `03_kn_reprojekce.py`,
`03c_oprava_orientace.sql`, `05_cenova_spolehlivost.sql`,
`05_cenova_metodika.sql`, `06_detekce_odlehlych.sql`,
`07_hladiny_a_priznaky.sql`, `07_hladiny_dle_UP.sql`,
`07b_hladiny_dle_druhu.sql`, `08_prirazeni_UP_opraveno.py`,
`17_oprava_parcel_z_katastru.py`, `20_pozemek_se_stavbou.sql`, a od
kroku 30 také `09_parcely_UP_kompletni.py`, `17_oprava_parcel.py`,
`17b_geografie.py` (pro nová data; jako dokumentace zůstávají).

Skripty s příponou „a" opravují chybu v předchozím kroku a musí se pustit
po něm; samy předchozí krok nenahrazují, jen doplňují.

### Zálohy v databázi

Ověřeno 24. 10. 2026 — v databázi existují jen tyto:

| Tabulka | Řádků | Z kroku |
|---|---|---|
| `KN_parcel_data_zaloha_23g` | 13 040 | 23g |
| `zaloha_prahy_pred_28` | 308 | 28 |
| `zaloha_30a_valuo` | 862 | 30a |
| `zaloha_30a_kn_parcel` | 938 | 30a |
| `zaloha_30a_kn_up` | 847 | 30a |
| `zaloha_30a_up_stav` | 762 | 30a |
| `zaloha_30a_fronta` | 862 | 30a |
| `zaloha_30b_valuo` | 8 | 30b |
| `zaloha_30b_kn_parcel` | 8 | 30b |
| `zaloha_definice` | 2 | 31 — `v_Valuo_vzorek_q` a `sp_prepocet_jednotkovych_cen` před změnou |

Dřívější zálohy uváděné v tomto dokumentu (`zaloha_datumy_20261022`,
`zaloha_gps_api_20261022`, `zaloha_duplicity_20261022`, `zaloha_geo_18`,
`zaloha_valuo_duplicity_20261022`, `oprava_gps_20261022`) v databázi
nejsou. Nemazat zbylé, dokud nebude revize potvrzená praxí.
