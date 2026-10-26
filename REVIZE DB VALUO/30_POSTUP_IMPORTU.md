# Postup importu nových dat do DB VALUO

Návod ke skriptu `30_import_valuo.py` **verze 30.6**. Platí pro každou novou
dávku excelů z Valua, ne jen pro jednu konkrétní.

Umístění skriptu: `E:\DATA_ANALYSIS\REVIZE DB VALUO\30_import_valuo.py`

> **Údržba tohoto dokumentu.** Zdrojem pravdy je soubor
> `30_POSTUP_IMPORTU.md` ve složce REVIZE DB VALUO vedle skriptu;
> `data/POSTUP_import.md` v Kontextu je jeho kopie. Mění-li se
> `30_import_valuo.py` způsobem, který mění postup, přepisuje se obojí.
> Drobnosti, které postup nemění, se nepřenášejí — zápis do Kontextu
> zneplatní prompt cache všem chatům projektu.
>
> Poslední aktualizace: 25. 10. 2026 — verze 30.6. Proti 30.3 přibylo:
> **bod vkladu se sám hojí** (30.4, krok 43), **upozornění na nedopočtené
> karty** (30.5) a **etapa `--dopocty`** (30.6), která pustí karty, mapu
> a registr zdrojů plochy jedním příkazem. Po krocích 41 až 44.
>
> *Pozn. 25. 10. 2026:* kopie na disku byla zastaralá (verze 30.2) proti
> Kontextu (30.3). Tímto zápisem jsou obě srovnané. Při každé další změně
> přepiš obojí najednou.

---

## 1. K čemu to je

Jeden skript provede celý řetězec: excely → katastr → územní plán
→ RÚIAN → přepočty → karty a mapa. Po doběhnutí je databáze kompletně
provázaná a přepočítaná včetně starých dat, protože **žádná ze sedmi
přepočtových procedur nepracuje inkrementálně** — všechny přepočítávají
celou `Valuo_data`.

### Co skript dělá

| etapa | příkaz | co udělá |
|---|---|---|
| 1 | `--inventura` | zjistí, které soubory ještě neprošly; **nic nemění** |
| 2 | `--import` | načte nové excely do `Valuo_data` |
| 3 | `--parcely` | dotáhne parcely z katastru včetně geometrie a promítne souřadnice a kód území do `Valuo_data` |
| 4 | `--up` | zatřídí nové pražské parcely do územního plánu |
| 5 | `--ruian` | spáruje na RÚIAN a vypíše chybějící obce |
| 6 | `--prepocty` | spustí sedm procedur v závazném pořadí |
| 7 | `--dopocty` | karty vkladu, podklad mapy a registr zdrojů plochy |
| — | `--vse` | všech sedm za sebou |

Etapa 7 je nejdelší (u plné databáze hodiny), ale **přerušitelná
a navazující**. Dá se fázovat přepínačem `--krok`:

```
python 30_import_valuo.py --dopocty --krok karty
```

Hodnoty: `okoli`, `karty`, `tvar`, `mapa`, `plochy`, `vse`. Totéž umí
i samostatný `38_prepocty.py`, který etapa 7 uvnitř volá — logika je
na jednom místě, aby se obojí nemohlo rozejít.

### Co skript nedělá

- **Nestahuje ani neimportuje RÚIAN.** Jen řekne, které obce
  chybí. Stahování zůstává na `27_ruian_import.py` — RÚIAN má
  jinou kadenci i granularitu, stahuje se po obcích nezávisle
  na tom, kdy přijdou nové excely.
- **Nestahuje kurzy ČNB.** Na to je `19_kurzy_CNB.py`.
- **Nikdy nemaže data.** Jediná výjimka: u vkladu, kterému se podařilo
  stáhnout nové parcely, se staré vazby parcel nahradí — stejně jako
  v kroku 17.
- **Přepisuje jen tři sloupce `Valuo_data`:** `geo_bod`, `geo_zdroj`
  a `kod_ku`, a to z největší parcely vkladu. Bez nich vzorek nové řádky
  nevidí.
- **Nikdy nesahá na ruční zjištění znalce.** Tabulky `Valuo_vklad_rucne`,
  `Valuo_vklad_nalezy` a `Valuo_poznamky` jsou mimo dosah importu
  i přepočtů. Ověřená plocha má přednost i po novém importu.

> **Od verze 30.4 se bod vkladu sám hojí.** Dřívější podmínka
> přeskakovala každý řádek, který už měl `geo_zdroj = 'KN_refPoint'`,
> a tím konzervovala 8 428 řádků se špatným bodem — průměrně o 1 150 m
> vedle, nejvíc o 3 672 m, ve 36 katastrálních územích na pouhých
> 43 různých bodech. Nově rozhoduje obsah, ne štítek: kdykoli bod
> neodpovídá největší parcele řádku, přepíše se. Zůstává idempotentní —
> podruhé nezmění ani řádek, takže **počet změněných řádků v logu je nově
> užitečný signál „kolik bodů se posunulo"**. Jednorázovou opravu
> dosavadních dat udělal krok 43.

---

## 2. Než začneš

**Zálohuj databázi.** Skript zálohu nedělá.

**Kam dát nové excely:** kamkoli pod
`C:\Users\ijttr\OneDrive\Dokumenty\OCEŇOVÁNÍ\_GEO_DATA_VALUE_MAPS\VALUO\data_strukturovana`

Složka se prochází rekurzivně, na vnoření nezáleží. Nejpřehlednější
je nový číslovaný podadresář. **Na názvu souboru nezáleží** —
soubory se poznávají podle otisku SHA-256 obsahu, protože
`cadastre_report_5_2024 (1).xlsx` a `...(2).xlsx` jsou různé
balíčky, ne kopie.

**Jinou složku** lze předat přes `--slozka`, jiný server přes
`--server`.

**Souběh:** nové soubory můžeš kopírovat i během běhu etapy
katastru. Seznam souborů se čte jen na začátku etapy importu.

