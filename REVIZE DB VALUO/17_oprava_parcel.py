r"""
VALUO — KROK 17: PŘETAŽENÍ PARCEL Z KATASTRU (OPRAVENÁ VERZE)

Spouštěj POSTUPNĚ:
    1) v Management Studiu:  17a_doplneni_seznamu.sql
    2) python 17_oprava_parcel.py --test      (sekundy, nic nemění)
    3) python 17_oprava_parcel.py             (cca 1,5 hodiny)
    4) python 17b_geografie.py                (geo_bod a geo_plocha)
    5) python 09_parcely_UP_kompletni.py      (zatřídění do ÚP)

================================================================
CO BYLO ŠPATNĚ V PŮVODNÍM SKRIPTU
================================================================

CHYBA 1 — FUNKCE IGNOROVALA SVŮJ PARAMETR  (řádek 310)

    def get_parcel_data(zoning_name, parcel_number):
        upper_zoning_id = get_zoning_code(
            zoning_name=row["kat_uzemi"], okres=row["okres"])

    Funkce dostala zoning_name vytažený z popisu, ale použila
    globální row["kat_uzemi"] — tedy území BALÍČKU.

    Valuo prodává data po balíčcích "území + měsíc". Obsahuje-li
    vklad nemovitosti ve více územích, mají v balíčku všechny
    stejné kat_uzemi. Parcela se proto hledala ve špatném území:
    buď se nenašla (8 067 záznamů bez vazby), nebo se našla cizí
    parcela téhož čísla (342 záznamů).

CHYBA 2 — ZÁMĚNA STAVEBNÍ A POZEMKOVÉ PARCELY  (řádek 51)

    is_stavebni = bool(re.search(
        r"\bstavební\b|\bstavba\b|\bč\.\s*\d+", popis, re.IGNORECASE))

    Výraz \bč\.\s*\d+ vyhoví každému popisu s "č. 373", tedy
    i pozemkové parcele. Výraz \bstavba\b vyhoví textu
    "(součástí je stavba č.p. 1388)", který má u budov téměř
    každý záznam. Důsledek: 329 záznamů má navázanou stavební
    parcelu místo pozemkové; jsou to dvě různé parcely, které
    se jen shodně číslují.

CHYBA 3 — KAŽDÝ ZÁZNAM SE STAHOVAL DVAKRÁT  (řádky 554–573)

    try:
        df_parcel = get_parcel_data(kat, parc)
    except Exception:
        ...
    else:
        df_parcel = get_parcel_data(kat_uzemi, parc_cislo)

    Blok else u try/except se provede pokaždé, když výjimka
    NENASTALA. Parcela se stáhla podruhé, jiným parserem,
    a vložila znovu. Odtud 271 záznamů s oběma typy parcel.

CHYBA 4 — FALLBACK NA CIZÍ OKRES  (řádky 246–254)

    Nenašla-li se shoda s okresem, vzalo se první území téhož
    jména, klidně z druhého konce republiky. Shoda okresu se
    navíc testovala podřetězcem, takže "Praha" vyhovělo
    Praze-východ, Praze-západ i hlavnímu městu.

================================================================
JAK TO ŘEŠÍ TATO VERZE
================================================================

ÚZEMÍ Z POPISU, NE Z BALÍČKU
    Název území i parcelní číslo se berou z popisu. U parcel
    a budov má popis tvar "č. 2442/1 Chodov", u jednotek
    "... na parcele 330/20 Třebonice", u práv stavby
    "... k parcele 4561/68 Dejvice".

KÓD ÚZEMÍ Z ČÍSELNÍKU, NE Z KATASTRU
    Všech 13 074 názvů k.ú. v číselníku ČÚZK je unikátních
    (proto rozlišovací přívlastky: Vinařice u Suchomast,
    Bukovec u Jablunkova). Název tedy určuje kód jednoznačně
    a dotaz GetZoningByName je zbytečný — ubyla polovina
    dotazů a celý problém s nejednoznačností.

TYP PARCELY PODLE PREFIXU POPISU
    "stavební č. 147/7 Osov" → hledá se "st. 147/7"
    "č. 373 Nupaky"          → hledá se "373"
    Žádná kontextová detekce, žádné hádání.

PK A GP PARCELY SE PŘESKAKUJÍ
    14 záznamů s popisem "PK č. 4203 Poděbrady" nebo
    "GP č. 527 Kobylí Hlava" jsou parcely pozemkové knihy
    a grafického přídělu. V KN pod tímto číslem neexistují.

KONTROLA PŘED ZÁPISEM
    Odpověď katastru nese v CP:zoning atribut xlink:title
    s názvem území. Neodpovídá-li požadovanému, parcela se
    nevloží a zapíše se do logu. Žádný záznam se nespoléhá
    na to, že katastr vrátil, co se čekalo.

BEZPEČNÉ MAZÁNÍ
    Dosavadní vazby se mažou, jen když se nová parcela
    podařila stáhnout — nebo když je stará prokazatelně
    špatná (důvod CIZI_UZEMI, STAVEBNI_NESOULAD). Nepodaří-li
    se u ostatních důvodů nic stáhnout, zůstává stav jak byl.

RESTARTOVATELNÝ
    Zpracované záznamy se značí v KN_k_pretazeni.zpracovano.
    Přerušení nevadí, další běh pokračuje tam, kde se skončilo.
"""

