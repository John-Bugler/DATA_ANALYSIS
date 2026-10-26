"""
VALUO — KROK 8: PŘIŘAZENÍ PARCEL K PLOCHÁM ÚZEMNÍHO PLÁNU (OPRAVENO)

Opravuje chybu v původním skriptu, kvůli níž je zatřídění parcel
do funkčního využití u významné části dat chybné.

================================================================
CO BYLO ŠPATNĚ
================================================================
Původní skript rozhodoval o klíči pro UPDATE takto:

    group_key = 'id' if ('id' in joined.columns
                         and 'id_right' in joined.columns) else 'parcela_row'

a ve větvi else použil:

    UPDATE dbo.KN_parcel_data
    SET id_UP_FVU_data = :up_id
    WHERE parcel_number = :parc_num

Parcelní číslo NENÍ unikátní. V databázi se 3 953 čísel vyskytuje
ve více katastrálních územích, jedno dokonce v jedenácti; dotčeno
je 51 484 parcel (34,7 %). UPDATE podle čísla tedy přepsal
zatřídění všem parcelám téhož čísla napříč celou republikou.

Důkaz z dat: ze 2 752 parcelních čísel, která leží ve více
katastrálních územích, má všech 2 752 (100 %) přiřazené SHODNÉ
id_UP_FVU_data. Při prostorovém zatřídění by se musela lišit
prakticky vždy.

Dotaz navíc dělal SELECT * z JOINu KN_parcel_data a Valuo_data.
Obě tabulky mají sloupec id, takže v DataFrame vznikala kolize
názvů a podmínka pro group_key byla nespolehlivá.

================================================================
CO JE JINAK
================================================================
1) Dotaz vybírá sloupce výslovně a klíč nese jednoznačný název
   kn_id. Žádné SELECT * a žádná kolize.

2) UPDATE jde vždy přes primární klíč KN_parcel_data.id.
   Fallback na parcel_number je odstraněn — kdyby klíč chyběl,
   skript skončí chybou, místo aby tiše poškodil data.

3) Volba REPOCITAT_VSE řídí, zda se zpracují jen parcely bez
   zatřídění, nebo všechny znovu. Po této opravě je nutné
   přepočítat všechno.

Metoda zůstává stejná: parcele se přiřadí plocha ÚP s největší
plochou průniku, počítáno v S-JTSK (EPSG:5514).

Použití:
    pip install geopandas shapely sqlalchemy pyodbc
"""

import logging
import urllib.parse

import geopandas as gpd
import pandas as pd
from shapely.geometry import Polygon
from shapely import wkt
from sqlalchemy import create_engine, text

# ------------------------------------------------------------------
# NASTAVENÍ
# ------------------------------------------------------------------
REPOCITAT_VSE = True       # True = přepočítat všechny parcely
                           # False = jen ty bez zatřídění
DAVKA = 5000               # velikost dávky pro UPDATE

