#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
27_ruian_import.py — stažení a import technickoekonomických atributů z RÚIAN.

Čte soubory výměnného formátu RÚIAN (VFR) po obcích, vytáhne z nich stavební
objekty a uloží je do samostatných tabulek. Do Valuo_data nezapisuje nic;
párování obstarávají pohledy v_RUIAN_budovy a v_RUIAN_jednotky.

Před prvním během spusť 27_ruian_tabulky.sql.

VARIANTY SOUBORU
    UKSH  kompletní sada — parcely včetně polygonů. Výchozí od verze 27.4.
    UZSZ  základní sada — u parcel POUZE definiční bod, žádné hranice.
          Ověřeno 24. 10. 2026 na obci Kostelec: 3 196 parcel, 0 polygonů.
    Soubory leží v podsložce podle varianty: RUIAN obce / UKSH.

POSTUP
    python 27_ruian_import.py --seznam-obci            # které obce stáhnout
    python 27_ruian_import.py --rozpocet --kraj "Středočeský kraj" --vcetne-stazenych
    python 27_ruian_import.py --stahni 503916          # jedna obec
    python 27_ruian_import.py --stahni auto --kraj "Středočeský kraj" --vcetne-stazenych
    python 27_ruian_import.py --stahni auto            # obce s budovou/jednotkou
    python 27_ruian_import.py --ciselnik ciselnik_20251103_ST_UCIS.xml
    python 27_ruian_import.py --test                   # rozbor, bez zápisu
    python 27_ruian_import.py --import                 # zápis do databáze
    python 27_ruian_import.py --parovani               # kontrola napojení

POZNÁMKY K VÝKONU (ověřeno na souboru o velikosti Prahy, 1,05 GB XML)
    ZIP se nikdy nerozbaluje — XML se čte proudem přímo z archivu.
    Vrchol paměti 75 MB, průchod 24 s. Naivní parser se stejným souborem
    vyšplhá na 3,4 GB, protože mu v paměti zůstanou parcely, které jsou
    v souboru PŘED stavebními objekty.

DVĚ PASTI, KTERÉ TENTO SKRIPT OBCHÁZÍ
    1. tag='{*}StavebniObjekt' chytí i <ami:StavebniObjekt>, což je pouhý
       odkaz uvnitř adresního místa: <ami:StavebniObjekt><soi:Kod>…</soi:Kod>.
       Na testu to dalo 123 584 falešných záznamů navíc. Proto se používá
       přesný jmenný prostor vf:.
    2. IdentifikacniParcela nese <pai:Id>, nikoli <pai:Kod>.
