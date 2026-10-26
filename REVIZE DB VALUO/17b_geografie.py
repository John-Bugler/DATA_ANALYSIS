"""
VALUO — KROK 17b: DOPLNĚNÍ GEOGRAFIE NOVÝM PARCELÁM

Doplní geo_bod a geo_plocha parcelám, které je nemají.
Spouštěj po každém importu nových parcel — zpracuje jen to,
co chybí, hotové nechá být.

================================================================
PROČ TO NEUDĚLÁ SAMO SQL
================================================================
Katastr dodává geometrii v S-JTSK (EPSG:5514), zatímco typ
geography pracuje v WGS84 (EPSG:4326). SQL Server reprojekci
mezi souřadnicovými systémy neumí, takže ji musí spočítat
Python přes pyproj.

================================================================
ORIENTACE RINGU — NA TOM JSEM SE UŽ SPÁLIL
================================================================
Typ geography vyžaduje, aby vnější ring plochy obíhal proti
směru hodinových ručiček; u obráceného polygonu SQL Server
chápe jako vnitřek celý zbytek planety a STArea() vrátí
510 065 621 710 996 m2.

V kroku 03b jsem orientaci počítal na souřadnicích v S-JTSK
a teprve pak transformoval. Osy obou systémů jsou orientované
různě, takže výsledek byl obrácený u všech 148 404 polygonů
a musel se opravovat zvlášť skriptem 03d.

Tady se orientace počítá TEPRVE PO transformaci, na dvojicích
(lon, lat). Pro jistotu se po vložení ještě kontroluje plocha
a nepravděpodobně velké polygony se otočí v databázi.
"""

import logging
import urllib.parse
from collections import Counter

import pandas as pd
from pyproj import Transformer
from sqlalchemy import create_engine, text

CONN = (
    "Driver={ODBC Driver 17 for SQL Server};"
    "Server=localhost;"
    "Database=VALUO;"
    "Trusted_Connection=yes;"
)

DAVKA = 500

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s  %(levelname)-7s  %(message)s",
                    datefmt="%H:%M:%S")
log = logging.getLogger("geografie")

engine = create_engine(
    f"mssql+pyodbc:///?odbc_connect={urllib.parse.quote_plus(CONN)}"
)
TRANS = Transformer.from_crs("EPSG:5514", "EPSG:4326", always_xy=True)


def wkt_polygonu(poslist):
    """
    Z posListu v S-JTSK vyrobí WKT polygonu ve WGS84
    s vnějším ringem proti směru hodinových ručiček.
    """
    c = poslist.split()
    if len(c) < 8:                      # méně než 4 body
        return None
    try:
        body = [TRANS.transform(float(c[i]), float(c[i + 1]))
                for i in range(0, len(c) - 1, 2)]
    except ValueError:
        return None

    if body[0] != body[-1]:             # ring musí být uzavřený
        body.append(body[0])
    if len(body) < 4:
        return None

    # orientace se počítá až na WGS84 souřadnicích
    plocha2 = sum(body[i][0] * body[i + 1][1] - body[i + 1][0] * body[i][1]
                  for i in range(len(body) - 1))
    if plocha2 < 0:                     # po směru hodinových ručiček
        body.reverse()

    souradnice = ", ".join(f"{lon:.9f} {lat:.9f}" for lon, lat in body)
    return f"POLYGON(({souradnice}))"


SQL_BOD = text("""
    UPDATE dbo.KN_parcel_data
    SET    geo_bod = geography::Point(refPoint_lat, refPoint_lon, 4326)
    WHERE  geo_bod IS NULL
      AND  refPoint_lat IS NOT NULL
      AND  refPoint_lon IS NOT NULL
""")

SQL_PLOCHA = text("""
    UPDATE dbo.KN_parcel_data
    SET    geo_plocha = geography::STGeomFromText(:wkt, 4326)
    WHERE  id = :id
""")

SQL_OTOCIT = text("""
    UPDATE dbo.KN_parcel_data
    SET    geo_plocha = geo_plocha.ReorientObject()
    WHERE  geo_plocha IS NOT NULL
      AND  geo_plocha.STArea() > 1e10
""")


def main():
    # ---------- 1) referenční body ----------
    with engine.begin() as conn:
        doplneno = conn.execute(SQL_BOD).rowcount
    log.info(f"Doplněno referenčních bodů: {doplneno:,}".replace(",", " "))

    # ---------- 2) plochy ----------
    df = pd.read_sql("""
        SELECT id, geometry FROM dbo.KN_parcel_data
        WHERE geo_plocha IS NULL AND geometry IS NOT NULL
    """, engine)
    log.info(f"Parcel bez geometrie plochy: {len(df):,}".replace(",", " "))

    stat = Counter()
    if not df.empty:
        davka = []
        for i, r in enumerate(df.itertuples(), 1):
            wkt = wkt_polygonu(r.geometry)
            if wkt is None:
                stat["geometrie_neplatna"] += 1
                continue
            davka.append({"id": int(r.id), "wkt": wkt})

            if len(davka) >= DAVKA:
                stat["vlozeno"] += zapis(davka, stat)
                davka = []
                log.info(f"  {i:,} / {len(df):,}".replace(",", " "))
        if davka:
            stat["vlozeno"] += zapis(davka, stat)

    # ---------- 3) kontrola orientace ----------
    with engine.begin() as conn:
        otoceno = conn.execute(SQL_OTOCIT).rowcount
    log.info(f"Dodatečně otočeno obrácených polygonů: {otoceno:,}".replace(",", " "))

    log.info("")
    for k, v in stat.most_common():
        log.info(f"  {k:<24} {v:>7,}".replace(",", " "))

    # ---------- 4) výsledek ----------
    kontrola = pd.read_sql("""
        SELECT COUNT(*)                                             AS parcel,
               SUM(CASE WHEN geo_bod    IS NULL THEN 1 ELSE 0 END)  AS bez_bodu,
               SUM(CASE WHEN geo_plocha IS NULL THEN 1 ELSE 0 END)  AS bez_plochy,
               SUM(CASE WHEN geo_plocha IS NOT NULL
                         AND geo_plocha.STArea() > 1e10
                        THEN 1 ELSE 0 END)                          AS obracenych
        FROM dbo.KN_parcel_data
    """, engine)
    log.info("")
    log.info(kontrola.to_string(index=False))
    log.info("")
    log.info("Dál spusť 09_parcely_UP_kompletni.py — nové pražské parcely")
    log.info("ještě nemají zatřídění do územního plánu.")


def zapis(davka, stat):
    """Vloží dávku; neplatné polygony zkusí po jednom, aby dávku neshodily."""
    try:
        with engine.begin() as conn:
            conn.execute(SQL_PLOCHA, davka)
        return len(davka)
    except Exception:
        vlozeno = 0
        for radek in davka:
            try:
                with engine.begin() as conn:
                    conn.execute(SQL_PLOCHA, radek)
                vlozeno += 1
            except Exception as e:
                stat["odmitnuto_sql"] += 1
                log.warning(f"  id={radek['id']}: {type(e).__name__}")
        return vlozeno


if __name__ == "__main__":
    main()