**Nepouštěj dva běhy dopočtů současně** — oba sahají na pohled
`v_Valuo_karta_vkladu` a navzájem si překážejí až k vypršení dotazů.

**Než začneš, poznamenej si počet vkladů ve vzorku** — budeš ho
potřebovat na konci jako hlavní kontrolu:

```sql
SELECT COUNT(*) AS vkladu_ve_vzorku FROM dbo.v_Valuo_vzorek_q;
```

---

## 3. Postup krok za krokem

### Krok 1 — Inventura

```
python 30_import_valuo.py --inventura
```

Sekundy. Nic nemění, jen spočítá otisky a porovná s evidencí.

**Kontrola: počet musí odpovídat tomu, kolik souborů jsi přidal.**

Hlásí-li víc, znamená to, že se změnil obsah některého staršího
souboru (Valuo přepsalo balíček). Zastav se a zjisti který:

```sql
SELECT cesta, radku, vlozeno, nacteno
FROM dbo.Valuo_soubory ORDER BY nacteno DESC;
```

Duplicitu to nezpůsobí — klíč totožnosti si poradí — ale je dobré vědět,
že zdroj není stabilní.

### Krok 2 — Import excelů

```
python 30_import_valuo.py --import
```

Minuty. Čte po dávkách 50 souborů, každá dávka je jedna transakce.

Souhrn na konci vysvětluje:

| řádek | význam |
|---|---|
| `radku_nacteno` | kolik řádků bylo v souborech |
| `duplicita_v_davce` | tentýž záznam přišel ve dvou balíčcích jedné dávky |
| `jiz_v_databazi` | záznam v databázi už byl, přeskočeno |
| `vlozeno` | **kolik skutečně přibylo** |
| `vyrazeno_*` | vyhozeno filtrem validity (viz část 5) |
| `odmitnuty_radek` | nečitelný řádek, podrobnosti v CSV |

**Kontrola duplicit — musí vyjít 0** (od kroku 30b, 24. 10. 2026):

```sql
SELECT COUNT(*) AS kolizi
FROM (SELECT 1 AS x FROM dbo.Valuo_data
      GROUP BY cislo_vkladu, nemovitost, typ, adresa,
               ISNULL(jednotka_oznaceni, N''),
               ISNULL(popis, '')
      HAVING COUNT(*) > 1) g;
```

**Pozor: duplicity se nekontrolují pěticí s plochou.** Dotaz
`GROUP BY cislo_vkladu, adresa, nemovitost, typ, plocha` vrací nulu
i tehdy, když v databázi duplicity jsou — má stejnou slepou skvrnu,
jakou měl import do verze 30.1 (viz část 5).

**Co přibylo:**

```sql
SELECT COUNT(*) AS radku, COUNT(DISTINCT cislo_vkladu) AS vkladu,
       MIN(datum_zplatneni) AS od, MAX(datum_zplatneni) AS do
FROM dbo.Valuo_data
WHERE CAST([timestamp] AS date) = CAST(GETDATE() AS date);
```

**Přibudou-li řádky, ale žádný nový vklad, zbystři.** Může jít o doplnění
chybějící nemovitosti, ale 24. 10. 2026 to byly výhradně duplicity v jiné
podobě. Ověř kontrolou duplicit výše, než budeš pokračovat.

### Krok 3 — Parcely z katastru

```
python 30_import_valuo.py --parcely
```

**Nejdelší etapa importu. Počítej 1 až 3 sekundy na vklad** — 2 360 vkladů
trvalo 41 minut. Fronta na začátku řekne, kolik jich je.

Chceš-li napřed vyzkoušet, že katastr odpovídá:

```
python 30_import_valuo.py --parcely --limit 20
```

Naplní frontu celou, ale zpracuje jen 20 vkladů.

Na konci etapy skript **promítne souřadnice a kód území do `Valuo_data`**
— řádek *„Souřadnice a kód území promítnuty do Valuo_data: N"*. Bez toho
by vzorek nové řádky neviděl. Od verze 30.4 je to číslo zároveň počet
bodů, které se posunuly (viz rámeček v části 1).

**Kontrola geometrie — všechny tři sloupce musí být 0:**

```sql
SELECT COUNT(*) AS parcel,
  SUM(CASE WHEN k.geo_plocha IS NULL THEN 1 ELSE 0 END) AS bez_geometrie,
  SUM(CASE WHEN k.geo_plocha.STArea() > 1e10 THEN 1 ELSE 0 END) AS obracenych,
  SUM(CASE WHEN k.geometry IS NOT NULL THEN 1 ELSE 0 END) AS stary_sloupec
FROM dbo.KN_parcel_data k
JOIN dbo.KN_k_pretazeni q ON q.id_valuo = k.id_valuo
WHERE q.duvod = 'IMPORT30';
```

(`KN_parcel_data` nemá sloupec s datem vložení; nové parcely se poznají
přes frontu.) `obracenych` nad nulou by znamenalo obrácený ring polygonu
— `geography` pak vrací plochu kolem 510 000 000 000 000 m². Skript to
sám kontroluje a opravuje, takže by to vyjít nemělo.

**Kontrola souřadnic a kódu území — doplnitelných musí být 0:**

```sql
SELECT
  SUM(CASE WHEN geo_bod IS NULL THEN 1 ELSE 0 END) AS bez_souradnice,
  SUM(CASE WHEN kod_ku IS NULL AND geo_zdroj = 'KN_refPoint' THEN 1 ELSE 0 END) AS doplnitelnych_bez_kod_ku
FROM dbo.Valuo_data
WHERE CAST([timestamp] AS date) = CAST(GETDATE() AS date);
```

`bez_souradnice` smí být nenulové jen u vkladů, jejichž parcela se
nenašla (zaniklá parcela, PK/GP).

**Kontrola, že bod sedí na vlastní parcelu** (od kroku 43; musí být 0):

