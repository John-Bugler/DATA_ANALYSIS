r"""
VALUO — KROK 30: KOMPLETNÍ IMPORT NOVÝCH DAT

Jeden skript pro celý řetězec: excely z Valua → katastr → územní
plán → přepočtové procedury → fronta RÚIANu.

Spouštěj:
    python 30_import_valuo.py --inventura     co je nového, nic nemění
    python 30_import_valuo.py --vse           celý řetězec
nebo po etapách:
    --import --parcely --up --ruian --prepocty --dopocty

================================================================
PROČ SE PÍŠE ZNOVU A CO SE OPRAVUJE
================================================================

1) ŽÁDNÁ EVIDENCE IMPORTOVANÝCH SOUBORŮ

   Databáze dosud nevěděla, který z 2 684 souborů už prošel.
   Odtud 982 duplicit z opakovaného importu téhož souboru
   (krok 16) a osm vkladů s týmž popisem dvakrát.

   Nově tabulka Valuo_soubory: cesta, SHA-256, velikost, počet
   řádků, kolik se vložilo, kdy. Soubor se pozná podle otisku
   obsahu, ne podle názvu — ve složce jsou soubory
   "cadastre_report_5_2024 (1).xlsx", což jsou RŮZNÉ balíčky,
   a naopak "_cadastre_report_3_2022.xlsx" a
   "cadastre_report_3_2026(2).xlsx" se vymykají tvaru názvu.
   Na název se proto nespoléhá nic.

2) ZDROJOVÁ SLOŽKA NENÍ NADMNOŽINOU DATABÁZE

   Změřeno 23. 10. 2026 na všech 2 684 souborech:

       excely   109 395 řádků, 48 150 vkladů
       databáze 107 403 řádků, 48 863 vkladů

   V databázi je o 713 vkladů VÍC, než je ve zdrojových
   souborech; u roku 2024 je v databázi o 238 řádků víc než
   v excelech. Část dat tedy pochází ze souborů, které ve
   složce dnes nejsou.

   Import proto NIKDY nemaže a nenahrazuje. Vkládá jen to, co
   v databázi chybí, a v režimu --inventura hlásí i opačný
   směr, aby bylo vidět, co ve složce není.

3) PROHOZENÝ DEN A MĚSÍC (krok 12)

   Datumy jsou ve zdroji TEXT v ISO tvaru "2025-04-22 11:03:50".
   Prohození vzniklo při importu, ne u Valua. Proto se tu datum
   čte výhradně strptime s pevným vzorem. Žádný pandas, žádný
   dateutil, žádné hádání podle hodnoty. Nevyhoví-li tvar,
   řádek se odmítne a zapíše do logu — nikdy se neuhodne.

4) ÚZEMÍ Z POPISU, NE Z BALÍČKU

   Valuo prodává balíčky "katastrální území + měsíc", takže
   sloupce kat_uzemi a okres patří BALÍČKU, ne nemovitosti —
   12,9 % parcel leží jinde. Skutečné území je v popisu.
   Parser a kontrola proti xlink:title jsou převzaty z kroku 17
   beze změny; jsou odladěné na 15 tvarech popisu.

   Sloupec Valuo_data.kod_ku se plní z balíčku (tak je dnes
   definovaný), a proto je nespolehlivý: 8 067 řádků ho nemá
   a u 2 800 neodpovídá názvu v kat_uzemi. Pro dotažení parcel
   se nepoužívá — tam rozhoduje popis.

5) GEOMETRIE: JEDEN ZDROJ MÍSTO DVOU

   Sloupec KN_parcel_data.geometry je dnes NULL u všech 130 150
   parcel, zatímco geo_plocha má naplněných 130 136. Na tom
   padalo 09_parcely_UP_kompletni.py — ne na zrušeném sloupci
   kat_uzemi, jak se myslelo, ale na filtru
   "geometry IS NOT NULL AND LEN(geometry) > 0", který vrací
   nula řádků. Ze stejného důvodu nemá z čeho počítat ani
   17b_geografie.py.

   Tento skript geometry neplní a nečte. Z odpovědi katastru
   počítá rovnou geo_bod a geo_plocha, takže krok 17b odpadá.
   Sloupec zůstává v tabulce; jeho zrušení je samostatný zásah
   do struktury a patří do skriptu 30a, až to bude ověřené
   praxí.

   ORIENTACE RINGU — na tom ses už spálil v kroku 03b: typ
   geography chce vnější ring proti směru hodinových ručiček
   a u obráceného polygonu vrátí STArea() 510 065 621 710 996 m².
   Orientace se tu proto počítá TEPRVE PO transformaci, na
   dvojicích (lon, lat), a po vložení se ještě kontroluje
   plocha.

6) ZATŘÍDĚNÍ DO ÚZEMNÍHO PLÁNU DĚLÁ SQL

   Na KN_parcel_data.geo_plocha i UP_FVU_data.geo_plocha jsou
   prostorové indexy. Typ geography počítá plochy na elipsoidu
   rovnou v metrech, takže průniky spočítá databáze sama.
   Odpadá geopandas, reprojekce do S-JTSK i riziko obrácených
   ringů. Ověřeno na vzorku: plochy sedí na výměru z katastru.

   Počítá se jen pro parcely, které zatřídění ještě nemají.
   Tabulka se NEMAŽE a NEZAKLÁDÁ znovu — na rozdíl od kroku 09,
   který ji pokaždé dropoval.

7) PROCEDURY POUŠTÍ SKRIPT SÁM

   Pět ze sedmi procedur se nevejde do 60s limitu nástroje MCP.
   Skript je pouští pod účtem Windows přes pyodbc bez časového
   limitu, v závazném pořadí.

================================================================
CO SKRIPT NEDĚLÁ
================================================================

Nemaže nic z Valuo_data ani KN_parcel_data, s jedinou výjimkou:
vazby parcel u vkladu, kterému se podařilo stáhnout nové parcely
(stejné chování jako krok 17, blok VZDY_SMAZAT). Žádný DELETE,
UPDATE ani DROP nad daty bez toho, aby to bylo tady napsané.

Zálohu databáze si udělej před prvním ostrým během sám.

Použití:
    pip install openpyxl pandas requests lxml pyproj sqlalchemy pyodbc
"""

import argparse
import csv
import hashlib
import logging
import re
import time
import urllib.parse
from collections import Counter
from datetime import datetime
from pathlib import Path

import openpyxl
import pandas as pd
import requests
from lxml import etree
from pyproj import Transformer
from sqlalchemy import create_engine, text

VERZE = "30.6 (2026-10-25)"

# ------------------------------------------------------------------
# NASTAVENÍ
# ------------------------------------------------------------------
SERVER = "localhost"
DATABAZE = "VALUO"

SLOZKA = (r"C:\Users\ijttr\OneDrive\Dokumenty\OCEŇOVÁNÍ"
          r"\_GEO_DATA_VALUE_MAPS\VALUO\data_strukturovana")

PAUZA_S = 0.3          # prodleva mezi dotazy na katastr
DAVKA = 100            # po kolika vkladech se zapisuje
DAVKA_SQL = 2000       # po kolika řádcích se vkládá do stagingu
DAVKA_UP = 5000        # po kolika parcelách se počítá územní plán
OPAKOVANI = 3          # pokusů při chybě spojení
MIN_PODIL_PCT = 0.5    # menší průniky s plochou ÚP se neukládají

WFS = "https://services.cuzk.cz/wfs/inspire-CP-wfs.asp?"

NS = {
    "wfs":  "http://www.opengis.net/wfs/2.0",
    "gml":  "http://www.opengis.net/gml/3.2",
    "CP":   "http://inspire.ec.europa.eu/schemas/cp/4.0",
    "base": "http://inspire.ec.europa.eu/schemas/base/3.3",
}
XLINK_TITLE = "{http://www.w3.org/1999/xlink}title"
GML_ID = "{http://www.opengis.net/gml/3.2}id"

PRAHA = "Hlavní město Praha"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("import30")

TRANS = Transformer.from_crs("EPSG:5514", "EPSG:4326", always_xy=True)

_engine = None


def db():
    """Spojení pod účtem Windows. Bez časového limitu — přepočtové
    procedury běží desítky minut."""
    global _engine
    if _engine is None:
        conn = (
            "Driver={ODBC Driver 17 for SQL Server};"
            f"Server={SERVER};Database={DATABAZE};"
            "Trusted_Connection=yes;"
        )
        _engine = create_engine(
            f"mssql+pyodbc:///?odbc_connect={urllib.parse.quote_plus(conn)}",
            connect_args={"timeout": 0},
            fast_executemany=True,
        )
    return _engine


def cislo(radku):
    """' 1 234,50 ' -> 1234.5 ; prázdné -> None"""
    if radku is None:
        return None
    if isinstance(radku, (int, float)):
        return float(radku)
    s = str(radku).replace("\xa0", "").replace(" ", "").replace(",", ".")
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def datum(hodnota):
    """
    Datum ze zdroje. Ve zdroji je TEXT v ISO tvaru, takže se čte
    pevným vzorem. Nikdy se neodhaduje, co je den a co měsíc —
    přesně tím vznikla chyba opravovaná v kroku 12.
    """
    if hodnota is None:
        return None
    if isinstance(hodnota, datetime):
        return hodnota
    s = str(hodnota).strip()
    if not s:
        return None
    for vzor in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, vzor)
        except ValueError:
            continue
    raise ValueError(f"neznámý tvar data: {s!r}")


def otisk(cesta: Path) -> str:
    h = hashlib.sha256()
    with open(cesta, "rb") as f:
        for blok in iter(lambda: f.read(1 << 20), b""):
            h.update(blok)
    return h.hexdigest()


def mezery(n) -> str:
    return f"{n:,}".replace(",", " ")


