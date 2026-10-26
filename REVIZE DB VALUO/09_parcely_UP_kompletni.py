"""
VALUO — KROK 9: ÚPLNÉ ZATŘÍDĚNÍ PARCEL DO PLOCH ÚZEMNÍHO PLÁNU

Nahrazuje 08_prirazeni_UP_opraveno.py. Místo jediné dominantní
plochy eviduje VŠECHNY plochy, do kterých parcela zasahuje,
včetně podílu.

================================================================
PROČ NOVÁ TABULKA
================================================================
Parcela může zasahovat do více ploch územního plánu. Dosavadní
sloupec KN_parcel_data.id_UP_FVU_data unese jen jednu hodnotu,
takže informace o ostatních plochách se ztrácela — a s ní
i údaj o tom, nakolik je zatřídění jednoznačné.

Parcela ležící z 98 % v jedné ploše a parcela rozdělená 55/45
jsou pro ocenění zcela odlišné případy. Nová tabulka ten rozdíl
zachová.

Sloupec id_UP_FVU_data zůstává a plní se dominantní plochou,
aby stávající dotazy fungovaly beze změny.

================================================================
ZDROJ DAT
================================================================
Tabulka UP_FVU_data je věrným importem souboru
PUP_CUR_PVP_FVU_P (ZDROJ = PUP_2501, 15 542 ploch, 40 kódů
funkčního využití, EPSG:4326). Ověřeno shodou počtu řádků
i rozsahu OBJECTID, proto se načítá z databáze, ne ze souboru.

Územní plán pokrývá pouze Prahu.

================================================================
METODA
================================================================
1) Parcely se parsují z textové geometrie v S-JTSK (EPSG:5514).
2) Plochy ÚP se převedou z WGS84 do S-JTSK, aby se průniky
   počítaly v metrech.
3) Pro každou dvojici parcela–plocha se spočítá plocha průniku
   a podíl z výměry parcely.
4) Zapíší se všechny dvojice s nenulovým průnikem, seřazené
   podle velikosti.

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
CONN = (
    "Driver={ODBC Driver 17 for SQL Server};"
    "Server=localhost;"
    "Database=VALUO;"
    "Trusted_Connection=yes;"
)

DAVKA = 5000
MIN_PODIL_PCT = 0.5     # průniky menší než půl procenta se neukládají

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("UP")

engine = create_engine(
    f"mssql+pyodbc:///?odbc_connect={urllib.parse.quote_plus(CONN)}"
)


DDL = """
IF OBJECT_ID('dbo.KN_parcel_UP') IS NOT NULL
    DROP TABLE dbo.KN_parcel_UP;

CREATE TABLE dbo.KN_parcel_UP (
    kn_id             int           NOT NULL,
    up_id             int           NOT NULL,
    fvu_kod           varchar(10)   NULL,
    mira_vyuziti      varchar(10)   NULL,
    plocha_parcely_m2 decimal(18,2) NULL,
    plocha_pruniku_m2 decimal(18,2) NOT NULL,
    podil_pct         decimal(6,2)  NOT NULL,
    poradi            tinyint       NOT NULL,
    vypocteno         datetime2(0)  NOT NULL
        CONSTRAINT DF_KN_parcel_UP_vypocteno DEFAULT SYSDATETIME(),
    CONSTRAINT PK_KN_parcel_UP PRIMARY KEY CLUSTERED (kn_id, up_id)
);

CREATE NONCLUSTERED INDEX IX_KN_parcel_UP_dominantni
    ON dbo.KN_parcel_UP (kn_id, poradi)
    INCLUDE (up_id, fvu_kod, mira_vyuziti, podil_pct);

CREATE NONCLUSTERED INDEX IX_KN_parcel_UP_fvu
    ON dbo.KN_parcel_UP (fvu_kod, poradi)
    INCLUDE (kn_id, podil_pct);