```sql
WITH r AS (
  SELECT v.id, v.geo_bod.Lat AS la, v.geo_bod.Long AS lo
  FROM dbo.Valuo_data v WHERE v.geo_bod IS NOT NULL
), m AS (
  SELECT r.id, MAX(CASE WHEN ABS(k.refPoint_lat - r.la) < 0.000001
                         AND ABS(k.refPoint_lon - r.lo) < 0.000001
                        THEN 1 ELSE 0 END) AS sedi
  FROM r JOIN dbo.KN_parcel_data k ON k.id_valuo = r.id
  WHERE k.refPoint_lat IS NOT NULL
  GROUP BY r.id
)
SELECT COUNT(*) AS bod_nesedi_na_zadnou_vlastni_parcelu FROM m WHERE sedi = 0;
```

### Krok 4 — Územní plán

```
python 30_import_valuo.py --up
```

Sekundy. Týká se **jen Prahy** — územní plán je v `UP_FVU_data` jen
pro ni. Počítá se jen pro parcely, které zatřídění ještě nemají;
tabulka se nemaže.

```sql
SELECT
  (SELECT COUNT(DISTINCT kn_id) FROM dbo.KN_parcel_UP) AS zatridenych,
  (SELECT COUNT(*) FROM dbo.KN_parcel_UP_stav WHERE ploch = 0) AS bez_pruniku,
  (SELECT COUNT(*) FROM dbo.KN_parcel_data k
   JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
   WHERE c.kraj_nazev = N'Hlavní město Praha' AND k.geo_plocha IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_UP_stav s
                     WHERE s.kn_id = k.id)) AS zbyva;
```

`zbyva` musí být 0. `bez_pruniku` jednotky — jsou to parcely na
okraji Prahy, kde plán nekončí přesně na hranici katastru.
Desítky a víc = problém s geometrií nových parcel.

### Krok 5 — RÚIAN

```
python 30_import_valuo.py --ruian
```

Vypíše dvě věci:

1. **Obce k dotažení** — kde máš budovu nebo jednotku a RÚIAN
   chybí (`CHYBI`) nebo je starší než 180 dní (`ZASTARALE`).
   U obcí jen s pozemky nemá RÚIAN co nabídnout.
2. **Vklady bez údajů z RÚIANu** — konkrétní stavby bez napojení.

Výstup jde do konzole, do CSV `30_ruian_obce_<datum>.csv`
a do tabulky `dbo.RUIAN_k_pretazeni`.

**Druhé číslo se čte až po přepočtu.** Tabulka `RUIAN_vzorek` se plní
až v `--prepocty`, takže před nimi ukáže jako nenapojené **všechny** nové
vklady. Správné číslo dá druhé spuštění `--ruian` po přepočtech, nebo
tento dotaz:

```sql
SELECT v.nemovitost,
       COUNT(DISTINCT v.cislo_vkladu) AS novych_vkladu,
       COUNT(DISTINCT CASE WHEN r.cislo_vkladu IS NULL THEN v.cislo_vkladu END) AS bez_ruian
FROM dbo.Valuo_data v
LEFT JOIN dbo.RUIAN_vzorek r ON r.cislo_vkladu = v.cislo_vkladu
WHERE CAST(v.[timestamp] AS date) = CAST(GETDATE() AS date)
  AND v.nemovitost IN ('budova', 'jednotka')
GROUP BY v.nemovitost;
```

Vypsal-li obce k dotažení, dotáhni je **před** přepočty:

```
python 27_ruian_import.py --stahni <kódy oddělené čárkou>
python 27_ruian_import.py --import
```

Pozor na past: i když obec formálně „máš", stavby zkolaudované po datu
snapshotu v něm nejsou. Je-li po přepočtu mezi novými vklady hodně
nenapojených budov, má smysl obec přetáhnout a přepočty pustit znovu.

**RÚIAN je navíc opora registru ploch** (krok 44): bez podlahové plochy
budovy nejde u jednotky zkontrolovat posun desetinné čárky v podílu.
Chybějící obec tedy nestojí jen stáří a konstrukci stavby, ale i tuhle
kontrolu.

### Krok 6 — Kurzy ČNB

Jen pokud na to `--prepocty` upozorní:

```
python 19_kurzy_CNB.py
```

**Dělej to před přepočty.** `sp_prepocet_men` bere kurz ke dni
podání návrhu; chybí-li, zůstane vkladu prázdná `cena_Kc`
a tiše vypadne ze vzorku.

Ruční kontrola:

```sql
SELECT MAX(datum) AS posledni_kurz FROM dbo.CIS_kurzy_CNB;
SELECT COUNT(*) AS bez_kurzu FROM dbo.Valuo_data
WHERE mena <> 'CZK' AND cena_Kc IS NULL;
```

### Krok 7 — Přepočty

```
python 30_import_valuo.py --prepocty
```

**Pouštěj až po všech předchozích, jednou za všechno.** Při 110 tisících
řádků trvá kolem jedné až dvou minut. Na začátku se znovu promítnou
souřadnice a kód území (pojistka), pak běží procedury v závazném pořadí —
prahy čtou vzorek, vzorek čte klasifikaci a detektory:

1. `sp_prepocet_jednotkovych_cen` — klasifikace a plochy
2. `sp_prepocet_typu_prevodu` — dražba, dar, směna
3. `sp_prepocet_men` — `cena_Kc` z kurzů ČNB
4. `sp_detekce_hromadnych_prevodu` — detektor dle jednotkové ceny
5. `sp_detekce_prevodu_dle_ceny` — detektor dle celkové ceny
6. `sp_prepocet_ruian_vzorku` — RÚIAN na úroveň vkladu
7. `sp_prepocet_prahu` — meze z dat

**Hlavní kontrola celého importu:** počet vkladů ve vzorku (součet tabulky
hodnocení na konci výstupu) musí vzrůst **zhruba o počet nových vkladů**
proti číslu, které sis poznamenal na začátku. Nezmění-li se, přepočet
proběhl naprázdno — nové řádky nemají souřadnice nebo `kod_ku`.

**Druhá kontrola — porovnej rozložení hodnocení s předchozím stavem:**

```sql
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
```

