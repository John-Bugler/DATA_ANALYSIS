# -*- coding: utf-8 -*-
"""
35_export_word.py — karta vkladu do dokumentu Wordu
===================================================
Databáze: VALUO        Krok: 35        Datum: 24. 10. 2026

K čemu to je
------------
Vezme jeden nebo více vkladů, sestaví z nich kartu a uloží ji jako .docx
ve formátu znaleckého posudku. Je to příloha, kterou lze vložit rovnou do
posudku jako doklad o srovnávacím vzorku.

Proč běží na počítači znalce
----------------------------
Mapové služby ČÚZK a IPR nejsou z prostředí asistenta dosažitelné (proxy
je odmítá). Skript proto spouští znalec. Databáze i mapy jsou z tohoto
počítače dostupné bez omezení.

Jak se berou mapy
-----------------
NEFOTÍ se obrazovka. ArcGIS "export" i WMS "GetMap" vrátí hotový obrázek
pro přesně zadaný výřez, takže se stáhne jeden PNG na vrstvu v tiskovém
rozlišení a parcely se do něj dokreslí programem. Výjimkou je Metropolitní
plán, který má capabilities "Map,TilesOnly" — ten umí jen své dlaždice
a pro daný výřez se poskládá z několika kousků.

Vše se žádá v EPSG:5514 (S-JTSK), tedy v projekci, ve které ty služby
nativně jsou. Kreslení parcel je proto prostý lineární přepočet.

Dva výřezy
----------
Podrobné mapy (ortofoto, katastrální mapa, DTM) se kreslí na těsný výřez
kolem parcel. Plánovací mapy (územní plán, Metropolitní plán, cenová mapa)
na výřez širší, protože u nich jde o zařazení do okolí — a protože
Metropolitní plán má nejjemnější dlaždice 1,32 m/px a na těsném výřezu by
se jen rozmazal.

Formát stránky
--------------
Bere se ze SABLONA_MASTER.docx: A4 na výšku, okraje 2 cm, šířka sazby
17 cm. Používají se její vlastní styly (ZP text, ZP tab hlavička,
ZP tab text, ZP tab číslo, ZP obrázek, ZP popisek, ZP příloha nadpis,
tabulkový ZP tabulka), aby karta vypadala jako součást posudku.

Spuštění
--------
    python 35_export_word.py V-76414/2024-101
    python 35_export_word.py V-76414/2024-101 V-9857/2025-101 --vystup vzorek.docx
    python 35_export_word.py --ku Písnice --rok 2024 --limit 10

Závislosti: pyodbc nebo sqlalchemy, requests, Pillow, pyproj, python-docx.
"""

import argparse
import copy
import datetime
import io
import math
import os
import shutil
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET

import requests
from PIL import Image, ImageDraw, ImageFont
from pyproj import Transformer
import sqlalchemy
from docx import Document
from docx.shared import Cm, Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.section import WD_SECTION
from docx.text.paragraph import Paragraph
from docx.oxml import OxmlElement
from docx.oxml.ns import qn

# =============================================================================
# Nastavení
# =============================================================================

SERVER = "LOCALHOST"
DATABAZE = "VALUO"

SABLONA_NAZEV = "SABLONA_MASTER.docx"

# Kde se šablona hledá, když není zadána přepínačem --sablona. Skill se na
# disku verzuje do podsložek (v1, v2, v3-popis), proto se prohledává celý
# strom a bere se nejnovější nalezený soubor.
SABLONA_KORENY = [
    os.path.join(os.path.expanduser("~"), "OneDrive", "Dokumenty",
                 "_ZNALEC", "_SKILLS"),
    os.path.join(os.path.expanduser("~"), "Dokumenty", "_ZNALEC", "_SKILLS"),
    os.path.join(os.path.expanduser("~"), "Documents", "_ZNALEC", "_SKILLS"),
    os.path.dirname(os.path.abspath(__file__)),
]

CUZK = "https://ags.cuzk.gov.cz/arcgis1/rest/services"
IPR = "https://gs-pub.praha.eu/arcgis/rest/services"
DMVS = "https://dmvs.cuzk.gov.cz/api/wms"
KNWMS = "https://services.cuzk.gov.cz/wms/local-km-wms.asp"
MPP = "https://tiles.arcgis.com/tiles/SBTXIEUGWbqzUecw/arcgis/rest/services"

# Mřížka dlaždic Metropolitního plánu (z jeho tileInfo).
MPP_ORIGIN = (-33699800.0, 33699800.0)
MPP_DLAZDICE = 512
MPP_RES = [198.43789687579377, 132.2919312505292, 92.60435187537043,
           52.91677250021167, 39.687579375158755, 26.458386250105836,
           19.843789687579378, 13.229193125052918, 6.614596562526459,
           5.291677250021167, 3.9687579375158752, 2.6458386250105836,
           1.9843789687579376, 1.3229193125052918]

SIRKA_SAZBY_CM = 17.0
SIRKA_PX = 1700          # ~254 DPI při šířce 17 cm
# Jak velký okraj kolem parcel. Podrobné mapy (ortofoto, katastr, DTM) chtějí
# těsný rám, plánovací mapy (ÚP, Metropolitní plán, cenová mapa) odstup, aby
# bylo vidět zařazení do okolí. Čím vyšší číslo, tím menší celek na stránce.
REZERVA_DETAIL = 0.35
REZERVA_KONTEXT = 1.20

# Nejmenší šířka výřezu v metrech u podkladů, které nesou informaci až
# na větší ploše. Bez nich se u malé parcely — byt, garáž, úzký pozemek —
# výřez stáhl klidně na 70 m a z cenové mapy ani z Metropolitního plánu
# nebylo vidět nic než jedna barevná plocha bez popisků (pokyn znalce
# 25. 10. 2026). Parcela se tím zmenší, ale při 1700 px je i 20m parcela
# na 700m výřezu pořád přes 48 px, takže zůstane dobře patrná.
MIN_SIRKA_UP_M = 400.0        # územní plán SÚ hl. m. Prahy 1999
MIN_SIRKA_MPP_M = 1000.0      # Metropolitní plán — kreslí strukturu města
MIN_SIRKA_CENOVA_M = 700.0    # cenová mapa — ceny jsou popsané po blocích

# Velikost popisků se zadává v bodech, tedy v tom, co je vidět na papíře.
# Pod devět bodů je parcelní číslo na A4 nečitelné; co se v té velikosti
# dovnitř parcely nevejde, jde ven s odkazovou čárou.
POPISEK_MIN_BODU = 9.0
POPISEK_MAX_BODU = 13.0
# Do kolika parcel se do mapy kreslí parcelní čísla. Nad tuto mez se kreslí
# pořadová čísla a rozpis parcel dostane sloupec, kterým se dohledají —
# sedmiznakové parcelní číslo se do úzkého pásu v čitelné velikosti nevejde.
POPISEK_MEZ_PARCEL = 5
POMER = 1.45             # šířka ku výšce obrázku
TIMEOUT = 60

BARVY = {  # úplná paleta všech kombinací vlastnictví × role (28. 10. 2026)
    ('výhradní', 'kotva'): ((15, 110, 86), 'Hlavní nemovitost'),
    ('podílová', 'kotva'): ((122, 90, 18), 'Hlavní nemovitost na podílovém pozemku (např. pozemek pod domem s jednotkami)'),
    ('výhradní', 'celek'): ((29, 158, 117), 'Výhradní, funkční celek'),
    ('výhradní', 'oddělená'): ((55, 138, 221), 'Výhradní, mimo celek'),
    ('výhradní', 'bez kotvy'): ((106, 63, 181), 'Výhradní, vklad bez hlavní nemovitosti (soubor pozemků)'),
    ('podílová', 'celek'): ((186, 117, 23), 'Podíl, přilehlá'),
    ('podílová', 'oddělená'): ((239, 159, 39), 'Podíl, nepřilehlá'),
    ('podílová', 'bez kotvy'): ((227, 194, 27), 'Podíl, vklad bez hlavní nemovitosti'),
    ('neověřeno', 'celek'): ((163, 45, 45), 'Neověřené vlastnictví'),
    ('neověřeno', 'oddělená'): ((163, 45, 45), 'Neověřené vlastnictví'),
    ('neověřeno', 'bez kotvy'): ((163, 45, 45), 'Neověřené vlastnictví'),
}
# Dřív šedá (136, 135, 128) — na ortofotu a v územním plánu zanikala.
# Purpurová v přírodě ani v legendách ÚP SÚ hl. m. Prahy a Metropolitního
# plánu skoro není (pokyn znalce 28. 10. 2026).
BARVA_JINA = ((214, 0, 120), "Ostatní — mimo uvedené kategorie")

# Obrys parcel se kreslí ve třech vrstvách: tmavý lem, světlý lem a uprostřed
# barva role. Jediná barva čáry nemůže být vidět na všech podkladech —
# na tmavém ortofotu potřebuje světlé okolí, na světlém katastru a na pestrém
# územním plánu tmavé. Dvojí lem zajistí kontrast vždy a barva role zůstane
# zachovaná. Šířky v pixelech při SIRKA_PX = 1700 (17 cm), tj. 1 px ≈ 0,1 mm.
OBRYS_TMAVY = ((20, 20, 20, 215), 9)
OBRYS_SVETLY = ((255, 255, 255, 255), 6)
OBRYS_BARVA_PX = 3

SESSION = requests.Session()
SESSION.headers["User-Agent"] = "znalec-karta-vkladu/1.0"
T_WGS_SJTSK = Transformer.from_crs("EPSG:4326", "EPSG:5514", always_xy=True)


def barva(vlastnictvi, role):
    return BARVY.get((vlastnictvi, role), BARVA_JINA)


# =============================================================================
# 1. Data z databáze
# =============================================================================

def engine():
    return sqlalchemy.create_engine(
        f"mssql+pyodbc://{SERVER}/{DATABAZE}"
        "?driver=ODBC+Driver+17+for+SQL+Server&Trusted_Connection=yes")


SQL_VKLAD = """
SELECT k.*, t.pp_index_celku, t.plocha_celku_m2, t.obvod_celku_m,
       t.casti_celku, t.pp_index_vse
FROM dbo.v_Valuo_karta_vkladu k
LEFT JOIN dbo.Valuo_karta_vklad t ON t.cislo_vkladu = k.cislo_vkladu
WHERE k.cislo_vkladu = :v
"""

SQL_PLOCHY = """
/* Registr zdrojů plochy po řádcích (krok 45). Ruční plocha se čte ŽIVĚ z
   Valuo_vklad_rucne, ne z registru — znalec ji mohl zadat před vteřinou
   a registr se plní až přepočtem. Odvozené zdroje z registru stačí,
   ty se mění jen s importem. */
SELECT c.poradi, p.zdroj, c.nazev, c.popis, c.pro_cenu, c.autoritativni,
       p.id, p.jednotka, p.typ, p.nosna, p.plocha, p.platny, p.pouzito, p.poznamka
FROM (
    SELECT 'RUCNE' AS zdroj, 0 AS id, CAST(NULL AS nvarchar(50)) AS jednotka,
           CAST(NULL AS nvarchar(100)) AS typ, 1 AS nosna,
           r.plocha_rucne AS plocha, CAST(1 AS bit) AS platny,
           CAST(1 AS bit) AS pouzito, r.plocha_rucne_zdroj AS poznamka
    FROM dbo.Valuo_vklad_rucne r
    WHERE r.cislo_vkladu = :v AND r.plocha_rucne > 0
    UNION ALL
    SELECT z.zdroj, z.id, d.jednotka_oznaceni, d.typ,
           CASE WHEN t.priorita = vp.nosna_priorita
                 AND t.skupina  = vp.nosna_skupina THEN 1 ELSE 0 END,
           z.plocha, z.platny, z.pouzito, z.poznamka
    FROM dbo.Valuo_plochy z
    LEFT JOIN dbo.Valuo_data d ON d.id = z.id
    LEFT JOIN dbo.CIS_nemovitost_typ t ON t.nemovitost = d.nemovitost AND t.typ = d.typ
    LEFT JOIN dbo.Valuo_vklad_plocha vp ON vp.cislo_vkladu = z.cislo_vkladu
    WHERE z.cislo_vkladu = :v AND z.zdroj <> 'RUCNE'
) p
JOIN dbo.CIS_plochy_zdroje c ON c.kod = p.zdroj
ORDER BY CASE WHEN p.zdroj = 'RUCNE' THEN 0
              WHEN p.id > 0 AND p.nosna = 1 THEN 1
              WHEN p.id > 0 THEN 2 ELSE 3 END,
         p.id, c.poradi
"""