import argparse
import csv
import logging
import re
import time
import urllib.parse
from collections import Counter
from datetime import datetime
from pathlib import Path

import pandas as pd
import requests
from lxml import etree
from pyproj import Transformer
from sqlalchemy import create_engine, text

# ------------------------------------------------------------------
# NASTAVENÍ
# ------------------------------------------------------------------
CONN = (
    "Driver={ODBC Driver 17 for SQL Server};"
    "Server=localhost;"
    "Database=VALUO;"
    "Trusted_Connection=yes;"
)

PAUZA_S = 0.3        # prodleva mezi dotazy na katastr
DAVKA = 100          # po kolika záznamech se zapisuje do DB
OPAKOVANI = 3        # pokusů při chybě spojení

WFS = "https://services.cuzk.cz/wfs/inspire-CP-wfs.asp?"

NS = {
    "wfs":  "http://www.opengis.net/wfs/2.0",
    "gml":  "http://www.opengis.net/gml/3.2",
    "CP":   "http://inspire.ec.europa.eu/schemas/cp/4.0",
    "base": "http://inspire.ec.europa.eu/schemas/base/3.3",
}
XLINK_TITLE = "{http://www.w3.org/1999/xlink}title"
GML_ID = "{http://www.opengis.net/gml/3.2}id"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("oprava")

engine = create_engine(
    f"mssql+pyodbc:///?odbc_connect={urllib.parse.quote_plus(CONN)}"
)
TRANS = Transformer.from_crs("EPSG:5514", "EPSG:4326", always_xy=True)


# ==================================================================
# PARSOVÁNÍ POPISU
# ==================================================================
# Ověřeno na všech 13 tvarech popisu, které se v datech vyskytují
# (107 403 záznamů). Závorky se odstraňují z celého textu, protože
# u víceparcelních popisů stojí i uprostřed seznamu:
#   "na parcele st. 235 Labská (k.. Labská), st. 903 Hořejší Vrchlabí"

# ------------------------------------------------------------------
# DRUHÁ VERZE — první měla u seznamů parcel dvě chyby:
#
#   "č. 2342/504, 2342/505, 2342/506 Stodůlky"
#       vzor s \S+? sebral i čárku a vyšla z toho jediná parcela
#       "2342/504," v území "2342/505, 2342/506 Stodůlky"
#
#   "na parcele 1340, 1341 Nusle"
#       název území se dědil DOPŘEDU, takže parcela 1340 zůstala
#       bez území a zahodila se; vrátila se jen 1341
#
# Území se přitom v seznamu uvádí ZA poslední parcelou, ke které
# patří, takže se musí dědit od konce dopředu. Oba tvary se dělí
# po čárkách stejně; segmenty, které nezačínají číslem, se
# přeskakují — jsou to "podíl na společných částech …" a podobně.
#
# Ověřeno na 15 tvarech popisu, které se v datech vyskytují.
# ------------------------------------------------------------------