Podíl „bez výhrad" se drží kolem 51 % (24. 10. 2026: 25 400 z 49 689).
Kategorie `právo stavby` (od kroku 31, 48 vkladů) se mění jen s novými
právy stavby. Výrazný skok v „nelze porovnat"
u **starých** vkladů znamená, že jim přibyla nemovitost navíc — skoro
jistě duplicita. Ověř:

```sql
WITH v AS (
  SELECT cislo_vkladu,
         MAX(CASE WHEN CAST([timestamp] AS date) < CAST(GETDATE() AS date) THEN 1 ELSE 0 END) AS mel_stare,
         MAX(CASE WHEN CAST([timestamp] AS date) = CAST(GETDATE() AS date) THEN 1 ELSE 0 END) AS ma_dnesni
  FROM dbo.Valuo_data GROUP BY cislo_vkladu)
SELECT CASE WHEN v.mel_stare = 1 THEN 'starý vklad, doplněný dnes' ELSE 'nový vklad' END AS skupina,
       q.hodnoceni_ceny, COUNT(*) AS vkladu
FROM v JOIN dbo.v_Valuo_vzorek_q q ON q.cislo_vkladu = v.cislo_vkladu
WHERE v.ma_dnesni = 1
GROUP BY CASE WHEN v.mel_stare = 1 THEN 'starý vklad, doplněný dnes' ELSE 'nový vklad' END,
         q.hodnoceni_ceny
ORDER BY skupina, vkladu DESC;
```

### Krok 8 — Dopočty karet, mapy a registru ploch

```
python 30_import_valuo.py --dopocty
```

**Nejdelší etapa vůbec.** U plné databáze hodiny, protože karty se
počítají rychlostí kolem 3,6 vkladu za vteřinu. U běžné dávky nových
vkladů jsou to ale minuty — počítá se jen to, co chybí.

Pět kroků v závazném pořadí:

| krok | procedura | co dělá |
|---|---|---|
| 1 | `sp_prepocet_karty_okoli` | prostorové vztahy mezi parcelami, po katastrálních územích |
| 2 | `sp_prepocet_karet_davka` | role parcel, komponenty, výměry — **ta dlouhá část** |
| 3 | `sp_prepocet_karty_tvar` | PP index sloučeného celku |
| 4 | `sp_prepocet_ploch` | zlomky podílu, registr zdrojů plochy **po řádcích**, nosná nemovitost u jednotek, budov i pozemků, nosná výměra, medián Kč/m² po k.ú. a skupině |
| 5 | `sp_prepocet_mapy` | plochý podklad pro mapovou aplikaci — **jediný vlastník** `Valuo_mapa`, běží jako poslední |

**Krok 5 čte od 25. 10. 2026 i `RUIAN_stavebni_objekty`**, protože bod
jednotek a budov leží na stavbě. Proběhne i bez nich (bod zůstane na
definičním bodě parcely), ale po importu nových obcí je potřeba nejdřív
`--ruian`, jinak nové vklady značku na stavbě nedostanou. Krok 5 taky stojí
na kartě z kroku 2, takže pořadí je závazné i z tohoto důvodu.

**Krok 4 varuje, přinese-li import nový typ nemovitosti.** Hlášení procedury
nese `typu_mimo_ciselnik`; není-li nula, vypíše skript, kolik typů chybí
v `CIS_nemovitost_typ`, a dotaz, kterým se najdou. Takový typ dostane
prioritu 99 a skupinu „ostatní" — nespadne to, ale nebude nikdy nosný a jeho
cena se nesrovná se správnou skupinou. Doplň ho do číselníku a pusť
`--dopocty --krok plochy` znovu.

**Pořadí měnit nelze a mapa musí být poslední.** Tvar počítá nad hotovými
kartami. Mapa čte pohled `v_Valuo_karta_vkladu`, který stojí na výsledcích
kroku 4 — proto jde až po něm.

Do kroku 46 bylo pořadí obrácené a `sp_prepocet_ploch` si na konci sama
dolepovala do `Valuo_mapa` plochu a příznaky. Tím se řádek mapy rozešel sám
se sebou: plocha z nového přepočtu vedle ceny a druhu ze starého. U vkladu
V-23039/2026-101 to dávalo bytovou jednotku vedenou jako „bytový dům" za
7 793 Kč/m², zatímco karta měla správných 130 864 Kč/m². Od kroku 46 je
`sp_prepocet_mapy` **jediným vlastníkem** `Valuo_mapa` a běží jako poslední.

Fronta mapy navíc bere i k. ú., kde je zdroj novější než řádek mapy
(`vp.kdy > m.prepocteno`). Bez té podmínky se po změně pohledu nebo po
přepočtu ploch mapa nepřepočítala vůbec — všechny vklady v ní už byly —
a stará chyba by v ní zůstala. Cílený přepočet jednoho k. ú. umí
`@kod_ku_jen`.

**Fázování, když něco spadne:**

```
python 30_import_valuo.py --dopocty --krok karty
python 30_import_valuo.py --dopocty --krok plochy
```

**Úplný přepočet** (i toho, co už hotové je) — třeba po změně prahů
v `CIS_karta_parametry`:

```
python 30_import_valuo.py --dopocty --prepocitat
```

**Kontrola:**

```sql
SELECT
  (SELECT COUNT(DISTINCT cislo_vkladu) FROM dbo.Valuo_data) AS vkladu,
  (SELECT COUNT(*) FROM dbo.Valuo_karta_vklad) AS karet,
  (SELECT COUNT(*) FROM dbo.Valuo_mapa) AS v_mape,
  (SELECT COUNT(*) FROM dbo.Valuo_plochy) AS radku_registru,
  (SELECT COUNT(*) FROM dbo.Valuo_podil_jednotky) AS zlomku_podilu,
  (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha) AS vkladu_s_nosnou,
  (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE plocha > 0) AS ma_podlahovou,
  (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha WHERE vymera_nosna > 0) AS ma_nosnou_vymeru,
  (SELECT COUNT(*) FROM dbo.CIS_ku_median_jc) AS medianu_ku,
  (SELECT COUNT(*) FROM dbo.Valuo_mapa WHERE nalez_skala = 1) AS nalezu_skala,
  (SELECT COUNT(*) FROM dbo.Valuo_mapa WHERE nalez_vice_nosnych = 1) AS vice_nosnych,
  (SELECT COUNT(*) FROM dbo.Valuo_mapa WHERE nalez_bez_plochy = 1) AS nosna_bez_plochy,
  (SELECT COUNT(*) FROM dbo.Valuo_mapa WHERE jc_verdikt = 'k prověření') AS cena_k_proverení;
```