SQL_FVU = """
SELECT kp.parcel_number, u.fvu_kod, d.POPIS_Z, f.skupina,
       CAST(u.podil_pct AS decimal(6,2)) AS podil_pct,
       CAST(u.plocha_pruniku_m2 AS decimal(12,1)) AS prunik_m2
FROM dbo.Valuo_karta_parcely kp
JOIN dbo.KN_parcel_UP u ON u.kn_id = kp.kn_id
LEFT JOIN dbo.UP_FVU_data d ON d.id = u.up_id
LEFT JOIN dbo.CIS_FVU_skupiny f ON f.fvu_kod = u.fvu_kod
WHERE kp.cislo_vkladu = :v
ORDER BY kp.vymera_m2 DESC, u.poradi
"""

SQL_PARCELY = """
/* Druh parcely se bere z RÚIANu, ne z Valua. Valuo totiž u parcely, na které
   stavba stojí, uvádí ve sloupci typ tu stavbu („rodinný dům", „byt"), takže
   by v rozpisu parcel stálo jako druh pozemku „rodinný dům" místo „zastavěná
   plocha a nádvoří". Valuův text zůstává jako způsob využití — u parcel bez
   stavby je konkrétnější než druh („zeleň", „rybník", „manipulační plocha"). */
SELECT kp.parcel_number, kp.vymera_m2, kp.druh_valuo, kp.vlastnictvi,
       cdp.nazev AS druh_pozemku,
       kp.prostorova_role, kp.je_kotva, kp.komponenta, kp.hlavnich_nemovitosti,
       kp.vkladu_s_parcelou, kp.je_druh_komunikace, kp.kompaktnost,
       kp.prum_sirka_m, kp.tvar_cesty, kp.cizich_se_stavbou, kp.podil_odhad,
       kp.vymera_dle_podilu, kp.vzdalenost_od_kotvy_m, kp.duvod, kp.gml_id,
       kn.geo_plocha.STAsText() AS wkt
FROM dbo.Valuo_karta_parcely kp
JOIN dbo.KN_parcel_data kn ON kn.id = kp.kn_id
LEFT JOIN dbo.RUIAN_parcely rp ON rp.gml_id = kn.gml_id
LEFT JOIN dbo.CIS_RUIAN cdp ON cdp.ciselnik = 'DruhPozemku'
                           AND cdp.kod = rp.druh_pozemku_kod
WHERE kp.cislo_vkladu = :v
ORDER BY kp.vymera_m2 DESC
"""


def druh_parcely(p):
    """Co se vypíše ve sloupci Druh. Nikdy druh stavby — ten do rozpisu
    parcel nepatří (pokyn znalce 25. 10. 2026).

    Druh pozemku dává RÚIAN; Valuův text se přidá v závorce, je-li
    konkrétnější a nejde o kotvu, kde Valuo uvádí právě tu stavbu."""
    druh = p.get("druh_pozemku")
    detail = (p.get("druh_valuo") or "").strip()
    if not druh:
        # RÚIAN parcelu nezná; Valuův text se použije, jen když to není stavba
        return "—" if p.get("je_kotva") else (detail or "—")
    if detail and not p.get("je_kotva") and detail.lower() != druh.lower():
        return f"{druh} ({detail})"
    return druh


SQL_POCET_STAVEB = """
/* Kolik staveb RÚIAN k parcelám vkladu vede. Řetěz po indexech, ne
   prostorový průnik — ten chytá i sousedy přes společnou zeď a nad
   1,19 mil. objektů bez prostorového indexu dotaz nedoběhne (krok 37). */
SELECT COUNT(DISTINCT so.kod_so) AS staveb
FROM dbo.Valuo_karta_parcely kp
JOIN dbo.KN_parcel_data kn ON kn.id = kp.kn_id
JOIN dbo.RUIAN_parcely rp ON rp.gml_id = kn.gml_id
JOIN dbo.RUIAN_stavebni_objekty so ON so.parcela_id = rp.kod_parcely
WHERE kp.cislo_vkladu = :v
"""


def pocet_staveb(conn, cislo):
    """Pro paritu s HTML kartou, která staveb vypisuje počet."""
    x = conn.execute(sqlalchemy.text(SQL_POCET_STAVEB), {"v": cislo}).scalar()
    return int(x or 0)


def nacti_plochy(conn, cislo):
    """Registr zdrojů plochy. Karta i export z něj ukazují, odkud použité
    číslo je — do posudku to patří, protože z toho je vidět, proč je cena
    taková. Prázdný seznam není chyba: u starých vkladů registr nemusí mít
    co nabídnout."""
    return [dict(x) for x in conn.execute(
        sqlalchemy.text(SQL_PLOCHY), {"v": cislo}).mappings().all()]


def nacti_vklad(conn, cislo):
    v = conn.execute(sqlalchemy.text(SQL_VKLAD), {"v": cislo}).mappings().first()
    if v is None:
        raise SystemExit(f"Vklad {cislo} není v pohledu v_Valuo_karta_vkladu.")
    p = conn.execute(sqlalchemy.text(SQL_PARCELY), {"v": cislo}).mappings().all()
    if not p:
        raise SystemExit(f"Vklad {cislo} nemá v kartě žádné parcely "
                         f"(spusť sp_prepocet_karty).")
    fvu = conn.execute(sqlalchemy.text(SQL_FVU), {"v": cislo}).mappings().all()
    return dict(v), [dict(x) for x in p], [dict(x) for x in fvu]


def oznac_popisky(parcely):
    """Rozhodne, čím se parcely popíšou v mapě, a zapíše to k nim.

    Vrací True, když se kreslí pořadová čísla — pak rozpis parcel potřebuje
    sloupec navíc. Volá se víckrát, výsledek je pokaždé stejný.
    """
    poradove = len(parcely) > POPISEK_MEZ_PARCEL
    for i, p in enumerate(parcely, 1):
        p["poradi"] = i
        p["popisek"] = str(i) if poradove else str(p["parcel_number"])
    return poradove


def parcely_sjtsk(parcely):
    """WKT ve WGS84 -> seznam prstenců v S-JTSK."""
    out = []
    for p in parcely:
        wkt = p.get("wkt") or ""
        prsteny = []
        for kus in wkt.replace("MULTIPOLYGON", "").replace("POLYGON", "").split("(("):
            body = kus.split("))")[0]
            if "," not in body:
                continue
            souradnice = []
            for dvojice in body.split(","):
                cast = dvojice.strip().strip("()").split()
                if len(cast) < 2:
                    continue
                lon, lat = float(cast[0]), float(cast[1])
                souradnice.append(T_WGS_SJTSK.transform(lon, lat))
            if len(souradnice) >= 3:
                prsteny.append(souradnice)
        if prsteny:
            out.append((p, prsteny))
    return out


def vyrez(geometrie, rezerva=0.35, min_sirka_m=0.0):
    """Výřez kolem geometrie vkladu, srovnaný na poměr stran obrázku.

    min_sirka_m je spodní mez šířky v metrech. Používá se u podkladů, které
    na přílišném přiblížení ztrácejí smysl — cenová mapa a Metropolitní plán
    popisují bloky, ne jednotlivé parcely."""
    xs = [x for _, prsteny in geometrie for r in prsteny for x, _ in r]
    ys = [y for _, prsteny in geometrie for r in prsteny for _, y in r]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    sx, sy = max(x1 - x0, 1.0), max(y1 - y0, 1.0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    # srovnat na poměr stran obrázku
    sirka = max(sx * (1 + 2 * rezerva), sy * (1 + 2 * rezerva) * POMER)
    sirka = max(sirka, float(min_sirka_m or 0.0))
    vyska = sirka / POMER
    return (cx - sirka / 2, cy - vyska / 2, cx + sirka / 2, cy + vyska / 2)


# =============================================================================
# 2. Mapové podklady
# =============================================================================

_MEZIPAMET = {}


def _stahni(url, params, nazev):
    # Některý podklad se v rámci jednoho vkladu žádá dvakrát (ortofoto zvlášť
    # a ještě jako podklad pod DTM). Stejný dotaz se proto stáhne jen jednou.
    klic = (url, tuple(sorted((k, str(v)) for k, v in (params or {}).items())))
    if klic in _MEZIPAMET:
        hotovo = _MEZIPAMET[klic]
        return hotovo.copy() if hotovo is not None else None
    try:
        r = SESSION.get(url, params=params, timeout=TIMEOUT)
        r.raise_for_status()
        if "image" not in r.headers.get("content-type", ""):
            hlas = r.text[:200].replace("\n", " ")
            print(f"   [!] {nazev}: server nevrátil obrázek — {hlas}")
            _MEZIPAMET[klic] = None
            return None
        img = Image.open(io.BytesIO(r.content)).convert("RGBA")
        _MEZIPAMET[klic] = img
        return img.copy()
    except Exception as e:
        print(f"   [!] {nazev}: {e}")
        return None


def ags_export(sluzba, bbox, px, vrstvy=None, pruhledne=True, format="png32",
               vnucene_meritko=None):
    """vnucene_meritko řeší vrstvy, které služba nad určité měřítko nekreslí.

    ArcGIS z parametru mapScale odvodí i VÝŘEZ, takže se musí zároveň
    dopočítat velikost obrázku tak, aby při tom měřítku vyšel přesně
    požadovaný výřez — jinak se podklad rozejde s mapou.
    """
    sirka_m = bbox[2] - bbox[0]
    vyska_m = bbox[3] - bbox[1]
    w, h, ms = px[0], px[1], None
    if vnucene_meritko:
        m_na_px = 0.0254 / 96
        meritko = sirka_m / (px[0] * m_na_px)
        if meritko > vnucene_meritko:
            ms = vnucene_meritko
            krok = ms * m_na_px
            w, h = int(round(sirka_m / krok)), int(round(vyska_m / krok))
            if max(w, h) > 4000:
                ms, w, h = None, px[0], px[1]
    p = {"bbox": ",".join(f"{v:.2f}" for v in bbox), "bboxSR": 5514,
         "imageSR": 5514, "size": f"{w},{h}", "format": format,
         "transparent": str(pruhledne).lower(), "f": "image", "dpi": 96}
    if vrstvy:
        p["layers"] = vrstvy
    if ms:
        p["mapScale"] = ms
    return _stahni(sluzba + "/MapServer/export", p, sluzba.rsplit("/", 1)[-1])


def wms(url, vrstvy, bbox, px, nazev):
    p = {"service": "WMS", "request": "GetMap", "version": "1.3.0",
         "crs": "EPSG:5514", "bbox": ",".join(f"{v:.2f}" for v in bbox),
         "width": px[0], "height": px[1], "layers": vrstvy, "styles": "",
         "format": "image/png", "transparent": "true"}
    return _stahni(url, p, nazev)


def mpp_mozaika(sluzba, bbox, px):
    """Metropolitní plán umí jen dlaždice — poskládáme je pro daný výřez."""
    x0, y0, x1, y1 = bbox
    potreba = (x1 - x0) / px[0]
    uroven = min(range(len(MPP_RES)),
                 key=lambda i: abs(MPP_RES[i] - potreba) if MPP_RES[i] <= potreba * 2
                 else 1e9)
    uroven = max(uroven, 0)
    if MPP_RES[uroven] > potreba:
        uroven = len(MPP_RES) - 1          # nejjemnější, co je k dispozici
    res = MPP_RES[uroven]
    krok = res * MPP_DLAZDICE
    c0 = int(math.floor((x0 - MPP_ORIGIN[0]) / krok))
    c1 = int(math.floor((x1 - MPP_ORIGIN[0]) / krok))
    r0 = int(math.floor((MPP_ORIGIN[1] - y1) / krok))
    r1 = int(math.floor((MPP_ORIGIN[1] - y0) / krok))
    if (c1 - c0 + 1) * (r1 - r0 + 1) > 48:
        print("   [!] Metropolitní plán: výřez by si vyžádal příliš dlaždic")
        return None
    sirka_px = (c1 - c0 + 1) * MPP_DLAZDICE
    vyska_px = (r1 - r0 + 1) * MPP_DLAZDICE
    platno = Image.new("RGBA", (sirka_px, vyska_px), (0, 0, 0, 0))
    nacteno = 0
    for c in range(c0, c1 + 1):
        for r in range(r0, r1 + 1):
            u = f"{MPP}/{sluzba}/MapServer/tile/{uroven}/{r}/{c}"
            try:
                odp = SESSION.get(u, timeout=TIMEOUT)
                if odp.status_code != 200 or "image" not in odp.headers.get("content-type", ""):
                    continue
                dl = Image.open(io.BytesIO(odp.content)).convert("RGBA")
                platno.paste(dl, ((c - c0) * MPP_DLAZDICE, (r - r0) * MPP_DLAZDICE))
                nacteno += 1
            except Exception:
                continue
    if not nacteno:
        print("   [!] Metropolitní plán: nenačetla se ani jedna dlaždice")
        return None
    # ořez na požadovaný výřez
    px0 = (x0 - (MPP_ORIGIN[0] + c0 * krok)) / res
    py0 = ((MPP_ORIGIN[1] - r0 * krok) - y1) / res
    px1 = px0 + (x1 - x0) / res
    py1 = py0 + (y1 - y0) / res
    orez = platno.crop((int(px0), int(py0), int(math.ceil(px1)), int(math.ceil(py1))))
    return orez.resize(px, Image.LANCZOS)


# =============================================================================
# 3. Kreslení parcel do obrázku
# =============================================================================

_PISMA = {}
_CESTY_PISEM = (
    r"C:\Windows\Fonts\segoeui.ttf",
    r"C:\Windows\Fonts\arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
)


def pismo(velikost):
    """Písmo dané velikosti.

    Musí to být škálovatelné TrueType. ImageFont.load_default() zadanou
    velikost ignoruje a kreslí pořád stejně malá písmena — popisky by pak
    byly nečitelné bez ohledu na nastavení. Když se žádné písmo nenajde,
    skript to raději řekne, než aby tiše sázel nečitelně.
    """
    velikost = int(max(6, velikost))
    if velikost in _PISMA:
        return _PISMA[velikost]
    for cesta in _CESTY_PISEM:
        if os.path.exists(cesta):
            try:
                _PISMA[velikost] = ImageFont.truetype(cesta, velikost)
                return _PISMA[velikost]
            except Exception:
                pass
    if not _PISMA:
        print("   [!] nenalezeno škálovatelné písmo — popisky budou drobné")
    _PISMA[velikost] = ImageFont.load_default()
    return _PISMA[velikost]


def _uvnitr(bod_xy, mnohouhelnik):
    """Leží bod uvnitř mnohoúhelníku? (paprskový test)"""
    x, y = bod_xy
    uvnitr = False
    n = len(mnohouhelnik)
    for i in range(n):
        x1, y1 = mnohouhelnik[i]
        x2, y2 = mnohouhelnik[(i + 1) % n]
        if (y1 > y) != (y2 > y):
            if x < x1 + (y - y1) * (x2 - x1) / (y2 - y1 + 1e-12):
                uvnitr = not uvnitr
    return uvnitr


def _vzdalenost_k_obrysu(bod_xy, obrys):
    x, y = bod_xy
    nejmensi = 1e18
    n = len(obrys)
    for i in range(n):
        x1, y1 = obrys[i]
        x2, y2 = obrys[(i + 1) % n]
        dx, dy = x2 - x1, y2 - y1
        delka2 = dx * dx + dy * dy
        t = 0.0 if delka2 == 0 else max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / delka2))
        px_, py_ = x1 + t * dx, y1 + t * dy
        nejmensi = min(nejmensi, ((x - px_) ** 2 + (y - py_) ** 2) ** 0.5)
    return nejmensi