# ==================================================================
# STRUKTURA ZDROJOVÝCH SOUBORŮ
# ==================================================================
# Ve složce jsou dvě varianty hlavičky, ověřeno na všech 2 684
# souborech (23. 10. 2026): 2 195 souborů má 16 sloupců, 489 má 17
# — navíc "Plocha pozemku (v m2)" na pozici 11. Ten sloupec se
# zahazuje; ověřeno, že se od "Plocha (v m2)" neliší ani jednou
# z 6 807 případů.
#
# Jakákoli JINÁ hlavička import zastaví. Nedopočítává se, nehádá
# se podle pořadí — Valuo může formát změnit a tichý posun sloupců
# by znamenal čísla v nesprávných polích.
# ==================================================================

HLAVICKA_16 = (
    "Číslo vkladu", "Datum podání", "Datum zplatnění", "Listina",
    "Nemovitost", "Typ", "Adresa", "Cenový údaj", "Měna",
    "Plocha (v m2)", "Typ plochy", "Popis", "Okres", "Kat. území",
    "Rok", "Měsíc",
)
HLAVICKA_17 = (
    "Číslo vkladu", "Datum podání", "Datum zplatnění", "Listina",
    "Nemovitost", "Typ", "Adresa", "Cenový údaj", "Měna",
    "Plocha (v m2)", "Typ plochy", "Plocha pozemku (v m2)", "Popis",
    "Okres", "Kat. území", "Rok", "Měsíc",
)
ZNAME_HLAVICKY = {HLAVICKA_16: 16, HLAVICKA_17: 17}

# zdrojový název -> sloupec v databázi
NA_SLOUPEC = {
    "Číslo vkladu": "cislo_vkladu",
    "Datum podání": "datum_podani",
    "Datum zplatnění": "datum_zplatneni",
    "Listina": "listina",
    "Nemovitost": "nemovitost",
    "Typ": "typ",
    "Adresa": "adresa",
    "Cenový údaj": "cenovy_udaj",
    "Měna": "mena",
    "Plocha (v m2)": "plocha",
    "Typ plochy": "typ_plochy",
    "Popis": "popis",
    "Okres": "okres",
    "Kat. území": "kat_uzemi",
    "Rok": "rok",
    "Měsíc": "mesic",
}
TEXTOVE = {"cislo_vkladu", "listina", "nemovitost", "typ", "adresa",
           "mena", "typ_plochy", "popis", "okres", "kat_uzemi"}
DELKY = {"cislo_vkladu": 50, "nemovitost": 50, "typ": 100, "adresa": 400,
         "mena": 10, "typ_plochy": 300, "popis": 800, "okres": 100,
         "kat_uzemi": 100}
POVINNE = ("cislo_vkladu", "datum_podani", "datum_zplatneni", "nemovitost",
           "cenovy_udaj", "mena", "okres", "kat_uzemi", "rok", "mesic")

# Valuo u části záznamů nevyplňuje Typ a Adresu — druh nemovitosti
# je pak jen v popisu ("garáž v budově č.p. 810", "budova bez čp/če,
# garáž"). V databázi jsou oba sloupce NOT NULL a jsou součástí
# UQ_Valuo_zaznam, takže se doplňují náhradou.
#
# Hodnoty MUSÍ zůstat přesně takto. Dosavadní data je tak mají
# (281 řádků "Neznámé", 726 "Neznámá adresa") a kdyby se sem
# dosadilo cokoli jiného, anti-join by ty řádky nepoznal
# a při každém běhu by je vložil znovu.
NAHRADY = {"typ": "Neznámé", "adresa": "Neznámá adresa"}


# ==================================================================
# CO JE JEŠTĚ POUŽITELNÝ ZÁZNAM A CO UŽ BALAST
# ==================================================================
# Změřeno na všech 2 684 souborech (105 025 záznamů po dedupu):
#
#   103 713  úplné
#       345  chybí typ nebo adresa, cena i plocha jsou
#       533  chybí plocha, ale metrika ji nepotřebuje (KUS, CELEK)
#       434  chybí plocha a metrika ji potřebuje (JC, JC_PODLAHOVA)
#
# Záznam se vyhazuje jen tehdy, když ho nelze UMÍSTIT nebo nemá
# CENU — bez popisu se nedá dohledat parcela, bez ceny není co
# porovnávat. Těchto případů je v dnešních datech nula; filtr je
# pojistka pro další dávky.
#
# Chybějící plocha záznam nevyřazuje, protože:
#   - u metrik KUS (garáž) a CELEK (bytový dům, jiná stavba) se
#     plocha nepoužívá vůbec — porovnává se celková cena vkladu
#   - u budov ji umí doplnit RÚIAN
#   - vklad i bez plochy vstupuje do detektorů hromadných převodů
#     podle celkové ceny a do počtu prodejů téže stavby
#   - vzorek si ho sám označí jako „bez JC" nebo „chybí podlahová
#     plocha", takže se do porovnání nedostane
#
# Zahodit ho při importu by znamenalo filtrovat dvakrát a přijít
# o 533 garáží a bytových domů, které jsou plně použitelné.
#
# Kdo chce přísnější chování, přepne ODMITAT_BEZ_PLOCHY na True:
# vyhodí těch 434 záznamů, kde metrika plochu potřebuje. Garáží
# a bytových domů se to nedotkne.
# ==================================================================

ODMITAT_BEZ_PLOCHY = False

# metriky, které se bez plochy neobejdou
METRIKY_S_PLOCHOU = {"JC", "JC_PODLAHOVA"}


def nacti_metriky():
    """(nemovitost, typ) -> metrika, z číselníku CIS_metrika_ceny."""
    df = pd.read_sql(
        "SELECT nemovitost, typ, metrika FROM dbo.CIS_metrika_ceny", db())
    return {(r.nemovitost, r.typ): r.metrika for r in df.itertuples()}


def duvod_vyrazeni(r, metriky):
    """None = záznam je použitelný, jinak důvod."""
    if not r.get("popis"):
        return "bez_popisu"          # nemovitost nelze umístit
    cena = r.get("cenovy_udaj")
    if cena is None or cena <= 0:
        return "bez_ceny"
    if ODMITAT_BEZ_PLOCHY and r.get("plocha") in (None, 0):
        if metriky.get((r["nemovitost"], r["typ"])) in METRIKY_S_PLOCHOU:
            return "bez_plochy_u_metriky_JC"
    return None

# pětice, kterou se pozná tentýž záznam (shodná s UQ_Valuo_zaznam).
# kat_uzemi v ní záměrně NENÍ — je to území balíčku, takže tentýž
# vklad má v různých balíčcích různou hodnotu.
KLIC = ("cislo_vkladu", "adresa", "nemovitost", "typ", "plocha")


class ZmenaStruktury(Exception):
    """Hlavička souboru neodpovídá žádné známé variantě."""


def nacti_excel(cesta: Path):
    """
    Vrátí (seznam řádků jako dict, seznam odmítnutých).
    Při neznámé hlavičce vyhodí ZmenaStruktury — soubor se
    nezpracuje a import se zastaví.
    """
    wb = openpyxl.load_workbook(cesta, read_only=True, data_only=True)
    try:
        ws = wb[wb.sheetnames[0]]
        radky = ws.iter_rows(values_only=True)
        try:
            hlavicka = tuple(
                (str(x).strip() if x is not None else "")
                for x in next(radky)
            )
        except StopIteration:
            return [], []

        if hlavicka not in ZNAME_HLAVICKY:
            raise ZmenaStruktury(
                f"{cesta.name}: neznámá hlavička ({len(hlavicka)} sloupců)\n"
                f"    nalezeno: {' ; '.join(hlavicka)}"
            )

        vysledek, odmitnute = [], []
        for cislo_radku, radek in enumerate(radky, start=2):
            if radek is None or all(b is None for b in radek):
                continue
            z = dict(zip(hlavicka, radek))

            try:
                r = {}
                for nazev, sloupec in NA_SLOUPEC.items():
                    h = z.get(nazev)
                    if sloupec in ("datum_podani", "datum_zplatneni"):
                        r[sloupec] = datum(h)
                    elif sloupec in ("cenovy_udaj", "plocha"):
                        r[sloupec] = cislo(h)
                    elif sloupec in ("rok", "mesic"):
                        c = cislo(h)
                        r[sloupec] = int(c) if c is not None else None
                    else:
                        t = str(h).strip() if h is not None else None
                        if t == "":
                            t = None
                        if t is not None and sloupec in DELKY:
                            t = t[:DELKY[sloupec]]
                        r[sloupec] = t

                for sloupec, nahrada in NAHRADY.items():
                    if r.get(sloupec) is None:
                        r[sloupec] = nahrada

                chybi = [s for s in POVINNE if r.get(s) is None]
                if chybi:
                    raise ValueError("chybí " + ", ".join(chybi))

                vysledek.append(r)
            except Exception as e:
                odmitnute.append((cesta.name, cislo_radku,
                                  f"{type(e).__name__}: {e}"))
        return vysledek, odmitnute
    finally:
        wb.close()


def soubory(slozka: Path):
    return sorted(slozka.rglob("*.xlsx"))