Rozdíl mezi `vkladu` a `karet` jsou vklady **bez jediné parcely
z katastru** — ty kartu mít nemohou (25. 10. 2026 jich bylo 138).
Fronta si je proto nebere a řídicí skript se zastaví, přestane-li
počet zbývajících klesat; dřív se na nich dávka protáčela naprázdno
9,4 hodiny.

`nalezu_skala` jsou vzorky, kde se čitatel podílu přepočtený škálou domu liší od Valuovy plochy o celý řád. Přepíše se jen tam, kde je nezávislý doklad, která plocha je správná (25. 10. 2026: 57 ze 2 571); u ostatních zůstává Valuova a vzorek čeká na prověření v listině. `cena_k_proverení` jsou vzorky mimo pásmo mediánu své skupiny v katastrálním území — vodítko, ne závada.

**Posun desetinné čárky se od kroku 45 nehledá.** V datech nemá vrchol na násobku 10 a pásmo 6,7 až 15 nabíralo nesouvisející rozptyl; `Valuo_mapa.nalez_plocha_posun` se už neplní a zůstává nulový.

---

## 4. Co se může stát a co s tím

### Skript se zastavil na „ZMĚNA STRUKTURY"

Valuo změnilo hlavičku excelu. Skript **nezapsal nic** z té dávky
a vypsal, co našel.

Známé varianty: 16 sloupců (běžná) a 17 sloupců (navíc
`Plocha pozemku (v m2)`, zahazuje se — ověřeno, že se od
`Plocha (v m2)` neliší).

Doplň novou hlavičku do `ZNAME_HLAVICKY` ve skriptu a spusť znovu.
Co už prošlo, se podruhé nenačte. **Nikdy neřeš posunem sloupců
podle pořadí** — tichý posun by nasypal čísla do nesprávných polí.

### Běh spadl uprostřed

Spusť stejný příkaz znovu. Všechny etapy pokračují tam, kde
skončily:

- **import** — hotové dávky jsou v evidenci, nenačtou se podruhé
- **parcely** — zpracované vklady mají ve frontě `zpracovano = 1`
- **územní plán** — hotové parcely jsou v `KN_parcel_UP_stav`
- **dopočty** — každý z pěti kroků si bere jen to, co chybí; procedury
  mají vlastní časové stropy a po přerušení navazují

Rozpracovaná dávka se rollbackne celá, takže polovičatý stav
nevznikne.

### Dopočty běží a nic nepřibývá

Řídicí skript se sám zastaví s hláškou *„počet zbývajících se nemění"*.
Znamená to, že si fronta bere něco, co zpracovat nejde — typicky vklady
bez parcely z katastru. Ověř:

```sql
SELECT COUNT(*) AS vkladu_bez_parcely
FROM (SELECT DISTINCT cislo_vkladu FROM dbo.Valuo_data) d
WHERE NOT EXISTS (
  SELECT 1 FROM dbo.Valuo_data v
  JOIN dbo.KN_parcel_data k ON k.id_valuo = v.id
  WHERE v.cislo_vkladu = d.cislo_vkladu);
```

Jsou-li to tyhle, není co řešit — kartu mít nemohou. Má-li smysl zkusit
parcely dotáhnout znovu, vrať je do fronty (viz *Chci nechat vklad
dotáhnout znovu*) a pusť `--parcely`.

### Přepočet proběhl, ale vzorek se nezměnil

Nové řádky nemají `geo_zdroj = 'KN_refPoint'` nebo `kod_ku`, takže je
`v_Valuo_vzorek` nevidí. Od verze 30.1 se to doplňuje samo; stalo-li se
to přesto, ověř kontrolou souřadnic v kroku 3 a pusť `--prepocty` znovu.

### Import přidal řádky, ale žádné nové vklady — a „nelze porovnat" vyskočilo

Typický příznak duplicit v jiné podobě. Ověř kontrolou duplicit novým
klíčem (krok 2). Vzor, jak takovou dávku bezpečně odstranit včetně záloh
a všech navázaných tabulek, je `30a_odstraneni_rannich_duplicit.sql`.

### `ResourceClosedError: This result object does not return rows`

Dávka několika SQL příkazů bez `SET NOCOUNT ON` — ovladač vrátí
jako první výsledek hlášení o počtu řádků místo závěrečného
SELECTu. Ve skriptu je to ošetřené u `SQL_UP_DAVKA`
a `SQL_RUIAN_FRONTA`. Objeví-li se jinde, přidej na začátek dávky
`SET NOCOUNT ON;` a na konec `SET NOCOUNT OFF;` — nastavení jinak
zůstane na spojení z poolu a `.rowcount` pak všude vrací −1.

### Parcely se nenašly

U čerstvých balíčků je to desetiny procenta, u starších 5 až 9 %.
Důvody v souhrnu:

| hláška | co to je | řešitelné? |
|---|---|---|
| `nenalezeno` | parcela od data převodu zanikla dělením nebo sloučením; WFS vrací jen aktuální stav | ne |
| `PK_GP_neni_v_KN` | parcela zjednodušené evidence nebo grafický příděl | ne |
| `cizi_uzemi_odmitnuto` | katastr vrátil parcelu z jiného území, než říká popis — správně zahozeno | ne |
| `uzemi_neni_v_ciselniku` | název území z popisu není v `CIS_katastralni_uzemi` | **ano, prověř** |
| `bez_popisu`, `neznamy_tvar` | popis nejde rozparsovat | podle případu |
| `katastr_nedostupny` | WFS neodpověděl ani na tři pokusy | ano, spusť znovu |