ZAVORKY = re.compile(r"\([^)]*\)")
VZOR_DIL = re.compile(r"(?i),\s*díl\s+\d+")
VZOR_SEZNAM = re.compile(r"(?i)\b(?:na|k)\s+parcele\s+(.+)$")
VZOR_PREFIX = re.compile(r"^(?i:(stavební|PK|GP)\s+)?č\.\s+(.+)$")
VZOR_SEGMENT = re.compile(r"(?i)^(st\.\s*)?(\d+(?:/\d+)?)(?:\s+(.+))?$")


def parcely_z_popisu(popis):
    """
    Vrátí (seznam [(uzemi, parcelni_cislo)], duvod_neuspechu).
    Při úspěchu je druhá hodnota None.
    """
    if not popis:
        return [], "bez_popisu"

    p = ZAVORKY.sub(" ", popis)
    p = VZOR_DIL.sub("", p)                 # ", díl 2" není parcela
    p = re.sub(r"\s+", " ", p).strip().rstrip(",")
    st_vsude = False

    # tvar "... na parcele 330/20 Třebonice" — jednotky, budovy
    # bez čp/če, práva stavby
    m = VZOR_SEZNAM.search(p)
    if m:
        zbytek = m.group(1)
    else:
        # tvar "č. 2442/1 Chodov" — parcely a budovy
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
        cislo = ("st. " if (sm.group(1) or st_vsude) else "") + sm.group(2)
        segmenty.append((cislo, sm.group(3).strip() if sm.group(3) else None))

    if not segmenty:
        return [], "seznam_neparsovan"

    # název území platí pro parcely PŘED sebou
    vysledek, posledni = [], None
    for cislo, uzemi in reversed(segmenty):
        if uzemi:
            posledni = uzemi
        if posledni:
            vysledek.append((posledni, cislo))
    vysledek.reverse()

    if vysledek:
        return vysledek, None
    return [], "bez_uzemi"


# ==================================================================
# STAŽENÍ PARCELY
# ==================================================================
def stahni_parcelu(kod_ku, cislo, nazev_uzemi):
    """
    Vrátí (seznam zaznamu, duvod_neuspechu).
    Vkládají se jen parcely, u nichž katastr potvrdil území.
    """
    parametry = {
        "service": "WFS", "version": "2.0.0", "request": "GetFeature",
        "storedQuery_id": "GetParcel",
        "UPPER_ZONING_ID": str(kod_ku), "TEXT": cislo,
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
        tree = etree.fromstring(odpoved)
    except Exception:
        return [], "odpoved_neplatna"

    zaznamy, cizi = [], 0
    for prvek in tree.findall(".//CP:CadastralParcel", namespaces=NS):

        # kontrola území — katastr vrací název v CP:zoning
        zoning = prvek.find("CP:zoning", namespaces=NS)
        zoning_nazev = (zoning.get(XLINK_TITLE) or "").strip() if zoning is not None else ""
        if zoning_nazev and zoning_nazev.lower() != nazev_uzemi.lower():
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
            namespaces=NS,
        )

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
            "parcel_number": cislo,
            "gml_id": prvek.get(GML_ID),
            "areaValue_m2": vymera,
            "beginLifespanVersion": txt("CP:beginLifespanVersion"),
            "geometry": geom.text.strip() if geom is not None and geom.text else None,
            "refPoint_x": x, "refPoint_y": y,
            "refPoint_lon": lon, "refPoint_lat": lat,
            "label": txt("CP:label"),
        })

    if not zaznamy:
        return [], "cizi_uzemi_odmitnuto" if cizi else "nenalezeno"
    return zaznamy, None


