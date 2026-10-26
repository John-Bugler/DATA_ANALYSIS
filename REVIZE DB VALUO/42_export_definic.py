# -*- coding: utf-8 -*-
r"""
42_export_definic.py — záloha definic pohledů a procedur do _definice\

Proč samostatný skript
----------------------
Podle rozhodnutí z 24. 10. 2026 (`data/ROZHODNUTI.md`, oddíl *Soubory na disk
ukládá asistent sám*) se po každé změně pohledu nebo procedury ukládají
**úplné definice všech** do `_definice\definice_RRRRMMDD.sql`.

Asistent to sám udělat nemůže: jeho spojení vrací text po kouscích přes
MCP a u ~150 kB definic by to byly desítky volání, při kterých se snadno
něco zkomolí. Tenhle skript to vezme z `sys.sql_modules` jedním dotazem
a zapíše beze změny.

Použití
-------
    python 42_export_definic.py                  # dnešní datum
    python 42_export_definic.py --popis "po kroku 41"
    python 42_export_definic.py --datum 20261025

Kontrola
--------
Po zápisu přečte soubor zpátky a ověří, že každá definice je v něm znak
za znakem. Nesouhlasí-li jediná, skončí nenulovým kódem a vypíše, která
to je — soubor, který neprošel kontrolou, se smaže.

Zápis i čtení jde s `newline=""`. Bez toho Windows přeloží každé "\n"
na "\r\n" a definice, které CRLF už obsahují (vytvořené v SSMS), se
v souboru rozpadnou na "\r\r\n"; kontrola je pak nenajde, i když je
export v pořádku. Stalo se to 25. 10. 2026 u 11 z 23 objektů.
"""

import argparse
import urllib.parse
from datetime import date
from pathlib import Path

from sqlalchemy import create_engine, text

SERVER = "localhost"
DATABAZE = "VALUO"
SLOZKA = Path(__file__).resolve().parent / "_definice"

ODDELOVAC = "/* " + "-" * 72 + "\n   {typ}  {nazev}\n   změněno {kdy}\n   " + "-" * 72 + " */\n"


def db():
    conn = ("Driver={ODBC Driver 17 for SQL Server};"
            f"Server={SERVER};Database={DATABAZE};"
            "Trusted_Connection=yes;")
    return create_engine(
        f"mssql+pyodbc:///?odbc_connect={urllib.parse.quote_plus(conn)}",
        connect_args={"timeout": 0})


SQL = """
SELECT o.type_desc AS typ,
       'dbo.' + o.name AS nazev,
       CONVERT(varchar(16), o.modify_date, 120) AS kdy,
       LEN(m.definition) AS delka,
       m.definition AS definice
FROM sys.sql_modules m
JOIN sys.objects o ON o.object_id = m.object_id
WHERE o.type IN ('V', 'P', 'FN', 'IF', 'TF')
  AND o.is_ms_shipped = 0
ORDER BY o.type_desc, o.name;
"""


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--datum", help="RRRRMMDD do názvu souboru; výchozí dnes")
    p.add_argument("--popis", default="", help="co se právě dokončilo")
    a = p.parse_args()

    den = a.datum or date.today().strftime("%Y%m%d")
    SLOZKA.mkdir(exist_ok=True)
    cil = SLOZKA / f"definice_{den}.sql"

    with db().connect() as c:
        radky = c.execute(text(SQL)).mappings().all()

    if not radky:
        raise SystemExit("Databáze nevrátila žádnou definici — zkontroluj spojení.")

    hlavicka = [
        "/* " + "=" * 64,
        "   VALUO — ZÁLOHA DEFINIC POHLEDŮ A PROCEDUR",
        f"   Stav databáze k {date.today().strftime('%d. %m. %Y')}"
        + (f", {a.popis}." if a.popis else "."),
        "",
        "   Export z sys.sql_modules, text beze změny.",
        "",
        "   Obnova jednoho objektu: zkopíruj jeho blok, „CREATE“ přepiš",
        "   na „CREATE OR ALTER“ a spusť v SSMS nad databází VALUO.",
        "",
        f"   Obsah ({len(radky)} objektů):",
    ]
    for r in radky:
        hlavicka.append(f"     {r['typ']:<22} {r['nazev']:<36} změněno {r['kdy']}")
    hlavicka.append("   " + "=" * 64 + " */")

    casti = ["\n".join(hlavicka), ""]
    for r in radky:
        casti.append(ODDELOVAC.format(typ=r["typ"], nazev=r["nazev"], kdy=r["kdy"]))
        casti.append(r["definice"].rstrip())
        casti.append("\nGO\n")

    # newline="" je podstatné: bez něj Windows přeloží každé "\n" na "\r\n",
    # takže definice, které už CRLF obsahují (vytvořené v SSMS), skončí
    # v souboru s "\r\r\n" a po zpětném přečtení se neshodují. Definice se
    # ukládají tak, jak jsou v databázi — smíšené konce řádků jsou v pořádku.
    with open(cil, "w", encoding="utf-8-sig", newline="") as f:
        f.write("\n".join(casti))
    print(f"zapsáno {cil}  ({cil.stat().st_size:,} B, {len(radky)} objektů)".replace(",", " "))

    # kontrola: každá definice musí být v souboru znak za znakem
    with open(cil, "r", encoding="utf-8-sig", newline="") as f:
        text_souboru = f.read()
    chyby = []
    for r in radky:
        if r["definice"].rstrip() not in text_souboru:
            chyby.append(f"{r['nazev']}: definice v souboru není")
    if chyby:
        cil.unlink()
        for ch in chyby:
            print("  [!] " + ch)
        raise SystemExit("kontrola nesouhlasí — soubor smazán")

    soucet = sum(len(r["definice"]) for r in radky)
    print(f"kontrola v pořádku: {len(radky)} definic, {soucet:,} znaků".replace(",", " "))


if __name__ == "__main__":
    main()