`uzemi_neni_v_ciselniku` je skoro vždy chyba parsování, ne
chybějící území (24. 10. 2026: vnořené závorky, „Satalice )").
Zjisti popis a ověř název:

```sql
SELECT id, cislo_vkladu, popis FROM dbo.Valuo_data WHERE id = <id_valuo>;
SELECT ku_kod, ku_nazev FROM dbo.CIS_katastralni_uzemi
WHERE ku_nazev LIKE '%<část názvu>%';
```

Podrobnosti ke všem případům jsou v CSV `30_katastr_<datum>.csv`.

### Chci nechat vklad dotáhnout znovu

Po opravě parseru nebo při výpadku katastru:

```sql
-- jeden vklad
UPDATE dbo.KN_k_pretazeni SET zpracovano = 0 WHERE id_valuo = <id>;

-- všechny, kterým se nepodařilo nic najít
UPDATE q SET zpracovano = 0
FROM dbo.KN_k_pretazeni q
WHERE q.zpracovano = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data k
                  WHERE k.id_valuo = q.id_valuo);
```

Pak spusť `--parcely`. Opakování má smysl jen u výpadku katastru
nebo opraveného parseru — zaniklé parcely se nenajdou nikdy.

### Výměra z katastru nesedí na výměru z Valua

Zaznamenáno v CSV jako `vymera_nesedi`, nikam to nezasahuje.
Běžný podíl jsou jednotky procent. Odchylka plochy spočítané
z geometrie proti `areaValue_m2` do 1–3 % je normální —
katastr zaokrouhluje výměru na celé m².

### Chci import vrátit

Dávka se vymezí rozsahem `id` ve `Valuo_data` (id přidělená v jednom běhu
tvoří souvislý úsek se stejným `timestamp`). Smazat se musí **všechno
navázané** — vazby na ÚP, evidence ÚP, parcely, fronta, a teprve pak řádky
`Valuo_data` — a vždy se zálohou předem. Hotový vzor je
`30a_odstraneni_rannich_duplicit.sql`: kontrola rozsahu, pět záloh, smazání
v jedné transakci, kontrola osiřelých vazeb.

Má-li se dávka importovat znovu, smaž i její záznamy ve `Valuo_soubory`,
jinak se soubory podruhé nenačtou. Potom vždy `--prepocty` a `--dopocty`.

Jednotlivé řádky místo celé dávky odstraňuje stejným postupem
`30b_odstraneni_starych_duplicit.sql` (výčet `id`, zálohy, jedna transakce).

**Ruční zjištění znalce se tím nemažou** — `Valuo_vklad_rucne`,
`Valuo_vklad_nalezy` a `Valuo_poznamky` jsou klíčované číslem vkladu
a návrat importu se jich netýká. Vrátí-li se vklad do databáze, ověřená
plocha se na něj zase napojí.

---

## 5. Totožnost záznamu a filtr validity

### Kdy je záznam „tentýž"

Valuo popisuje tutéž nemovitost v různých balíčcích různě — chybějící
plochu jednou jako 0, jindy prázdnou; plochu jednotky z podílu přepočítá
jinak (53,6 × 536 m²); u budov změnilo formát popisu. Plocha proto
**do klíče totožnosti nepatří**. Od verze 30.3 import porovnává:

```
cislo_vkladu + nemovitost + typ + adresa + číslo jednotky + popis
```