def _kotevni_bod(obrys):
    """Bod uvnitř parcely co nejdál od jejích hranic, a ta vzdálenost.

    Těžiště u parcel do L, do U nebo s dírou často padá mimo obrazec —
    popisek by pak ležel vedle parcely. Prohledá se proto mřížka uvnitř
    obalového obdélníku a vybere se bod s největším odstupem od obrysu.
    """
    bx0 = min(b[0] for b in obrys); bx1 = max(b[0] for b in obrys)
    by0 = min(b[1] for b in obrys); by1 = max(b[1] for b in obrys)
    nej, nej_r = None, -1.0
    for i in range(1, 12):
        for j in range(1, 12):
            bod_xy = (bx0 + (bx1 - bx0) * i / 12.0, by0 + (by1 - by0) * j / 12.0)
            if not _uvnitr(bod_xy, obrys):
                continue
            r = _vzdalenost_k_obrysu(bod_xy, obrys)
            if r > nej_r:
                nej, nej_r = bod_xy, r
    if nej is None:
        return ((bx0 + bx1) / 2, (by0 + by1) / 2), 0.0
    return nej, nej_r


def _nejblizsi_na_obrysu(bod_xy, obrys):
    x, y = bod_xy
    nej, nejd = obrys[0], 1e18
    for i in range(len(obrys)):
        x1, y1 = obrys[i]
        x2, y2 = obrys[(i + 1) % len(obrys)]
        dx, dy = x2 - x1, y2 - y1
        delka2 = dx * dx + dy * dy
        t = 0.0 if delka2 == 0 else max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / delka2))
        kand = (x1 + t * dx, y1 + t * dy)
        d = (x - kand[0]) ** 2 + (y - kand[1]) ** 2
        if d < nejd:
            nej, nejd = kand, d
    return nej


def _tmavsi(rgb, podil=0.62):
    """Barva výplně je světlá, text z ní by na ní zanikl."""
    return tuple(int(k * podil) for k in rgb)


def _protina(a, b, mezera=5):
    return not (a[2] + mezera < b[0] or b[2] + mezera < a[0] or
                a[3] + mezera < b[1] or b[3] + mezera < a[1])


