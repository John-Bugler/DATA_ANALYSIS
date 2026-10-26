"""
VALUO — KROK 3b: REPROJEKCE POLYGONŮ PARCEL S-JTSK -> WGS84

Nahrazuje 03_kn_reprojekce.py, který odkazoval na sloupec
kat_uzemi zrušený v kroku 10.

================================================================
PROČ PYTHON A NE SQL
================================================================
KN_parcel_data.geometry je holý seznam souřadnic v S-JTSK
(EPSG:5514), bez WKT obalu:

    "-741561.96 -1049133.36 -741558.17 -1049142.88 ..."

SQL Server neumí transformovat mezi souřadnicovými systémy.
UP_FVU_data i Valuo_data jsou ve WGS84, takže se musí převést
parcely, ne naopak.

Transformace ověřena proti sloupcům refPoint_lon / refPoint_lat
ve stejné tabulce — odchylka 0,000 m.

================================================================
CO SKRIPT DĚLÁ NAVÍC
================================================================
Porovná vypočtenou plochu polygonu s areaValue_m2 z katastru.
Rozdíl nad toleranci zapíše do CSV logu — to je vstup k revizi
těch 1 706 záznamů, kde výměra nesedí.

================================================================
BĚH
================================================================
148 422 polygonů. Zapisuje se po dávkách, takže to trvá řádově
desítky minut. Skript je restartovatelný — zpracuje jen řádky,
kde je geo_plocha dosud NULL. Můžeš ho pustit a odejít.

Předpoklady:
    pip install pyproj pyodbc
    ODBC Driver 17 nebo 18 for SQL Server
"""

import sys
from datetime import datetime
from pathlib import Path

import pyodbc
from pyproj import Transformer

# ------------------------------------------------------------------
CONN_STR = (
    "DRIVER={ODBC Driver 17 for SQL Server};"
    "SERVER=localhost;"
    "DATABASE=VALUO;"
    "Trusted_Connection=yes;"
    "TrustServerCertificate=yes;"
)

DAVKA = 1000           # kolik řádků načíst a zapsat najednou
TOLERANCE_PCT = 5.0    # povolená odchylka plochy proti katastru [%]
LOG = Path(__file__).parent / f"reprojekce_log_{datetime.now():%Y%m%d_%H%M}.csv"

# EPSG:5514 = S-JTSK / Krovak East North
TRANS = Transformer.from_crs("EPSG:5514", "EPSG:4326", always_xy=True)


# ------------------------------------------------------------------
def plocha_shoelace(body):
    """Znaménková plocha mnohoúhelníku."""
    s = 0.0
    for i in range(len(body) - 1):
        x1, y1 = body[i]
        x2, y2 = body[i + 1]
        s += x1 * y2 - x2 * y1
    return s / 2.0


def na_wkt(text_sjtsk):
    """
    Vrátí (wkt_polygon_wgs84, plocha_m2).

    geography vyžaduje vnější ring proti směru hodinových ručiček.
    Orientaci řešíme tady, aby se v SQL nemusel volat
    ReorientObject().
    """
    cisla = text_sjtsk.split()
    if len(cisla) % 2 != 0:
        raise ValueError(f"lichý počet souřadnic ({len(cisla)})")

    body = [
        (float(cisla[i]), float(cisla[i + 1]))
        for i in range(0, len(cisla), 2)
    ]
    if len(body) < 3:
        raise ValueError(f"jen {len(body)} bodů")

    if body[0] != body[-1]:
        body.append(body[0])
    if len(body) < 4:
        raise ValueError("po uzavření méně než 4 body")

    plocha = plocha_shoelace(body)
    if abs(plocha) < 1e-9:
        raise ValueError("nulová plocha")

    # S-JTSK má obě osy záporné, proto je znaménko obrácené
    # oproti běžné rovině
    if plocha > 0:
        body.reverse()

    wgs = [TRANS.transform(x, y) for x, y in body]
    souradnice = ", ".join(f"{lon:.9f} {lat:.9f}" for lon, lat in wgs)
    return f"POLYGON (({souradnice}))", abs(plocha)