# ==================================================================
# TABULKY, KTERÉ SI SKRIPT ZAKLÁDÁ
# ==================================================================
DDL = """
IF OBJECT_ID('dbo.Valuo_soubory') IS NULL
CREATE TABLE dbo.Valuo_soubory (
    id          int IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_Valuo_soubory PRIMARY KEY CLUSTERED,
    otisk       char(64)      NOT NULL,
    cesta       nvarchar(400) NOT NULL,
    velikost    bigint        NOT NULL,
    zmeneno     datetime2(0)  NULL,
    radku       int           NULL,   -- řádků v souboru
    vlozeno     int           NULL,   -- z toho zapsáno do Valuo_data
    odmitnuto   int           NULL,   -- nečitelné (chybný tvar data ap.)
    vyrazeno    int           NULL,   -- vyřazeno filtrem validity
    nacteno     datetime2(0)  NOT NULL
        CONSTRAINT DF_Valuo_soubory_nacteno DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_Valuo_soubory_otisk UNIQUE (otisk)
);

IF OBJECT_ID('dbo.Valuo_staging') IS NULL
CREATE TABLE dbo.Valuo_staging (
    cislo_vkladu    varchar(50)   NOT NULL,
    datum_podani    datetime      NOT NULL,
    datum_zplatneni datetime      NOT NULL,
    listina         varchar(max)  NULL,
    nemovitost      varchar(50)   NOT NULL,
    typ             varchar(100)  NOT NULL,
    adresa          varchar(400)  NOT NULL,
    cenovy_udaj     decimal(18,2) NOT NULL,
    mena            varchar(10)   NOT NULL,
    plocha          decimal(18,2) NULL,
    typ_plochy      varchar(300)  NULL,
    popis           varchar(800)  NULL,
    okres           varchar(100)  NOT NULL,
    kat_uzemi       varchar(100)  NOT NULL,
    rok             int           NOT NULL,
    mesic           int           NOT NULL,
    zdroj           nvarchar(400) NULL
);

IF COL_LENGTH('dbo.Valuo_staging', 'jednotka_oznaceni') IS NULL
ALTER TABLE dbo.Valuo_staging ADD jednotka_oznaceni AS
    (case when [nemovitost]<>'jednotka' OR NOT [popis] like N'jednotka č. %'
               OR charindex(',',[popis],(13))<=(13) then NULL
          when charindex(',',[popis],(13))>(17)
               then (substring([popis],(13),charindex(',',[popis],(13))-(17))+N'/')
                    +CONVERT([nvarchar](10),TRY_CAST(substring([popis],
                     charindex(',',[popis],(13))-(4),(4)) AS [int]))
          else substring([popis],(13),charindex(',',[popis],(13))-(13)) end);

IF OBJECT_ID('dbo.RUIAN_k_pretazeni') IS NULL
CREATE TABLE dbo.RUIAN_k_pretazeni (
    obec_kod     int           NOT NULL
        CONSTRAINT PK_RUIAN_k_pretazeni PRIMARY KEY CLUSTERED,
    obec_nazev   nvarchar(100) NULL,
    nemovitosti  int           NOT NULL,
    duvod        varchar(20)   NOT NULL,
    zjisteno     datetime2(0)  NOT NULL
        CONSTRAINT DF_RUIAN_k_pretazeni_zjisteno DEFAULT SYSDATETIME(),
    zpracovano   bit           NOT NULL
        CONSTRAINT DF_RUIAN_k_pretazeni_zpracovano DEFAULT 0
);
"""


def zaloz_tabulky():
    with db().begin() as c:
        for prikaz in DDL.split(";"):
            if prikaz.strip():
                c.execute(text(prikaz))


# ==================================================================
# ETAPA 1 — INVENTURA
# ==================================================================
def etapa_inventura(slozka: Path, podrobne=False):
    """
    Zjistí, které soubory ještě neprošly. Nic nemění.
    Soubor se pozná podle otisku obsahu, ne podle názvu.
    """
    zaloz_tabulky()
    vsechny = soubory(slozka)
    if not vsechny:
        log.error(f"Ve složce {slozka} není žádný .xlsx")
        return []

    log.info(f"Soubory ve složce: {mezery(len(vsechny))}")
    log.info("Počítám otisky…")
    hotove = {
        r[0] for r in db().connect().execute(
            text("SELECT otisk FROM dbo.Valuo_soubory")).fetchall()
    }
    log.info(f"  v evidenci: {mezery(len(hotove))}")

    nove, znovu, videno = [], 0, {}
    for cesta in vsechny:
        h = otisk(cesta)
        if h in videno:
            znovu += 1          # tentýž obsah pod jiným názvem
            continue
        videno[h] = cesta
        if h not in hotove:
            nove.append((cesta, h))

    log.info("")
    log.info(f"  shodný obsah pod více názvy: {mezery(znovu)}")
    log.info(f"  NOVÝCH K IMPORTU:            {mezery(len(nove))}")

    if podrobne and nove:
        log.info("")
        for cesta, _ in nove[:40]:
            log.info(f"    {cesta.relative_to(slozka)}")
        if len(nove) > 40:
            log.info(f"    … a dalších {len(nove) - 40}")

    # opačný směr: co je v databázi a ve složce není
    if not hotove:
        log.info("")
        log.info("Evidence je prázdná — první běh projde všechny soubory.")
        log.info("Vklady, které v databázi jsou a ve složce nejsou, se")
        log.info("NIJAK nedotknou; import nikdy nemaže.")
    return nove


# ==================================================================
# ETAPA 2 — IMPORT EXCELŮ
# ==================================================================
# Postup na jednu dávku souborů:
#   1) načtení a normalizace v Pythonu
#   2) deduplikace v rámci dávky (pětice KLIC)
#   3) zápis do Valuo_staging
#   4) INSERT do Valuo_data jen těch řádků, které v databázi
#      nejsou — anti-join přes INTERSECT, protože ten porovnává
#      NULL jako rovné, a plocha NULL být může
#   5) zápis souborů do evidence, vyprázdnění stagingu
#
# Celá dávka je jedna transakce. Spadne-li běh, ztratí se nejvýš
# rozpracovaná dávka a další spuštění pokračuje od ní — soubory
# se poznají podle otisku.
# ==================================================================

SQL_STAGING = text("""
    INSERT INTO dbo.Valuo_staging
        (cislo_vkladu, datum_podani, datum_zplatneni, listina,
         nemovitost, typ, adresa, cenovy_udaj, mena, plocha,
         typ_plochy, popis, okres, kat_uzemi, rok, mesic, zdroj)
    VALUES (:cislo_vkladu, :datum_podani, :datum_zplatneni, :listina,
            :nemovitost, :typ, :adresa, :cenovy_udaj, :mena, :plocha,
            :typ_plochy, :popis, :okres, :kat_uzemi, :rok, :mesic, :zdroj)
""")

# Logika "co je nové" je schválně rozepsaná do tří kroků nad
# stagingem místo jednoho slepence. Díky tomu jde po kroku b)
# spočítat, kolik řádků připadlo na KTERÝ soubor, a evidence
# pak nelže — nerozpočítává se podíl dávky.

# a) duplicity uvnitř dávky: tentýž záznam přišel ze dvou balíčků
# KLÍČ TOTOŽNOSTI ZÁZNAMU (od verze 30.3)
#
# Unikátní index UQ_Valuo_zaznam má pětici (vklad, adresa, nemovitost,
# typ, plocha). Plocha v ní 24. 10. 2026 způsobila 862 duplicit, protože
# Valuo uvádí tutéž nemovitost v různých balíčcích různě:
#   - chybějící plochu starý import ukládal jako 0, nový jako NULL (851×)
#   - plochu jednotky z podílu přepočítá jinak (53,6 × 536; 69 × 357)
#   - u rodinných domů jednou podlahovou plochu, jindy výměru parcely
#
# Import proto porovnává BEZ plochy, ale VŽDY S POPISEM:
#   vklad + druh + typ + adresa + číslo jednotky + popis
#
# Popis je nutný všude, ne jen u řádků bez adresy (tak to bylo ve 30.2).
# Valuo u části budov uvádí v jednom vkladu DVA řádky „budova" se stejnou
# adresou: jeden ve tvaru stavby („č.p. 736, …, na parcele 1781 Kunratice",
# plocha 0) a druhý ve tvaru parcely („č. 1781 Kunratice", výměra parcely).
# Jsou to dvě různé položky vkladu — bez popisu by je klíč slil a jednu
# zahodil. Ve starých datech je takových vkladů 25.
#
# Popis je v čase stabilní: všech 862 ranních duplicit mělo dvojníka
# s totožným popisem, importovaného o 1 až 20 měsíců dřív.
#
# Změřeno: ve starých datech tento klíč najde 8 skupin skutečných
# duplicit, ranní dávku chytí celou (862 z 862), druhou dávku 43 balíčků
# nechá celou (0 z 2 359).
KLIC_SQL = """
    {a}.cislo_vkladu, {a}.nemovitost, {a}.typ, {a}.adresa,
    ISNULL({a}.jednotka_oznaceni, N''), ISNULL({a}.popis, '')
"""

# a) duplicity uvnitř dávky: tentýž záznam přišel ze dvou balíčků
# KLÍČ TOTOŽNOSTI ZÁZNAMU (od verze 30.2)
#
# Unikátní index UQ_Valuo_zaznam má pětici (vklad, adresa, nemovitost,
# typ, plocha). Plocha v ní 24. 10. 2026 způsobila 862 duplicit, protože
# Valuo uvádí tutéž nemovitost v různých balíčcích různě:
#   - chybějící plochu starý import ukládal jako 0, nový jako NULL (851×)
#   - plochu jednotky z podílu přepočítá jinak (53,6 × 536; 69 × 357)
#   - u budov mezitím změnilo formát popisu
#
# Import proto porovnává BEZ plochy:
#   vklad + druh + typ + adresa + číslo jednotky
#   + popis, ale jen tam, kde adresa chybí
# Popis je u řádků bez adresy nutný — jeden vklad může mít několik
# garáží „bez čp/če", všechny s náhradou „Neznámá adresa" (ve starých
# datech 21 takových vkladů). Jinde se popis nebere, protože se mění
# formát.
#
# Změřeno: ve starých datech tento klíč označí jen 7 skupin (známé
# duplicity z auditu), ranní dávku chytí celou (862 z 862) a druhou
# dávku 43 balíčků nechá celou (0 kolizí).
KLIC_SQL = """
    {a}.cislo_vkladu, {a}.nemovitost, {a}.typ, {a}.adresa,
    ISNULL({a}.jednotka_oznaceni, N''),
    CASE WHEN {a}.adresa = N'Neznámá adresa' THEN ISNULL({a}.popis, '') ELSE '' END
"""