def vykresli(podklad, geometrie, bbox, px, popisky="vse"):
    """Vykreslí parcely do mapového podkladu.

    popisky: "vse" — popsat každou parcelu, "kotva" — jen parcelu nesoucí
    hlavní nemovitost, "zadne" — nepopisovat. Na širokém výřezu (územní plán,
    Metropolitní plán, cenová mapa) je celek malý a popisky všech parcel by
    ho zakryly, proto se tam popisuje jen kotva.

    Popisek se nesází pevnou velikostí. Písmo se zmenšuje, dokud se číslo
    nevejde dovnitř kresby parcely — ověřuje se, že všechny čtyři rohy textu
    leží uvnitř, aby popisek nepřetekl u úzkých pásů. Co se nevejde ani při
    nejmenší čitelné velikosti, nebo by se krylo s jiným popiskem, odsune se
    k okraji kresby a spojí se s parcelou tenkou odkazovou čárou vedenou
    k nejbližšímu bodu hranice, aby čára nešla přes obrazec. Místo bílého
    obdélníku pod textem je bílá obrysová záře — zakryje podklad jen kolem
    písmen.
    """
    if popisky is True:
        popisky = "vse"
    elif popisky is False:
        popisky = "zadne"

    img = Image.new("RGBA", px, (255, 255, 255, 255))
    if podklad is not None:
        img.alpha_composite(podklad.resize(px, Image.LANCZOS))
    vrstva = Image.new("RGBA", px, (0, 0, 0, 0))
    kr = ImageDraw.Draw(vrstva)
    x0, y0, x1, y1 = bbox
    sx = px[0] / (x1 - x0)
    sy = px[1] / (y1 - y0)

    def bod(p):
        return ((p[0] - x0) * sx, (y1 - p[1]) * sy)

    # výplň zvlášť, obrysy až nad všemi výplněmi — jinak by výplň sousední
    # parcely přemalovala lem té předchozí
    for p, prsteny in geometrie:
        rgb, _ = barva(p["vlastnictvi"], p["prostorova_role"])
        for r in prsteny:
            kr.polygon([bod(q) for q in r], fill=rgb + (70,))
    for barva_cary, sirka in (OBRYS_TMAVY, OBRYS_SVETLY):
        for _p, prsteny in geometrie:
            for r in prsteny:
                b = [bod(q) for q in r]
                kr.line(b + [b[0]], fill=barva_cary, width=sirka, joint="curve")
    for p, prsteny in geometrie:
        rgb, _ = barva(p["vlastnictvi"], p["prostorova_role"])
        for r in prsteny:
            b = [bod(q) for q in r]
            kr.line(b + [b[0]], fill=rgb + (255,), width=OBRYS_BARVA_PX,
                    joint="curve")

    if popisky == "zadne":
        img.alpha_composite(vrstva)
        return img.convert("RGB")

    k_popisu = list(geometrie)
    if popisky == "kotva":
        kotvy = [g for g in k_popisu
                 if (g[0].get("prostorova_role") or "") == "kotva"]
        if not kotvy:
            kotvy = [max(k_popisu, key=lambda g: g[0].get("vymera_m2") or 0)]
        k_popisu = kotvy[:1]

    # bodů -> pixely: obrázek px[0] se do dokumentu vkládá na SIRKA_SAZBY_CM
    na_bod = (px[0] / SIRKA_SAZBY_CM) * 0.03528
    min_px = max(12, int(POPISEK_MIN_BODU * na_bod))
    max_px = max(min_px, int(POPISEK_MAX_BODU * na_bod))
    f_odkaz = pismo(min_px)
    mer = ImageDraw.Draw(Image.new("RGB", (1, 1)))

    def rozmer(txt, velikost):
        l, t, r_, b_ = mer.textbbox((0, 0), txt, font=pismo(velikost))
        return r_ - l, b_ - t

    # obalový obdélník celé kresby — u něj stojí odsunuté popisky
    vsechny = [bod(q) for _, prsteny in geometrie for q in prsteny[0]]
    kx0 = min(b[0] for b in vsechny); kx1 = max(b[0] for b in vsechny)

    uvnitr, mimo = [], []
    for p, prsteny in k_popisu:
        rgb, _ = barva(p["vlastnictvi"], p["prostorova_role"])
        obrys = [bod(q) for q in prsteny[0]]
        kotva, polomer = _kotevni_bod(obrys)
        txt = (str(p["parcel_number"]) if popisky == "kotva"
               else str(p.get("popisek") or p["parcel_number"]))
        w100, h100 = rozmer(txt, 100)
        vel = int(min(100 * 2 * polomer * 1.9 / max(w100, 1),
                      100 * 2 * polomer * 0.9 / max(h100, 1), max_px))
        if vel < min_px:
            vel = min_px          # ať se ověří, jestli se nevejde aspoň takhle
        umisteno = None
        while vel >= min_px:
            w, h = rozmer(txt, vel)
            ram = (kotva[0] - w / 2, kotva[1] - h / 2,
                   kotva[0] + w / 2, kotva[1] + h / 2)
            rohy = [(ram[0], ram[1]), (ram[2], ram[1]),
                    (ram[0], ram[3]), (ram[2], ram[3])]
            if all(_uvnitr(r, obrys) for r in rohy):
                umisteno = {"txt": txt, "rgb": rgb, "vel": vel, "ram": ram,
                            "plocha": polomer}
                break
            vel -= 2
        if umisteno:
            uvnitr.append(umisteno)
        else:
            mimo.append({"txt": txt, "rgb": rgb, "obrys": obrys, "kotva": kotva})

    # kolize uvnitř: parcela s větším odstupem od hranic má přednost
    uvnitr.sort(key=lambda z: -z["plocha"])
    umistene, obsazene = [], []
    for z in uvnitr:
        if any(_protina(z["ram"], r) for r in obsazene):
            mimo.append({"txt": z["txt"], "rgb": z["rgb"], "obrys": None,
                         "kotva": ((z["ram"][0] + z["ram"][2]) / 2,
                                   (z["ram"][1] + z["ram"][3]) / 2)})
        else:
            umistene.append(z); obsazene.append(z["ram"])

    for z in umistene:
        kr.text((z["ram"][0], z["ram"][1]), z["txt"], font=pismo(z["vel"]),
                fill=_tmavsi(z["rgb"]) + (255,), stroke_width=max(2, z["vel"] // 9),
                stroke_fill=(255, 255, 255, 240))

    if mimo:
        _, vys = rozmer("0", min_px)
        krok = vys + 10
        horni, dolni = 8, px[1] - 10 - int(px[1] * 0.07)   # dole je měřítko
        for strana in ("L", "P"):
            skupina = [z for z in mimo
                       if ((z["kotva"][0] - kx0) < (kx1 - z["kotva"][0]))
                       == (strana == "L")]
            if not skupina:
                continue
            skupina.sort(key=lambda z: z["kotva"][1])
            y = min(max(horni, skupina[0]["kotva"][1] - krok / 2),
                    max(horni, dolni - len(skupina) * krok))
            for z in skupina:
                y = max(y, min(z["kotva"][1] - vys / 2, dolni - krok))
                w, _h = rozmer(z["txt"], min_px)
                if strana == "L":
                    lx = max(8, kx0 - 14 - w)
                    spoj = (lx + w + 4, y + vys / 2)
                else:
                    lx = min(px[0] - 8 - w, kx1 + 14)
                    spoj = (lx - 4, y + vys / 2)
                cil = (_nejblizsi_na_obrysu(spoj, z["obrys"])
                       if z["obrys"] else z["kotva"])
                kr.line([spoj, cil], fill=_tmavsi(z["rgb"]) + (190,), width=2)
                kr.text((lx, y), z["txt"], font=f_odkaz,
                        fill=_tmavsi(z["rgb"]) + (255,),
                        stroke_width=3, stroke_fill=(255, 255, 255, 240))
                y += krok

    img.alpha_composite(vrstva)
    return img.convert("RGB")


def meritko(img, bbox):
    """Dokreslí grafické měřítko do levého dolního rohu."""
    kr = ImageDraw.Draw(img)
    sirka_m = bbox[2] - bbox[0]
    for kandidat in (10, 20, 25, 50, 100, 200, 250, 500, 1000):
        if kandidat <= sirka_m / 4:
            delka_m = kandidat
    px_na_m = img.width / sirka_m
    d = delka_m * px_na_m
    vel = max(18, img.width // 52)
    f = pismo(vel)
    x, y = int(img.width * 0.015), img.height - int(img.height * 0.05)
    # podkladový obdélník i odsazení popisku se řídí velikostí písma,
    # jinak text při větším písmu leze na čáru měřítka
    kr.rectangle([x - 8, y - vel - 14, x + d + 12, y + 14], fill=(255, 255, 255, 235))
    kr.line([x, y, x + d, y], fill=(0, 0, 0), width=3)
    for konec in (x, x + d):
        kr.line([konec, y - 7, konec, y + 7], fill=(0, 0, 0), width=3)
    kr.text((x, y - vel - 12), f"{delka_m} m", fill=(0, 0, 0), font=f)
    return img


# =============================================================================
# 4. Sestavení map pro jeden vklad
# =============================================================================

def mapy_vkladu(geometrie, praha):
    # Mezipaměť platí jen pro jeden vklad — každý má jiný výřez a obrázky
    # 1700x1172 px by při dávce zabraly stovky MB.
    _MEZIPAMET.clear()
    detail = vyrez(geometrie, rezerva=REZERVA_DETAIL)
    kontext = vyrez(geometrie, rezerva=REZERVA_KONTEXT)
    # Územní plán, Metropolitní plán a cenová mapa dostanou vlastní, širší
    # výřez — na výřezu podle velikosti parcely z nich není nic patrné.
    uzemni = vyrez(geometrie, rezerva=REZERVA_KONTEXT, min_sirka_m=MIN_SIRKA_UP_M)
    # Metropolitní plán jde ještě dál: kreslí strukturu města — lokality,
    # zastavitelnost, veřejná prostranství — a na 400 m z něj u rodinného
    # domu pořád nebylo patrné, v čem ten dům vlastně leží. Dům se tím zmenší
    # na pár desítek pixelů, ale tady jde právě o okolí (pokyn znalce).
    mpp = vyrez(geometrie, rezerva=REZERVA_KONTEXT, min_sirka_m=MIN_SIRKA_MPP_M)
    cenovy = vyrez(geometrie, rezerva=REZERVA_KONTEXT, min_sirka_m=MIN_SIRKA_CENOVA_M)
    px = (SIRKA_PX, int(SIRKA_PX / POMER))
    hotove = []

    def pridej(nadpis, podklad, bbox, zdroj):
        if podklad is None:
            return
        rezim = "vse" if bbox is detail else "kotva"
        img = meritko(vykresli(podklad, geometrie, bbox, px, rezim), bbox)
        hotove.append((nadpis, img, zdroj))

    print("   ortofotomapa…")
    pridej("Ortofotomapa", ags_export(f"{CUZK}/ORTOFOTO", detail, px,
           pruhledne=False, format="jpg"), detail, "Ortofotomapa ČR, ČÚZK")

    print("   katastrální mapa…")
    kn = wms(KNWMS, "KN", detail, px, "katastrální mapa")
    if kn is not None:
        podklad = Image.new("RGBA", px, (255, 255, 255, 255))
        podklad.alpha_composite(kn)
        pridej("Katastrální mapa", podklad, detail,
               "Katastrální mapa, WMS KN, ČÚZK")

    print("   věcná břemena…")
    vb = wms(KNWMS, "vb,vb_linie", detail, px, "věcná břemena")
    if vb is not None and kn is not None:
        podklad = Image.new("RGBA", px, (255, 255, 255, 255))
        podklad.alpha_composite(kn)
        podklad.alpha_composite(vb)
        pridej("Věcná břemena", podklad, detail,
               "Věcná břemena, WMS KN, ČÚZK")

    print("   digitální technická mapa…")
    orto_d = ags_export(f"{CUZK}/ORTOFOTO", detail, px, pruhledne=False, format="jpg")
    ti = wms(f"{DMVS}/dtm_ti_ver",
             "el_ved,el_kom,plyn,voda,kan,teplo,produkt,odp_hosp",
             detail, px, "DTM sítě")
    prip = wms(f"{DMVS}/dtm_pripojky", "el_ved_prip,plyn_prip,vod_prip,kan_prip",
               detail, px, "DTM přípojky")
    if ti is not None:
        podklad = (orto_d.copy() if orto_d is not None
                   else Image.new("RGBA", px, (255, 255, 255, 255)))
        podklad.alpha_composite(ti)
        if prip is not None:
            podklad.alpha_composite(prip)
        pridej("Digitální technická mapa — sítě a přípojky", podklad, detail,
               "DTM ČR, DMVS, ČÚZK")

    if praha:
        print("   územní plán 1999…")
        up = ags_export(f"{IPR}/pup/uzemni_plan_platny", uzemni, px)
        kn_k = wms(KNWMS, "KN", uzemni, px, "katastr pro ÚP")
        if up is not None:
            podklad = Image.new("RGBA", px, (255, 255, 255, 255))
            podklad.alpha_composite(up)
            if kn_k is not None:
                podklad.alpha_composite(kn_k)
            pridej("Územní plán SÚ hl. m. Prahy 1999, ve znění změn",
                   podklad, uzemni, "Územní plán, IPR Praha")

        print("   Metropolitní plán…")
        mp = mpp_mozaika("Z02_Hlavni_vykres_struktury_NkV_2605", mpp, px)
        if mp is not None:
            podklad = Image.new("RGBA", px, (255, 255, 255, 255))
            podklad.alpha_composite(mp)
            # katastr se dokresluje ve výřezu Metropolitního plánu, ne ÚP —
            # jinak by se podklady rozešly
            kn_m = wms(KNWMS, "KN", mpp, px, "katastr pro MPP")
            if kn_m is not None:
                podklad.alpha_composite(kn_m)
            pridej("Metropolitní plán, hlavní výkres", podklad, mpp,
                   "Metropolitní plán, IPR Praha")

        print("   cenová mapa…")
        cm = ags_export(f"{IPR}/sed/cenova_mapa", cenovy, px, vrstvy="show:0,1",
                        vnucene_meritko=19000)
        if cm is not None:
            podklad = Image.new("RGBA", px, (255, 255, 255, 255))
            podklad.alpha_composite(cm)
            pridej("Cenová mapa stavebních pozemků hl. m. Prahy", podklad,
                   cenovy, "Cenová mapa, IPR Praha")

    return hotove


# =============================================================================
# 5. Dokument
# =============================================================================

def kc(v, des=0):
    if v is None:
        return "—"
    return f"{v:,.{des}f}".replace(",", "\u00a0").replace(".", ",")


def styl(doc, nazev, zaloha="Normal"):
    try:
        doc.styles[nazev]
        return nazev
    except KeyError:
        return zaloha


def novy_dokument(sablona):
    """Vezme ze šablony jen nastavení stránky a styly, obsah zahodí.

    Záhlaví šablony nese zástupné symboly generátoru posudku ({{...}}),
    které by v samostatné příloze vypadaly jako chyba — nahradí se názvem
    přílohy.
    """
    doc = Document(sablona)
    body = doc.element.body
    for prvek in list(body):
        if prvek.tag.endswith("}sectPr"):
            continue
        body.remove(prvek)
    for sekce in doc.sections:
        for cast in (sekce.header, sekce.footer, sekce.first_page_header,
                     sekce.even_page_header):
            if cast is None:
                continue
            for odst in cast.paragraphs:
                for beh in odst.runs:
                    if "{{" in beh.text:
                        beh.text = beh.text.replace("{{CISLO_POLOZKY}}", "").replace("{{", "").replace("}}", "")
                if "{{" in odst.text or "ZP č." in odst.text:
                    for beh in odst.runs[1:]:
                        beh.text = ""
                    if odst.runs:
                        odst.runs[0].text = "Karty srovnávacích vzorků"
    # Vzor záhlaví se schová stranou: každý vklad dostane vlastní sekci
    # s vlastním záhlavím a formátování se přebírá odtud, aby vypadalo
    # stejně jako v posudku.
    prvni = doc.sections[0].header
    doc._vzor_zahlavi = (copy.deepcopy(prvni.paragraphs[0]._element)
                         if prvni.paragraphs else None)
    return doc


def popis_vkladu(v):
    """Jednořádkový popis vkladu do záhlaví stránky."""
    jednotka = (f", jednotka č. {v['jednotka_oznaceni']}"
                if v.get("jednotka_oznaceni") else "")
    # U souboru pozemků žádná hlavní stavba není a hlavni_druh je prázdný.
    druh = v.get("hlavni_druh") or (
        f"{v['parcel_celkem']} pozemků" if v.get("parcel_celkem") else "pozemky")
    adresa = (v.get("hlavni_adresa") or "").strip()
    misto = adresa or f"k. ú. {v['kat_uzemi']}, {v['obec']}"
    text = f"{v['cislo_vkladu']} — {druh}{jednotka}, {misto}"
    if len(text) > 110:
        text = (f"{v['cislo_vkladu']} — {druh}{jednotka}, "
                f"k. ú. {v['kat_uzemi']}, {v['obec']}")
    return text


def zahlavi_sekce(doc, sekce, text):
    """Vloží do záhlaví sekce jeden řádek a odpojí ho od předchozí sekce."""
    try:
        # Šablona posudku má jiné záhlaví na první straně (titulní list).
        # V příloze to nechceme — každá strana karty nese své záhlaví.
        sekce.different_first_page_header_footer = False
    except Exception:
        pass
    zah = sekce.header
    try:
        if sekce is not doc.sections[0]:
            zah.is_linked_to_previous = False
    except Exception:
        pass
    for odst in list(zah.paragraphs):
        odst._element.getparent().remove(odst._element)
    vzor = getattr(doc, "_vzor_zahlavi", None)
    if vzor is not None:
        prvek = copy.deepcopy(vzor)
        zah._element.append(prvek)
        p = Paragraph(prvek, zah)
        for beh in p.runs[1:]:
            beh._element.getparent().remove(beh._element)
        if p.runs:
            p.runs[0].text = text
        else:
            p.add_run(text)
    else:
        zah.add_paragraph(text)


def pevne_sirky(t, sirky_cm):
    """Zafixuje šířky sloupců.

    Nastavit šířku buňkám nestačí — Word i LibreOffice při rozvržení
    vycházejí z w:tblGrid, a ten python-docx nechává prázdný. Bez toho
    si šířky přepočítají podle obsahu a úzké sloupce se roztáhnou na úkor
    širokých.
    """
    tbl = t._tbl
    tblPr = tbl.tblPr
    for znacka, atr in (("w:tblLayout", "w:type"), ):
        for stary in tblPr.findall(qn(znacka)):
            tblPr.remove(stary)
        prvek = OxmlElement(znacka)
        prvek.set(qn(atr), "fixed")
        tblPr.append(prvek)
    for stary in tblPr.findall(qn("w:tblW")):
        tblPr.remove(stary)
    sirka = OxmlElement("w:tblW")
    sirka.set(qn("w:w"), str(int(sum(sirky_cm) * 567)))
    sirka.set(qn("w:type"), "dxa")
    tblPr.append(sirka)
    for stary in tbl.findall(qn("w:tblGrid")):
        tbl.remove(stary)
    grid = OxmlElement("w:tblGrid")
    for cm in sirky_cm:
        sl = OxmlElement("w:gridCol")
        sl.set(qn("w:w"), str(int(cm * 567)))
        grid.append(sl)
    tblPr.addnext(grid)


def _ze_zipu(cesta_zip):
    """Je-li v zipu SABLONA_MASTER.docx, rozbalí ji do dočasného souboru."""
    try:
        with zipfile.ZipFile(cesta_zip) as z:
            for polozka in z.namelist():
                if os.path.basename(polozka) == SABLONA_NAZEV:
                    cil = os.path.join(tempfile.gettempdir(),
                                       "SABLONA_MASTER_z_zipu.docx")
                    with z.open(polozka) as zdroj, open(cil, "wb") as ven:
                        shutil.copyfileobj(zdroj, ven)
                    return cil
    except Exception:
        pass
    return None


def najdi_sablonu(zadana=None):
    """Vrátí cestu k SABLONA_MASTER.docx, nebo None.

    Pořadí: zadaná cesta → proměnná prostředí ZNALEC_SABLONA → prohledání
    známých kořenů. Šablona se hledá jak jako samostatný soubor, tak uvnitř
    zipů se zálohami skillu — tam totiž reálně leží. Skill se verzuje
    (v1, v2, v3-popis), proto se ze všech nálezů bere naposledy změněný,
    tedy poslední verze. Ze zipu se rozbalí do dočasného souboru.
    """
    if zadana:
        return zadana if os.path.exists(zadana) else None
    z_prostredi = os.environ.get("ZNALEC_SABLONA")
    if z_prostredi and os.path.exists(z_prostredi):
        return z_prostredi
    nalezene = []
    for koren in SABLONA_KORENY:
        if not os.path.isdir(koren):
            continue
        for slozka, _, soubory in os.walk(koren):
            for soubor in soubory:
                cesta = os.path.join(slozka, soubor)
                if soubor == SABLONA_NAZEV:
                    nalezene.append((os.path.getmtime(cesta), cesta, False))
                elif soubor.lower().endswith(".zip"):
                    nalezene.append((os.path.getmtime(cesta), cesta, True))
    nalezene.sort(reverse=True)
    for _, cesta, je_zip in nalezene:
        if not je_zip:
            return cesta
        rozbalena = _ze_zipu(cesta)
        if rozbalena:
            print(f"Šablona vzata ze zálohy skillu: {cesta}")
            return rozbalena
    return None


def tabulka(doc, radky, sirky_cm, hlavicka=None):
    s_tab = styl(doc, "ZP tabulka", "Table Grid")
    t = doc.add_table(rows=0, cols=len(sirky_cm))
    try:
        t.style = s_tab
    except Exception:
        pass
    t.autofit = False
    pevne_sirky(t, sirky_cm)
    if hlavicka:
        bunky = t.add_row().cells
        for b, txt, sirka in zip(bunky, hlavicka, sirky_cm):
            b.width = Cm(sirka)
            p = b.paragraphs[0]
            p.style = styl(doc, "ZP tab hlavička", "Normal")
            p.add_run(str(txt)).bold = True
    for radek in radky:
        bunky = t.add_row().cells
        for i, (b, txt, sirka) in enumerate(zip(bunky, radek, sirky_cm)):
            b.width = Cm(sirka)
            p = b.paragraphs[0]
            cislo = isinstance(txt, str) and txt and (txt[0].isdigit() or txt[0] == "—")
            p.style = styl(doc, "ZP tab číslo" if cislo else "ZP tab text", "Normal")
            if cislo:
                p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
            p.add_run("" if txt is None else str(txt))
    return t


def odstavec(doc, text, stylek="ZP text", tucne=False):
    p = doc.add_paragraph()
    p.style = styl(doc, stylek, "Normal")
    r = p.add_run(text)
    r.bold = tucne
    return p


def pocet(n, jedno, dva, pet):
    """České skloňování po číslovce: 1 parcela, 2 parcely, 5 parcel."""
    if n in (None, 0):
        return ""
    n = int(n)
    if n == 1:
        return f"1 {jedno}"
    if 2 <= n <= 4:
        return f"{n} {dva}"
    return f"{n} {pet}"


def karta_do_dokumentu(doc, v, parcely, fvu, geometrie, mapy, prvni,
                       plochy=None, staveb=None):
    # Každý vklad dostane vlastní sekci, protože záhlaví je vlastnost sekce:
    # jen tak může mít každá karta v záhlaví své číslo vkladu a popis
    # nemovitosti. Pouhé zalomení stránky by dalo všem stejné záhlaví.
    try:
        sekce = doc.add_section(WD_SECTION.NEW_PAGE)
    except Exception:
        doc.add_page_break()
        sekce = doc.sections[-1]
    zahlavi_sekce(doc, sekce, popis_vkladu(v))

    odstavec(doc, f"Srovnávací vzorek — vklad {v['cislo_vkladu']}",
             "ZP příloha nadpis", tucne=True)

    # Podtitul karty; u souboru pozemků není ani druh, ani adresa.
    casti_podtitulu = [popis_vkladu(v).split(" — ", 1)[-1]]
    odstavec(doc, ", ".join(x for x in casti_podtitulu if x))
    odstavec(doc, f"Katastrální území {v['kat_uzemi']}, obec {v['obec']}. "
                  f"Vklad zplatněn {v['datum_zplatneni']:%d. %m. %Y}. "
                  f"Kupní cena {kc(v['cena_Kc'])} Kč.")

    # --- cena a plocha hned nahoře ------------------------------------------
    # Při procházení dvaceti vzorků potřebuje znalec nejdřív tři čísla: cenu,
    # plochu a cenu za metr. Dřív byly roztroušené — cena v podtitulu, plocha
    # a jednotková cena až v bloku „Jednotkové ceny“ o dvě stránky níž za
    # mapami. Teď jsou pohromadě na prvním místě karty.
    zaklad = [["Kupní cena", f"{kc(v['cena_Kc'])} Kč", ""]]
    if v.get("plocha_podlahova_karty"):
        zaklad.append(["Podlahová plocha",
                       f"{kc(v['plocha_podlahova_karty'], 1)} m²",
                       v.get("plocha_podlahova_zdroj") or ""])
    if v.get("jc_Kc_m2_podlahova"):
        zaklad.append(["Kč/m² podlahové plochy",
                       kc(v["jc_Kc_m2_podlahova"]),
                       "hlavní jednotková cena vzorku"])
    if v.get("vymera_pozemku_vse"):
        zaklad.append(["Výměra pozemků", f"{kc(v['vymera_pozemku_vse'], 1)} m²",
                       "celý předmět vkladu"])
    if v.get("jc_Kc_m2_vsech_pozemku"):
        zaklad.append(["Kč/m² všech pozemků", kc(v["jc_Kc_m2_vsech_pozemku"]),
                       "hlavní jednotková cena vzorku" if not v.get("jc_Kc_m2_podlahova")
                       else "celý předmět vkladu"])
    if not v.get("jc_Kc_m2_podlahova") and not v.get("jc_Kc_m2_vsech_pozemku"):
        zaklad.append(["Jednotková cena", "—",
                       "nelze spočítat — chybí plocha, viz „Z čeho se počítá cena za m²“"])
    odstavec(doc, "Cena a plocha", "ZP text", tucne=True)
    tabulka(doc, zaklad, [6.5, 3.0, 7.5])

    # --- předmět vkladu ---
    odstavec(doc, "Předmět vkladu", "ZP text", tucne=True)
    je_jednotka = bool(v.get("pocet_jednotek") or 0) or v.get("klasifikace") == "JC_JEDNOTKA"
    popis_hl = v.get("hlavni_druh") or "pozemek"
    if v.get("jednotka_oznaceni"):
        popis_hl += f", jednotka č. {v['jednotka_oznaceni']}"
    radky = [["Hlavní nemovitost", popis_hl, ""]]
    if (v.get("pocet_budov") or 0) + (v.get("pocet_jednotek") or 0) > 1:
        radky.append(["Vedlejší stavby", v.get("slozeni_vkladu") or "", ""])
    def poc(n):
        return pocet(n, "parcela", "parcely", "parcel")
    if v.get("vymera_vyhradni_celek"):
        radky.append(["Výhradní pozemky v celku", f"{kc(v['vymera_vyhradni_celek'])} m²",
                      poc(v.get("parcel_vyhradni_celek"))])
    elif not je_jednotka:
        # Rozptýlený soubor pozemků nemá jeden funkční celek; prázdná rubrika
        # by vypadala jako chybějící údaj, proto se uvede počet částí.
        casti = v.get("casti_vse")
        radky.append(["Pozemky bez souvislého celku", f"{kc(v['vymera_pozemku_vse'])} m²",
                      pocet(casti, "samostatná část", "samostatné části",
                            "samostatných částí") or "nesouvislé"])
    if v.get("vymera_vyhradni_mimo"):
        radky.append(["Výhradní pozemky mimo celek",
                      f"{kc(v['vymera_vyhradni_mimo'])} m²",
                      poc(v.get("parcel_vyhradni_mimo"))])
    if v.get("vymera_podilova"):
        radky.append(["Podíly na společných pozemcích",
                      f"{kc(v['vymera_podilova'])} m²",
                      (poc(v.get("parcel_podilovych")) +
                       (f", dle odhadu podílu {kc(v['vymera_podilova_dle_podilu'], 1)} m²"
                        if v.get("vymera_podilova_dle_podilu") else ""))])
    radky.append(["Pozemky vkladu celkem", f"{kc(v['vymera_pozemku_vse'])} m²",
                  poc(v.get("parcel_celkem"))])
    tabulka(doc, radky, [5.5, 4.0, 7.5])

    # --- stavba ---
    if v.get("ruian_rok") or v.get("ruian_podlahova_plocha") or v.get("ruian_zastavena_plocha"):
        # U jednotky popisuje RÚIAN celý dům, ne prodávaný byt — musí to být
        # v nadpisu, jinak se zastavěná plocha domu čte jako plocha bytu.
        odstavec(doc, "Stavba dle RÚIAN — dům, v němž jednotka leží" if je_jednotka
                 else "Stavba dle RÚIAN", "ZP text", tucne=True)
        VODA = {1: "S vodovodem", 2: "Bez vodovodu"}
        KANAL = {1: "Přípoj na kanalizační síť", 2: "Vlastní čistička odpadních vod",
                 3: "Žumpa, jímka, septik"}
        PLYN = {1: "Plyn z veřejné sítě", 2: "Plyn z domovního zásobníku",
                3: "Bez plynu"}
        # Parita s HTML kartou — Word musí nést tatáž data (pokyn znalce
        # 25. 10. 2026). Chyběly: počet staveb, pásmo stáří, poměr PP/OP.
        r = [["Staveb ve vkladu dle RÚIAN", str(staveb) if staveb else "—"],
             ["Rok dokončení", str(v.get("ruian_rok") or "—") +
              ("" if v.get("ruian_rok_presny") else " (jen rok)")],
             ["Pásmo stáří", v.get("ruian_pasmo") or "—"],
             ["Zastavěná plocha", f"{kc(v.get('ruian_zastavena_plocha'))} m²"],
             ["Podlahová plocha", f"{kc(v.get('ruian_podlahova_plocha'))} m²"],
             ["Obestavěný prostor", f"{kc(v.get('ruian_obestaveny_prostor'))} m³"],
             ["Počet podlaží", str(v.get("ruian_pocet_podlazi") or "—")],
             ["Počet bytů", str(v.get("ruian_pocet_bytu") or "—")],
             ["Druh konstrukce", v.get("ruian_druh_konstrukce") or "—"],
             ["Vytápění", v.get("ruian_vytapeni") or "—"],
             ["Výtah", v.get("ruian_vytah") or "—"],
             ["Vodovod", VODA.get(v.get("pripojeni_vodovod_kod"), "—")],
             ["Kanalizace", KANAL.get(v.get("pripojeni_kanalizace_kod"), "—")],
             ["Plyn", PLYN.get(v.get("pripojeni_plyn_kod"), "—")],
             ["Poměr PP/OP", "—" if v.get("ruian_pomer_pp_op") is None
              else str(v["ruian_pomer_pp_op"]).replace(".", ",")]]
        tabulka(doc, r, [6.0, 11.0])

    # --- jednotkové ceny a tvar ---
    odstavec(doc, "Jednotkové ceny a tvar pozemku", "ZP text", tucne=True)
    r = []
    if v.get("jc_Kc_m2_podlahova"):
        popis_pp = v.get("plocha_podlahova_zdroj") or "podlahová plocha stavby"
        if v.get("plocha_podlahova_karty"):
            popis_pp += f", {kc(v['plocha_podlahova_karty'], 1)} m²"
        r.append(["Kč/m² podlahové plochy", kc(v["jc_Kc_m2_podlahova"]), popis_pp])
    # Nosná výměra pozemku: výhradní parcely bez tvaru pásu a bez druhu
    # komunikace. U pozemkového vkladu hlavní metrika — podíly na
    # komunikacích by ji jinak rozmělnily (krok 46).
    if v.get("jc_Kc_m2_nosne_vymery"):
        popis_n = "výhradní parcely bez komunikací a pásů"
        if v.get("parcel_nosnych"):
            popis_n += f", {v['parcel_nosnych']}\u00d7, {kc(v.get('vymera_nosna'), 1)} m²"
        r.append(["Kč/m² nosné výměry", kc(v["jc_Kc_m2_nosne_vymery"]), popis_n])
    if v.get("jc_Kc_m2_s_podilem"):
        popis_sp = "nosná výměra plus podíl na ostatních parcelách"
        if v.get("vymera_podilu"):
            popis_sp += f" ({kc(v['vymera_podilu'], 1)} m²)"
        r.append(["Kč/m² včetně podílu", kc(v["jc_Kc_m2_s_podilem"]), popis_sp])
    if v.get("jc_Kc_m2_vyhradni_celek"):
        r.append(["Kč/m² výhradního celku", kc(v["jc_Kc_m2_vyhradni_celek"]),
                  "jen výhradní pozemky v celku"])
    if v.get("jc_Kc_m2_vsech_pozemku"):
        r.append(["Kč/m² všech pozemků", kc(v["jc_Kc_m2_vsech_pozemku"]),
                  "celý předmět vkladu"])
    if v.get("jc_Kc_m3"):
        r.append(["Kč/m³ obestavěného prostoru", kc(v["jc_Kc_m3"]),
                  "kubatura dle RÚIAN"])
    if v.get("pp_index_celku") is not None:
        r.append(["Kompaktnost výhradního celku (PP index)",
                  f"{float(v['pp_index_celku']):.3f}".replace(".", ","),
                  "4πA/O² ze sloučené geometrie"])
        if v.get("plocha_celku_m2"):
            r.append(["Plocha celku (sloučená)", f"{kc(v['plocha_celku_m2'], 1)} m²",
                      "po sloučení sousedících parcel"])
        if v.get("obvod_celku_m"):
            r.append(["Obvod celku", f"{kc(v['obvod_celku_m'], 1)} m", ""])
    if v.get("pp_index_vse") is not None and v.get("pp_index_vse") != v.get("pp_index_celku"):
        r.append(["Kompaktnost všech pozemků (PP index)",
                  f"{float(v['pp_index_vse']):.3f}".replace(".", ","),
                  "4πA/O² ze sloučené geometrie"])
        if v.get("plocha_vse_m2"):
            r.append(["Plocha všech pozemků (sloučená)",
                      f"{kc(v['plocha_vse_m2'], 1)} m²", "včetně podílových"])
        if v.get("obvod_vse_m"):
            r.append(["Obvod všech pozemků", f"{kc(v['obvod_vse_m'], 1)} m", ""])
    tabulka(doc, r, [6.5, 3.0, 7.5])

    # --- rozpis parcel ---
    odstavec(doc, "Rozpis parcel", "ZP text", tucne=True)
    poradove = oznac_popisky(parcely)
    radky = []
    for p in parcely:
        radek = [
            p["parcel_number"],
            f"{kc(p['vymera_m2'])} m²",
            druh_parcely(p),
            "—" if p["kompaktnost"] is None else f"{float(p['kompaktnost']):.3f}".replace(".", ","),
            p["vlastnictvi"],
            p["prostorova_role"],
            p["duvod"] or "—"]
        radky.append([str(p["poradi"])] + radek if poradove else radek)
    if poradove:
        sirky = [0.8, 1.4, 1.4, 1.9, 1.7, 2.0, 1.4, 6.4]
        hlavicka = ["č."]
    else:
        sirky = [1.5, 1.5, 2.1, 1.8, 1.7, 1.5, 6.9]
        hlavicka = []
    hlavicka += ["Parcela", "Výměra", "Druh", "Kompakt.",
                 "Vlastnictví", "Poloha", "Z čeho role vychází"]
    t = tabulka(doc, radky, sirky, hlavicka=hlavicka)
    sl = 1 if poradove else 0
    for radek in t.rows[1:]:                       # parcelní číslo doleva
        radek.cells[sl].paragraphs[0].alignment = WD_ALIGN_PARAGRAPH.LEFT
    odstavec(doc, "Vlastnictví je odhad dopočtený z dat, nikoli údaj z katastru. "
                  "Za podílovou se bere parcela, která se prodávala společně "
                  "s několika různými hlavními nemovitostmi. Kompaktnost je "
                  "Polsby-Popperův index 4πA/O².", "ZP popisek")

    # --- z čeho se počítá cena za m²: všechny známé plochy vedle sebe ---
    # Do posudku to patří, protože z toho je vidět, proč je cena taková.
    if plochy:
        odstavec(doc, "Z čeho se počítá cena za m²", "ZP text", tucne=True)
        radky, skupina = [], object()
        for z in plochy:
            # Registr je po jednotkách. Hlavička u každé jednotky říká, jestli
            # se její plocha do plochy vkladu sčítá, nebo je jen v ceně.
            klic = "rucne" if z.get("zdroj") == "RUCNE" else z.get("id")
            if klic != skupina:
                skupina = klic
                if klic == "rucne":
                    nadp = "Ověřeno znalcem"
                elif klic:
                    nadp = ((z.get("typ") or "jednotka") + " "
                            + (z.get("jednotka") or "")).strip()
                    if not z.get("nosna"):
                        nadp += " — rozpuštěno v ceně, do plochy se nesčítá"
                else:
                    nadp = "Kontrolní údaje za celý vklad"
                radky.append([nadp, "", ""])
            pozn = z.get("poznamka") or ("" if z.get("pro_cenu") else "jen kontrola řádu")
            if z.get("pouzito"):
                pozn = (pozn + " — " if pozn else "") + "POUŽITO"
            radky.append([(z.get("nazev") or "") + (" *" if z.get("autoritativni") else ""),
                          f"{kc(z.get('plocha'), 1)} m²", pozn])
        tabulka(doc, radky, [6.5, 3.0, 7.5])
        odstavec(doc, "Plochy ze všech známých zdrojů, u každé jednotky vkladu "
                      "zvlášť; použitá je označena a poznámka u ní říká proč. "
                      "Plocha vkladu je součet použitých ploch nosné nemovitosti — "
                      "jednotky označené „rozpuštěno v ceně“ se do ní nesčítají, "
                      "ačkoli v kupní ceně zahrnuté jsou. Nic se nepřepisuje: "
                      "všichni kandidáti zůstávají v registru. Hvězdička označuje "
                      "údaj ověřený znalcem, který má přednost přede všemi "
                      "ostatními.", "ZP popisek")

    # --- co zjistil znalec ručně ---
    POUZ = {"vhodny": "vhodný", "s_vyhradou": "s výhradou",
            "nepouzitelny": "nepoužitelný"}
    zj = []
    if v.get("pouzitelnost"):
        zj.append(["Použitelnost vzorku", POUZ.get(v["pouzitelnost"], v["pouzitelnost"]),
                   v.get("pouzitelnost_duvod") or ""])
    if v.get("plocha_rucne") is not None:
        zj.append(["Plocha ověřená znalcem", f"{kc(v['plocha_rucne'], 1)} m²",
                   v.get("plocha_rucne_zdroj") or ""])
    if v.get("nalez_plocha_cely_dum"):
        zj.append(["Nález databáze", "plocha jednotky odpovídá celému domu",
                   "Valuo uvedlo u jednotky podlahovou plochu celého domu; "
                   "v domě jsou aspoň dvě jednotky, takže cena za m² by vyšla "
                   "násobně nižší, než má být"])
    if v.get("nalez_skala"):
        zj.append(["Nález databáze", "rozpor ve škále čitatele podílu",
                   "čitatel podílu přepočtený škálou domu se od Valuovy plochy "
                   "liší o celý řád; v registru ploch výše je u dotčené jednotky "
                   "uvedeno, zda se plocha přepsala a čím je to doloženo"])
    if v.get("nalez_vice_nosnych"):
        zj.append(["Nález databáze", "více nosných nemovitostí stejného druhu",
                   f"ve vkladu je {v.get('radku_nosnych') or '?'}× "
                   f"{v.get('nosny_typ') or 'nosná nemovitost'} a žádná z nich není "
                   "hlavní; cena se dělí součtem jejich ploch, takže jednotková "
                   "cena je průměr za všechny, ne cena jedné"])
    if v.get("nalez_bez_plochy"):
        zj.append(["Nález databáze", "nosná nemovitost nemá podlahovou plochu",
                   "aspoň jedna nosná nemovitost plochu nemá, proto se nic nedělí "
                   "a uvádí se jen celková cena; u budov je to běžné — Valuo dává "
                   "do pole plocha výměru parcely a RÚIAN tu stavbu často nezná"])
    if v.get("rozpusteno"):
        zj.append(["Složení vkladu", "v ceně je i " + str(v["rozpusteno"]),
                   "do plochy se sčítají jen řádky nosné nemovitosti "
                   f"({v.get('nosny_typ') or '—'}), ostatní jednotky jsou v ceně "
                   "rozpuštěné a jednotkovou cenu tím snižují"])
    if v.get("jc_verdikt") == "k prověření" and v.get("jc_median_ku"):
        zj.append(["Kontrola ceny", "mimo pásmo mediánu v katastrálním území",
                   f"medián skupiny „{v.get('nosna_skupina') or '—'}“ v k.ú. je "
                   f"{kc(v['jc_median_ku'])} Kč/m² z {v.get('jc_vzorku_ku') or 0} "
                   "vzorků; je to jen vodítko, kde se vyplatí plochu prověřit "
                   "v listině, plochu to nevybírá"])
    if v.get("nalez_plocha_mimo_ocekavani"):
        zj.append(["Nález databáze", "plocha se vymyká ploše domu na jednotku",
                   f"dle RÚIANu vychází {kc(v.get('plocha_na_byt'), 1)} m² na jednu "
                   "jednotku; v domě ale bývají i garáže a nebytové prostory "
                   "a dům se může skládat z více čísel popisných"])
    if v.get("nalezu_rucne"):
        zj.append(["Zaznamenaných nálezů", str(v["nalezu_rucne"]), ""])
    if v.get("poznamek"):
        zj.append(["Poznámek ke vkladu", str(v["poznamek"]), ""])
    if zj:
        odstavec(doc, "Co zjistil znalec", "ZP text", tucne=True)
        tabulka(doc, zj, [5.5, 4.0, 7.5])
        odstavec(doc, "Tyto údaje nepocházejí z katastru ani z databáze Valuo — "
                      "doplnil je znalec a přepočet je upřednostňuje před údaji "
                      "ze zdroje.", "ZP popisek")

    # --- funkční využití dle ÚP (jen Praha) ---
    if fvu:
        odstavec(doc, "Funkční využití dle územního plánu", "ZP text", tucne=True)
        radky, predchozi = [], None
        for f in fvu:
            radky.append([
                "" if f["parcel_number"] == predchozi else f["parcel_number"],
                f.get("POPIS_Z") or f.get("fvu_kod") or "—",
                (f.get("skupina") or "").lower(),
                f"{kc(f['podil_pct'], 1)} %",
                f"{kc(f['prunik_m2'], 1)} m²"])
            predchozi = f["parcel_number"]
        tabulka(doc, radky, [2.6, 3.4, 3.4, 3.2, 4.4],
                hlavicka=["Parcela", "Plocha dle ÚP", "Cenová skupina",
                          "Podíl parcely", "Výměra průniku"])
        souhrn = {}
        for f in fvu:
            k = f.get("POPIS_Z") or f.get("fvu_kod") or "—"
            souhrn[k] = souhrn.get(k, 0) + float(f["prunik_m2"] or 0)
        odstavec(doc, "Souhrn za vklad: " + ", ".join(
            f"{k} {kc(x)} m²" for k, x in sorted(souhrn.items(), key=lambda y: -y[1])) +
            ". Územní plán sídelního útvaru hl. m. Prahy z roku 1999 ve znění změn, "
            "prostorově provázaný na parcely. Parcela může ležet ve více plochách; "
            "uvádí se podíl její výměry v každé z nich.", "ZP popisek")

    # --- mapy ---
    for nadpis, img, zdroj in mapy:
        doc.add_page_break()
        odstavec(doc, nadpis, "ZP text", tucne=True)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        buf.seek(0)
        p = doc.add_paragraph()
        p.style = styl(doc, "ZP obrázek", "Normal")
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.add_run().add_picture(buf, width=Cm(SIRKA_SAZBY_CM))
        cislovani = (" Parcely jsou v mapě označeny pořadovým číslem "
                     "z rozpisu parcel." if oznac_popisky(parcely) else "")
        odstavec(doc, f"Zdroj: {zdroj}. Hranice parcel vkladu vyznačeny barevně "
                      f"podle role v předmětu vkladu.{cislovani}", "ZP popisek")


def stin_bunky(bunka, rgb):
    tcPr = bunka._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), "%02X%02X%02X" % rgb)
    tcPr.append(shd)