# ------------------------------------------------------------------
SQL_NACTI = """
    SELECT TOP (?) id, kod_ku, parcel_number, areaValue_m2, geometry
    FROM dbo.KN_parcel_data
    WHERE geometry IS NOT NULL
      AND LEN(geometry) > 0
      AND geo_plocha IS NULL
    ORDER BY id
"""

SQL_ZAPIS = """
    UPDATE dbo.KN_parcel_data
    SET geo_plocha = geography::STGeomFromText(?, 4326)
    WHERE id = ?
"""

SQL_PRAZDNY = """
    UPDATE dbo.KN_parcel_data
    SET geo_plocha = geography::STGeomFromText('POLYGON EMPTY', 4326)
    WHERE id = ?
"""


def main():
    cn = pyodbc.connect(CONN_STR, autocommit=False)
    cn.timeout = 600
    cur = cn.cursor()

    cur.execute("""
        SELECT COUNT(*) FROM dbo.KN_parcel_data
        WHERE geometry IS NOT NULL AND LEN(geometry) > 0
          AND geo_plocha IS NULL
    """)
    zbyva = cur.fetchone()[0]
    print(f"Ke zpracování: {zbyva:,} parcel".replace(",", " "))
    if zbyva == 0:
        print("Nic k práci. Konec.")
        return

    hotovo = chyb = podezrelych = 0
    log = open(LOG, "w", encoding="utf-8-sig", newline="")
    log.write("id;kod_ku;parcel_number;problem;detail\n")

    while True:
        cur.execute(SQL_NACTI, DAVKA)
        radky = cur.fetchall()
        if not radky:
            break

        davka_ok = []      # (wkt, id)
        davka_prazdna = [] # (id,)

        for rid, ku, pc, area_kn, geom in radky:
            try:
                wkt, plocha_vyp = na_wkt(geom)
            except ValueError as e:
                chyb += 1
                log.write(f"{rid};{ku};{pc};neplatna_geometrie;{e}\n")
                davka_prazdna.append((rid,))
                continue

            if area_kn and area_kn > 0:
                odchylka = abs(plocha_vyp - area_kn) / area_kn * 100
                if odchylka > TOLERANCE_PCT:
                    podezrelych += 1
                    log.write(
                        f"{rid};{ku};{pc};odchylka_plochy;"
                        f"katastr={area_kn:.1f} vypocet={plocha_vyp:.1f} "
                        f"rozdil={odchylka:.1f}%\n"
                    )

            davka_ok.append((wkt, rid))

        # dávkový zápis; při chybě spadne na zápis po řádcích
        if davka_ok:
            try:
                cur.executemany(SQL_ZAPIS, davka_ok)
            except pyodbc.Error:
                cn.rollback()
                for wkt, rid in davka_ok:
                    try:
                        cur.execute(SQL_ZAPIS, wkt, rid)
                    except pyodbc.Error as e:
                        chyb += 1
                        log.write(f"{rid};;;sql_chyba;{str(e)[:150]}\n")
                        cur.execute(SQL_PRAZDNY, rid)

        if davka_prazdna:
            cur.executemany(SQL_PRAZDNY, davka_prazdna)

        cn.commit()
        hotovo += len(radky)
        print(f"  {hotovo:,} / {zbyva:,}".replace(",", " "), end="\r")

    log.close()
    print()
    print(f"Hotovo:             {hotovo:,}".replace(",", " "))
    print(f"Neplatná geometrie: {chyb:,}".replace(",", " "))
    print(f"Odchylka plochy:    {podezrelych:,}".replace(",", " "))
    print(f"Log:                {LOG}")
    print()
    print("Teď v SSMS dostav prostorový index:")
    print()
    print("  CREATE SPATIAL INDEX SIX_KN_geo_plocha")
    print("      ON dbo.KN_parcel_data (geo_plocha)")
    print("      USING GEOGRAPHY_AUTO_GRID")
    print("      WITH (CELLS_PER_OBJECT = 64);")

    cn.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nPřerušeno. Skript je restartovatelný — "
              "zpracuje jen parcely, kde je geo_plocha dosud NULL.")
        sys.exit(1)