# ==================================================================
# ZÁPIS
# ==================================================================
SQL_SMAZ_UP = text("""
    DELETE u FROM dbo.KN_parcel_UP u
    JOIN dbo.KN_parcel_data k ON k.id = u.kn_id
    WHERE k.id_valuo = :idv
""")
SQL_SMAZ_PARCELY = text("DELETE FROM dbo.KN_parcel_data WHERE id_valuo = :idv")
SQL_VLOZ = text("""
    INSERT INTO dbo.KN_parcel_data
        (id_valuo, kod_ku, parcel_number, gml_id, areaValue_m2,
         beginLifespanVersion, geometry,
         refPoint_x, refPoint_y, refPoint_lon, refPoint_lat)
    VALUES (:id_valuo, :kod_ku, :parcel_number, :gml_id, :areaValue_m2,
            :beginLifespanVersion, :geometry,
            :refPoint_x, :refPoint_y, :refPoint_lon, :refPoint_lat)
""")
SQL_OZNAC = text("UPDATE dbo.KN_k_pretazeni SET zpracovano = 1 WHERE id_valuo = :idv")

# důvody, u nichž je dosavadní vazba prokazatelně špatná
VZDY_SMAZAT = {"CIZI_UZEMI", "STAVEBNI_NESOULAD"}


def zapis_davku(davka):
    """davka = [(id_valuo, duvod, [zaznamy_parcel])]"""
    with engine.begin() as conn:
        for id_valuo, duvod, parcely in davka:
            if parcely or duvod in VZDY_SMAZAT:
                conn.execute(SQL_SMAZ_UP, {"idv": int(id_valuo)})
                conn.execute(SQL_SMAZ_PARCELY, {"idv": int(id_valuo)})
            videno = set()
            for z in parcely:
                if z["gml_id"] in videno:
                    continue
                videno.add(z["gml_id"])
                conn.execute(SQL_VLOZ, {
                    k: v for k, v in z.items() if k != "label"
                } | {"id_valuo": int(id_valuo)})
            conn.execute(SQL_OZNAC, {"idv": int(id_valuo)})