def legenda_do_dokumentu(doc):
    odstavec(doc, "Vysvětlivky k vyznačení parcel v mapách", "ZP text", tucne=True)
    polozky = list(dict((lab, (rgb, lab)) for rgb, lab in BARVY.values()).values())
    t = tabulka(doc, [["", popis] for _, popis in polozky], [1.4, 15.6])
    for radek, (rgb, _) in zip(t.rows, polozky):
        stin_bunky(radek.cells[0], rgb)
    odstavec(doc, "Vlastnictví je odhad dopočtený z dat, nikoli údaj z katastru. "
                  "Za podílovou se bere parcela, která se v datech prodávala "
                  "společně s několika různými hlavními nemovitostmi. "
                  "Hranice parcel jsou vedeny barvou role s tmavým a bílým lemem, "
                  "aby byly čitelné na ortofotomapě, katastrální mapě i územním plánu.",
                  "ZP popisek")


# =============================================================================
# 5b. Přehledová mapa srovnávacího souboru (28. 10. 2026)
# =============================================================================
# Na začátek dokumentu jedna mapa se všemi vzorky: tečka v místě značky
# z mapové aplikace (Valuo_mapa.lat/lon — stejný bod, jaký znalec viděl při
# výběru), barva podle jednotkové ceny UVNITŘ vzorku (zelená nejlevnější,
# červená nejdražší, lineárně mezi minimem a maximem) a popisek s číslem
# vkladu a Kč/m². Orientační ceny se ukazují šedě a do škály se nepočítají,
# stejně jako v aplikaci.