# a) duplicity uvnitř dávky: tentýž záznam přišel ze dvou balíčků
SQL_DEDUP = text(f"""
    WITH d AS (
        SELECT ROW_NUMBER() OVER (
                   PARTITION BY {KLIC_SQL.format(a='s')}
                   ORDER BY CASE WHEN s.plocha > 0 THEN 0 ELSE 1 END,
                            s.datum_zplatneni) AS poradi
        FROM dbo.Valuo_staging s
    )
    DELETE FROM d WHERE poradi > 1;
""")

# b) co v databázi už je — stejný klíč
SQL_ODECTI_EXISTUJICI = text("""
    DELETE s FROM dbo.Valuo_staging s
    WHERE EXISTS (
        SELECT 1 FROM dbo.Valuo_data v
        WHERE v.cislo_vkladu = s.cislo_vkladu
          AND v.nemovitost   = s.nemovitost
          AND v.typ          = s.typ
          AND v.adresa       = s.adresa
          AND ISNULL(v.jednotka_oznaceni, N'') = ISNULL(s.jednotka_oznaceni, N'')
          AND ISNULL(v.popis, '') = ISNULL(s.popis, '')
    );
""")

SQL_PODLE_ZDROJE = text("""
    SELECT zdroj, COUNT(*) AS radku
    FROM dbo.Valuo_staging GROUP BY zdroj
""")

# c) zbytek stagingu je to, co v databázi chybí.
#    kod_ku se dohledá podle kat_uzemi, tedy podle území BALÍČKU —
#    tak je ten sloupec definovaný dnes. Je proto nespolehlivý
#    (8 067 řádků ho nemá, u 2 800 neodpovídá názvu) a pro
#    dotahování parcel se nepoužívá.
SQL_VLOZ_NOVE = text("""
    INSERT INTO dbo.Valuo_data
        (cislo_vkladu, datum_podani, datum_zplatneni, listina,
         nemovitost, typ, adresa, cenovy_udaj, mena, plocha,
         typ_plochy, popis, okres, kat_uzemi, rok, mesic,
         kod_ku, [timestamp])
    SELECT s.cislo_vkladu, s.datum_podani, s.datum_zplatneni, s.listina,
           s.nemovitost, s.typ, s.adresa, s.cenovy_udaj, s.mena, s.plocha,
           s.typ_plochy, s.popis, s.okres, s.kat_uzemi, s.rok, s.mesic,
           c.ku_kod, SYSDATETIME()
    FROM dbo.Valuo_staging s
    LEFT JOIN dbo.CIS_katastralni_uzemi c ON c.ku_nazev = s.kat_uzemi;
""")

SQL_EVIDENCE = text("""
    INSERT INTO dbo.Valuo_soubory
        (otisk, cesta, velikost, zmeneno, radku, vlozeno, odmitnuto, vyrazeno)
    VALUES (:otisk, :cesta, :velikost, :zmeneno, :radku, :vlozeno,
            :odmitnuto, :vyrazeno)
""")


def etapa_import(slozka: Path, nove=None, davka_souboru=50, log_csv=None):
    zaloz_tabulky()
    if nove is None:
        nove = etapa_inventura(slozka)
    if not nove:
        log.info("Žádný nový soubor — import nemá co dělat.")
        return 0

    w = None
    if log_csv:
        f = open(log_csv, "w", encoding="utf-8-sig", newline="")
        w = csv.writer(f, delimiter=";")
        w.writerow(["soubor", "radek", "duvod"])

    metriky = nacti_metriky()
    stat = Counter()
    celkem_vlozeno = 0
    zacatek = time.time()

    for zacatek_davky in range(0, len(nove), davka_souboru):
        cast = nove[zacatek_davky:zacatek_davky + davka_souboru]
        radky, evidence = [], []

        for cesta, h in cast:
            try:
                nactene, odmitnute = nacti_excel(cesta)
            except ZmenaStruktury as e:
                log.error("")
                log.error("ZMĚNA STRUKTURY ZDROJOVÝCH SOUBORŮ")
                log.error(str(e))
                log.error("")
                log.error("Import se zastavuje. Dosud vložené dávky")
                log.error("zůstávají; po doplnění hlavičky do")
                log.error("ZNAME_HLAVICKY spusť znovu — co už prošlo,")
                log.error("se podruhé nenačte.")
                raise

            rel = str(cesta.relative_to(slozka))
            vyrazeno_zde = 0
            for s, r, d in odmitnute:
                stat["odmitnuty_radek"] += 1
                if w:
                    w.writerow([rel, r, d])

            for r in nactene:
                duvod = duvod_vyrazeni(r, metriky)
                if duvod:
                    stat[f"vyrazeno_{duvod}"] += 1
                    vyrazeno_zde += 1
                    if w:
                        w.writerow([rel, "", duvod])
                    continue
                r["zdroj"] = rel
                radky.append(r)

            st = cesta.stat()
            evidence.append({
                "otisk": h, "cesta": rel, "velikost": st.st_size,
                "zmeneno": datetime.fromtimestamp(st.st_mtime),
                "radku": len(nactene), "vlozeno": None,
                "odmitnuto": len(odmitnute), "vyrazeno": vyrazeno_zde,
            })

        # deduplikace v rámci dávky
        pred = len(radky)
        videno, cisté = set(), []
        for r in radky:
            k = tuple(r[s] for s in KLIC)
            if k in videno:
                continue
            videno.add(k)
            cisté.append(r)
        stat["duplicita_v_davce"] += pred - len(cisté)

        with db().begin() as c:
            c.execute(text("TRUNCATE TABLE dbo.Valuo_staging"))
            for i in range(0, len(cisté), DAVKA_SQL):
                c.execute(SQL_STAGING, cisté[i:i + DAVKA_SQL])

            c.execute(SQL_DEDUP)
            c.execute(SQL_ODECTI_EXISTUJICI)

            podle_zdroje = {
                r[0]: r[1] for r in c.execute(SQL_PODLE_ZDROJE).fetchall()
            }
            vlozeno = c.execute(SQL_VLOZ_NOVE).rowcount
            c.execute(text("TRUNCATE TABLE dbo.Valuo_staging"))

            for e in evidence:
                e["vlozeno"] = podle_zdroje.get(e["cesta"], 0)
            c.execute(SQL_EVIDENCE, evidence)

        celkem_vlozeno += vlozeno
        stat["radku_nacteno"] += pred
        stat["vlozeno"] += vlozeno
        stat["jiz_v_databazi"] += len(cisté) - vlozeno

        hotovo = min(zacatek_davky + davka_souboru, len(nove))
        podil = hotovo / len(nove)
        zbyva = (time.time() - zacatek) / max(podil, 1e-9) * (1 - podil)
        log.info(f"  soubory {mezery(hotovo)} / {mezery(len(nove))} "
                 f"({podil:.0%}), vloženo {mezery(celkem_vlozeno)}, "
                 f"zbývá asi {zbyva / 60:.0f} min")

        if w:
            f.flush()

    if w:
        f.close()

    log.info("")
    log.info("IMPORT EXCELŮ — SOUHRN")
    for k, v in stat.most_common():
        log.info(f"  {k:<24} {mezery(v):>9}")
    if log_csv and stat["odmitnuty_radek"]:
        log.info(f"  odmítnuté řádky: {log_csv}")
    return celkem_vlozeno


# ==================================================================
# ETAPA 3 — PARCELY Z KATASTRU
# ==================================================================
# Parser popisu je převzat z kroku 17 beze změny. Ověřen na 15
# tvarech popisu, které se v datech vyskytují.
#
# Dvě věci, na kterých to v minulosti padlo:
#   - území se v seznamu uvádí ZA poslední parcelou, ke které
#     patří, takže se dědí od konce dopředu (krok 23g: 13 040
#     cizích parcel navázaných na vklady)
#   - typ parcely se pozná VÝHRADNĚ podle prefixu "stavební",
#     žádná kontextová detekce; "součástí je stavba č.p. 1388"
#     má u budov skoro každý záznam (krok 17, chyba b)
# ==================================================================

ZAVORKY = re.compile(r"\([^)]*\)")
VZOR_DIL = re.compile(r"(?i),\s*díl\s+\d+")
VZOR_SEZNAM = re.compile(r"(?i)\b(?:na|k)\s+parcele\s+(.+)$")
VZOR_PREFIX = re.compile(r"^(?i:(stavební|PK|GP)\s+)?č\.\s+(.+)$")
VZOR_SEGMENT = re.compile(r"(?i)^(st\.\s*)?(\d+(?:/\d+)?)(?:\s+(.+))?$")


def parcely_z_popisu(popis):
    """Vrátí (seznam [(uzemi, parcelni_cislo)], duvod_neuspechu)."""
    if not popis:
        return [], "bez_popisu"

    # Závorky se odstraňují opakovaně, protože bývají VNOŘENÉ:
    #   "... 546/5 Satalice (součástí je stavba ... (~)) (~)"
    # Jeden průchod sežere vnitřní pár a zvenčí zbude osamocená
    # závorka, která se přilepí k názvu území ("Satalice )") —
    # to pak v číselníku neexistuje a parcela se nedohledá.
    p = popis
    predchozi = None
    while predchozi != p:
        predchozi = p
        p = ZAVORKY.sub(" ", p)
    p = p.replace("(", " ").replace(")", " ")   # nepárové zbytky
    p = VZOR_DIL.sub("", p)
    p = re.sub(r"\s+", " ", p).strip().rstrip(",")
    st_vsude = False

    m = VZOR_SEZNAM.search(p)
    if m:
        zbytek = m.group(1)
    else:
        m = VZOR_PREFIX.match(p)
        if not m:
            return [], "neznamy_tvar"
        druh = (m.group(1) or "").lower()
        if druh in ("pk", "gp"):
            return [], "PK_GP_neni_v_KN"
        zbytek = m.group(2)
        st_vsude = (druh == "stavební")

    segmenty = []
    for seg in (s.strip() for s in zbytek.split(",")):
        if not seg:
            continue
        sm = VZOR_SEGMENT.match(seg)
        if not sm:
            continue
        c = ("st. " if (sm.group(1) or st_vsude) else "") + sm.group(2)
        uzemi = sm.group(3).strip(" ,.;:-") if sm.group(3) else None
        segmenty.append((c, uzemi or None))

    if not segmenty:
        return [], "seznam_neparsovan"

    vysledek, posledni = [], None
    for c, uzemi in reversed(segmenty):
        if uzemi:
            posledni = uzemi
        if posledni:
            vysledek.append((posledni, c))
    vysledek.reverse()

    return (vysledek, None) if vysledek else ([], "bez_uzemi")


