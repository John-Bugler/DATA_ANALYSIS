"""
VALUO — KROK 19: KURZY ČNB

Stáhne denní kurzy devizového trhu ČNB za roky 2016–2026 a uloží je
do tabulky CIS_kurzy_CNB. Nic jiného nemění, takže běží bez problémů
současně s krokem 17.

Po dokončení spusť 19b_prepocet_men.sql.

================================================================
PROČ TO POTŘEBUJEME
================================================================
247 vkladů má cenu v cizí měně a dnes se u nich jednotková cena
nepočítá vůbec — ve srovnávacím vzorku tedy chybí.

| Měna | Vkladů | Roky |
|------|--------|------|
| EUR  | 228    | 2016–2026 |
| USD  | 12     | 2021–2025 |
| CHF  | 3      | 2020–2025 |
| GBP  | 2      | 2025 |
| AUD  | 1      | 2021 |
| ANG  | 1      | 2025 |

ANG (nizozemskoantilský gulden) ČNB nekotuje. Ten jeden vklad
zůstane označený k rozhodnutí znalce; kurz se neodhaduje.

================================================================
KE KTERÉMU DNI SE PŘEPOČÍTÁVÁ
================================================================
K datu podání návrhu na vklad (datum_podani), ne k datu
zplatnění. Cena byla sjednána v kupní smlouvě, která je starší
než vklad, a datum podání je k ní nejblíž — mezi podáním
a zplatněním je v těchto datech průměrně 27 dní. Datum samotné
smlouvy data neobsahují.

ČNB kurz o víkendech a státních svátcích nevyhlašuje, takže
19b bere poslední vyhlášený kurz ke dni podání nebo před ním.

================================================================
FORMÁT ZDROJE
================================================================
https://www.cnb.cz/cs/financni-trhy/devizovy-trh/
    kurzy-devizoveho-trhu/kurzy-devizoveho-trhu/rok.txt?rok=2024

    Datum|1 AUD|1 BGN|...|100 HUF|1000 IDR|...|1 USD|1 XDR|1 ZAR
    02.01.2024|15,278|12,570|...

Oddělovač je svislítko, desetinný oddělovač čárka. U některých
měn je kurz vyhlášen za sto či tisíc jednotek (100 HUF, 1000 IDR,
100 INR, 100 ISK, 100 JPY, 100 KRW, 100 PHP, 100 THB, 100 TRY).
Množství se ukládá do samostatného sloupce, aby byl uložený kurz
doložitelný proti originálu, a přepočet na jednotku dělá teprve
19b.
"""

import logging
import urllib.parse
from datetime import datetime

import requests
from sqlalchemy import create_engine, text

CONN = (
    "Driver={ODBC Driver 17 for SQL Server};"
    "Server=localhost;"
    "Database=VALUO;"
    "Trusted_Connection=yes;"
)

ROKY = range(2016, 2027)
MENY = {"EUR", "USD", "CHF", "GBP", "AUD"}   # ANG ČNB nekotuje

URL = ("https://www.cnb.cz/cs/financni-trhy/devizovy-trh/"
       "kurzy-devizoveho-trhu/kurzy-devizoveho-trhu/rok.txt")

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s  %(levelname)-7s  %(message)s",
                    datefmt="%H:%M:%S")
log = logging.getLogger("kurzy")

engine = create_engine(
    f"mssql+pyodbc:///?odbc_connect={urllib.parse.quote_plus(CONN)}"
)

SQL_TABULKA = """
IF OBJECT_ID('dbo.CIS_kurzy_CNB') IS NULL
CREATE TABLE dbo.CIS_kurzy_CNB (
    mena      char(3)        NOT NULL,
    datum     date           NOT NULL,
    mnozstvi  int            NOT NULL,
    kurz      decimal(12,4)  NOT NULL,
    CONSTRAINT PK_CIS_kurzy_CNB PRIMARY KEY CLUSTERED (mena, datum)
);
"""

SQL_VLOZ = text("""
    MERGE dbo.CIS_kurzy_CNB AS c
    USING (SELECT :mena AS mena, :datum AS datum) AS n
       ON c.mena = n.mena AND c.datum = n.datum
    WHEN MATCHED THEN
        UPDATE SET mnozstvi = :mnozstvi, kurz = :kurz
    WHEN NOT MATCHED THEN
        INSERT (mena, datum, mnozstvi, kurz)
        VALUES (:mena, :datum, :mnozstvi, :kurz);
""")