SQL_PREHLED = sqlalchemy.text("""
SELECT m.cislo_vkladu, m.lat, m.lon, m.cena_m2, m.jc_orientacni, m.kat_uzemi,
       m.datum_zplatneni, m.cena_Kc, m.plocha, m.zaklad_ceny,
       k.vymera_pozemku_vse
FROM dbo.Valuo_mapa m
LEFT JOIN dbo.v_Valuo_karta_vkladu k ON k.cislo_vkladu = m.cislo_vkladu
WHERE m.cislo_vkladu IN :v AND m.lat IS NOT NULL AND m.lon IS NOT NULL
""").bindparams(sqlalchemy.bindparam("v", expanding=True))

PREHLED_MIN_SIRKA_M = 1500.0     # jeden vzorek nebo vzorky v jedné ulici
PREHLED_OKRAJ = 0.30             # rezerva kolem bodů na popisky
PREHLED_ZTM_DO_M = 25000.0       # do této šířky ZTM, nad ní Přehledová mapa
PREHLED_SKALA = [(26, 150, 65), (242, 197, 0), (215, 25, 28)]
PREHLED_ORIENT = (150, 150, 150)


def _skala(t):
    t = max(0.0, min(1.0, t))
    if t <= 0.5:
        a, b, u = PREHLED_SKALA[0], PREHLED_SKALA[1], t / 0.5
    else:
        a, b, u = PREHLED_SKALA[1], PREHLED_SKALA[2], (t - 0.5) / 0.5
    return tuple(int(round(a[i] + (b[i] - a[i]) * u)) for i in range(3))