def wkt_polygonu(poslist):
    """
    Z posListu katastru (S-JTSK) udělá WKT ve WGS84 s vnějším
    ringem proti směru hodinových ručiček.

    Orientace se počítá AŽ PO transformaci. V kroku 03b se
    počítala na S-JTSK souřadnicích a protože osy obou systémů
    jsou orientované různě, vyšla obráceně u všech 148 404
    polygonů.
    """
    c = poslist.split()
    if len(c) < 8:
        return None
    try:
        body = [TRANS.transform(float(c[i]), float(c[i + 1]))
                for i in range(0, len(c) - 1, 2)]
    except ValueError:
        return None

    if body[0] != body[-1]:
        body.append(body[0])
    if len(body) < 4:
        return None

    plocha2 = sum(body[i][0] * body[i + 1][1] - body[i + 1][0] * body[i][1]
                  for i in range(len(body) - 1))
    if plocha2 < 0:
        body.reverse()

    return "POLYGON((" + ", ".join(
        f"{lon:.9f} {lat:.9f}" for lon, lat in body) + "))"


def stahni_parcelu(kod_ku, cislo_parcely, nazev_uzemi):
    """
    Vrátí (seznam záznamů, důvod neúspěchu). Vkládají se jen
    parcely, u nichž katastr potvrdil území v xlink:title —
    nikdy se nespoléhá na to, že vrátil, co se čekalo.
    """
    parametry = {
        "service": "WFS", "version": "2.0.0", "request": "GetFeature",
        "storedQuery_id": "GetParcel",
        "UPPER_ZONING_ID": str(kod_ku), "TEXT": cislo_parcely,
    }

    odpoved = None
    for pokus in range(1, OPAKOVANI + 1):
        try:
            r = requests.get(WFS, params=parametry, timeout=90)
            if r.status_code == 200:
                odpoved = r.content
                break
            log.warning(f"  HTTP {r.status_code} (pokus {pokus})")
        except Exception as e:
            log.warning(f"  spojení selhalo: {type(e).__name__} (pokus {pokus})")
        time.sleep(2 * pokus)

    if odpoved is None:
        return [], "katastr_nedostupny"

    try:
        strom = etree.fromstring(odpoved)
    except Exception:
        return [], "odpoved_neplatna"

    zaznamy, cizi = [], 0
    for prvek in strom.findall(".//CP:CadastralParcel", namespaces=NS):
        zoning = prvek.find("CP:zoning", namespaces=NS)
        nazev = (zoning.get(XLINK_TITLE) or "").strip() if zoning is not None else ""
        if nazev and nazev.lower() != nazev_uzemi.lower():
            cizi += 1
            continue

        def txt(cesta):
            el = prvek.find(cesta, namespaces=NS)
            return el.text.strip() if el is not None and el.text else None

        try:
            vymera = float(txt("CP:areaValue")) if txt("CP:areaValue") else None
        except ValueError:
            vymera = None

        geom = prvek.find(
            "CP:geometry/gml:Polygon/gml:exterior/gml:LinearRing/gml:posList",
            namespaces=NS)
        wkt = wkt_polygonu(geom.text.strip()) if (
            geom is not None and geom.text) else None

        x = y = lon = lat = None
        bod = prvek.find("CP:referencePoint/gml:Point/gml:pos", namespaces=NS)
        if bod is not None and bod.text:
            c = bod.text.strip().split()
            if len(c) >= 2:
                try:
                    x, y = float(c[0]), float(c[1])
                    lon, lat = TRANS.transform(x, y)
                except ValueError:
                    pass

        zaznamy.append({
            "kod_ku": int(kod_ku),
            "parcel_number": cislo_parcely,
            "gml_id": prvek.get(GML_ID),
            "areaValue_m2": vymera,
            "beginLifespanVersion": txt("CP:beginLifespanVersion"),
            "refPoint_x": x, "refPoint_y": y,
            "refPoint_lon": lon, "refPoint_lat": lat,
            "wkt": wkt,
        })

    if not zaznamy:
        return [], "cizi_uzemi_odmitnuto" if cizi else "nenalezeno"
    return zaznamy, None


SQL_FRONTA = text("""
    INSERT INTO dbo.KN_k_pretazeni
        (id_valuo, duvod, adresa, popis, okres, kat_uzemi,
         nemovitost, plocha, zpracovano)
    SELECT v.id, 'IMPORT30', v.adresa, v.popis, v.okres, v.kat_uzemi,
           v.nemovitost, v.plocha, 0
    FROM dbo.Valuo_data v
    WHERE NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data k
                      WHERE k.id_valuo = v.id)
      AND NOT EXISTS (SELECT 1 FROM dbo.KN_k_pretazeni q
                      WHERE q.id_valuo = v.id);
""")

SQL_SMAZ_UP = text("""
    DELETE u FROM dbo.KN_parcel_UP u
    JOIN dbo.KN_parcel_data k ON k.id = u.kn_id
    WHERE k.id_valuo = :idv
""")
SQL_SMAZ_PARCELY = text(
    "DELETE FROM dbo.KN_parcel_data WHERE id_valuo = :idv")

# geometrie se zapisuje rovnou jako geography; sloupec geometry
# zůstává nedotčený (je NULL u všech řádků, viz úvod)
SQL_VLOZ_PARCELU = text("""
    INSERT INTO dbo.KN_parcel_data
        (id_valuo, kod_ku, parcel_number, gml_id, areaValue_m2,
         beginLifespanVersion, refPoint_x, refPoint_y,
         refPoint_lon, refPoint_lat, geo_bod, geo_plocha)
    VALUES (:id_valuo, :kod_ku, :parcel_number, :gml_id, :areaValue_m2,
            :beginLifespanVersion, :refPoint_x, :refPoint_y,
            :refPoint_lon, :refPoint_lat,
            CASE WHEN :refPoint_lat IS NULL THEN NULL
                 ELSE geography::Point(:refPoint_lat, :refPoint_lon, 4326)
            END,
            CASE WHEN :wkt IS NULL THEN NULL
                 ELSE geography::STGeomFromText(:wkt, 4326)
            END)
""")
SQL_OZNAC = text(
    "UPDATE dbo.KN_k_pretazeni SET zpracovano = 1 WHERE id_valuo = :idv")

SQL_OTOCIT = text("""
    UPDATE dbo.KN_parcel_data
    SET geo_plocha = geo_plocha.ReorientObject()
    WHERE geo_plocha IS NOT NULL AND geo_plocha.STArea() > 1e10
""")


# Souřadnice a kód území vkladu se berou z NEJVĚTŠÍ parcely vkladu —
# stejná logika jako v krocích 02c, 02d a 18. Bez tohohle kroku vzorek
# nové záznamy nevidí: v_Valuo_vzorek bere jen geo_zdroj = 'KN_refPoint'.
# Ve verzi 30.0 tento krok chyběl a přepočty 24. 10. 2026 proběhly
# jen nad starými daty.
#
# kod_ku se tu PŘEPISUJE kódem z katastru. Import ho plní z názvu
# území balíčku, protože jiný údaj v té chvíli není — jenže balíček
# je u ~13 % parcel jiné území než nemovitost. Stará data mají kod_ku
# z katastru (98 901 z 99 281 shod s největší parcelou), takže tohle
# je návrat ke stejnému významu sloupce, ne nové pravidlo.
#
# Podmínka „kod_ku IS NULL" je od 24. 10. 2026 trvalá pojistka.
# Při prvním běhu doplnila 7 134 starých řádků: krok 17 jim dotáhl
# parcely, krok 18 souřadnice, ale kod_ku nedoplnil nikdo (byly to
# přesně ty řádky, které krok 17 zpracovával) — 604 vkladů proto
# vypadávalo ze vzorku, který se k číselníku území připojuje přes kod_ku.
#
# LAT a LON se nenastavují — jsou to počítané sloupce z geo_bod.
SQL_DOPLN_VALUO = text("""
    WITH nejvetsi_parcela AS (
        SELECT k.id_valuo, k.refPoint_lat, k.refPoint_lon, k.kod_ku,
               ROW_NUMBER() OVER (PARTITION BY k.id_valuo
                                  ORDER BY k.areaValue_m2 DESC, k.id) AS poradi
        FROM dbo.KN_parcel_data k
        WHERE k.refPoint_lat BETWEEN 48.5 AND 51.1
          AND k.refPoint_lon BETWEEN 12.0 AND 18.9
    )
    UPDATE v
    SET v.geo_bod   = geography::Point(p.refPoint_lat, p.refPoint_lon, 4326),
        v.geo_zdroj = 'KN_refPoint',
        v.kod_ku    = p.kod_ku
    FROM dbo.Valuo_data v
    JOIN nejvetsi_parcela p ON p.id_valuo = v.id AND p.poradi = 1
    /* Od verze 30.4 rozhoduje OBSAH, ne štítek. Předchozí znění
       přeskakovalo každý řádek, který už měl geo_zdroj = 'KN_refPoint'
       a kod_ku — a tím konzervovalo 8 428 řádků (6 152 vkladů ve 36 k. ú.),
       jejichž bod neodpovídal žádné jejich vlastní parcele; průměrně
       o 1 150 m, nejvíc o 3 672 m. Krok 43 je opravil, tato podmínka
       zabraňuje návratu: kdykoli bod neodpovídá největší parcele řádku,
       přepíše se. Zůstává idempotentní — podruhé nezmění ani řádek.
       Pozor: kdyby se někdy zavedl ruční bod od znalce, potřebuje výjimku. */
    WHERE v.geo_zdroj IS NULL
       OR v.geo_zdroj <> 'KN_refPoint'
       OR v.kod_ku IS NULL
       OR v.kod_ku <> p.kod_ku
       OR v.geo_bod IS NULL
       OR ABS(v.geo_bod.Lat  - p.refPoint_lat) > 0.000001
       OR ABS(v.geo_bod.Long - p.refPoint_lon) > 0.000001;
""")


