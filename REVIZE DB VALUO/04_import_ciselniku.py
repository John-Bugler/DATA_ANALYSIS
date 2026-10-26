"""
VALUO — KROK 4: IMPORT ČÍSELNÍKU KATASTRÁLNÍCH ÚZEMÍ ČÚZK
===========================================================

Zdroj: SC_SEZNAMKUKRA_DOTAZ.csv (ČÚZK, číselníky ISKN)
       https://cuzk.gov.cz/Katastr-nemovitosti/Poskytovani-udaju-z-KN/
       Ciselniky-ISKN/Ciselniky-katastralnich-uzemi-a-pracovist-resortu/
       Katastralni-uzemi.aspx

Ověřeno na dodaném souboru:
    13 074 katastrálních území, všechna platná
    KU_KOD je unikátní, bez duplicit
    kódování CP1250, oddělovač ';', datum DD.MM.YYYY
    všech 435 kódů z KN_parcel_data je v číselníku

Pozor na prázdný OKRES_NAZEV: 112 řádků (pražská území).
Praha není okres, má jen kraj. V dotazech proto
COALESCE(okres_nazev, kraj_nazev).

Použití:
    pip install pyodbc
    uprav CESTA_CSV a CONN_STR, pak spusť
"""

import csv
from datetime import datetime

import pyodbc

from pathlib import Path

# ------------------------------------------------------------------
CESTA_CSV = Path(__file__).parent / "SC_SEZNAMKUKRA_DOTAZ.csv"

if not CESTA_CSV.exists():
    raise SystemExit(f"Soubor nenalezen: {CESTA_CSV}")

CONN_STR = (
    "DRIVER={ODBC Driver 17 for SQL Server};"
    "SERVER=localhost;"
    "DATABASE=VALUO;"
    "Trusted_Connection=yes;"
    "TrustServerCertificate=yes;"
)

DDL = """
IF OBJECT_ID('dbo.CIS_katastralni_uzemi') IS NOT NULL
    DROP TABLE dbo.CIS_katastralni_uzemi;

CREATE TABLE dbo.CIS_katastralni_uzemi (
    ku_kod          int          NOT NULL,
    ku_nazev        varchar(60)  NOT NULL,
    ku_prac         varchar(10)  NULL,
    obec_kod        int          NULL,
    obec_nazev      varchar(60)  NULL,
    okres_kod       varchar(10)  NULL,
    okres_nazev     varchar(40)  NULL,
    nuts4           varchar(10)  NULL,
    kraj_kod        varchar(10)  NULL,
    kraj_nazev      varchar(40)  NULL,
    mapa            varchar(5)   NULL,
    ciselna_rada    varchar(5)   NULL,
    platnost_od     date         NULL,
    platnost_do     date         NULL,
    prares_kod      varchar(10)  NULL,
    prares_nazev    varchar(120) NULL,
    poznamka        varchar(500) NULL,
    nacteno         datetime2(0) NOT NULL
        CONSTRAINT DF_CIS_ku_nacteno DEFAULT SYSDATETIME(),
    CONSTRAINT PK_CIS_katastralni_uzemi PRIMARY KEY CLUSTERED (ku_kod)
);

CREATE NONCLUSTERED INDEX IX_CIS_ku_nazev
    ON dbo.CIS_katastralni_uzemi (ku_nazev) INCLUDE (ku_kod, okres_nazev);

CREATE NONCLUSTERED INDEX IX_CIS_ku_okres
    ON dbo.CIS_katastralni_uzemi (okres_nazev) INCLUDE (ku_kod, ku_nazev);
"""


def datum(txt):
    """'01.03.1994' -> date, prázdné -> None"""
    txt = (txt or "").strip()
    if not txt:
        return None
    return datetime.strptime(txt, "%d.%m.%Y").date()


def cislo(txt):
    txt = (txt or "").strip()
    return int(txt) if txt.isdigit() else None


def text(txt):
    txt = (txt or "").strip()
    return txt if txt else None


def main():
    print("Načítám CSV…")
    with open(CESTA_CSV, encoding="cp1250", newline="") as f:
        radky = list(csv.DictReader(f, delimiter=";"))
    print(f"  {len(radky):,} řádků".replace(",", " "))

    data = []
    for r in radky:
        data.append((
            int(r["KU_KOD"]),
            r["KU_NAZEV"].strip(),
            text(r["KU_PRAC"]),
            cislo(r["OBEC_KOD"]),
            text(r["OBEC_NAZEV"]),
            text(r["OKRES_KOD"]),
            text(r["OKRES_NAZEV"]),
            text(r["NUTS4"]),
            text(r["KRAJ_KOD"]),
            text(r["KRAJ_NAZEV"]),
            text(r["MAPA"]),
            text(r["CISELNA_RADA"]),
            datum(r["PLATNOST_OD"]),
            datum(r["PLATNOST_DO"]),
            text(r["PRARES_KOD"]),
            text(r["PRARES_NAZEV"]),
            text(r["POZNAMKA"]),
        ))

    cn = pyodbc.connect(CONN_STR, autocommit=False)
    cur = cn.cursor()

    print("Zakládám tabulku…")
    for prikaz in DDL.split(";"):
        if prikaz.strip():
            cur.execute(prikaz)
    cn.commit()

    print("Importuji…")
    cur.fast_executemany = True
    cur.executemany("""
        INSERT INTO dbo.CIS_katastralni_uzemi
            (ku_kod, ku_nazev, ku_prac, obec_kod, obec_nazev,
             okres_kod, okres_nazev, nuts4, kraj_kod, kraj_nazev,
             mapa, ciselna_rada, platnost_od, platnost_do,
             prares_kod, prares_nazev, poznamka)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """, data)
    cn.commit()

    cur.execute("SELECT COUNT(*) FROM dbo.CIS_katastralni_uzemi")
    print(f"Hotovo: {cur.fetchone()[0]:,} území v číselníku".replace(",", " "))

    # kontrola pokrytí
    cur.execute("""
        SELECT COUNT(DISTINCT k.kod_ku) AS kodu_v_datech,
               COUNT(DISTINCT c.ku_kod) AS z_toho_v_ciselniku
        FROM dbo.KN_parcel_data k
        LEFT JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
        WHERE k.kod_ku IS NOT NULL
    """)
    v_datech, v_ciselniku = cur.fetchone()
    print(f"Pokrytí: {v_ciselniku} z {v_datech} kódů")
    if v_ciselniku < v_datech:
        print("  POZOR: některé kódy v číselníku chybí.")

    cn.close()
    print("\nPokračuj skriptem 04_ciselnik_napojeni.sql")


if __name__ == "__main__":
    main()