def nacti_prehled(conn, vklady):
    """Body vzorků v pořadí srovnávacího souboru, souřadnice v S-JTSK."""
    radky = {r.cislo_vkladu: r for r in
             conn.execute(SQL_PREHLED, {"v": list(vklady)})}
    body = []
    for poradi, cislo in enumerate(vklady, 1):
        r = radky.get(cislo)
        if r is None:
            continue
        x, y = T_WGS_SJTSK.transform(float(r.lon), float(r.lat))
        cena = float(r.cena_m2) if r.cena_m2 is not None else None
        body.append({"poradi": poradi, "cislo": cislo, "x": x, "y": y,
                     "cena": cena, "orient": bool(r.jc_orientacni),
                     "ku": r.kat_uzemi, "datum": r.datum_zplatneni,
                     "cena_kc": float(r.cena_Kc) if r.cena_Kc is not None else None,
                     "vymera": (float(r.vymera_pozemku_vse)
                                if r.vymera_pozemku_vse is not None else None),
                     "zaklad_plocha": float(r.plocha) if r.plocha is not None else None,
                     "zaklad": r.zaklad_ceny})
    return body


def _vyrez_bodu(body):
    xs = [b["x"] for b in body]; ys = [b["y"] for b in body]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    sx, sy = max(xs) - min(xs), max(ys) - min(ys)
    sirka = max(sx * (1 + 2 * PREHLED_OKRAJ),
                sy * (1 + 2 * PREHLED_OKRAJ) * POMER, PREHLED_MIN_SIRKA_M)
    vyska = sirka / POMER
    return (cx - sirka / 2, cy - vyska / 2, cx + sirka / 2, cy + vyska / 2)