def dopln_souradnice_valuo():
    """Promítne souřadnice a kód území z parcel do Valuo_data.
    Idempotentní — dá se pouštět kdykoli."""
    with db().begin() as c:
        n = c.execute(SQL_DOPLN_VALUO).rowcount
    zbyva = db().connect().execute(text("""
        SELECT COUNT(*) FROM dbo.Valuo_data v
        WHERE v.geo_bod IS NULL
          AND EXISTS (SELECT 1 FROM dbo.KN_parcel_data k
                      WHERE k.id_valuo = v.id)
    """)).scalar()
    log.info(f"Souřadnice a kód území promítnuty do Valuo_data: {mezery(n)}")
    if n:
        log.info("  (od verze 30.4 je to počet řádků, jimž se bod skutečně "
                 "posunul — při opakovaném běhu bez nových parcel má být 0)")
    if zbyva:
        log.warning(f"  {mezery(zbyva)} řádků má parcelu, ale stále nemá "
                    "souřadnici — parcela mimo rozsah ČR nebo bez bodu")
    return n


def zapis_parcely(davka):
    """davka = [(id_valuo, [zaznamy])] — jedna transakce na dávku."""
    with db().begin() as c:
        for id_valuo, parcely in davka:
            if parcely:
                c.execute(SQL_SMAZ_UP, {"idv": int(id_valuo)})
                c.execute(SQL_SMAZ_PARCELY, {"idv": int(id_valuo)})
            videno = set()
            for z in parcely:
                if z["gml_id"] in videno:
                    continue
                videno.add(z["gml_id"])
                c.execute(SQL_VLOZ_PARCELU,
                          dict(z, id_valuo=int(id_valuo)))
            c.execute(SQL_OZNAC, {"idv": int(id_valuo)})


def etapa_parcely(limit=None, log_csv=None):
    zaloz_tabulky()
    with db().begin() as c:
        pridano = c.execute(SQL_FRONTA).rowcount
    log.info(f"Do fronty přidáno vkladů: {mezery(pridano)}")

    ciselnik = pd.read_sql(
        "SELECT ku_kod, ku_nazev FROM dbo.CIS_katastralni_uzemi", db())
    kody = {r.ku_nazev.strip().lower(): int(r.ku_kod)
            for r in ciselnik.itertuples()}

    sql = ("SELECT id_valuo, duvod, popis, nemovitost, plocha "
           "FROM dbo.KN_k_pretazeni WHERE zpracovano = 0 ORDER BY id_valuo")
    if limit:
        sql = sql.replace("SELECT", f"SELECT TOP {limit}", 1)
    df = pd.read_sql(sql, db())
    log.info(f"Ke zpracování: {mezery(len(df))} vkladů")
    if df.empty:
        log.info("Fronta je prázdná.")
        dopln_souradnice_valuo()
        return 0

    w = None
    if log_csv:
        f = open(log_csv, "w", encoding="utf-8-sig", newline="")
        w = csv.writer(f, delimiter=";")
        w.writerow(["id_valuo", "uzemi", "parcela", "vysledek",
                    "vymera_valuo", "vymera_katastr", "detail"])

    davka, stat = [], Counter()
    zacatek = time.time()

    for i, r in enumerate(df.itertuples(), 1):
        parcely, duvod = parcely_z_popisu(r.popis)

        if duvod:
            stat[duvod] += 1
            if w:
                w.writerow([r.id_valuo, "", "", duvod, r.plocha, "",
                            (r.popis or "")[:90]])
            davka.append((r.id_valuo, []))
        else:
            nalezene = []
            for uzemi, cislo_parcely in parcely:
                kod = kody.get(uzemi.strip().lower())
                if kod is None:
                    stat["uzemi_neni_v_ciselniku"] += 1
                    if w:
                        w.writerow([r.id_valuo, uzemi, cislo_parcely,
                                    "uzemi_neni_v_ciselniku", r.plocha, "", ""])
                    continue

                zaznamy, chyba = stahni_parcelu(kod, cislo_parcely, uzemi)
                time.sleep(PAUZA_S)

                if chyba:
                    stat[chyba] += 1
                    if w:
                        w.writerow([r.id_valuo, uzemi, cislo_parcely, chyba,
                                    r.plocha, "", f"kod_ku={kod}"])
                    continue

                nalezene.extend(zaznamy)
                stat["nalezeno"] += 1
                vym = zaznamy[0]["areaValue_m2"]
                sedi = ""
                if r.nemovitost == "parcela" and r.plocha and vym:
                    sedi = ("vymera_sedi" if abs(float(r.plocha) - vym) < 1
                            else "vymera_nesedi")
                if w:
                    w.writerow([r.id_valuo, uzemi, cislo_parcely, "ok",
                                r.plocha, vym, sedi])

            davka.append((r.id_valuo, nalezene))

        if len(davka) >= DAVKA:
            zapis_parcely(davka)
            davka = []
            if w:
                f.flush()
            podil = i / len(df)
            zbyva = (time.time() - zacatek) / max(podil, 1e-9) * (1 - podil)
            log.info(f"  {mezery(i)} / {mezery(len(df))} ({podil:.0%}), "
                     f"zbývá asi {zbyva / 60:.0f} min")

    if davka:
        zapis_parcely(davka)
    if w:
        f.close()

    with db().begin() as c:
        otoceno = c.execute(SQL_OTOCIT).rowcount
    if otoceno:
        log.warning(f"Dodatečně otočeno obrácených polygonů: {otoceno}")

    dopln_souradnice_valuo()

    log.info("")
    log.info("KATASTR — SOUHRN")
    for k, v in stat.most_common():
        log.info(f"  {k:<24} {mezery(v):>9}")
    if log_csv:
        log.info(f"  log: {log_csv}")
    return stat["nalezeno"]


# ==================================================================
# ETAPA 4 — ZATŘÍDĚNÍ DO ÚZEMNÍHO PLÁNU
# ==================================================================
# Počítá SQL Server nad geo_plocha. Typ geography měří na
# elipsoidu rovnou v metrech, takže reprojekce do S-JTSK není
# potřeba a nehrozí problém s orientací ringů, na kterém padal
# krok 03b.
#
# Tabulka KN_parcel_UP se NEMAŽE. Krok 09 ji pokaždé dropoval
# a počítal celou Prahu znovu; tady se zpracují jen parcely,
# které zatřídění ještě nemají.
#
# Evidence KN_parcel_UP_stav je tu proto, že parcela bez průniku
# se žádným řádkem neprojeví — bez evidence by se počítala při
# každém běhu znovu a cyklus by se nezastavil.
#
# Územní plán pokrývá jen Prahu (UP_FVU_data, ZDROJ = PUP_2501).
# ==================================================================

DDL_UP = """
IF OBJECT_ID('dbo.KN_parcel_UP_stav') IS NULL
CREATE TABLE dbo.KN_parcel_UP_stav (
    kn_id      int          NOT NULL
        CONSTRAINT PK_KN_parcel_UP_stav PRIMARY KEY CLUSTERED,
    ploch      int          NOT NULL,
    vypocteno  datetime2(0) NOT NULL
        CONSTRAINT DF_KN_parcel_UP_stav DEFAULT SYSDATETIME()
);

-- parcely zatříděné dřívějšími běhy se doplní jednorázově,
-- aby se nepočítaly znovu
INSERT INTO dbo.KN_parcel_UP_stav (kn_id, ploch)
SELECT u.kn_id, COUNT(*)
FROM dbo.KN_parcel_UP u
WHERE NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_UP_stav s
                  WHERE s.kn_id = u.kn_id)
GROUP BY u.kn_id;
"""