def stahni_rok(rok):
    """Vrátí seznam slovníků s kurzy za jeden rok."""
    try:
        r = requests.get(URL, params={"rok": rok}, timeout=90)
    except Exception as e:
        log.error(f"  {rok}: spojení selhalo — {type(e).__name__}")
        return []

    if r.status_code != 200:
        log.error(f"  {rok}: HTTP {r.status_code}")
        return []

    r.encoding = "windows-1250"
    radky = [x for x in r.text.splitlines() if x.strip()]
    if len(radky) < 2:
        log.error(f"  {rok}: soubor je prázdný")
        return []

    # hlavička: Datum|1 AUD|1 BGN|...|100 HUF|...
    hlavicka = radky[0].split("|")
    sloupce = {}        # index -> (mena, mnozstvi)
    for i, pole in enumerate(hlavicka[1:], start=1):
        casti = pole.strip().split()
        if len(casti) != 2:
            continue
        try:
            mnozstvi = int(casti[0])
        except ValueError:
            continue
        mena = casti[1].upper()
        if mena in MENY:
            sloupce[i] = (mena, mnozstvi)

    chybi = MENY - {m for m, _ in sloupce.values()}
    if chybi:
        log.warning(f"  {rok}: v hlavičce chybí {', '.join(sorted(chybi))}")

    vysledek = []
    for radek in radky[1:]:
        pole = radek.split("|")
        try:
            datum = datetime.strptime(pole[0].strip(), "%d.%m.%Y").date()
        except (ValueError, IndexError):
            continue
        for i, (mena, mnozstvi) in sloupce.items():
            if i >= len(pole):
                continue
            hodnota = pole[i].strip().replace(",", ".")
            if not hodnota:
                continue
            try:
                kurz = float(hodnota)
            except ValueError:
                continue
            if kurz <= 0:
                continue
            vysledek.append({"mena": mena, "datum": datum,
                             "mnozstvi": mnozstvi, "kurz": kurz})
    return vysledek


def main():
    with engine.begin() as conn:
        conn.execute(text(SQL_TABULKA))

    celkem = 0
    for rok in ROKY:
        zaznamy = stahni_rok(rok)
        if not zaznamy:
            continue
        with engine.begin() as conn:
            conn.execute(SQL_VLOZ, zaznamy)
        celkem += len(zaznamy)
        dny = len({z["datum"] for z in zaznamy})
        log.info(f"  {rok}: {dny} dnů, {len(zaznamy)} kurzů")

    log.info("")
    log.info(f"Uloženo celkem {celkem:,} kurzů".replace(",", " "))

    import pandas as pd
    prehled = pd.read_sql("""
        SELECT mena, COUNT(*) AS dnu, MIN(datum) AS od, MAX(datum) AS do,
               CAST(MIN(kurz / mnozstvi) AS decimal(10,3)) AS kurz_min,
               CAST(MAX(kurz / mnozstvi) AS decimal(10,3)) AS kurz_max
        FROM dbo.CIS_kurzy_CNB GROUP BY mena ORDER BY mena
    """, engine)
    log.info("")
    log.info(prehled.to_string(index=False))

    chybejici = pd.read_sql("""
        SELECT v.mena, COUNT(DISTINCT v.cislo_vkladu) AS vkladu_bez_kurzu
        FROM dbo.Valuo_data v
        WHERE v.mena IS NOT NULL AND v.mena <> 'CZK'
          AND NOT EXISTS (SELECT 1 FROM dbo.CIS_kurzy_CNB k
                          WHERE k.mena = v.mena AND k.datum <= v.datum_podani)
        GROUP BY v.mena ORDER BY v.mena
    """, engine)
    if not chybejici.empty:
        log.info("")
        log.info("Vklady, pro které kurz není (čekáno: jen ANG):")
        log.info(chybejici.to_string(index=False))

    log.info("")
    log.info("Dál spusť 19b_prepocet_men.sql.")


if __name__ == "__main__":
    main()