CONN = (
    "Driver={ODBC Driver 17 for SQL Server};"
    "Server=localhost;"
    "Database=VALUO;"
    "Trusted_Connection=yes;"
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("UP")

params = urllib.parse.quote_plus(CONN)
engine = create_engine(f"mssql+pyodbc:///?odbc_connect={params}")


# ------------------------------------------------------------------
# DOTAZ NA PARCELY
# Sloupce vyjmenované, klíč pojmenovaný kn_id — žádné SELECT *.
# Územní plán je jen pro Prahu, proto filtr na okres.
# ------------------------------------------------------------------
def dotaz_parcely() -> str:
    podminka = "" if REPOCITAT_VSE else "AND k.id_UP_FVU_data IS NULL"
    return f"""
        SELECT  k.id              AS kn_id,
                k.parcel_number,
                k.kat_uzemi,
                k.kod_ku,
                k.areaValue_m2,
                k.id_UP_FVU_data  AS up_puvodni,
                k.geometry
        FROM dbo.KN_parcel_data k
        JOIN dbo.Valuo_data v ON v.id = k.id_valuo
        WHERE k.geometry IS NOT NULL
          AND LEN(k.geometry) > 0
          AND v.okres = N'Hlavní město Praha'
          {podminka}
    """


def parsuj_sjtsk(text_geom):
    """'x1 y1 x2 y2 ...' v S-JTSK -> shapely Polygon"""
    if not text_geom:
        return None
    try:
        c = list(map(float, text_geom.split()))
        if len(c) < 6:
            return None
        return Polygon([(c[i], c[i + 1]) for i in range(0, len(c), 2)])
    except Exception as e:
        log.error(f"geometrie parcely: {e}")
        return None


def nacti_parcely() -> gpd.GeoDataFrame:
    log.info("Načítám parcely…")
    df = pd.read_sql(dotaz_parcely(), engine)
    log.info(f"  {len(df):,} parcel".replace(",", " "))

    if "kn_id" not in df.columns:
        raise KeyError(
            "Ve výsledku chybí sloupec kn_id. "
            "KN_parcel_data musí mít primární klíč id (krok 1b)."
        )
    if df["kn_id"].duplicated().any():
        raise ValueError("kn_id není unikátní — dotaz vrací duplicity.")

    df["geometry"] = df["geometry"].apply(parsuj_sjtsk)
    df = df[df["geometry"].notna()].copy()

    gdf = gpd.GeoDataFrame(df, geometry="geometry", crs="EPSG:5514")
    log.info(f"  {len(gdf):,} s platnou geometrií".replace(",", " "))
    return gdf


def nacti_up() -> gpd.GeoDataFrame:
    log.info("Načítám plochy územního plánu…")
    df = pd.read_sql(
        "SELECT id, KODFP1_A, ZAS1, geometry FROM dbo.UP_FVU_data "
        "WHERE geometry IS NOT NULL",
        engine,
    )
    df["geom"] = df["geometry"].apply(
        lambda s: wkt.loads(s) if s else None
    )
    df = df[df["geom"].notna()].drop(columns=["geometry"])

    gdf = gpd.GeoDataFrame(df, geometry="geom", crs="EPSG:4326")
    gdf = gdf.rename_geometry("geometry").to_crs(epsg=5514)
    log.info(f"  {len(gdf):,} ploch".replace(",", " "))
    return gdf


# ------------------------------------------------------------------
def prirad(parcely: gpd.GeoDataFrame, up: gpd.GeoDataFrame) -> pd.DataFrame:
    """Vrátí DataFrame [kn_id, up_id] — plocha s největším průnikem."""
    log.info("Prostorový join…")
    j = gpd.sjoin(
        parcely,
        up[["id", "KODFP1_A", "geometry"]],
        how="inner",
        predicate="intersects",
    ).rename(columns={"id": "up_id", "index_right": "up_row"})

    log.info(f"  {len(j):,} dvojic parcela–plocha".replace(",", " "))

    log.info("Počítám plochy průniků…")
    prave = up.geometry.iloc[j["up_row"].to_numpy()].reset_index(drop=True)
    leve = j.geometry.reset_index(drop=True)
    prunik = gpd.GeoSeries(leve, crs=5514).intersection(
        gpd.GeoSeries(prave, crs=5514)
    )
    j = j.reset_index(drop=True)
    j["plocha_pruniku"] = prunik.area.fillna(0.0)

    j = j[j["plocha_pruniku"] > 0]
    nejlepsi = j.loc[j.groupby("kn_id")["plocha_pruniku"].idxmax()]

    log.info(f"  {len(nejlepsi):,} parcel zatříděno".replace(",", " "))

    # kolik se jich mění proti původnímu stavu
    zmena = nejlepsi[nejlepsi["up_id"] != nejlepsi["up_puvodni"]]
    log.info(f"  z toho {len(zmena):,} má JINÉ zatřídění než dosud"
             .replace(",", " "))

    return nejlepsi[["kn_id", "up_id"]].copy()


def zapis(vysledek: pd.DataFrame):
    """UPDATE výhradně přes primární klíč. Žádný fallback."""
    log.info("Zapisuji…")
    sql = text(
        "UPDATE dbo.KN_parcel_data "
        "SET id_UP_FVU_data = :up_id "
        "WHERE id = :kn_id"
    )
    radku = len(vysledek)
    with engine.begin() as conn:
        for zacatek in range(0, radku, DAVKA):
            cast = vysledek.iloc[zacatek:zacatek + DAVKA]
            conn.execute(
                sql,
                [
                    {"up_id": int(r.up_id), "kn_id": int(r.kn_id)}
                    for r in cast.itertuples()
                ],
            )
            log.info(f"  {min(zacatek + DAVKA, radku):,} / {radku:,}"
                     .replace(",", " "))
    log.info("Hotovo.")


def main():
    if REPOCITAT_VSE:
        log.warning("REPOCITAT_VSE = True — přepíše se zatřídění "
                    "u všech pražských parcel.")

    parcely = nacti_parcely()
    if parcely.empty:
        log.info("Není co zpracovat.")
        return

    up = nacti_up()
    vysledek = prirad(parcely, up)

    if vysledek.empty:
        log.warning("Žádná parcela nezatříděna — nic se nezapisuje.")
        return

    zapis(vysledek)

    print()
    print("Ověř v SSMS, že číslo parcely už nerozhoduje o zatřídění:")
    print()
    print("  WITH s AS (SELECT parcel_number FROM dbo.KN_parcel_data")
    print("             WHERE parcel_number IS NOT NULL")
    print("               AND id_UP_FVU_data IS NOT NULL")
    print("             GROUP BY parcel_number")
    print("             HAVING COUNT(DISTINCT kod_ku) > 1)")
    print("  SELECT COUNT(*) AS cisel,")
    print("         SUM(CASE WHEN r = 1 THEN 1 ELSE 0 END) AS vsechny_stejne,")
    print("         SUM(CASE WHEN r > 1 THEN 1 ELSE 0 END) AS ruzne")
    print("  FROM (SELECT parcel_number,")
    print("               COUNT(DISTINCT id_UP_FVU_data) AS r")
    print("        FROM dbo.KN_parcel_data")
    print("        WHERE parcel_number IN (SELECT parcel_number FROM s)")
    print("          AND id_UP_FVU_data IS NOT NULL")
    print("        GROUP BY parcel_number) x;")
    print()
    print("Před opravou: vsechny_stejne = 2752, ruzne = 0")
    print("Po opravě má převažovat 'ruzne'.")


if __name__ == "__main__":
    main()