# SET NOCOUNT ON je tu nutné, ne kosmetické: tenhle batch má víc
# příkazů za sebou a bez něj vrací ovladač jako první výsledek
# hlášení o počtu řádků z úvodního INSERTu. Čtení závěrečného
# SELECTu pak spadne na "This result object does not return rows".
SQL_UP_DAVKA = text("""
    SET NOCOUNT ON;

    DECLARE @davka TABLE (kn_id int PRIMARY KEY);

    INSERT INTO @davka (kn_id)
    SELECT TOP (:davka) k.id
    FROM dbo.KN_parcel_data k
    JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
    WHERE c.kraj_nazev = :praha
      AND k.geo_plocha IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_UP_stav s
                      WHERE s.kn_id = k.id)
    ORDER BY k.id;

    INSERT INTO dbo.KN_parcel_UP
        (kn_id, up_id, fvu_kod, mira_vyuziti,
         plocha_parcely_m2, plocha_pruniku_m2, podil_pct, poradi)
    SELECT x.kn_id, x.up_id, x.fvu_kod, x.mira_vyuziti,
           x.pp, x.ppr, x.pct,
           ROW_NUMBER() OVER (PARTITION BY x.kn_id ORDER BY x.ppr DESC)
    FROM (
        SELECT y.kn_id, y.up_id, y.fvu_kod, y.mira_vyuziti, y.pp, y.ppr,
               CAST(100.0 * y.ppr / NULLIF(y.pp, 0) AS decimal(6,2)) AS pct
        FROM (
            SELECT d.kn_id,
                   u.id        AS up_id,
                   u.KODFP1_A  AS fvu_kod,
                   u.ZAS1      AS mira_vyuziti,
                   CAST(k.geo_plocha.STArea() AS decimal(18,2)) AS pp,
                   CAST(k.geo_plocha.STIntersection(u.geo_plocha).STArea()
                        AS decimal(18,2)) AS ppr
            FROM @davka d
            JOIN dbo.KN_parcel_data k ON k.id = d.kn_id
            JOIN dbo.UP_FVU_data u
                 ON u.geo_plocha.STIntersects(k.geo_plocha) = 1
        ) y
        WHERE y.ppr > 0
    ) x
    WHERE x.pct >= :min_podil
      AND NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_UP p
                      WHERE p.kn_id = x.kn_id AND p.up_id = x.up_id);

    INSERT INTO dbo.KN_parcel_UP_stav (kn_id, ploch)
    SELECT d.kn_id, (SELECT COUNT(*) FROM dbo.KN_parcel_UP p
                     WHERE p.kn_id = d.kn_id)
    FROM @davka d;

    SELECT COUNT(*) FROM @davka;

    -- zpět, jinak by nastavení zůstalo na spojení z poolu
    -- a .rowcount u dalších příkazů by vracel -1
    SET NOCOUNT OFF;
""")

SQL_UP_DOMINANTNI = text("""
    UPDATE k SET k.id_UP_FVU_data = p.up_id
    FROM dbo.KN_parcel_data k
    JOIN dbo.KN_parcel_UP p ON p.kn_id = k.id AND p.poradi = 1
    WHERE k.id_UP_FVU_data IS NULL OR k.id_UP_FVU_data <> p.up_id
""")


def etapa_up():
    with db().begin() as c:
        for prikaz in DDL_UP.split(";"):
            if prikaz.strip():
                c.execute(text(prikaz))

    zbyva = db().connect().execute(text("""
        SELECT COUNT(*) FROM dbo.KN_parcel_data k
        JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
        WHERE c.kraj_nazev = :praha AND k.geo_plocha IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_UP_stav s
                          WHERE s.kn_id = k.id)
    """), {"praha": PRAHA}).scalar()

    log.info(f"Pražských parcel bez zatřídění: {mezery(zbyva)}")
    if not zbyva:
        log.info("Není co počítat.")
        return 0

    hotovo, zacatek = 0, time.time()
    while True:
        with db().begin() as c:
            zpracovano = c.execute(SQL_UP_DAVKA, {
                "davka": DAVKA_UP, "praha": PRAHA,
                "min_podil": MIN_PODIL_PCT,
            }).scalar()
        if not zpracovano:
            break
        hotovo += zpracovano
        podil = hotovo / zbyva
        log.info(f"  {mezery(hotovo)} / {mezery(zbyva)} ({podil:.0%}), "
                 f"{(time.time() - zacatek) / 60:.0f} min")

    with db().begin() as c:
        zmeneno = c.execute(SQL_UP_DOMINANTNI).rowcount
    log.info(f"Dominantní plocha doplněna u parcel: {mezery(zmeneno)}")

    prehled = pd.read_sql("""
        SELECT ploch, COUNT(*) AS parcel
        FROM (SELECT kn_id, COUNT(*) AS ploch FROM dbo.KN_parcel_UP
              GROUP BY kn_id) t
        GROUP BY ploch ORDER BY ploch
    """, db())
    log.info("")
    log.info("Do kolika ploch ÚP parcela zasahuje:")
    for r in prehled.itertuples():
        log.info(f"  {r.ploch:>2} ploch  {mezery(r.parcel):>9} parcel")
    return hotovo


# ==================================================================
# ETAPA 5 — PÁROVÁNÍ NA RÚIAN A CHYBĚJÍCÍ OBCE
# ==================================================================
# RÚIAN se stahuje po obcích a jeho import je samostatný
# (27_ruian_import.py) — jiná kadence i jiná granularita.
# Tenhle krok jen řekne, co chybí: obce, kde jsou nové budovy
# nebo jednotky a RÚIAN pro ně v databázi není, nebo je starý.
#
# U obcí, kde jsou jen pozemky, nemá RÚIAN co nabídnout.
# ==================================================================

STARI_RUIAN_DNU = 180

SQL_RUIAN_FRONTA = text("""
    SET NOCOUNT ON;

    DELETE FROM dbo.RUIAN_k_pretazeni WHERE zpracovano = 0;

    INSERT INTO dbo.RUIAN_k_pretazeni (obec_kod, obec_nazev, nemovitosti, duvod)
    SELECT t.obec_kod, t.obec_nazev, t.nemovitosti,
           CASE WHEN s.obec_kod IS NULL THEN 'CHYBI' ELSE 'ZASTARALE' END
    FROM (
        SELECT ku.obec_kod, MIN(ku.obec_nazev) AS obec_nazev,
               COUNT(DISTINCT v.id) AS nemovitosti
        FROM dbo.Valuo_data v
        JOIN dbo.KN_parcel_data p ON p.id_valuo = v.id
        JOIN dbo.CIS_katastralni_uzemi ku ON ku.ku_kod = p.kod_ku
        WHERE v.nemovitost IN ('budova', 'jednotka')
        GROUP BY ku.obec_kod
    ) t
    LEFT JOIN dbo.RUIAN_obce_stav s ON s.obec_kod = t.obec_kod
    WHERE s.obec_kod IS NULL
       OR s.soubor_datum < DATEADD(day, -:stari, CAST(SYSDATETIME() AS date));

    SET NOCOUNT OFF;
""")


def etapa_ruian(log_csv=None):
    zaloz_tabulky()
    with db().begin() as c:
        c.execute(SQL_RUIAN_FRONTA, {"stari": STARI_RUIAN_DNU})

    fronta = pd.read_sql("""
        SELECT obec_kod, obec_nazev, nemovitosti, duvod
        FROM dbo.RUIAN_k_pretazeni WHERE zpracovano = 0
        ORDER BY duvod, nemovitosti DESC
    """, db())

    # kolik nemovitostí po importu zůstalo bez napojení na RÚIAN
    nenapojeno = pd.read_sql("""
        SELECT v.nemovitost, COUNT(DISTINCT v.cislo_vkladu) AS vkladu
        FROM dbo.Valuo_data v
        WHERE v.nemovitost IN ('budova', 'jednotka')
          AND NOT EXISTS (SELECT 1 FROM dbo.RUIAN_vzorek r
                          WHERE r.cislo_vkladu = v.cislo_vkladu)
        GROUP BY v.nemovitost
    """, db())

    log.info("")
    log.info("PÁROVÁNÍ NA RÚIAN")
    if not nenapojeno.empty:
        log.info("  vklady bez údajů z RÚIANu:")
        for r in nenapojeno.itertuples():
            log.info(f"    {r.nemovitost:<12} {mezery(r.vkladu):>9}")

    if log_csv:
        # CSV se zakládá vždy, i když je prázdné — ať je po běhu
        # jasné, že se kontrola provedla, a nehledá se, kde soubor je
        with open(log_csv, "w", encoding="utf-8-sig", newline="") as f:
            z = csv.writer(f, delimiter=";")
            z.writerow(["obec_kod", "obec_nazev", "nemovitosti", "duvod"])
            for r in fronta.itertuples():
                z.writerow([r.obec_kod, r.obec_nazev, r.nemovitosti, r.duvod])

    if fronta.empty:
        log.info("  RÚIAN pokrývá všechny obce s budovou nebo jednotkou.")
        if log_csv:
            log.info(f"  (prázdný seznam i tak uložen: {log_csv})")
        return 0

    log.info("")
    log.info(f"  OBCE K DOTAŽENÍ: {len(fronta)}")
    log.info(f"  {'kód':>7}  {'obec':<34} {'nemovitostí':>11}  důvod")
    for r in fronta.itertuples():
        log.info(f"  {r.obec_kod:>7}  {(r.obec_nazev or '')[:34]:<34} "
                 f"{mezery(r.nemovitosti):>11}  {r.duvod}")

    kody = ",".join(str(k) for k in fronta["obec_kod"])
    log.info("")
    log.info("  Stáhni a naimportuj je:")
    log.info(f"    python 27_ruian_import.py --stahni {kody}")
    log.info("    python 27_ruian_import.py --import")
    log.info("")
    log.info("  Seznam je i v tabulce dbo.RUIAN_k_pretazeni.")
    if log_csv:
        log.info(f"  CSV: {log_csv}")
    log.info("  Po doimportování pusť znovu --prepocty, aby se")
    log.info("  nové údaje promítly do vzorku a do mezí.")
    return len(fronta)


# ==================================================================
# ETAPA 6 — PŘEPOČTY
# ==================================================================
# Pořadí je závazné: prahy čtou vzorek, vzorek čte klasifikaci
# a detektory. Pět z nich se nevejde do 60s limitu nástroje MCP,
# proto se pouští odsud, pod účtem Windows a bez časového limitu.
# ==================================================================

PROCEDURY = [
    ("sp_prepocet_jednotkovych_cen", "klasifikace vkladů a plochy"),
    ("sp_prepocet_typu_prevodu",     "dražba, dar, směna"),
    ("sp_prepocet_men",              "cena_Kc z kurzů ČNB"),
    ("sp_detekce_hromadnych_prevodu", "detektor podle jednotkové ceny"),
    ("sp_detekce_prevodu_dle_ceny",  "detektor podle celkové ceny"),
    ("sp_prepocet_ruian_vzorku",     "RÚIAN na úroveň vkladu"),
    ("sp_prepocet_prahu",            "meze z dat — čte vzorek, běží nakonec"),
]