"""

import argparse
import csv
import gzip
import io
import math
import os
import re
import sys
import time
import zipfile
from collections import Counter
from datetime import date, timedelta

try:
    from lxml import etree
except ImportError:
    sys.exit("Chybí lxml:  pip install lxml")

VERZE = "27.7 (2026-10-24)"
# 27.1 první verze
# 27.2 bez konfigurace (složka skriptu, Windows ověření), přepínač --varianta
# 27.3 kontrola násobnosti párování v --parovani; patří k 27a_oprava_jednotek.sql
# 27.4 soubory v DATA_KN\RUIAN obce (podsložka podle varianty), výchozí UKSH,
#      výběr obcí podle kraje a okresu, režim --rozpocet (HEAD bez stahování)
# 27.5 parcely z UKSH: geometrie, BPEJ, půdorysy staveb; patří
#      k 32_ruian_parcely.sql
# 27.6 hranice složené z oblouků: gml:Ring s curveMembery, ArcString
#      a Circle (v Kostelci 4 parcely z 3 196)
# 27.7 MakeValid na geometrie, které SQL Server odmítne (STArea na
#      neplatné instanci shodí dávku); chyba jedné obce nezastaví import

# ---------------------------------------------------------------------------
# KONFIGURACE
# ---------------------------------------------------------------------------

# Kořen se soubory VFR. Uvnitř jsou podsložky podle varianty:
#     …\RUIAN obce\UZSZ   základní sada — u parcel jen definiční bod
#     …\RUIAN obce\UKSH   kompletní sada — parcely včetně polygonů
# Podsložka se volí sama podle varianty; chybí-li, čte se kořen.
# Jiný kořen zadáš přepínačem --slozka.
SLOZKA = (r"C:\Users\ijttr\OneDrive\Dokumenty\OCEŇOVÁNÍ"
          r"\_GEO_DATA_VALUE_MAPS\DATA_KN\RUIAN obce")

# Připojení k databázi. Nic se nevyplňuje: ovladač se najde sám mezi
# nainstalovanými a přihlašuje se účtem Windows, pod kterým skript běží.
# Jiný server zadáš přepínačem --server.
SERVER = "localhost"
DATABAZE = "VALUO"

# Kompletní datová sada: prvky včetně originálních hranic, parcely včetně
# polygonů. Základní sada UZSZ nese u parcel POUZE definiční bod — ověřeno
# 24. 10. 2026 na souboru obce Kostelec (503916): 3 196 parcel,
# 7 926 definičních bodů, 0 polygonů. Pro geometrii okolí je proto nutná UKSH.
VARIANTA = "UKSH"
BASE = "https://vdp.cuzk.gov.cz/vymenny_format/soucasna"
HLAVICKY = {"User-Agent": "Mozilla/5.0 (VALUO RUIAN import)"}

VF = "{urn:cz:isvs:ruian:schemas:VymennyFormatTypy:v1}"
SOI = "{urn:cz:isvs:ruian:schemas:StavObjIntTypy:v1}"
PAI = "{urn:cz:isvs:ruian:schemas:ParcelaIntTypy:v1}"
COM = "{urn:cz:isvs:ruian:schemas:CommonTypy:v1}"
GML = "{http://www.opengis.net/gml/3.2}"

# Sloupce tabulky RUIAN_parcely, mimo geografické a mimo gml_id (počítaný).
PARCELA_SLOUPCE = ["kod_parcely", "obec_kod", "kod_ku", "kmenove_cislo",
                   "poddeleni", "druh_cislovani_kod", "druh_pozemku_kod",
                   "zpusob_vyuziti_kod", "vymera_m2", "plati_od",
                   "soubor_datum"]

# Prvky, které se při průchodu průběžně uvolňují. Bez Parcely a AdresniMisto
# zůstanou v paměti celé a u Prahy to znamená několik GB.
UKLIZET = (VF + "StavebniObjekt", VF + "Parcela",
           VF + "AdresniMisto", VF + "Ulice")

# sloupec v databázi -> název prvku v XML
MAPA = [
    ("kod_so",                   "Kod"),
    ("typ_so_kod",               "TypStavebnihoObjektuKod"),
    ("zpusob_vyuziti_kod",       "ZpusobVyuzitiKod"),
    ("dokonceni",                "Dokonceni"),
    ("iskn_budova_id",           "IsknBudovaId"),
    ("pocet_bytu",               "PocetBytu"),
    ("pocet_podlazi",            "PocetPodlazi"),
    ("zastavena_plocha",         "ZastavenaPlocha"),
    ("podlahova_plocha",         "PodlahovaPlocha"),
    ("obestaveny_prostor",       "ObestavenyProstor"),
    ("druh_konstrukce_kod",      "DruhKonstrukceKod"),
    ("zpusob_vytapeni_kod",      "ZpusobVytapeniKod"),
    ("vybaveni_vytahem_kod",     "VybaveniVytahemKod"),
    ("pripojeni_kanalizace_kod", "PripojeniKanalizaceKod"),
    ("pripojeni_plyn_kod",       "PripojeniPlynKod"),
    ("pripojeni_vodovod_kod",    "PripojeniVodovodKod"),
    ("plati_od",                 "PlatiOd"),
]
SLOUPCE = [s for s, _ in MAPA] + ["parcela_id", "cast_obce_kod",
                                  "obec_kod", "soubor_datum"]
DATUMY = {"dokonceni", "plati_od"}

CISELNIKY = {          # blok ve VFR -> název v CIS_RUIAN
    "DruhyKonstrukce": "DruhKonstrukce",
    "PripojeniKanalizace": "PripojeniKanalizace",
    "PripojeniPlynu": "PripojeniPlynu",
    "PripojeniVody": "PripojeniVody",
    "VybaveniVytahu": "VybaveniVytahem",
    "ZpusobyVytapeni": "ZpusobVytapeni",
    "ZpusobyVyuzitiObjektu": "ZpusobVyuzitiObjektu",
    "TypyStavebnichObjektu": "TypStavebnihoObjektu",
    "DruhyPozemku": "DruhPozemku",
    "DruhyCislovaniParcel": "DruhCislovaniParcel",
    "ZpusobyVyuzitiPozemku": "ZpusobVyuzitiPozemku",
    "TypyOchrany": "TypOchrany",
    "ZpusobyOchrany": "ZpusobOchrany",
}

VZOR = re.compile(r"^(\d{8})_OB_(\d+)_([A-Z]{4})\.xml(\.zip|\.gz)?$", re.I)


# ---------------------------------------------------------------------------
# POMOCNÉ
# ---------------------------------------------------------------------------

def cele(x):
    if x is None:
        return None
    s = str(x).strip()
    if not s:
        return None
    try:
        return int(float(s.replace(" ", "").replace(",", ".")))
    except ValueError:
        return None


def datum(x):
    return x[:10] if x else None


_TRANS = None


def transformer():
    """S-JTSK (EPSG:5514) -> WGS84. Načítá se až při prvním použití, aby
    skript běžel i bez pyproj, dokud se nesahá na geometrii."""
    global _TRANS
    if _TRANS is None:
        try:
            from pyproj import Transformer
        except ImportError:
            sys.exit("Chybí pyproj:  pip install pyproj")
        _TRANS = Transformer.from_crs("EPSG:5514", "EPSG:4326", always_xy=True)
    return _TRANS


def _souradnice(el):
    """Souřadnice jednoho segmentu (posList, nebo několik gml:pos)."""
    p = el.find(GML + "posList")
    if p is not None and p.text:
        text = p.text
    else:
        pos = [q.text for q in el.findall(GML + "pos") if q.text]
        if not pos:
            raise ValueError("segment bez souřadnic")
        text = " ".join(pos)
    c = text.split()
    if len(c) % 2:
        raise ValueError("lichý počet souřadnic")
    return [(float(c[i]), float(c[i + 1])) for i in range(0, len(c), 2)]


def _stred(a, b, c):
    """Střed kružnice třemi body. Počítá se v S-JTSK, tedy v metrech."""
    d = 2 * (a[0] * (b[1] - c[1]) + b[0] * (c[1] - a[1]) + c[0] * (a[1] - b[1]))
    if abs(d) < 1e-9:
        raise ValueError("tři body na přímce")
    aa, bb, cc = a[0]**2 + a[1]**2, b[0]**2 + b[1]**2, c[0]**2 + c[1]**2
    return ((aa * (b[1] - c[1]) + bb * (c[1] - a[1]) + cc * (a[1] - b[1])) / d,
            (aa * (c[0] - b[0]) + bb * (a[0] - c[0]) + cc * (b[0] - a[0])) / d)


def _oblouk(a, b, c, cely=False, tolerance=0.01):
    """Oblouk třemi body -> lomená čára, bez počátečního bodu.

    geography neumí kruhové oblouky uvnitř polygonu, takže se nahrazují
    úsečkami. Krok se volí podle poloměru tak, aby sečna od oblouku
    neutekla víc než o toleranci (1 cm). cely=True je gml:Circle.
    """
    sx, sy = _stred(a, b, c)
    r = math.hypot(a[0] - sx, a[1] - sy)
    if r <= tolerance:
        return [b, c]
    fa = math.atan2(a[1] - sy, a[0] - sx)
    if cely:
        rozsah, smer = 2 * math.pi, 1
    else:
        fb = math.atan2(b[1] - sy, b[0] - sx)
        fc = math.atan2(c[1] - sy, c[0] - sx)
        dv = (2 * math.pi)
        if (fb - fa) % dv < (fc - fa) % dv:
            rozsah, smer = (fc - fa) % dv, 1
        else:
            rozsah, smer = (fa - fc) % dv, -1
    krok = 2 * math.acos(max(-1.0, min(1.0, 1 - tolerance / r)))
    n = max(2, min(256, int(math.ceil(rozsah / max(krok, 1e-6)))))
    return [(sx + r * math.cos(fa + smer * rozsah * i / n),
             sy + r * math.sin(fa + smer * rozsah * i / n))
            for i in range(1, n + 1)]


def _hranice(el):
    """Vnější nebo vnitřní hranice -> body v S-JTSK.

    Hranice bývá prostý gml:LinearRing, ale také gml:Ring poskládaný
    z curveMemberů: úseček, oblouků (ArcString) i celých kružnic
    (Circle). V Kostelci takovou hranici mají 4 parcely z 3 196 — kruhová
    je třeba zastavěná plocha pod silem.
    """
    body = []

    def pridej(nove):
        if not nove:
            return
        if body and body[-1] == nove[0]:
            nove = nove[1:]
        body.extend(nove)

    def projdi(x):
        t = x.tag.split("}")[-1]
        if t in ("LinearRing", "LineString"):
            pridej(_souradnice(x))
        elif t == "ArcString":
            p = _souradnice(x)
            for i in range(0, len(p) - 2, 2):
                pridej([p[i]] + _oblouk(p[i], p[i + 1], p[i + 2]))
        elif t in ("Circle", "ArcByCenterPoint", "CircleByCenterPoint"):
            p = _souradnice(x)
            if len(p) >= 3:
                pridej([p[0]] + _oblouk(p[0], p[1], p[2], cely=(t == "Circle")))
        elif t != "posList" and t != "pos":
            for ch in x:
                projdi(ch)

    projdi(el)
    if len(body) >= 3 and body[0] != body[-1]:
        body.append(body[0])
    if len(body) < 4:
        raise ValueError(f"hranice má {len(body)} bodů")
    return body


def _shoelace(b):
    s = 0.0
    for i in range(len(b) - 1):
        s += b[i][0] * b[i + 1][1] - b[i + 1][0] * b[i][1]
    return s / 2.0


def _ring_wgs(b, vnejsi):
    """Transformace a teprve POTOM orientace.

    Tohle je přesně to místo, kde krok 03b selhal: orientace se počítala
    na souřadnicích v S-JTSK a teprve pak se transformovalo. Osy obou
    systémů jsou orientované různě, takže výsledek byl obrácený u všech
    148 404 polygonů a STArea() vracela 510 065 621 710 996 m².
    geography chce vnější ring proti směru hodinových ručiček (kladná
    znaménková plocha nad dvojicemi lon/lat), vnitřní opačně.
    """
    lon, lat = transformer().transform([x for x, _ in b], [y for _, y in b])
    wgs = list(zip(lon, lat))
    p = _shoelace(wgs)
    if abs(p) < 1e-14:
        raise ValueError("nulová plocha")
    if (p < 0) == bool(vnejsi):
        wgs.reverse()
    return wgs


def wkt_bod(el):
    """pai:DefinicniBod / soi:DefinicniBod -> WKT POINT ve WGS84."""
    pos = el.find(GML + "Point/" + GML + "pos")
    if pos is None or not pos.text:
        return None
    x, y = (float(v) for v in pos.text.split()[:2])
    lon, lat = transformer().transform(x, y)
    return f"POINT ({lon:.8f} {lat:.8f})"


def wkt_polygon(el):
    """gml:Polygon -> WKT POLYGON ve WGS84, s dírami."""
    ext = el.find(GML + "exterior")
    if ext is None:
        raise ValueError("polygon bez vnější hranice")
    ringy = [_ring_wgs(_hranice(ext), True)]
    for ins in el.findall(GML + "interior"):
        try:
            ringy.append(_ring_wgs(_hranice(ins), False))
        except ValueError:
            pass                # vadná díra se zahodí, polygon zůstane
    return "POLYGON (" + ", ".join(
        "(" + ", ".join(f"{lo:.8f} {la:.8f}" for lo, la in r) + ")"
        for r in ringy) + ")"


def wkt_plocha(el):
    """OriginalniHranice: jeden Polygon, nebo MultiSurface u staveb."""
    pol = list(el.iter(GML + "Polygon"))
    if not pol:
        return None
    casti = [wkt_polygon(x)[len("POLYGON "):] for x in pol]
    if len(casti) == 1:
        return "POLYGON " + casti[0]
    return "MULTIPOLYGON (" + ", ".join(casti) + ")"


def otevri(cesta):
    """Vrátí binární proud XML. ZIP se NEROZBALUJE na disk."""
    n = cesta.lower()
    if n.endswith(".zip"):
        z = zipfile.ZipFile(cesta)
        xml = [p for p in z.namelist() if p.lower().endswith(".xml")]
        if not xml:
            raise ValueError(f"{cesta}: v archivu není XML")
        return z.open(xml[0]), z
    if n.endswith(".gz"):
        return gzip.open(cesta, "rb"), None
    return open(cesta, "rb"), None


_SERVER = None   # nastaví main() podle --server


def db():
    """Připojení přes Windows ověření. Ovladač se vybere z nainstalovaných,
    od nejnovějšího — není co konfigurovat."""
    try:
        import pyodbc
    except ImportError:
        sys.exit("Chybí pyodbc:  pip install pyodbc")

    ovladace = [d for d in pyodbc.drivers() if "SQL Server" in d]
    if not ovladace:
        sys.exit("Není nainstalovaný žádný ovladač ODBC pro SQL Server.\n"
                 "Stáhni 'ODBC Driver 18 for SQL Server' z webu Microsoftu.")
    # nejdřív číslované verze od nejvyšší, teprve pak starý 'SQL Server'
    def poradi(d):
        c = re.search(r"(\d+)", d)
        return (1 if c else 0, int(c.group(1)) if c else 0)
    ovladace.sort(key=poradi, reverse=True)

    posledni = None
    for ovl in ovladace:
        cs = (f"DRIVER={{{ovl}}};SERVER={_SERVER or SERVER};"
              f"DATABASE={DATABAZE};Trusted_Connection=yes;"
              "TrustServerCertificate=yes;")
        try:
            return pyodbc.connect(cs, autocommit=False)
        except Exception as e:
            posledni = f"{ovl}: {str(e)[:150]}"
    sys.exit(f"K databázi {DATABAZE} na {_SERVER or SERVER} se nelze připojit.\n"
             f"  {posledni}\n"
             f"  Jiný server zadáš přepínačem --server, např. --server RYZEN9")


# ---------------------------------------------------------------------------
# PARSOVÁNÍ
# ---------------------------------------------------------------------------

def parsuj(cesta, obec_kod, soubor_datum, hlas=True, s_parcelami=True):
    """Streamové čtení jednoho souboru VFR.

    Vrací (radky, cisla_domovni, nalezy). Paměť zůstává konstantní bez
    ohledu na velikost souboru.
    """
    radky, cisla, parcely, bpej = [], [], [], []
    nalezy = Counter()
    t0 = time.time()
    proud, archiv = otevri(cesta)
    try:
        ctx = etree.iterparse(proud, events=("end",), tag=UKLIZET,
                              recover=True, huge_tree=True)
        for _, el in ctx:
            if el.tag == VF + "StavebniObjekt":
                r = {}
                for sloupec, prvek in MAPA:
                    e = el.find(SOI + prvek)
                    txt = e.text.strip() if e is not None and e.text else None
                    r[sloupec] = datum(txt) if sloupec in DATUMY else cele(txt)

                # IdentifikacniParcela nese pai:Id, ne Kod
                pid = el.find(SOI + "IdentifikacniParcela/{*}Id")
                if pid is None:
                    pid = el.find(SOI + "IdentifikacniParcela/{*}Kod")
                r["parcela_id"] = cele(pid.text) if pid is not None else None

                co = el.find(SOI + "CastObce/{*}Kod")
                r["cast_obce_kod"] = cele(co.text) if co is not None else None
                r["obec_kod"] = obec_kod
                r["soubor_datum"] = soubor_datum

                # půdorys stavby: jen UKSH, u UZSZ zůstane None
                r["wkt_plocha"] = None
                g = el.find(SOI + "Geometrie")
                if g is not None and s_parcelami:
                    try:
                        r["wkt_plocha"] = wkt_plocha(g)
                        if r["wkt_plocha"]:
                            nalezy["so_pudorys"] += 1
                    except Exception:
                        nalezy["so_pudorys_chyba"] += 1

                if r["kod_so"] is not None:
                    radky.append(r)
                    for cd in el.iter("{*}CisloDomovni"):
                        n = cele(cd.text)
                        if n is not None:
                            cisla.append((r["kod_so"], n, obec_kod))
                    for s in ("dokonceni", "zastavena_plocha", "podlahova_plocha",
                              "obestaveny_prostor", "pocet_podlazi", "pocet_bytu",
                              "druh_konstrukce_kod", "parcela_id"):
                        if r[s] is not None:
                            nalezy[s] += 1
                else:
                    nalezy["bez_kodu"] += 1

            elif el.tag == VF + "Parcela" and s_parcelami:
                kodp = cele(el.findtext(PAI + "Id"))
                if kodp is None:
                    nalezy["parcela_bez_id"] += 1
                else:
                    ku = el.find(PAI + "KatastralniUzemi/{*}Kod")
                    r = {
                        "kod_parcely": kodp,
                        "obec_kod": obec_kod,
                        "kod_ku": cele(ku.text) if ku is not None else None,
                        "kmenove_cislo": cele(el.findtext(PAI + "KmenoveCislo")),
                        "poddeleni": cele(el.findtext(PAI + "PododdeleniCisla")),
                        "druh_cislovani_kod": cele(el.findtext(PAI + "DruhCislovaniKod")),
                        "druh_pozemku_kod": cele(el.findtext(PAI + "DruhPozemkuKod")),
                        # kolekce ZpusobyVyuzitiPozemku bývá prázdná (ověřeno
                        # na Kostelci: 1 351 prázdných elementů)
                        "zpusob_vyuziti_kod": cele(el.findtext(
                            PAI + "ZpusobyVyuzitiPozemku/{*}ZpusobVyuzitiPozemkuKod")),
                        "vymera_m2": cele(el.findtext(PAI + "VymeraParcely")),
                        "plati_od": datum(el.findtext(PAI + "PlatiOd")),
                        "soubor_datum": soubor_datum,
                        "wkt_bod": None,
                        "wkt_plocha": None,
                    }
                    g = el.find(PAI + "Geometrie")
                    if g is not None:
                        b = g.find("{*}DefinicniBod")
                        if b is not None:
                            try:
                                r["wkt_bod"] = wkt_bod(b)
                            except Exception:
                                nalezy["parcela_bod_chyba"] += 1
                        try:
                            r["wkt_plocha"] = wkt_plocha(g)
                            if r["wkt_plocha"]:
                                nalezy["parcela_plocha"] += 1
                        except Exception:
                            nalezy["parcela_plocha_chyba"] += 1
                    parcely.append(r)
                    for bd in el.iter(COM + "BonitovanyDil"):
                        k = cele(bd.findtext(COM + "BonitovanaJednotkaKod"))
                        if k is not None:
                            bpej.append((kodp, k, cele(bd.findtext(COM + "Vymera")),
                                         soubor_datum))

            # uvolnění: platí pro VŠECHNY sledované prvky, ne jen budovy
            el.clear()
            p = el.getparent()
            while p is not None and p.getprevious() is not None:
                del p.getparent()[0]
                p = p.getparent()
    finally:
        proud.close()
        if archiv:
            archiv.close()

    if hlas:
        print(f"    {len(radky):7} objektů, {len(cisla):7} čísel domovních,"
              f" {len(parcely):7} parcel (z toho {nalezy['parcela_plocha']} s hranicí)"
              f"   za {time.time() - t0:5.1f} s")
    return radky, cisla, parcely, bpej, nalezy


def slozka_varianty(koren, varianta=None):
    """Soubory leží v podsložce pojmenované po variantě (UZSZ / UKSH).
    Není-li podsložka založená, použije se kořen — kvůli starším složkám."""
    var = (varianta or VARIANTA).upper()
    kandidat = os.path.join(koren, var)
    return kandidat if os.path.isdir(kandidat) else koren


def soubory(slozka, jen_obec=None, varianta=None):
    """Pro každou obec jeden soubor: nejnovější datum, při shodě data
    přednost zvolené variantě.

    Leží-li ve složce pro touž obec a totéž datum víc variant (třeba UZSZ
    i UKSH), skript to oznámí a řekne, kterou bere — jinak by volba
    závisela na pořadí souborů ve složce, což je tichá past.
    """
    if not os.path.isdir(slozka):
        sys.exit(f"Složka neexistuje: {slozka}")
    chtena = (varianta or VARIANTA).upper()
    vse = {}
    for f in sorted(os.listdir(slozka)):
        m = VZOR.match(f)
        if not m:
            continue
        d, kod, var, _ = m.groups()
        kod = int(kod)
        if jen_obec and kod != jen_obec:
            continue
        vse.setdefault(kod, []).append((d, var.upper(), os.path.join(slozka, f), f))

    nej = {}
    for kod, sez in vse.items():
        if varianta:                       # vynucená varianta
            sez = [x for x in sez if x[1] == chtena]
            if not sez:
                continue
        sez.sort(key=lambda x: (x[0], x[1] == chtena, x[1]), reverse=True)
        d, var, cesta, nazev = sez[0]
        jine = sorted({x[1] for x in vse[kod] if x[0] == d})
        if len(jine) > 1 and not varianta:
            print(f"  obec {kod}: ve složce jsou varianty {', '.join(jine)} "
                  f"→ beru {var}   (jinou vynutíš přepínačem --varianta)")
        nej[kod] = (d, cesta, nazev)
    return nej


# ---------------------------------------------------------------------------
# STAHOVÁNÍ
# ---------------------------------------------------------------------------

def najdi_datum(obec, dnu=95, varianta=None):
    """Soubory se generují jednou měsíčně. Datum se zjistí jednou a platí
    pak pro všechny obce."""
    from urllib.error import HTTPError, URLError
    from urllib.request import Request, urlopen
    var = (varianta or VARIANTA).upper()
    for i in range(dnu):
        d = (date.today() - timedelta(days=i)).strftime("%Y%m%d")
        u = f"{BASE}/{d}_OB_{obec}_{var}.xml.zip"
        try:
            r = urlopen(Request(u, headers=HLAVICKY, method="HEAD"), timeout=60)
            r.close()
            return d
        except HTTPError as e:
            if e.code != 404:
                print(f"  {u} -> HTTP {e.code}")
        except URLError as e:
            print(f"  {u} -> {e.reason}")
    return None


def stahni(obce, slozka, varianta=None):
    from urllib.error import HTTPError
    from urllib.request import Request, urlopen
    var = (varianta or VARIANTA).upper()
    os.makedirs(slozka, exist_ok=True)

    print(f"Hledám datum nejnovějšího souboru (obec {obce[0]}, {var})…")
    print(f"Ukládám do: {slozka}")
    d = najdi_datum(obce[0], varianta=var)
    if not d:
        sys.exit("Soubor se nepodařilo najít. Ověř kód obce, nebo si "
                 "soubor stáhni ručně z https://vdp.cuzk.cz/vdp/ruian/vymennyformat")
    print(f"Datum souborů: {d}\n")

    ok = chyby = presk = 0
    for i, kod in enumerate(obce, 1):
        nazev = f"{d}_OB_{kod}_{var}.xml.zip"
        cil = os.path.join(slozka, nazev)
        if os.path.exists(cil):
            print(f"[{i}/{len(obce)}] {nazev} — už je")
            presk += 1
            continue
        u = f"{BASE}/{nazev}"
        try:
            t0 = time.time()
            with urlopen(Request(u, headers=HLAVICKY), timeout=900) as r, \
                    open(cil + ".tmp", "wb") as f:
                while True:
                    blok = r.read(1 << 20)
                    if not blok:
                        break
                    f.write(blok)
            os.replace(cil + ".tmp", cil)
            mb = os.path.getsize(cil) / 1e6
            print(f"[{i}/{len(obce)}] {nazev}  {mb:7.1f} MB  "
                  f"za {time.time() - t0:.0f} s")
            ok += 1
        except HTTPError as e:
            print(f"[{i}/{len(obce)}] {nazev} — HTTP {e.code}")
            if os.path.exists(cil + ".tmp"):
                os.remove(cil + ".tmp")
            chyby += 1
        except Exception as e:
            print(f"[{i}/{len(obce)}] {nazev} — {e}")
            if os.path.exists(cil + ".tmp"):
                os.remove(cil + ".tmp")
            chyby += 1
    print(f"\nStaženo {ok}, přeskočeno {presk}, chyb {chyby}.")


def obce_z_databaze():
    """Obce, kde mám budovu nebo jednotku. U obcí jen s pozemky nemá
    RÚIAN co nabídnout."""
    with db() as c:
        return [(r[0], r[1], r[2]) for r in c.cursor().execute("""
            SELECT ku.obec_kod, MIN(ku.obec_nazev), COUNT(DISTINCT v.id)
            FROM dbo.Valuo_data v
            JOIN dbo.KN_parcel_data p ON p.id_valuo = v.id
            JOIN dbo.CIS_katastralni_uzemi ku ON ku.ku_kod = p.kod_ku
            WHERE v.nemovitost IN ('budova','jednotka')
            GROUP BY ku.obec_kod
            ORDER BY COUNT(DISTINCT v.id) DESC""").fetchall()]


def obce_vyberem(kraj=None, okresy=None, s_vklady=False, stazene=False,
                 s_budovami=False):
    """Seznam obcí ke stažení. Volby se SČÍTAJÍ (sjednocení), takže
    --kraj a --vcetne-stazenych dohromady dají kraj plus všechno, co už
    je staženo jinde. Bez voleb se chová jako do verze 27.3: obce, kde je
    budova nebo jednotka.

    Zrušená katastrální území (platnost_do) se neberou.
    """
    if not (kraj or okresy or s_vklady or stazene or s_budovami):
        s_budovami = True

    casti, parametry = [], []
    if kraj:
        casti.append("""
            SELECT DISTINCT obec_kod FROM dbo.CIS_katastralni_uzemi
            WHERE kraj_nazev = ? AND platnost_do IS NULL""")
        parametry.append(kraj)
    for okres in (okresy or []):
        casti.append("""
            SELECT DISTINCT obec_kod FROM dbo.CIS_katastralni_uzemi
            WHERE okres_nazev = ? AND platnost_do IS NULL""")
        parametry.append(okres)
    if s_vklady:
        casti.append("""
            SELECT DISTINCT ku.obec_kod
            FROM dbo.Valuo_data v
            JOIN dbo.CIS_katastralni_uzemi ku ON ku.ku_kod = v.kod_ku""")
    if s_budovami:
        casti.append("""
            SELECT DISTINCT ku.obec_kod
            FROM dbo.Valuo_data v
            JOIN dbo.KN_parcel_data p ON p.id_valuo = v.id
            JOIN dbo.CIS_katastralni_uzemi ku ON ku.ku_kod = p.kod_ku
            WHERE v.nemovitost IN ('budova','jednotka')""")
    if stazene:
        casti.append("SELECT obec_kod FROM dbo.RUIAN_obce_stav")

    sql = ("WITH vyber AS (" + " UNION ".join(casti) + ")\n"
           "SELECT v.obec_kod, MIN(ku.obec_nazev)\n"
           "FROM vyber v\n"
           "JOIN dbo.CIS_katastralni_uzemi ku ON ku.obec_kod = v.obec_kod\n"
           "GROUP BY v.obec_kod\n"
           "ORDER BY MIN(ku.obec_nazev)")
    with db() as c:
        return [(r[0], r[1]) for r in c.cursor().execute(sql, parametry).fetchall()]


def rozpocet(obce, slozka, varianta=None):
    """Suchý běh: HEAD dotaz na každý soubor, sečte Content-Length.
    Nestahuje ani bajt — slouží k rozhodnutí, do čeho jdeme."""
    from urllib.error import HTTPError, URLError
    from urllib.request import Request, urlopen
    var = (varianta or VARIANTA).upper()

    print(f"Hledám datum nejnovějšího souboru (obec {obce[0]}, {var})…")
    d = najdi_datum(obce[0], varianta=var)
    if not d:
        sys.exit("Soubor se nepodařilo najít. Ověř kód obce a variantu.")
    print(f"Datum souborů: {d}\n")

    bajty = mame = 0
    chybejici = []
    t0 = time.time()
    for i, kod in enumerate(obce, 1):
        nazev = f"{d}_OB_{kod}_{var}.xml.zip"
        if os.path.exists(os.path.join(slozka, nazev)):
            mame += 1
        u = f"{BASE}/{nazev}"
        try:
            r = urlopen(Request(u, headers=HLAVICKY, method="HEAD"), timeout=60)
            bajty += int(r.headers.get("Content-Length") or 0)
            r.close()
        except (HTTPError, URLError):
            chybejici.append(kod)
        if i % 50 == 0 or i == len(obce):
            print(f"  [{i}/{len(obce)}]  {bajty / 1e9:6.2f} GB   "
                  f"bez souboru {len(chybejici):3}   "
                  f"({time.time() - t0:.0f} s)")

    print(f"\nSouborů ke stažení: {len(obce) - len(chybejici)}")
    print(f"Celkem:             {bajty / 1e9:.2f} GB")
    print(f"Už máš ve složce:   {mame}")
    if chybejici:
        print(f"Bez souboru ({len(chybejici)}): "
              + ", ".join(str(k) for k in chybejici[:30])
              + (" …" if len(chybejici) > 30 else ""))


# ---------------------------------------------------------------------------
# ZÁPIS DO DATABÁZE
# ---------------------------------------------------------------------------

SQL_GEO_PARCELA = """
    UPDATE dbo.RUIAN_parcely
    SET geo_plocha = CASE WHEN ? IS NULL THEN NULL
                          ELSE geography::STGeomFromText(?, 4326) END,
        geo_bod    = CASE WHEN ? IS NULL THEN NULL
                          ELSE geography::STGeomFromText(?, 4326) END
    WHERE kod_parcely = ?"""

SQL_GEO_SO = """
    UPDATE dbo.RUIAN_stavebni_objekty
    SET geo_plocha = geography::STGeomFromText(?, 4326)
    WHERE kod_so = ?"""


def _geo_update(cur, sql, data, popis, log, velikost=500):
    """Geometrie se doplňuje UPDATEM, ne při INSERTu.

    Důvod: geography odmítne polygon, který se sám protíná, a dávkový
    INSERT by na jediném takovém spadl celý — a část řádků by přitom už
    byla vložena, takže opakování by narazilo na primární klíč. UPDATE
    se dá opakovat bez následků: spadne-li blok, rozpadne se po řádcích
    a vadná geometrie zůstane NULL a jde do logu.
    """
    chyb = 0
    for i in range(0, len(data), velikost):
        blok = data[i:i + velikost]
        try:
            cur.executemany(sql, blok)
        except Exception:
            for radek in blok:
                try:
                    cur.execute(sql, radek)
                except Exception as e:
                    chyb += 1
                    log.append((popis, radek[-1], str(e)[:130]))
    return chyb


def zapis_parcely(con, parcely, bpej, obec_kod, log):
    """Parcely obce. Obec se přepíše celá, stejně jako u staveb."""
    cur = con.cursor()
    cur.fast_executemany = True
    cur.execute("""DELETE b FROM dbo.RUIAN_parcely_bpej b
                   JOIN dbo.RUIAN_parcely p ON p.kod_parcely = b.kod_parcely
                   WHERE p.obec_kod = ?""", obec_kod)
    cur.execute("DELETE FROM dbo.RUIAN_parcely WHERE obec_kod = ?", obec_kod)
    if not parcely:
        con.commit()
        return 0

    sl = ",".join(PARCELA_SLOUPCE)
    ot = ",".join("?" * len(PARCELA_SLOUPCE))
    cur.executemany(f"INSERT INTO dbo.RUIAN_parcely ({sl}) VALUES ({ot})",
                    [tuple(r[s] for s in PARCELA_SLOUPCE) for r in parcely])

    chyb = _geo_update(cur, SQL_GEO_PARCELA,
                       [(r["wkt_plocha"], r["wkt_plocha"],
                         r["wkt_bod"], r["wkt_bod"], r["kod_parcely"])
                        for r in parcely if r["wkt_plocha"] or r["wkt_bod"]],
                       "parcela", log)

    if bpej:
        # Táž parcela může mít víc dílů se stejným BPEJ; primární klíč je
        # (parcela, BPEJ), takže se výměry sečtou.
        souhrn = {}
        for kodp, kod_bpej, vymera, sd in bpej:
            k = (kodp, kod_bpej)
            stara, _ = souhrn.get(k, (0, sd))
            souhrn[k] = (stara + (vymera or 0), sd)
        cur.executemany(
            "INSERT INTO dbo.RUIAN_parcely_bpej "
            "(kod_parcely, bpej_kod, vymera_m2, soubor_datum) VALUES (?,?,?,?)",
            [(kodp, kod_bpej, v or None, sd)
             for (kodp, kod_bpej), (v, sd) in souhrn.items()])

    # Geography přijme i polygon, který se sám protíná, ale STArea() na něm
    # vyhodí 24144 a shodí celou dávku. MakeValid takový tvar narovná;
    # body se můžou nepatrně posunout, což je proti ztrátě geometrie levné.
    cur.execute("UPDATE dbo.RUIAN_parcely SET geo_plocha = geo_plocha.MakeValid() "
                "WHERE obec_kod = ? AND geo_plocha IS NOT NULL "
                "AND geo_plocha.STIsValid() = 0", obec_kod)
    opraveno = max(cur.rowcount, 0)
    cur.execute("UPDATE dbo.RUIAN_parcely SET geo_plocha_m2 = "
                "CASE WHEN geo_plocha.STIsValid() = 1 THEN geo_plocha.STArea() END "
                "WHERE obec_kod = ? AND geo_plocha IS NOT NULL", obec_kod)
    con.commit()
    if opraveno:
        log.append(("parcely MakeValid", obec_kod, f"{opraveno} geometrií narovnáno"))
    return chyb


def zapis(con, radky, cisla, obec_kod, obec_nazev, soubor_datum, soubor_nazev,
          varianta=None, pocet_parcel=None, log=None):
    """Obec se přepíše celá — co v novém souboru není, zmizí i tady."""
    cur = con.cursor()
    cur.fast_executemany = True

    cur.execute("DELETE FROM dbo.RUIAN_so_cisla_domovni WHERE obec_kod = ?", obec_kod)
    cur.execute("DELETE FROM dbo.RUIAN_stavebni_objekty WHERE obec_kod = ?", obec_kod)

    if radky:
        sl = ",".join(SLOUPCE)
        ot = ",".join("?" * len(SLOUPCE))
        cur.executemany(
            f"INSERT INTO dbo.RUIAN_stavebni_objekty ({sl}) VALUES ({ot})",
            [tuple(r[s] for s in SLOUPCE) for r in radky])
    if cisla:
        cur.executemany(
            "INSERT INTO dbo.RUIAN_so_cisla_domovni "
            "(kod_so, cislo_domovni, obec_kod) VALUES (?,?,?)",
            sorted(set(cisla)))

    pudorysy = [(r["wkt_plocha"], r["kod_so"]) for r in radky
                if r.get("wkt_plocha")]
    if pudorysy:
        _geo_update(cur, SQL_GEO_SO, pudorysy, "stavba",
                    log if log is not None else [])
        cur.execute("UPDATE dbo.RUIAN_stavebni_objekty "
                    "SET geo_plocha = geo_plocha.MakeValid() "
                    "WHERE obec_kod = ? AND geo_plocha IS NOT NULL "
                    "AND geo_plocha.STIsValid() = 0", obec_kod)
        if log is not None and cur.rowcount > 0:
            log.append(("stavby MakeValid", obec_kod,
                        f"{cur.rowcount} půdorysů narovnáno"))
        cur.execute("UPDATE dbo.RUIAN_stavebni_objekty SET geo_plocha_m2 = "
                    "CASE WHEN geo_plocha.STIsValid() = 1 THEN geo_plocha.STArea() END "
                    "WHERE obec_kod = ? AND geo_plocha IS NOT NULL", obec_kod)

    cur.execute("""
        MERGE dbo.RUIAN_obce_stav AS c
        USING (SELECT ? AS obec_kod) AS n ON c.obec_kod = n.obec_kod
        WHEN MATCHED THEN UPDATE SET obec_nazev = ?, soubor_datum = ?,
             soubor_nazev = ?, pocet_so = ?, varianta = ?, pocet_parcel = ?,
             nacteno = SYSDATETIME()
        WHEN NOT MATCHED THEN
             INSERT (obec_kod, obec_nazev, soubor_datum, soubor_nazev, pocet_so,
                     varianta, pocet_parcel)
             VALUES (?,?,?,?,?,?,?);""",
        obec_kod, obec_nazev, soubor_datum, soubor_nazev, len(radky),
        varianta, pocet_parcel,
        obec_kod, obec_nazev, soubor_datum, soubor_nazev, len(radky),
        varianta, pocet_parcel)
    con.commit()


def ciselniky(cesta):
    """Načte ST_UCIS do CIS_RUIAN. Stačí jednou; soubor je jeden za ČR."""
    if not os.path.exists(cesta):
        sys.exit(f"Číselník nenalezen: {cesta}")
    root = etree.parse(cesta).getroot()
    davka = []
    for blok, nazev in CISELNIKY.items():
        n = 0
        for polozka in root.findall(f".//{{*}}{blok}/*"):
            kod = cele(polozka.findtext("./{*}Kod"))
            txt = polozka.findtext("./{*}Nazev")
            if kod is None or not txt:
                continue
            davka.append((nazev, kod, txt.strip(),
                          datum(polozka.findtext("./{*}PlatiOd")),
                          datum(polozka.findtext("./{*}PlatiDo"))))
            n += 1
        print(f"  {nazev:24} {n:4}")
    with db() as c:
        cur = c.cursor()
        cur.fast_executemany = True
        cur.execute("DELETE FROM dbo.CIS_RUIAN")
        cur.executemany(
            "INSERT INTO dbo.CIS_RUIAN "
            "(ciselnik, kod, nazev, platnost_od, platnost_do) VALUES (?,?,?,?,?)",
            davka)
        c.commit()
    print(f"\nZapsáno {len(davka)} položek do CIS_RUIAN.")


# ---------------------------------------------------------------------------
# REŽIMY
# ---------------------------------------------------------------------------

def rozbor(radky, nalezy):
    n = len(radky)
    if not n:
        print("    žádné objekty")
        return
    print(f"\n  VYPLNĚNOST ({n} objektů):")
    for s in ("dokonceni", "zastavena_plocha", "obestaveny_prostor",
              "podlahova_plocha", "pocet_podlazi", "pocet_bytu",
              "druh_konstrukce_kod", "parcela_id"):
        v = nalezy.get(s, 0)
        print(f"    {s:22} {v:7}  ({v / n * 100:5.1f} %)")

    pod = [r for r in radky
           if r["podlahova_plocha"] and r["zastavena_plocha"]
           and r["pocet_podlazi"] and r["zastavena_plocha"] > 0
           and r["pocet_podlazi"] > 0]
    if pod:
        p = sorted(r["podlahova_plocha"] / (r["zastavena_plocha"] * r["pocet_podlazi"])
                   for r in pod)
        nizke = sum(1 for x in p if x < 0.5)
        print(f"\n  PODLAHOVÁ PLOCHA — poměr k zastavěné × podlaží ({len(p)} objektů):")
        print(f"    medián {p[len(p)//2]:.2f}   P10 {p[len(p)//10]:.2f}   "
              f"P90 {p[len(p)*9//10]:.2f}")
        print(f"    pod 0,5 (nevěrohodně nízká): {nizke} ({nizke/len(p)*100:.1f} %)")

    op = [r for r in radky
          if r["obestaveny_prostor"] and r["zastavena_plocha"]
          and r["pocet_podlazi"] and r["zastavena_plocha"] > 0
          and r["pocet_podlazi"] > 0]
    if op:
        q = sorted(r["obestaveny_prostor"] / (r["zastavena_plocha"] * r["pocet_podlazi"] * 3)
                   for r in op)
        print(f"\n  OBESTAVĚNÝ PROSTOR — poměr k zastavěné × podlaží × 3 m ({len(q)}):")
        print(f"    medián {q[len(q)//2]:.2f}   P10 {q[len(q)//10]:.2f}   "
              f"P90 {q[len(q)*9//10]:.2f}")

    roky = [int(r["dokonceni"][:4]) for r in radky if r["dokonceni"]]
    if roky:
        roky.sort()
        print(f"\n  ROK DOKONČENÍ: {len(roky)} objektů, medián {roky[len(roky)//2]}, "
              f"min {roky[0]}, max {roky[-1]}")


def parovani():
    """Kolik nemovitostí z Valua najde svůj stavební objekt."""
    dotazy = [
        ("obcí načteno", "SELECT COUNT(*) FROM dbo.RUIAN_obce_stav"),
        ("stavebních objektů", "SELECT COUNT(*) FROM dbo.RUIAN_stavebni_objekty"),
        ("z toho s parcelou", "SELECT COUNT(*) FROM dbo.RUIAN_stavebni_objekty WHERE parcela_id IS NOT NULL"),
        ("budov Valuo spárováno", "SELECT COUNT(DISTINCT valuo_id) FROM dbo.v_RUIAN_budovy"),
        ("  z toho s rokem dokončení", "SELECT COUNT(DISTINCT valuo_id) FROM dbo.v_RUIAN_budovy WHERE ruian_dokonceni IS NOT NULL"),
        ("  z toho s obestavěným prostorem", "SELECT COUNT(DISTINCT valuo_id) FROM dbo.v_RUIAN_budovy WHERE ruian_obestaveny_prostor IS NOT NULL"),
        ("  z toho s podlahovou plochou", "SELECT COUNT(DISTINCT valuo_id) FROM dbo.v_RUIAN_budovy WHERE ruian_podlahova_plocha IS NOT NULL"),
        ("  z toho podlahová podezřelá", "SELECT COUNT(DISTINCT valuo_id) FROM dbo.v_RUIAN_budovy WHERE ruian_podlahova_podezrela = 1"),
        ("jednotek Valuo spárováno", "SELECT COUNT(DISTINCT valuo_id) FROM dbo.v_RUIAN_jednotky"),
        ("  z toho s rokem dokončení domu", "SELECT COUNT(DISTINCT valuo_id) FROM dbo.v_RUIAN_jednotky WHERE dum_dokonceni IS NOT NULL"),
        ("  z toho s druhem konstrukce", "SELECT COUNT(DISTINCT valuo_id) FROM dbo.v_RUIAN_jednotky WHERE druh_konstrukce_kod IS NOT NULL"),
    ]

    # Průměr objektů na jednu nemovitost. Pod 1,1 je v pořádku; vyšší
    # hodnota znamená, že se párování někde rozmnožilo — přesně to se
    # stalo pohledu v_RUIAN_jednotky před opravou 27a (36,3 objektu
    # na jednotku, protože se pároval podle čísla popisného v obci).
    nasobnost = [
        ("násobnost budov", "v_RUIAN_budovy"),
        ("násobnost jednotek", "v_RUIAN_jednotky"),
    ]
    with db() as c:
        cur = c.cursor()
        print("KONTROLA NAPOJENÍ\n")
        for popis, q in dotazy:
            try:
                print(f"  {popis:36} {cur.execute(q).fetchval():8}")
            except Exception as e:
                print(f"  {popis:36} chyba: {str(e)[:60]}")

        print()
        for popis, pohled in nasobnost:
            try:
                n = cur.execute(
                    f"SELECT CAST(COUNT(*) * 1.0 / NULLIF(COUNT(DISTINCT valuo_id),0) "
                    f"AS decimal(6,2)) FROM dbo.{pohled}").fetchval()
                vlajka = "" if n is None or n <= 1.1 else "   <-- POZOR, parovani se rozmnozilo"
                print(f"  {popis:36} {n:8}{vlajka}")
            except Exception as e:
                print(f"  {popis:36} chyba: {str(e)[:60]}")

        print("\n  Kandidáti na doplnění (budovy bez podlahové plochy od Valua):")
        try:
            for r in cur.execute("""
                SELECT TOP 10 b.typ,
                       COUNT(DISTINCT b.valuo_id) AS sparovano,
                       SUM(CASE WHEN b.ruian_obestaveny_prostor IS NOT NULL THEN 1 ELSE 0 END) AS s_OP,
                       SUM(CASE WHEN b.ruian_podlahova_plocha IS NOT NULL THEN 1 ELSE 0 END) AS s_PP,
                       SUM(CASE WHEN b.ruian_dokonceni IS NOT NULL THEN 1 ELSE 0 END) AS s_rokem
                FROM dbo.v_RUIAN_budovy b
                WHERE b.typ_plochy_valuo IS NULL OR b.typ_plochy_valuo <> 'Podlahová plocha'
                GROUP BY b.typ ORDER BY COUNT(DISTINCT b.valuo_id) DESC""").fetchall():
                print(f"    {r[0][:34]:34} spárováno {r[1]:5}  "
                      f"OP {r[2]:5}  PP {r[3]:5}  rok {r[4]:5}")
        except Exception as e:
            print(f"    chyba: {str(e)[:80]}")


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--slozka", default=SLOZKA,
                   help="kořen se soubory VFR; podsložka se volí podle varianty")
    p.add_argument("--server", default=SERVER,
                   help="SQL server (výchozí: %s)" % SERVER)
    p.add_argument("--seznam-obci", action="store_true",
                   help="vypíše obce z databáze, kde má RÚIAN co nabídnout")
    p.add_argument("--stahni", metavar="KODY",
                   help="'auto', nebo kódy obcí oddělené čárkou")
    p.add_argument("--rozpocet", action="store_true",
                   help="HEAD přes výběr obcí: kolik GB by se stahovalo")
    p.add_argument("--kraj", metavar="NAZEV",
                   help='obce celého kraje, např. "Středočeský kraj"')
    p.add_argument("--okres", metavar="NAZVY",
                   help='obce okresů oddělených čárkou, např. '
                        '"Praha-východ,Praha-západ"')
    p.add_argument("--s-vklady", dest="s_vklady", action="store_true",
                   help="obce, kde je jakýkoli vklad (i jen pozemkový)")
    p.add_argument("--vcetne-stazenych", dest="vcetne_stazenych",
                   action="store_true",
                   help="přidat obce, které už jsou v RUIAN_obce_stav")
    p.add_argument("--ciselnik", metavar="XML", help="načte ST_UCIS do CIS_RUIAN")
    p.add_argument("--test", action="store_true", help="rozbor bez zápisu")
    p.add_argument("--import", dest="imp", action="store_true", help="zápis do databáze")
    p.add_argument("--parovani", action="store_true", help="kontrola napojení")
    p.add_argument("--obec", type=int, help="omezit na jednu obec")
    p.add_argument("--bez-parcel", dest="bez_parcel", action="store_true",
                   help="načíst jen stavební objekty, parcely vynechat")
    p.add_argument("--jen-nove", dest="jen_nove", action="store_true",
                   help="přeskočit obce, které už jsou v této variantě "
                        "naimportované (pro navázání po přerušení)")
    p.add_argument("--varianta", metavar="UZSZ|UKSH",
                   help="vynutit variantu souboru (výchozí: %s)" % VARIANTA)
    p.add_argument("--csv", metavar="SOUBOR", help="uložit rozbor do CSV")
    p.add_argument("--verze", action="version", version=f"27_ruian_import {VERZE}")
    a = p.parse_args()

    print(f"27_ruian_import {VERZE}\n")

    global _SERVER
    _SERVER = a.server

    var = (a.varianta or VARIANTA).upper()
    volby = bool(a.kraj or a.okres or a.s_vklady or a.vcetne_stazenych)

    def vyber():
        okresy = [x.strip() for x in (a.okres or "").split(",") if x.strip()]
        o = obce_vyberem(kraj=a.kraj, okresy=okresy, s_vklady=a.s_vklady,
                         stazene=a.vcetne_stazenych)
        if not o:
            sys.exit("Výběr nevrátil žádnou obec.")
        return o

    if a.seznam_obci:
        if volby:
            o = vyber()
            print(f"{len(o)} obcí ve výběru:\n")
            for kod, nazev in o[:40]:
                print(f"  {kod}  {nazev}")
        else:
            o = obce_z_databaze()
            print(f"{len(o)} obcí s budovou nebo jednotkou "
                  f"({sum(x[2] for x in o)} nemovitostí):\n")
            for kod, nazev, n in o[:40]:
                print(f"  {kod}  {nazev[:34]:34} {n:6}")
        if len(o) > 40:
            print(f"  … a dalších {len(o) - 40}")
        print(f"\nStažení výběru:  python {os.path.basename(__file__)} "
              f"--stahni auto" + (" " + " ".join(sys.argv[1:]).replace(
                  "--seznam-obci", "").strip() if volby else ""))
        return

    if a.rozpocet:
        obce = [x[0] for x in (vyber() if volby else obce_vyberem())]
        print(f"{len(obce)} obcí ve výběru, varianta {var}.\n")
        rozpocet(obce, os.path.join(a.slozka, var), varianta=var)
        return

    if a.stahni:
        if a.stahni.strip().lower() == "auto":
            obce = [x[0] for x in (vyber() if volby else obce_vyberem())]
            print(f"{len(obce)} obcí z databáze.\n")
        else:
            obce = [int(x) for x in a.stahni.replace(" ", "").split(",") if x]
        stahni(obce, os.path.join(a.slozka, var), varianta=var)
        return

    if a.ciselnik:
        ciselniky(a.ciselnik)
        return

    if a.parovani:
        parovani()
        return

    if not (a.test or a.imp):
        p.error("zadej --test, --import, --stahni, --ciselnik, "
                "--parovani nebo --seznam-obci")

    slozka = slozka_varianty(a.slozka, a.varianta)
    nalezene = soubory(slozka, a.obec, a.varianta)
    if not nalezene:
        sys.exit(f"Ve složce nejsou soubory VFR: {slozka}")
    print(f"Čtu ze složky: {slozka}")

    # Volby výběru platí i pro import: ve složce může ležet víc obcí, než
    # se má teď importovat (soubory se stahují do zásoby).
    if volby:
        chtene = {x[0] for x in vyber()}
        vsech = len(nalezene)
        nalezene = {k: v for k, v in nalezene.items() if k in chtene}
        print(f"Výběr: {len(nalezene)} obcí z {vsech} souborů ve složce")
        if not nalezene:
            sys.exit("Žádný soubor ve složce neodpovídá výběru.")

    if a.imp and a.jen_nove:
        with db() as c:
            hotove = {r[0] for r in c.cursor().execute(
                "SELECT obec_kod FROM dbo.RUIAN_obce_stav "
                "WHERE varianta = ? AND ISNULL(pocet_parcel, 0) > 0",
                var).fetchall()}
        pred = len(nalezene)
        nalezene = {k: v for k, v in nalezene.items() if k not in hotove}
        print(f"Přeskakuji {pred - len(nalezene)} už naimportovaných obcí, "
              f"zbývá {len(nalezene)}")
        if not nalezene:
            sys.exit("Všechny obce výběru už jsou naimportované.")

    nazvy = {}
    if a.imp:
        with db() as c:
            nazvy = {r[0]: r[1] for r in c.cursor().execute(
                "SELECT obec_kod, MIN(obec_nazev) FROM dbo.CIS_katastralni_uzemi "
                "GROUP BY obec_kod").fetchall()}

    print(f"{'ROZBOR (bez zápisu)' if a.test else 'IMPORT DO DATABÁZE'} — "
          f"{len(nalezene)} obcí\n")
    con = db() if a.imp else None
    celkem = Counter()
    vsechny = []
    log_geo = []
    neuspesne = []
    try:
        for i, (kod, (d, cesta, nazev)) in enumerate(sorted(nalezene.items()), 1):
            mb = os.path.getsize(cesta) / 1e6
            print(f"[{i}/{len(nalezene)}] obec {kod}  {nazev}  ({mb:.1f} MB)")
            sd = f"{d[:4]}-{d[4:6]}-{d[6:]}"
            try:
                radky, cisla, parcely, bpej, nalezy = parsuj(
                    cesta, kod, sd, s_parcelami=not a.bez_parcel)
                celkem.update(nalezy)
                celkem["objektu"] += len(radky)
                celkem["parcel"] += len(parcely)
                if a.imp:
                    zapis(con, radky, cisla, kod, nazvy.get(kod), sd, nazev,
                          varianta=a.varianta or VARIANTA,
                          pocet_parcel=len(parcely), log=log_geo)
                    vynechano = 0
                    if not a.bez_parcel:
                        vynechano = zapis_parcely(con, parcely, bpej, kod, log_geo)
                    print("    zapsáno" + (f", {vynechano} geometrií vynecháno"
                                           if vynechano else ""))
                else:
                    vsechny.extend(radky)
            except Exception as e:
                # Jedna obec nesmí zastavit dávku. Nedokončená obec se vrátí
                # celá (zápis je v transakci) a projde znovu příště.
                if con:
                    try:
                        con.rollback()
                    except Exception:
                        pass
                neuspesne.append(kod)
                log_geo.append(("obec", kod, str(e)[:200]))
                print(f"    CHYBA, obec přeskočena: {str(e)[:110]}")
    finally:
        if con:
            con.close()

    if neuspesne:
        print(f"\nObcí, které neprošly: {len(neuspesne)}  "
              f"({', '.join(str(k) for k in neuspesne[:20])}"
              f"{' …' if len(neuspesne) > 20 else ''})")
        print("Po opravě je dožeň:  --import --jen-nove  se stejným výběrem")

    if log_geo:
        cesta_log = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 f"27_geometrie_{time.strftime('%Y%m%d_%H%M')}.csv")
        with open(cesta_log, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.writer(f, delimiter=";")
            w.writerow(["co", "klic", "chyba"])
            w.writerows(log_geo)
        odmitnute = sum(1 for r in log_geo if "MakeValid" not in r[0])
        print(f"\nZáznamů o geometrii: {len(log_geo)}"
              f"  (z toho odmítnutých databází: {odmitnute}, zbytek narovnal"
              f" MakeValid)  -> {os.path.basename(cesta_log)}")

    if a.test:
        print(f"\n{'=' * 64}")
        rozbor(vsechny, celkem)
        if a.csv:
            with open(a.csv, "w", newline="", encoding="utf-8-sig") as f:
                w = csv.DictWriter(f, fieldnames=SLOUPCE, delimiter=";")
                w.writeheader()
                w.writerows(vsechny)
            print(f"\n  CSV: {os.path.abspath(a.csv)}")
    else:
        print(f"\nHotovo: {celkem['objektu']} stavebních objektů.")
        print("Kontrola napojení:  python "
              f"{os.path.basename(__file__)} --parovani")


if __name__ == "__main__":
    main()