def prehledova_mapa(body, bez_podkladu=False):
    """Vrátí (obrázek, zdroj) nebo None, nejsou-li žádné body."""
    if not body:
        return None
    px = (SIRKA_PX, int(SIRKA_PX / POMER))
    bbox = _vyrez_bodu(body)
    sirka_m = bbox[2] - bbox[0]

    img = Image.new("RGBA", px, (255, 255, 255, 255))
    zdroj = "bez mapového podkladu"
    if not bez_podkladu:
        if sirka_m <= PREHLED_ZTM_DO_M:
            podklad = ags_export(f"{CUZK}/ZTM", bbox, px, pruhledne=False,
                                 format="png")
            zdroj = "Základní topografická mapa, ČÚZK"
        else:
            podklad = ags_export(f"{CUZK}/PrehledovaMapa", bbox, px,
                                 pruhledne=False, format="png")
            zdroj = "Přehledová mapa ČR, ČÚZK"
        if podklad is not None:
            img.alpha_composite(podklad.resize(px, Image.LANCZOS))
            # podklad mírně zesvětlit, aby barevné tečky vystoupily
            img = Image.blend(img, Image.new("RGBA", px, (255, 255, 255, 255)), 0.25)
        else:
            zdroj = "mapový podklad se nepodařilo stáhnout"

    # barvy
    ceny = [b["cena"] for b in body if b["cena"] and not b["orient"]]
    lo, hi = (min(ceny), max(ceny)) if ceny else (None, None)
    for b in body:
        if b["cena"] and not b["orient"]:
            t = 0.5 if hi == lo else (b["cena"] - lo) / (hi - lo)
            b["rgb"] = _skala(t)
        else:
            b["rgb"] = PREHLED_ORIENT

    x0, y0, x1, y1 = bbox
    sx, sy = px[0] / (x1 - x0), px[1] / (y1 - y0)
    for b in body:
        b["px"] = ((b["x"] - x0) * sx, (y1 - b["y"]) * sy)

    vrstva = Image.new("RGBA", px, (0, 0, 0, 0))
    kr = ImageDraw.Draw(vrstva)
    na_bod = (px[0] / SIRKA_SAZBY_CM) * 0.03528      # pixelů na typografický bod
    R = max(15, int(px[0] * 0.0105))                  # poloměr tečky ≈ 1,8 mm
    f1 = pismo(int(8.5 * na_bod))
    f2 = pismo(int(8.0 * na_bod))
    mer = ImageDraw.Draw(Image.new("RGB", (1, 1)))

    def box_textu(txt, f):
        l, t, r_, b_ = mer.textbbox((0, 0), txt, font=f)
        return r_ - l, b_ - t, l, t

    # zakázané plochy: všechny tečky, měřítko vlevo dole, legenda vpravo dole
    obsazene = [(b["px"][0] - R - 4, b["px"][1] - R - 4,
                 b["px"][0] + R + 4, b["px"][1] + R + 4) for b in body]
    obsazene.append((0, px[1] * 0.88, px[0] * 0.30, px[1]))
    obsazene.append((px[0] * 0.62, px[1] * 0.84, px[0], px[1]))

    smery = [(1, -1), (1, 1), (-1, -1), (-1, 1), (0, -1), (0, 1), (1, 0), (-1, 0)]
    popisky = []
    # nejdřív body v nejhustším okolí — mají nejméně volných míst
    def hustota(b):
        return sum(1 for c in body if c is not b and
                   abs(c["px"][0] - b["px"][0]) < 300 and
                   abs(c["px"][1] - b["px"][1]) < 150)
    for b in sorted(body, key=hustota, reverse=True):
        r1 = b["cislo"]
        r2 = (f"{b['cena']:,.0f}".replace(",", " ") + " Kč/m²"
              + (" (orient.)" if b["orient"] else "")) if b["cena"] else "bez Kč/m²"
        w1, h1, _, _ = box_textu(r1, f1)
        w2, h2, _, _ = box_textu(r2, f2)
        w, h = max(w1, w2), h1 + h2 + 8
        cx, cy = b["px"]
        umisteni = None
        for vzd in (1.0, 2.2, 3.6, 5.2):
            for dx, dy in smery:
                ox = cx + dx * (R + 6) * vzd
                oy = cy + dy * (R + 6) * vzd
                lx = ox if dx > 0 else (ox - w if dx < 0 else ox - w / 2)
                ly = oy if dy > 0 else (oy - h if dy < 0 else oy - h / 2)
                ram = (lx - 4, ly - 4, lx + w + 4, ly + h + 4)
                if ram[0] < 6 or ram[1] < 6 or ram[2] > px[0] - 6 or ram[3] > px[1] - 6:
                    continue
                if any(_protina(ram, o, 2) for o in obsazene):
                    continue
                umisteni = (lx, ly, ram, vzd > 1.0, (ox, oy))
                break
            if umisteni:
                break
        if not umisteni:                       # nouzově vpravo nahoru přes cokoli
            lx, ly = cx + R + 6, cy - R - 6 - h
            lx = min(max(6, lx), px[0] - 6 - w); ly = min(max(6, ly), px[1] - 6 - h)
            umisteni = (lx, ly, (lx - 4, ly - 4, lx + w + 4, ly + h + 4), False, None)
        lx, ly, ram, s_carou, kotva = umisteni
        obsazene.append(ram)
        popisky.append((b, r1, r2, lx, ly, h1, ram, s_carou))

    # odkazové čáry pod tečkami
    for b, _r1, _r2, lx, ly, _h1, ram, s_carou in popisky:
        if s_carou:
            cx, cy = b["px"]
            tx = min(max(cx, ram[0]), ram[2]); ty = min(max(cy, ram[1]), ram[3])
            kr.line([(cx, cy), (tx, ty)], fill=(40, 40, 40, 220), width=3)
    # tečky: tmavý okraj, bílý lem, barva
    for b in body:
        cx, cy = b["px"]
        kr.ellipse([cx - R - 4, cy - R - 4, cx + R + 4, cy + R + 4], fill=(20, 20, 20, 230))
        kr.ellipse([cx - R - 1, cy - R - 1, cx + R + 1, cy + R + 1], fill=(255, 255, 255, 255))
        kr.ellipse([cx - R + 3, cy - R + 3, cx + R - 3, cy + R - 3], fill=b["rgb"] + (255,))
    # popisky s bílou září
    for b, r1, r2, lx, ly, h1, _ram, _s in popisky:
        kr.text((lx, ly), r1, font=f1, fill=(20, 20, 20, 255),
                stroke_width=4, stroke_fill=(255, 255, 255, 245))
        kr.text((lx, ly + h1 + 8), r2, font=f2, fill=_tmavsi(b["rgb"], 0.75) + (255,),
                stroke_width=4, stroke_fill=(255, 255, 255, 245))

    # legenda škály vpravo dole
    if ceny:
        lw, lh = int(px[0] * 0.26), int(px[1] * 0.025)
        lx0 = px[0] - lw - int(px[0] * 0.03); ly0 = px[1] - int(px[1] * 0.075)
        fl = pismo(int(7.5 * na_bod))
        t_lo = f"{lo:,.0f}".replace(",", " ")
        t_hi = f"{hi:,.0f}".replace(",", " ") + " Kč/m²"
        _, ht, _, _ = box_textu(t_lo, fl)
        kr.rectangle([lx0 - 14, ly0 - ht - 22, lx0 + lw + 14, ly0 + lh + 12],
                     fill=(255, 255, 255, 235))
        for i in range(lw):
            kr.line([(lx0 + i, ly0), (lx0 + i, ly0 + lh)], fill=_skala(i / max(lw - 1, 1)) + (255,))
        kr.rectangle([lx0, ly0, lx0 + lw, ly0 + lh], outline=(40, 40, 40, 255), width=2)
        kr.text((lx0, ly0 - ht - 12), t_lo, font=fl, fill=(20, 20, 20, 255))
        wt, _, _, _ = box_textu(t_hi, fl)
        kr.text((lx0 + lw - wt, ly0 - ht - 12), t_hi, font=fl, fill=(20, 20, 20, 255))

    img.alpha_composite(vrstva)
    img = meritko(img.convert("RGB"), bbox)
    return img, zdroj, lo, hi


def prehled_do_dokumentu(doc, conn, vklady, bez_podkladu=False):
    """Přehledová mapa a soupis vzorků na začátek dokumentu."""
    body = nacti_prehled(conn, vklady)
    vysledek = prehledova_mapa(body, bez_podkladu)
    if not vysledek:
        return
    img, zdroj, lo, hi = vysledek

    # --- souhrnná tabulka vzorků (pokyn znalce 28. 10. 2026) ---------------
    # Kč/m² je táž jednotková cena jako v mapové aplikaci. Počítá-li se
    # k jiné ploše než k celkové výměře pozemků (nosná výměra, podlahová
    # plocha), označí se odkazem, aby tabulka nesváděla k dělení cena/výměra.
    odstavec(doc, "Souhrn srovnávacích vzorků", "ZP text", tucne=True)
    radky, jiny_zaklad = [], []
    for b in body:
        jc = (kc(b["cena"]) if b["cena"] else "—")
        if b["cena"] and b["orient"]:
            jc += " orient."
        if (b["cena"] and b["zaklad_plocha"] and b["vymera"]
                and abs(b["zaklad_plocha"] - b["vymera"]) > 0.5):
            jiny_zaklad.append(b)
            jc += f" ({len(jiny_zaklad)})"
        radky.append([str(b["poradi"]), b["cislo"], b["ku"] or "",
                      f"{b['datum']:%d. %m. %Y}" if b["datum"] else "—",
                      kc(b["vymera"], 0) if b["vymera"] else "—",
                      kc(b["cena_kc"]) if b["cena_kc"] else "—", jc])
    tabulka(doc, radky, [0.8, 3.5, 3.0, 2.2, 2.2, 2.9, 2.4],
            hlavicka=["č.", "Číslo vkladu", "Katastrální území", "Zplatněno",
                      "Výměra pozemků m²", "Kupní cena Kč", "Kč/m²"])
    poznamky = ["Výměra pozemků = součet výměr všech parcel předmětu vkladu. "
                "Kč/m² = jednotková cena vzorku shodná s mapovou aplikací."]
    for i, b in enumerate(jiny_zaklad, 1):
        poznamky.append(f"({i}) {b['cislo']}: jednotková cena počítána k ploše "
                        f"{kc(b['zaklad_plocha'], 0)} m² — {b['zaklad'] or 'jiný základ'}.")
    odstavec(doc, " ".join(poznamky), "ZP popisek")

    # --- přehledová mapa ----------------------------------------------------
    odstavec(doc, "Přehledová mapa srovnávacích vzorků", "ZP text", tucne=True)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    p = doc.add_paragraph()
    p.style = styl(doc, "ZP obrázek", "Normal")
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.add_run().add_picture(buf, width=Cm(SIRKA_SAZBY_CM))
    skala = (f" Barva tečky vyjadřuje jednotkovou cenu v rámci souboru: zelená "
             f"{kc(lo)} Kč/m² (nejnižší), červená {kc(hi)} Kč/m² (nejvyšší), "
             f"mezi nimi lineárně." if lo is not None and hi != lo else "")
    odstavec(doc, f"Zdroj: {zdroj}. Vzorky vyznačeny v místě hlavní nemovitosti."
                  f"{skala} Šedě vzorky s orientační cenou nebo bez jednotkové ceny, "
                  f"do škály se nezapočítávají.", "ZP popisek")
    chybi = [c for c in vklady if c not in {b["cislo"] for b in body}]
    if chybi:
        odstavec(doc, "V mapě chybí (vklad nemá bod v mapové vrstvě): "
                      + ", ".join(chybi) + ".", "ZP popisek")


# =============================================================================
# 6. Hlavní běh
# =============================================================================

def main():
    global SERVER
    ap = argparse.ArgumentParser(description="Karta vkladu do dokumentu Wordu")
    ap.add_argument("vklady", nargs="*", help="čísla vkladů")
    ap.add_argument("--ku", help="katastrální území místo výčtu vkladů")
    ap.add_argument("--rok", type=int)
    ap.add_argument("--limit", type=int, default=10)
    ap.add_argument("--vystup", default=None)
    ap.add_argument("--sablona", default=None)
    ap.add_argument("--server", default=SERVER)
    ap.add_argument("--bez-map", action="store_true",
                    help="nestahovat mapové podklady, jen parcely na prázdném podkladu")
    a = ap.parse_args()
    SERVER = a.server

    sablona = najdi_sablonu(a.sablona)
    if not sablona:
        kde = "\n".join("  " + k for k in SABLONA_KORENY)
        raise SystemExit(
            f"Šablona {SABLONA_NAZEV} nenalezena — ani jako soubor, ani "
            f"uvnitř zipů. Hledal jsem v:\n{kde}\n"
            f"Zadej cestu přepínačem --sablona, nebo ji ulož do proměnné "
            f"prostředí ZNALEC_SABLONA.")
    print(f"Šablona: {sablona}")

    eng = engine()
    with eng.connect() as conn:
        vklady = list(a.vklady)
        if a.ku:
            q = ("SELECT TOP (:n) cislo_vkladu FROM dbo.v_Valuo_karta_vkladu "
                 "WHERE kat_uzemi = :ku")
            par = {"n": a.limit, "ku": a.ku}
            if a.rok:
                q += " AND rok = :r"
                par["r"] = a.rok
            q += " ORDER BY datum_zplatneni DESC"
            vklady = [r[0] for r in conn.execute(sqlalchemy.text(q), par)]
        if not vklady:
            raise SystemExit("Nebyl zadán ani nalezen žádný vklad.")

        doc = novy_dokument(sablona)
        odstavec(doc, "Srovnávací vzorky — karty vkladů", "ZP příloha nadpis",
                 tucne=True)
        odstavec(doc, f"Příloha obsahuje {len(vklady)} "
                      f"{'kartu' if len(vklady) == 1 else 'karet'} vkladu. "
                      f"Sestaveno {datetime.date.today():%d. %m. %Y} z databáze "
                      f"cenových údajů ze sbírky listin katastru nemovitostí.")
        prehled_do_dokumentu(doc, conn, vklady, bez_podkladu=a.bez_map)
        legenda_do_dokumentu(doc)

        for i, cislo in enumerate(vklady):
            print(f"[{i+1}/{len(vklady)}] {cislo}")
            v, parcely, fvu = nacti_vklad(conn, cislo)
            geometrie = parcely_sjtsk(parcely)
            if not geometrie:
                print("   [!] vklad nemá geometrii, přeskakuji")
                continue
            oznac_popisky(parcely)
            praha = (v.get("obec") or "").strip().lower().startswith("praha")
            mapy = ([] if a.bez_map else mapy_vkladu(geometrie, praha))
            if a.bez_map:
                px = (SIRKA_PX, int(SIRKA_PX / POMER))
                bb = vyrez(geometrie, rezerva=REZERVA_DETAIL)
                mapy = [("Parcely vkladu", meritko(vykresli(None, geometrie, bb, px), bb),
                         "Katastr nemovitostí, ČÚZK — bez mapového podkladu")]
            karta_do_dokumentu(doc, v, parcely, fvu, geometrie, mapy,
                               prvni=False, plochy=nacti_plochy(conn, cislo),
                               staveb=pocet_staveb(conn, cislo))

    vystup = a.vystup or (
        f"karta_{vklady[0].replace('/', '-')}.docx" if len(vklady) == 1
        else f"vzorky_{datetime.date.today():%Y%m%d}.docx")
    doc.save(vystup)
    print(f"\nHotovo: {os.path.abspath(vystup)}")


if __name__ == "__main__":
    main()