SQL_KURZY = text("""
    SELECT (SELECT MAX(datum) FROM dbo.CIS_kurzy_CNB) AS kurzy_do,
           (SELECT COUNT(*) FROM dbo.Valuo_data v
            WHERE v.mena <> 'CZK'
              AND CAST(v.datum_podani AS date) >
                  (SELECT MAX(datum) FROM dbo.CIS_kurzy_CNB)) AS bez_kurzu
""")


def zkontroluj_kurzy():
    """
    sp_prepocet_men bere kurz ke dni podání návrhu na vklad.
    Přibyl-li vklad v cizí měně novější než poslední stažený kurz,
    zůstane mu cena_Kc prázdná a vypadne ze vzorku — tiše.
    """
    r = db().connect().execute(SQL_KURZY).fetchone()
    if r and r[1]:
        log.warning("")
        log.warning(f"  POZOR: {r[1]} vkladů v cizí měně je novějších")
        log.warning(f"  než poslední kurz ČNB ({r[0]}). Zůstala by jim")
        log.warning("  prázdná cena_Kc. Stáhni kurzy a pusť přepočty znovu:")
        log.warning("      python 19_kurzy_CNB.py")
        log.warning("")


def nacti_dopocty():
    """Krok 38 jako modul. Logika dopočtu karet je na jednom místě — tady
    se jen volá, aby to šlo pustit jedním příkazem."""
    import importlib.util
    # pathlib, ne os.path: tenhle modul os vůbec neimportuje. Volání
    # os.path.join tu leželo od zavedení funkce a spadlo na NameError při
    # prvním skutečném použití --dopocty (28. 10. 2026, nalezl znalec).
    cesta = Path(__file__).resolve().parent / "38_prepocty.py"
    if not cesta.exists():
        raise SystemExit(f"Vedle tohoto skriptu chybí 38_prepocty.py ({cesta}).")
    spec = importlib.util.spec_from_file_location("prepocty38", cesta)
    modul = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modul)
    return modul


def etapa_dopocty(krok="vse", prepocitat=False):
    """Karty, mapa a registr ploch. Trvá u plné databáze hodiny, ale je to
    přerušitelné a navazuje — po přerušení stačí pustit znovu.

    Fázovat se dá přes --krok (okoli, karty, tvar, mapa, plochy), kdyby
    některá část spadla a nemělo smysl opakovat zbytek."""
    log.info("")
    log.info("DOPOČTY KARET, MAPY A REGISTRU PLOCH")
    log.info("  Přerušitelné. Po přerušení pusť znovu — dopočítá se, co chybí.")
    nacti_dopocty().spust(krok=krok, prepocitat=prepocitat)


def etapa_prepocty():
    log.info("")
    log.info("PŘEPOČTY")
    # pojistka: bez souřadnic vzorek nové záznamy nevidí a přepočet
    # by proběhl jen nad starými daty
    dopln_souradnice_valuo()
    zkontroluj_kurzy()
    for nazev, popis in PROCEDURY:
        zacatek = time.time()
        log.info(f"  {nazev} — {popis}")
        with db().begin() as c:
            c.execute(text(f"EXEC dbo.{nazev}"))
        log.info(f"    hotovo za {(time.time() - zacatek) / 60:.1f} min")

    prehled = pd.read_sql("""
        SELECT hodnoceni_ceny, COUNT(*) AS vkladu
        FROM dbo.v_Valuo_vzorek_q
        GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC
    """, db())
    log.info("")
    log.info("STAV VZORKU PO PŘEPOČTU")
    for r in prehled.itertuples():
        log.info(f"  {(r.hodnoceni_ceny or '—'):<28} {mezery(r.vkladu):>9}")

    # Vrstva karty, mapy a registru ploch běží samostatně (38_prepocty.py),
    # protože dopočet karet trvá hodiny a nemá smysl ho vázat na každý import.
    # Bez něj ale nové vklady nemají kartu, nejsou v mapě a nemají kontrolu
    # posunu desetinné čárky — proto tahle připomínka na konci běhu.
    # Počítají se jen vklady, které kartu a bod MÍT MOHOU, tedy ty s kod_ku.
    # Bez kódu k. ú. je 96 vkladů, které v mapě nikdy nebudou, a 98 bez karty.
    # Do 25. 10. 2026 se do výstrahy počítaly, takže hlásila „mimo mapu 96"
    # po každém importu, i když mapa byla hotová, a posílala dopočítávat
    # něco, co dopočítat nelze. Falešná výstraha po pár opakováních přestane
    # být výstrahou.
    chybi = pd.read_sql("""
        SELECT (SELECT COUNT(DISTINCT d.cislo_vkladu) FROM dbo.Valuo_data d
                WHERE d.kod_ku IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM dbo.Valuo_karta_vklad k
                                  WHERE k.cislo_vkladu = d.cislo_vkladu)) AS bez_karty,
               (SELECT COUNT(DISTINCT d.cislo_vkladu) FROM dbo.Valuo_data d
                WHERE d.kod_ku IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM dbo.Valuo_mapa m
                                  WHERE m.cislo_vkladu = d.cislo_vkladu)) AS bez_mapy
    """, db()).iloc[0]
    if int(chybi.bez_karty) > 0 or int(chybi.bez_mapy) > 0:
        log.info("")
        log.warning(f"  Bez karty zůstává {mezery(int(chybi.bez_karty))} vkladů, "
                    f"mimo mapu {mezery(int(chybi.bez_mapy))}.")
        log.warning("  Dopočítej je:  python 38_prepocty.py")
        log.warning("  (okolí → karty → tvar → registr ploch → mapa; "
                    "přerušitelné, naváže)")
    return len(prehled)


# ==================================================================
def main():
    global SERVER
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--slozka", default=SLOZKA,
                   help="složka se zdrojovými excely")
    p.add_argument("--server", default=SERVER, help=f"SQL server ({SERVER})")
    p.add_argument("--inventura", action="store_true",
                   help="co je nového — nic nemění")
    p.add_argument("--import", dest="imp", action="store_true",
                   help="načte nové excely do Valuo_data")
    p.add_argument("--parcely", action="store_true",
                   help="dotáhne parcely z katastru včetně geometrie")
    p.add_argument("--up", action="store_true",
                   help="zatřídí pražské parcely do územního plánu")
    p.add_argument("--ruian", action="store_true",
                   help="spáruje na RÚIAN a vypíše chybějící obce")
    p.add_argument("--prepocty", action="store_true",
                   help="spustí sedm procedur v závazném pořadí")
    p.add_argument("--dopocty", action="store_true",
                   help="karty, mapa a registr ploch (krok 38); přerušitelné")
    p.add_argument("--krok", default="vse",
                   choices=["okoli", "karty", "tvar", "mapa", "plochy", "vse"],
                   help="fáze dopočtů, když má smysl opakovat jen část")
    p.add_argument("--prepocitat", action="store_true",
                   help="u dopočtů počítat znovu i to, co už hotové je")
    p.add_argument("--vse", action="store_true", help="celý řetězec")
    p.add_argument("--limit", type=int,
                   help="u --parcely zpracuje jen prvních N vkladů")
    p.add_argument("--podrobne", action="store_true",
                   help="u --inventura vypíše názvy souborů")
    p.add_argument("--verze", action="version",
                   version=f"30_import_valuo {VERZE}")
    a = p.parse_args()

    SERVER = a.server
    slozka = Path(a.slozka)

    print(f"30_import_valuo {VERZE}")
    print(f"server {SERVER}, databáze {DATABAZE}")
    print(f"zdroj  {slozka}\n")

    if not (a.inventura or a.imp or a.parcely or a.up or a.ruian
            or a.prepocty or a.dopocty or a.vse):
        p.error("zadej --inventura, --import, --parcely, --up, --ruian, "
                "--prepocty, --dopocty nebo --vse")

    if not slozka.is_dir() and (a.inventura or a.imp or a.vse):
        p.error(f"složka neexistuje: {slozka}")

    kdy = datetime.now().strftime("%Y%m%d_%H%M")
    tady = Path(__file__).parent
    zacatek = time.time()

    if a.inventura and not a.vse:
        etapa_inventura(slozka, podrobne=a.podrobne)
        return

    try:
        if a.imp or a.vse:
            log.info("=" * 58)
            log.info("ETAPA 1–2  EXCELY")
            log.info("=" * 58)
            etapa_import(slozka, log_csv=tady / f"30_odmitnute_{kdy}.csv")

        if a.parcely or a.vse:
            log.info("")
            log.info("=" * 58)
            log.info("ETAPA 3  KATASTR")
            log.info("=" * 58)
            etapa_parcely(limit=a.limit,
                          log_csv=tady / f"30_katastr_{kdy}.csv")

        if a.up or a.vse:
            log.info("")
            log.info("=" * 58)
            log.info("ETAPA 4  ÚZEMNÍ PLÁN")
            log.info("=" * 58)
            etapa_up()

        if a.ruian or a.vse:
            log.info("")
            log.info("=" * 58)
            log.info("ETAPA 5  RÚIAN")
            log.info("=" * 58)
            etapa_ruian(log_csv=tady / f"30_ruian_obce_{kdy}.csv")

        if a.prepocty or a.vse:
            log.info("")
            log.info("=" * 58)
            log.info("ETAPA 6  PŘEPOČTY")
            log.info("=" * 58)
            etapa_prepocty()

        if a.dopocty or a.vse:
            etapa_dopocty(krok=a.krok, prepocitat=a.prepocitat)

    except ZmenaStruktury:
        return 2
    except KeyboardInterrupt:
        log.warning("")
        log.warning("Přerušeno. Hotové dávky jsou zapsané; další běh")
        log.warning("pokračuje tam, kde se skončilo.")
        return 1

    log.info("")
    log.info(f"Celkem {(time.time() - zacatek) / 60:.0f} min.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