**Popis je v klíči u všech řádků** (ve verzi 30.2 jen u „Neznámá adresa").
Důvod: Valuo uvádí u rodinného domu často **dvakrát „budovu" se stejnou
adresou** — jednou samotnou stavbu, podruhé parcelu, jejíž součástí stavba
je („č. 1234/5 Ruzyně (součástí je stavba …)"). Jsou to dvě různé
nemovitosti; liší se jen popisem. Klíč bez popisu by jednu z nich zahodil.
Ve starých datech je takových vkladů 25.

Totéž platí pro garáže „bez čp/če" se stejnou náhradní adresou.

Ověřeno: klíč 30.3 chytil celou ranní dávku 24. 10. (862 z 862), druhou
dávku 43 balíčků nechal celou a ve starých datech našel 8 skutečných
duplicit, odstraněných krokem 30b. **Dnes je v databázi 0 kolizí.**

Unikátní index `UQ_Valuo_zaznam` v databázi má dosud starou pětici
s plochou; proti duplicitám v jiné podobě chrání jen importní skript.

### Co se vyřazuje

Skript vyhazuje jen to, co **nelze umístit nebo nemá cenu**:

- bez popisu — nedá se dohledat parcela ani území
- cena chybí nebo je ≤ 0

Chybějící `Typ` a `Adresa` se doplňují náhradou `Neznámé`
a `Neznámá adresa`. **Tyto řetězce se nesmí měnit** — dosavadní
data je tak mají a jsou součástí klíče totožnosti.

**Chybějící plocha záznam nevyřazuje**, protože:

- u metrik `KUS` (garáž) a `CELEK` (bytový dům, jiná stavba) se
  plocha nepoužívá vůbec, porovnává se celková cena
- u budov ji umí doplnit RÚIAN
- u jednotek ji od kroku 44 umí dopočítat registr ploch z podílu
  na společných částech
- vklad i bez plochy vstupuje do detektorů hromadných převodů
  podle celkové ceny
- vzorek si ho sám označí „bez JC" nebo „chybí podlahová plocha"

Chceš-li přísnější chování, přepni ve skriptu
`ODMITAT_BEZ_PLOCHY` na `True`. Vyhodí záznamy bez plochy tam,
kde ji metrika potřebuje (`JC`, `JC_PODLAHOVA`); garáží
a bytových domů se to nedotkne.

**Pozor:** vyřazený řádek se nevrátí. Soubor zůstane v evidenci
a podruhé se nenačte. Kolik čeho vypadlo, je v evidenci:

```sql
SELECT cesta, radku, vlozeno, vyrazeno, odmitnuto
FROM dbo.Valuo_soubory
WHERE vyrazeno > 0 OR odmitnuto > 0 ORDER BY nacteno DESC;
```

---

## 6. Tabulky, které si skript zakládá

| tabulka | k čemu |
|---|---|
| `Valuo_soubory` | evidence zpracovaných souborů podle otisku SHA-256 |
| `Valuo_staging` | pracovní, mezi dávkami se vyprazdňuje; má počítaný sloupec `jednotka_oznaceni` shodný s `Valuo_data` |
| `RUIAN_k_pretazeni` | obce, které chybí v RÚIANu |
| `KN_parcel_UP_stav` | které parcely už prošly zatříděním — i ty bez průniku, jinak by se počítaly dokola |

Etapa `--dopocty` plní tabulky kroků 34 až 45: `Valuo_karta_okoli`,
`Valuo_karta_parcely`, `Valuo_karta_vklad`, `Valuo_mapa`,
`Valuo_podil_jednotky`, `Valuo_plochy`, `Valuo_vklad_plocha`
a `CIS_ku_median_jc`. Zakládají se očíslovanými skripty, ne importem.

Od kroku 45 je `Valuo_plochy` **po řádcích**: klíč je
`(cislo_vkladu, id, zdroj)`, kde `id` je `Valuo_data.id` konkrétní jednotky
a `id` = 0 znamená údaj za celý vklad. Plochu vkladu drží
`Valuo_vklad_plocha` a je to součet použitých ploch **nosné nemovitosti** —
nejvyššího typu přítomného ve vkladu podle `CIS_nemovitost_typ.priorita`.
Co se do součtu nedostalo, je v textu `rozpusteno` a v kupní ceně zahrnuté
je.

Krok 46 to rozšířil na všechny tři kategorie. `Valuo_vklad_plocha` má řádek
pro každý vklad: jednotku, budovu, soubor pozemků i právo stavby. U pozemků
nese `vymera_nosna` (výhradní parcely bez tvaru pásu a bez druhu
komunikace); není-li žádná, je to balík a zůstane prázdná. **Nemá-li
podlahovou plochu každá nosná nemovitost, `plocha` je prázdná a nic se
nedělí** — uvádí se jen celková cena.

---

## 7. Co je dobré vědět o datech

**Území v balíčku není území nemovitosti.** Valuo prodává balíčky
„katastrální území + měsíc", takže `kat_uzemi` a `okres` patří
balíčku; zhruba 13 % parcel leží jinde. Skutečné území je
v popisu a odtud ho bere parser.

**`kod_ku` ve `Valuo_data` je kód území největší parcely vkladu**, ne
balíčku. Import ho nejdřív vyplní podle balíčku (jiný údaj v té chvíli
není) a po dotažení parcel ho přepíše kódem z katastru.

**Datumy jsou ve zdroji text v ISO tvaru.** Skript je čte pevným
vzorem a nikdy nehádá, co je den a co měsíc. Nevyhoví-li tvar,
řádek se odmítne a zapíše do CSV.

**Sloupec `KN_parcel_data.geometry` se nepoužívá.** Je prázdný;
geometrie žije v `geo_plocha` (typ `geography`, WGS84). Skript
ji počítá rovnou z odpovědi katastru, takže krok `17b_geografie.py`
odpadá.

**`nemovitost = '---'` jsou práva stavby.** Poznají se podle
popisu začínajícího „účel …". Od kroku 31 mají vlastní klasifikaci
`PRAVO_STAVBY` a hodnocení `právo stavby` — porovnávají se jen mezi
sebou a do mezí nevstupují. Importu se to netýká; klasifikaci přidělí
`--prepocty`.

**`CIS_metrika_ceny` nepokrývá všechny druhy budov.** Chybí mimo
jiné stavba technického a občanského vybavení, budova s číslem
evidenčním, průmyslový objekt. Dostanou výchozí `CELEK`.

**Plocha jednotky u Valua je skoro vždy dopočet z podílu, ne měření.**
Z 47 835 řádků jednotek s dopočtem jich 35 605 nese typ „Plocha
spočítaná z podílu na budově". Valuo si přitom volí, kolikrát posune
desetinnou čárku — stem u 10 578 řádků, deseti u 27 266, vůbec
u 4 447 — a občas se netrefí. Krok 44 to kontroluje poměrem čitatele
a jmenovatele podílu proti podlahové ploše domu z RÚIANu; poměr je
bezrozměrný, takže na posunu čárky nezávisí. **Opravu ale nikdy
nezapisuje sám** — nabídne hodnotu a potvrdit ji musí znalec.

**RÚIAN vede údaje k stavebnímu objektu, ne k číslu popisnému.**
98,6 % objektů má přesně jedno číslo popisné; objekt se třemi má
i plochu a počet bytů za všechna tři (ověřeno 25. 10. 2026: průměrná
podlahová plocha 317 m² u jednoho čísla proti 3 597 m² u tří). Sčítat
údaje přes čísla popisná proto **nemá smysl** — započítalo by se totéž
dvakrát. Kde vklad sahá na víc objektů, sčítá je `v_RUIAN_vzorek` samo
(přes `DISTINCT kod_so`).

---

## 8. Všechny kontroly na jednom místě

```sql
-- 1) duplicity klíčem totožnosti (musí být 0)
SELECT COUNT(*) AS kolizi
FROM (SELECT 1 AS x FROM dbo.Valuo_data
      GROUP BY cislo_vkladu, nemovitost, typ, adresa,
               ISNULL(jednotka_oznaceni, N''),
               ISNULL(popis, '')
      HAVING COUNT(*) > 1) g;

-- 2) celkový stav
SELECT
  (SELECT COUNT(*) FROM dbo.Valuo_data) AS radku,
  (SELECT COUNT(DISTINCT cislo_vkladu) FROM dbo.Valuo_data) AS vkladu,
  (SELECT COUNT(*) FROM dbo.v_Valuo_vzorek_q) AS ve_vzorku,
  (SELECT COUNT(*) FROM dbo.KN_parcel_data) AS parcel,
  (SELECT COUNT(DISTINCT kn_id) FROM dbo.KN_parcel_UP) AS zatridenych,
  (SELECT COUNT(*) FROM dbo.Valuo_soubory) AS souboru;

-- 3) geometrie celé tabulky (obracenych a stary_sloupec musí být 0)
SELECT
  SUM(CASE WHEN geo_plocha IS NULL THEN 1 ELSE 0 END) AS bez_geometrie,
  SUM(CASE WHEN geo_plocha.STArea() > 1e10 THEN 1 ELSE 0 END) AS obracenych,
  SUM(CASE WHEN geometry IS NOT NULL THEN 1 ELSE 0 END) AS stary_sloupec
FROM dbo.KN_parcel_data;

-- 4) souřadnice a kód území (doplnitelnych musí být 0)
SELECT
  SUM(CASE WHEN geo_zdroj = 'KN_refPoint' THEN 1 ELSE 0 END) AS souradnice_z_KN,
  SUM(CASE WHEN geo_bod IS NULL THEN 1 ELSE 0 END) AS bez_souradnice,
  SUM(CASE WHEN kod_ku IS NULL AND geo_zdroj = 'KN_refPoint' THEN 1 ELSE 0 END) AS doplnitelnych_bez_kod_ku
FROM dbo.Valuo_data;

-- 5) co zbývá ke zpracování
SELECT
  (SELECT COUNT(*) FROM dbo.KN_k_pretazeni WHERE zpracovano = 0) AS fronta_katastru,
  (SELECT COUNT(*) FROM dbo.RUIAN_k_pretazeni WHERE zpracovano = 0) AS obci_k_dotazeni,
  (SELECT COUNT(*) FROM dbo.Valuo_data WHERE mena <> 'CZK' AND cena_Kc IS NULL) AS bez_prepoctu_meny;

-- 6) vzorek po přepočtu
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;

-- 7) karty, mapa a registr ploch po --dopoctech
SELECT
  (SELECT COUNT(DISTINCT cislo_vkladu) FROM dbo.Valuo_data) AS vkladu,
  (SELECT COUNT(*) FROM dbo.Valuo_karta_vklad) AS karet,
  (SELECT COUNT(*) FROM dbo.Valuo_mapa) AS v_mape,
  (SELECT COUNT(*) FROM dbo.Valuo_plochy) AS radku_registru,
  (SELECT COUNT(*) FROM dbo.Valuo_podil_jednotky) AS zlomku_podilu,
  (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha) AS vkladu_s_plochou,
  (SELECT COUNT(*) FROM dbo.CIS_ku_median_jc) AS medianu_ku,
  (SELECT COUNT(*) FROM dbo.Valuo_mapa WHERE nalez_skala = 1) AS nalezu_skala;

-- 8) bod vkladu sedí na jeho vlastní parcelu (musí být 0, od kroku 43)
WITH r AS (
  SELECT v.id, v.geo_bod.Lat AS la, v.geo_bod.Long AS lo
  FROM dbo.Valuo_data v WHERE v.geo_bod IS NOT NULL
), m AS (
  SELECT r.id, MAX(CASE WHEN ABS(k.refPoint_lat - r.la) < 0.000001
                         AND ABS(k.refPoint_lon - r.lo) < 0.000001
                        THEN 1 ELSE 0 END) AS sedi
  FROM r JOIN dbo.KN_parcel_data k ON k.id_valuo = r.id
  WHERE k.refPoint_lat IS NOT NULL
  GROUP BY r.id
)
SELECT COUNT(*) AS bod_nesedi FROM m WHERE sedi = 0;

-- 9) ruční zjištění znalce zůstala nedotčená
SELECT
  (SELECT COUNT(*) FROM dbo.Valuo_vklad_rucne) AS rucnich_zaznamu,
  (SELECT COUNT(*) FROM dbo.Valuo_vklad_nalezy) AS nalezu,
  (SELECT COUNT(*) FROM dbo.Valuo_poznamky) AS poznamek;
```

---

## 9. Zkrácený postup

**Nejjednodušší cesta — jeden příkaz:**

```
-- poznamenej si: SELECT COUNT(*) FROM dbo.v_Valuo_vzorek_q

python 30_import_valuo.py --vse

-- vzorek musí vzrůst zhruba o počet nových vkladů
```

`--vse` projde všech sedm etap za sebou. Je to bezpečné: nic se nemaže,
všechno navazuje a po přerušení se stejný příkaz pustí znovu. Chybí-li
kurzy ČNB nebo obce v RÚIANu, upozorní na to a pokračuje — doplň je
a pusť `--prepocty --dopocty` znovu.

**Po etapách, když chceš vidět mezivýsledky nebo něco spadlo:**

```
python 30_import_valuo.py --inventura     # počet musí sedět
python 30_import_valuo.py --import        # pak kontrola duplicit novým klíčem
python 30_import_valuo.py --parcely       # nejdelší část importu, 1-3 s na vklad
python 30_import_valuo.py --up            # jen Praha, sekundy
python 30_import_valuo.py --ruian         # vypíše chybějící obce
   python 27_ruian_import.py --stahni <kódy>    # jen když něco vypsal
   python 27_ruian_import.py --import
   python 19_kurzy_CNB.py                       # jen když na to upozorní
python 30_import_valuo.py --prepocty      # minuty
python 30_import_valuo.py --dopocty       # karty, registr ploch, mapa
```

**Když spadne jen část dopočtů:**

```
python 30_import_valuo.py --dopocty --krok karty
python 30_import_valuo.py --dopocty --krok plochy
```

**Když měníš prahy v `CIS_karta_parametry`** a chceš přepočítat
i to, co už hotové je:

```
python 30_import_valuo.py --dopocty --prepocitat
```

Při prvním běhu na prázdné evidenci označí inventura **všechny**
soubory za nové. Je to správně — import projde všechny a vloží
jen to, co v databázi chybí.