"""


# ------------------------------------------------------------------
def parsuj_sjtsk(txt):
    """'x1 y1 x2 y2 ...' v S-JTSK -> shapely Polygon"""
    if not txt:
        return None
    try:
        c = list(map(float, txt.split()))
        if len(c) < 6:
            return None
        return Polygon([(c[i], c[i + 1]) for i in range(0, len(c), 2)])
    except Exception:
        return None


def nacti_parcely() -> gpd.GeoDataFrame:
    """
    Pražské parcely. Praha se určuje z číselníku ČÚZK přes kod_ku,
    ne ze sloupce okres ve Valuo_data — ten je u 1,12 % záznamů
    chybný.
    """
    sql = """
        SELECT  k.id             AS kn_id,
                k.parcel_number,
                c.ku_nazev       AS kat_uzemi,
                k.kod_ku,
                k.areaValue_m2,
                k.id_UP_FVU_data AS up_puvodni,
                k.geometry
        FROM dbo.KN_parcel_data k
        JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
        WHERE c.kraj_nazev = N'Hlavní město Praha'
          AND k.geometry IS NOT NULL
          AND LEN(k.geometry) > 0
    """
    log.info("Načítám pražské parcely…")
    df = pd.read_sql(sql, engine)
    log.info(f"  {len(df):,} parcel".replace(",", " "))

    if df["kn_id"].duplicated().any():
        raise ValueError("kn_id není unikátní.")

    df["geometry"] = df["geometry"].apply(parsuj_sjtsk)
    vadnych = df["geometry"].isna().sum()
    if vadnych:
        log.warning(f"  {vadnych} parcel s nečitelnou geometrií — vynechány")
    df = df[df["geometry"].notna()].copy()

    return gpd.GeoDataFrame(df, geometry="geometry", crs="EPSG:5514")


def nacti_up() -> gpd.GeoDataFrame:
    log.info("Načítám plochy územního plánu…")
    df = pd.read_sql(
        "SELECT id, KODFP1_A, ZAS1, geometry FROM dbo.UP_FVU_data "
        "WHERE geometry IS NOT NULL",
        engine,
    )
    df["geom"] = df["geometry"].apply(lambda s: wkt.loads(s) if s else None)
    df = df[df["geom"].notna()].drop(columns=["geometry"])

    gdf = gpd.GeoDataFrame(df, geometry="geom", crs="EPSG:4326")
    gdf = gdf.rename_geometry("geometry").to_crs(epsg=5514)
    gdf["geometry"] = gdf.geometry.buffer(0)      # oprava neplatných
    log.info(f"  {len(gdf):,} ploch".replace(",", " "))
    return gdf


# ------------------------------------------------------------------
def spocitej(parcely: gpd.GeoDataFrame, up: gpd.GeoDataFrame) -> pd.DataFrame:
    log.info("Prostorový join…")
    j = gpd.sjoin(
        parcely,
        up[["id", "KODFP1_A", "ZAS1", "geometry"]],
        how="inner",
        predicate="intersects",
    ).rename(columns={"id": "up_id", "index_right": "up_row"})
    log.info(f"  {len(j):,} dvojic parcela–plocha".replace(",", " "))

    log.info("Počítám plochy průniků…")
    j = j.reset_index(drop=True)
    prave = up.geometry.iloc[j["up_row"].to_numpy()].reset_index(drop=True)
    leve = j.geometry.reset_index(drop=True)
    prunik = gpd.GeoSeries(leve, crs=5514).intersection(
        gpd.GeoSeries(prave, crs=5514)
    )
    j["plocha_pruniku_m2"] = prunik.area.fillna(0.0)
    j["plocha_parcely_m2"] = leve.area

    j = j[j["plocha_pruniku_m2"] > 0].copy()
    j["podil_pct"] = (
        100.0 * j["plocha_pruniku_m2"] / j["plocha_parcely_m2"].replace(0, pd.NA)
    ).fillna(0.0)

    pred = len(j)
    j = j[j["podil_pct"] >= MIN_PODIL_PCT].copy()
    log.info(f"  {pred - len(j):,} zanedbatelných průniků vynecháno"
             .replace(",", " "))

    j["poradi"] = (
        j.sort_values("plocha_pruniku_m2", ascending=False)
         .groupby("kn_id")
         .cumcount() + 1
    )

    # statistika jednoznačnosti
    poctu = j.groupby("kn_id").size()
    log.info(f"  parcel celkem:          {len(poctu):,}".replace(",", " "))
    log.info(f"  v jediné ploše:         {(poctu == 1).sum():,}"
             .replace(",", " "))
    log.info(f"  ve dvou plochách:       {(poctu == 2).sum():,}"
             .replace(",", " "))
    log.info(f"  ve třech a více:        {(poctu >= 3).sum():,}"
             .replace(",", " "))

    dom = j[j["poradi"] == 1]
    zmena = dom[dom["up_id"] != dom["up_puvodni"]]
    log.info(f"  mění se zatřídění u:    {len(zmena):,} parcel"
             .replace(",", " "))

    return j[[
        "kn_id", "up_id", "KODFP1_A", "ZAS1",
        "plocha_parcely_m2", "plocha_pruniku_m2", "podil_pct", "poradi",
    ]].rename(columns={"KODFP1_A": "fvu_kod", "ZAS1": "mira_vyuziti"})


def zapis(df: pd.DataFrame):
    log.info("Zakládám tabulku…")
    with engine.begin() as conn:
        for prikaz in DDL.split(";"):
            if prikaz.strip():
                conn.execute(text(prikaz))

    log.info("Zapisuji…")
    sql = text("""
        INSERT INTO dbo.KN_parcel_UP
            (kn_id, up_id, fvu_kod, mira_vyuziti,
             plocha_parcely_m2, plocha_pruniku_m2, podil_pct, poradi)
        VALUES (:kn_id, :up_id, :fvu, :zas, :pp, :ppr, :pct, :por)
    """)
    n = len(df)
    with engine.begin() as conn:
        for i in range(0, n, DAVKA):
            cast = df.iloc[i:i + DAVKA]
            conn.execute(sql, [
                {
                    "kn_id": int(r.kn_id), "up_id": int(r.up_id),
                    "fvu": r.fvu_kod, "zas": r.mira_vyuziti,
                    "pp": float(r.plocha_parcely_m2),
                    "ppr": float(r.plocha_pruniku_m2),
                    "pct": round(float(r.podil_pct), 2),
                    "por": int(r.poradi),
                }
                for r in cast.itertuples()
            ])
            log.info(f"  {min(i + DAVKA, n):,} / {n:,}".replace(",", " "))

    log.info("Aktualizuji id_UP_FVU_data dominantní plochou…")
    with engine.begin() as conn:
        conn.execute(text("""
            UPDATE k
            SET k.id_UP_FVU_data = p.up_id
            FROM dbo.KN_parcel_data k
            JOIN dbo.KN_parcel_UP p ON p.kn_id = k.id AND p.poradi = 1
        """))
    log.info("Hotovo.")


def main():
    parcely = nacti_parcely()
    if parcely.empty:
        log.info("Není co zpracovat.")
        return

    up = nacti_up()
    vysledek = spocitej(parcely, up)

    if vysledek.empty:
        log.warning("Žádné průniky — nic se nezapisuje.")
        return

    zapis(vysledek)

    print()
    print("Kontrola v SSMS:")
    print()
    print("-- 1) jednoznačnost zatřídění")
    print("SELECT poradi, COUNT(*) AS dvojic FROM dbo.KN_parcel_UP")
    print("GROUP BY poradi ORDER BY poradi;")
    print()
    print("-- 2) parcely rozdělené mezi více ploch")
    print("SELECT TOP 20 kn_id, COUNT(*) AS ploch,")
    print("       MAX(podil_pct) AS nejvetsi_podil")
    print("FROM dbo.KN_parcel_UP GROUP BY kn_id")
    print("HAVING COUNT(*) > 1 ORDER BY MAX(podil_pct);")
    print()
    print("-- 3) už nerozhoduje parcelní číslo")
    print("WITH s AS (SELECT parcel_number FROM dbo.KN_parcel_data")
    print("           WHERE parcel_number IS NOT NULL")
    print("             AND id_UP_FVU_data IS NOT NULL")
    print("           GROUP BY parcel_number")
    print("           HAVING COUNT(DISTINCT kod_ku) > 1)")
    print("SELECT SUM(CASE WHEN r = 1 THEN 1 ELSE 0 END) AS vsechny_stejne,")
    print("       SUM(CASE WHEN r > 1 THEN 1 ELSE 0 END) AS ruzne")
    print("FROM (SELECT parcel_number,")
    print("             COUNT(DISTINCT id_UP_FVU_data) AS r")
    print("      FROM dbo.KN_parcel_data")
    print("      WHERE parcel_number IN (SELECT parcel_number FROM s)")
    print("        AND id_UP_FVU_data IS NOT NULL")
    print("      GROUP BY parcel_number) x;")
    print()
    print("Před opravou: vsechny_stejne = 2752, ruzne = 0")


if __name__ == "__main__":
    main()