# ==================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test", action="store_true",
                    help="jen rozparsuje popisy, na katastr se neobrací "
                         "a do databáze nezapisuje")
    ap.add_argument("--limit", type=int, default=None,
                    help="zpracuje jen prvních N záznamů")
    args = ap.parse_args()

    # ---------- číselník katastrálních území ----------
    ciselnik = pd.read_sql(
        "SELECT ku_kod, ku_nazev FROM dbo.CIS_katastralni_uzemi", engine
    )
    kody = {r.ku_nazev.strip().lower(): int(r.ku_kod)
            for r in ciselnik.itertuples()}
    log.info(f"Číselník: {len(kody):,} území".replace(",", " "))

    # ---------- seznam k přetažení ----------
    sql = """
        SELECT id_valuo, duvod, popis, nemovitost, okres, kat_uzemi, plocha
        FROM dbo.KN_k_pretazeni WHERE zpracovano = 0 ORDER BY id_valuo
    """
    if args.limit:
        sql = sql.replace("SELECT", f"SELECT TOP {args.limit}", 1)
    df = pd.read_sql(sql, engine)
    log.info(f"Ke zpracování: {len(df):,} záznamů".replace(",", " "))
    if df.empty:
        log.info("Nic k práci.")
        return

    # ---------- režim test ----------
    if args.test:
        stat, bez_uzemi, ukazky = Counter(), Counter(), []
        for r in df.itertuples():
            parcely, duvod = parcely_z_popisu(r.popis)
            if duvod:
                stat[duvod] += 1
                if len(ukazky) < 15 and duvod in ("neznamy_tvar", "seznam_neparsovan"):
                    ukazky.append((r.id_valuo, r.nemovitost, (r.popis or "")[:90]))
                continue
            chybne = [u for u, _ in parcely if u.strip().lower() not in kody]
            if chybne:
                stat["uzemi_neni_v_ciselniku"] += 1
                for u in chybne:
                    bez_uzemi[u] += 1
            else:
                stat["OK"] += 1

        log.info("")
        log.info("VÝSLEDEK PARSOVÁNÍ")
        for k, v in stat.most_common():
            log.info(f"  {k:<28} {v:>7,}".replace(",", " "))
        if bez_uzemi:
            log.info("")
            log.info("Území, která nejsou v číselníku:")
            for u, v in bez_uzemi.most_common(15):
                log.info(f"  {u:<40} {v:>5}")
        if ukazky:
            log.info("")
            log.info("Ukázky nerozparsovaných popisů:")
            for i, n, p in ukazky:
                log.info(f"  [{i}] {n}: {p}")
        log.info("")
        log.info("Nic se nezměnilo. Plný běh spusť bez --test.")
        return

    # ---------- plný běh ----------
    log_csv = Path(__file__).parent / f"17_log_{datetime.now():%Y%m%d_%H%M}.csv"
    f = open(log_csv, "w", encoding="utf-8-sig", newline="")
    w = csv.writer(f, delimiter=";")
    w.writerow(["id_valuo", "duvod_pretazeni", "uzemi", "parcela",
                "vysledek", "vymera_valuo", "vymera_katastr", "detail"])

    davka, stat = [], Counter()
    zacatek = time.time()

    for i, r in enumerate(df.itertuples(), 1):
        parcely, duvod = parcely_z_popisu(r.popis)

        if duvod:
            stat[duvod] += 1
            w.writerow([r.id_valuo, r.duvod, "", "", duvod,
                        r.plocha, "", (r.popis or "")[:90]])
            davka.append((r.id_valuo, r.duvod, []))
        else:
            nalezene = []
            for uzemi, cislo in parcely:
                kod = kody.get(uzemi.strip().lower())
                if kod is None:
                    stat["uzemi_neni_v_ciselniku"] += 1
                    w.writerow([r.id_valuo, r.duvod, uzemi, cislo,
                                "uzemi_neni_v_ciselniku", r.plocha, "", ""])
                    continue

                zaznamy, chyba = stahni_parcelu(kod, cislo, uzemi)
                time.sleep(PAUZA_S)

                if chyba:
                    stat[chyba] += 1
                    w.writerow([r.id_valuo, r.duvod, uzemi, cislo,
                                chyba, r.plocha, "", f"kod_ku={kod}"])
                    continue

                nalezene.extend(zaznamy)
                stat["nalezeno"] += 1
                vym = zaznamy[0]["areaValue_m2"]
                sedi = ""
                if r.nemovitost == "parcela" and r.plocha and vym:
                    sedi = "vymera_sedi" if abs(float(r.plocha) - vym) < 1 \
                           else "vymera_nesedi"
                w.writerow([r.id_valuo, r.duvod, uzemi, cislo, "ok",
                            r.plocha, vym, sedi])

            davka.append((r.id_valuo, r.duvod, nalezene))

        if len(davka) >= DAVKA:
            zapis_davku(davka)
            davka = []
            f.flush()
            hotovo = i / len(df)
            zbyva = (time.time() - zacatek) / max(hotovo, 1e-9) * (1 - hotovo)
            log.info(f"  {i:,} / {len(df):,}  ({hotovo:.0%}), "
                     f"zbývá asi {zbyva / 60:.0f} min".replace(",", " "))

    if davka:
        zapis_davku(davka)
    f.close()

    log.info("")
    log.info("SOUHRN")
    for k, v in stat.most_common():
        log.info(f"  {k:<28} {v:>7,}".replace(",", " "))
    log.info("")
    log.info(f"Log: {log_csv}")
    log.info("Dál spusť 17b_geografie.py, pak 09_parcely_UP_kompletni.py.")


if __name__ == "__main__":
    main()
