"""
VALUO — KROK 23c: MAPA HROMADNÝCH PŘEVODŮ SE ZÁPISEM DO DB

Spustí lokální server a otevře mapu v prohlížeči. Skupiny
z Valuo_hromadne_prevody si projdeš na katastrální mapě,
zatřídíš kliknutím a zatřídění se rovnou zapíše do databáze.

    python 23c_mapa_prevodu.py

Zastavíš Ctrl+C. Volby:
    --port 8111     jiný port
    --bez-prohlizece  neotevírat prohlížeč

Spusť po 23b_zatrideni_prevodu.sql.

================================================================
ZÁPIS DO DATABÁZE
================================================================
Statické HTML se k SQL Serveru nedostane, proto skript běží jako
malý server (http.server ze standardní knihovny, nic se
neinstaluje). Změna v roletce pošle požadavek, server provede
UPDATE a vrátí potvrzení, které se v panelu zobrazí u skupiny.

Změna zatřídění se přepíše. Prázdná volba zatřídění zruší
(typ_jevu = NULL).

Server poslouchá jen na 127.0.0.1, takže je dostupný pouze
z tohoto počítače.

================================================================
MAPOVÉ VRSTVY
================================================================
Ortofoto ČÚZK      ORTOFOTO_WM — cache v EPSG:3857, Leaflet ji
                   bere jako XYZ. Služba ORTOFOTO bez _WM je
                   dláždená v S-JTSK a vykreslí pozemek o
                   kilometry mimo; nezaměňovat.
Základní mapa      ZTM_WM, rovněž Web Mercator
Katastrální mapa   WMTS ČÚZK v měřítkové řadě Google; vrstvu
                   skript najde v GetCapabilities, aby ji neměl
                   zadrátovanou
Hranice parcel     tenký překryv nad ortofotem; užitečný při
                   identifikaci tvaru pozemku, odškrtnutím zmizí

================================================================
POZOR NA PŘEDMĚT VKLADU
================================================================
U vkladu jednotky je parcela v mapě jen poloha domu, ne předmět
prodeje — jednotková cena se počítá z podlahové plochy bytu.
Popup i tabulka to proto u každé parcely uvádějí.
================================================================
"""

import argparse
import json
import os
import re
import sys
import threading
import urllib.request
import webbrowser
import xml.etree.ElementTree as ET
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pyodbc

CONN = (
    "Driver={ODBC Driver 17 for SQL Server};"
    "Server=localhost;"
    "Database=VALUO;"
    "Trusted_Connection=yes;"
)

WMTS_KN = (
    "https://services.cuzk.cz/wmts/local-km-wmts-google.asp"
    "?service=WMTS&request=GetCapabilities"
)

ARCGIS = "https://ags.cuzk.gov.cz/arcgis1/rest/services"
ORTOFOTO = f"{ARCGIS}/ORTOFOTO_WM/MapServer/tile/{{z}}/{{y}}/{{x}}"
ZAKLADNI = f"{ARCGIS}/ZTM_WM/MapServer/tile/{{z}}/{{y}}/{{x}}"

ZJEDNODUSENI_M = 1

BARVY = {
    "PRIVATIZACE":      "#c2410c",
    "CENIK_NOVOSTAVBA": "#1d4ed8",
    "VYKUP_LINIOVY":    "#15803d",
    "STAVEBNI_PARCELY": "#a21caf",
    "PREVOD_PODILU":    "#0f766e",
    "JINE":             "#b45309",
    "TRH":              "#0e7490",
    None:               "#6b7280",
}


# ---------------------------------------------------------------
# 1. VRSTVY KATASTRÁLNÍ MAPY
# ---------------------------------------------------------------

def sablony_kn():
    """Vrátí {'mapa': url|None, 'hranice': url|None, 'info': text}."""
    ns = {"wmts": "http://www.opengis.net/wmts/1.0",
          "ows":  "http://www.opengis.net/ows/1.1"}
    out = {"mapa": None, "hranice": None, "info": ""}
    try:
        with urllib.request.urlopen(WMTS_KN, timeout=30) as r:
            root = ET.fromstring(r.read())
    except Exception as e:
        out["info"] = f"WMTS ČÚZK nedostupné: {e}"
        return out

    for layer in root.iter(f"{{{ns['wmts']}}}Layer"):
        ident = layer.find(f"{{{ns['ows']}}}Identifier")
        tms = layer.find(f".//{{{ns['wmts']}}}TileMatrixSetLink/"
                         f"{{{ns['wmts']}}}TileMatrixSet")
        formaty = [f.text for f in layer.findall(f"{{{ns['wmts']}}}Format")
                   if f.text]
        if ident is None or not ident.text or tms is None or not formaty:
            continue
        nazev = ident.text.strip()
        n = nazev.lower()

        sablona = None
        for res in layer.findall(f"{{{ns['wmts']}}}ResourceURL"):
            if res.get("resourceType") == "tile":
                sablona = res.get("template")
                break
        if sablona:
            sablona = (sablona
                       .replace("{TileMatrixSet}", tms.text.strip())
                       .replace("{TileMatrix}", "{z}")
                       .replace("{TileRow}", "{y}")
                       .replace("{TileCol}", "{x}")
                       .replace("{Style}", "default"))
        else:
            fmt = "image/png" if "image/png" in formaty else formaty[0]
            sablona = (WMTS_KN.split("?")[0]
                       + "?service=WMTS&request=GetTile&version=1.0.0"
                       + f"&layer={nazev}&style=default&format={fmt}"
                       + f"&tileMatrixSet={tms.text.strip()}"
                       + "&tileMatrix={z}&tileRow={y}&tileCol={x}")

        if "inverz" in n:
            continue
        if ("katastr" in n or n == "kn") and out["mapa"] is None:
            out["mapa"] = sablona
        elif "hranice" in n and out["hranice"] is None:
            out["hranice"] = sablona

    nalez = [k for k in ("mapa", "hranice") if out[k]]
    out["info"] = ("nalezeno: " + ", ".join(nalez)) if nalez \
        else "WMTS neobsahuje katastrální mapu"
    return out


# ---------------------------------------------------------------
# 2. DATA
# ---------------------------------------------------------------

DOTAZ_SKUPINY = """
SELECT  h.klasifikace, h.kat_uzemi, h.druh,
        CAST(h.jedn_cena_Kc_m2 AS float)  AS jc,
        CAST(h.median_lokality AS float)  AS median,
        CAST(h.pomer AS float)            AS pomer,
        h.vkladu, h.katastru, h.rok_min, h.rok_max,
        CAST(h.plocha_min AS float)       AS pl_min,
        CAST(h.plocha_max AS float)       AS pl_max,
        CAST(h.cena_min AS float)         AS cena_min,
        CAST(h.cena_max AS float)         AS cena_max,
        h.typ_jevu, h.poznamka
FROM dbo.Valuo_hromadne_prevody h
ORDER BY h.klasifikace, h.vkladu DESC
"""

DOTAZ_TYPY = """
SELECT typ_jevu, popis, do_medianu
FROM dbo.CIS_typy_hromadneho_prevodu
ORDER BY do_medianu, typ_jevu
"""

DOTAZ_PARCELY = """
SELECT DISTINCT
        q.klasifikace, q.kat_uzemi, ISNULL(q.druh, '?') AS druh,
        CAST(q.jedn_cena_Kc_m2 AS float) AS jc,
        q.cislo_vkladu,
        CONVERT(varchar(10), q.datum_zplatneni, 104) AS datum,
        CAST(q.cena_Kc AS float)         AS cena,
        CAST(q.plocha_jednotky_m2 AS float)  AS pl_jednotky,
        CAST(q.plocha_parcel_m2 AS float)    AS pl_parcel,
        CAST(q.plocha_podlahova_m2 AS float) AS pl_podlahova,
        v.jednotka_oznaceni,
        v.typ                            AS typ_jednotky,
        p.parcel_number,
        p.gml_id,
        CAST(p.areaValue_m2 AS float)    AS vymera,
        p.geo_plocha.Reduce(?).STAsText() AS wkt
FROM dbo.v_Valuo_vzorek_q q
JOIN dbo.Valuo_data v     ON v.cislo_vkladu = q.cislo_vkladu
JOIN dbo.KN_parcel_data p ON p.id_valuo     = v.id
WHERE q.hromadny_prevod = 1 AND p.geo_plocha IS NOT NULL
"""

UPDATE_TYP = """
UPDATE dbo.Valuo_hromadne_prevody
   SET typ_jevu = ?
 WHERE klasifikace = ? AND kat_uzemi = ? AND druh = ?
   AND jedn_cena_Kc_m2 = ?
"""

WKT_POLYGON = re.compile(r"\(\(([^)]*)\)\)")

# Jedno trvalé spojení pod zámkem. Nové pyodbc.connect pro každý
# zápis vedlo k "Login timeout expired / delay in prelogin
# response" — navazování spojení je u SQL Serveru dost drahé
# a souběžné pokusy se navzájem blokovaly.
_zamek = threading.Lock()
_spojeni = None


def spojeni():
    """Vrátí živé spojení; spadlé zahodí a naváže znovu."""
    global _spojeni
    if _spojeni is not None:
        try:
            _spojeni.cursor().execute("SELECT 1").fetchone()
            return _spojeni
        except Exception:
            try:
                _spojeni.close()
            except Exception:
                pass
            _spojeni = None
    _spojeni = pyodbc.connect(CONN, autocommit=True, timeout=30)
    return _spojeni


def ring(text):
    body = []
    for par in text.split(","):
        c = par.split()
        if len(c) >= 2:
            body.append([float(c[0]), float(c[1])])
    return body


def geometrie(wkt):
    if not wkt:
        return None
    r = [ring(m) for m in WKT_POLYGON.findall(wkt)]
    r = [x for x in r if len(x) >= 4]
    if not r:
        return None
    if wkt.upper().startswith("MULTIPOLYGON"):
        return {"type": "MultiPolygon", "coordinates": [[x] for x in r]}
    return {"type": "Polygon", "coordinates": r}


def nacti_skupiny():
    """Čte se při každém načtení stránky, aby refresh ukazoval
       skutečný stav databáze, ne stav při spuštění serveru."""
    with _zamek:
        cur = spojeni().cursor()
        cur.execute(DOTAZ_SKUPINY)
        sl = [c[0] for c in cur.description]
        out = []
        for r in cur.fetchall():
            s = dict(zip(sl, r))
            s["klic"] = (f"{s['klasifikace']}|{s['kat_uzemi']}|"
                         f"{s['druh']}|{s['jc']:.2f}")
            s["parcel"] = POCTY.get(s["klic"], 0)
            out.append(s)
        return out


POCTY = {}          # klíč skupiny -> počet parcel s geometrií


def nacti(tise=False):
    def log(*a):
        if not tise:
            print(*a)

    log("Čtu databázi…")
    with _zamek:
        cur = spojeni().cursor()

        cur.execute(DOTAZ_SKUPINY)
        log(f"  skupin: {len(cur.fetchall())}")

        cur.execute(DOTAZ_TYPY)
        typy = [{"typ": r[0], "popis": r[1], "do_medianu": int(r[2])}
                for r in cur.fetchall()]
        log(f"  typů v číselníku: {len(typy)}")

        cur.execute(DOTAZ_PARCELY, ZJEDNODUSENI_M)
        radky = cur.fetchall()

    # KN_parcel_data váže parcelu ke KAŽDÉMU řádku Valuo_data, takže
    # tatáž parcela je v tabulce tolikrát, kolik je na ní vkladů.
    # U jednotek je to 775 řádků na 59 skutečných parcel — kreslit
    # každý by znamenalo 13 polygonů přes sebe a popup jen toho
    # navrchu. Geometrie se proto dedupliguje na (skupina, gml_id)
    # a vklady se vedou zvlášť.
    prvky, videne, vklady = [], {}, {}

    for r in radky:
        k = f"{r.klasifikace}|{r.kat_uzemi}|{r.druh}|{r.jc:.2f}"
        gml = (r.gml_id[3:] if r.gml_id and r.gml_id.startswith("CP.")
               else r.gml_id)

        vklady.setdefault(k, {})[r.cislo_vkladu] = {
            "vklad":   r.cislo_vkladu,
            "datum":   r.datum,
            "cena":    r.cena,
            "jc":      r.jc,
            # u jednotky je jmenovatelem jednotkové ceny plocha
            # jednotky, plocha_podlahova_m2 se plní jen u staveb
            # jmenovatel jednotkové ceny — u každé klasifikace jiný
            # sloupec; plocha_podlahova_m2 se plní jen u staveb,
            # takže u pozemků zůstával sloupec m² prázdný
            "plocha":  (r.pl_jednotky  if r.klasifikace == "JC_JEDNOTKA"
                        else r.pl_parcel if r.klasifikace == "JC_PARCELY"
                        else r.pl_podlahova),
            "parcela": r.parcel_number,
            "gml":     gml,
            "jedn":    r.jednotka_oznaceni,
            "typ":     r.typ_jednotky,
        }

        if (k, gml) in videne:
            videne[(k, gml)]["vkladu"] += 1
            continue
        g = geometrie(r.wkt)
        if g is None:
            continue
        props = {
            "k":       k,
            "kl":      r.klasifikace,
            "parcela": r.parcel_number,
            "gml":     gml,
            "ku":      r.kat_uzemi,
            "druh":    r.druh,
            "vymera":  r.vymera,
            "jc":      r.jc,
            "vkladu":  1,
        }
        videne[(k, gml)] = props
        prvky.append({"type": "Feature", "geometry": g,
                      "properties": props})

    log(f"  řádků: {len(radky)}  →  parcel: {len(prvky)}, "
        f"vkladů: {sum(len(v) for v in vklady.values())}")

    POCTY.clear()           # plní se při každém načtení, ne kumulativně
    for p in prvky:
        k = p["properties"]["k"]
        POCTY[k] = POCTY.get(k, 0) + 1

    skupiny = nacti_skupiny()
    bez = sum(1 for s in skupiny if not s["parcel"])
    if bez:
        log(f"  skupin bez parcel: {bez}")

    seznamy = {k: sorted(v.values(), key=lambda x: x["datum"] or "")
               for k, v in vklady.items()}
    return skupiny, typy, prvky, seznamy


def zapis(klic, typ):
    """klic = 'klasifikace|kat_uzemi|druh|jc'; typ '' znamená NULL."""
    casti = klic.split("|")
    if len(casti) != 4:
        raise ValueError("neplatný klíč")
    klas, ku, druh, jc = casti
    with _zamek:
        cur = spojeni().cursor()
        cur.execute(UPDATE_TYP, (typ or None), klas, ku, druh, float(jc))
        return cur.rowcount


# ---------------------------------------------------------------
# 3. HTML
# ---------------------------------------------------------------

HTML = r"""<!doctype html>
<html lang="cs"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hromadné převody</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
:root{--bg:#f8f8f7;--panel:#fff;--line:#e3e3e0;--txt:#1a1a18;
      --dim:#6b6b66;--acc:#15803d;--warn:#b45309}
*{box-sizing:border-box}
html,body{margin:0;height:100%;font:14px/1.5 -apple-system,"Segoe UI",
      system-ui,sans-serif;color:var(--txt);background:var(--bg)}
#wrap{display:flex;height:100%}
#panel{width:540px;min-width:540px;background:var(--panel);
      border-right:1px solid var(--line);display:flex;flex-direction:column}
#map{flex:1}
header{padding:14px 16px 10px;border-bottom:1px solid var(--line)}
h1{margin:0 0 2px;font-size:16px;font-weight:600;letter-spacing:-.01em}
.sub{font-size:12px;color:var(--dim)}
#tools{padding:10px 16px;border-bottom:1px solid var(--line);
      display:flex;gap:6px}
input[type=search],select,button{font:inherit;padding:5px 8px;
      border:1px solid var(--line);border-radius:5px;background:#fff;
      color:var(--txt)}
input[type=search]{flex:1;min-width:120px}
button{cursor:pointer}
#list{flex:1;overflow-y:auto}
.g{border-bottom:1px solid var(--line)}
.gr{padding:9px 16px;cursor:pointer;display:flex;gap:8px;
      align-items:flex-start}
.gr:hover{background:#faf9f7}
.g.on>.gr{background:#f0f7f2;box-shadow:inset 3px 0 0 var(--acc)}
.g.nogeo .gt{opacity:.6}
.tw{flex:none;width:14px;color:var(--dim);font-size:11px;
      padding-top:3px;text-align:center;user-select:none}
.dot{width:9px;height:9px;border-radius:50%;flex:none;margin-top:5px}
.gi{flex:1;min-width:0}
.gt{font-weight:600;font-size:13px}
.gd{font-size:12px;color:var(--dim)}
.gq{font-size:12px;color:var(--dim);font-variant-numeric:tabular-nums}
.gb{padding:2px 16px 12px 38px}
.gm{display:grid;grid-template-columns:auto 1fr;gap:1px 10px;
      font-size:12px;margin:2px 0 8px}
.gm dt{color:var(--dim)}
.gm dd{margin:0;font-variant-numeric:tabular-nums}
.gb select{width:100%;font-size:12px;padding:5px 6px}
.ok{font-size:11px;margin-top:4px;color:var(--acc);min-height:15px}
.ok.err{color:#b91c1c}
.pt{width:100%;border-collapse:collapse;margin:9px 0 2px;font-size:11px;
      font-variant-numeric:tabular-nums}
.pt th{text-align:left;font-weight:500;color:var(--dim);
      border-bottom:1px solid var(--line);padding:3px 6px 3px 0}
.pt th:not(:first-child),.pt td:not(:first-child){text-align:right}
.pt td{padding:2px 6px 2px 0;border-bottom:1px solid var(--line)}
.pt a{color:var(--acc);font-weight:600;text-decoration:none}
.pt a:hover{text-decoration:underline}
.pn{font-size:11px;color:var(--dim);margin:3px 0 2px}
.pn b{color:var(--warn)}
#note{padding:8px 16px;background:#fffbeb;border-bottom:1px solid var(--line);
      font-size:12px;color:#854d0e}
.lbl{background:rgba(255,255,255,.9);border:1px solid var(--line);
      border-radius:3px;padding:1px 4px;font-size:11px;font-weight:600;
      box-shadow:none;white-space:nowrap}
.lbl::before{display:none}
.lbl a{color:var(--txt);text-decoration:none}
.leaflet-popup-content{font:13px/1.55 -apple-system,"Segoe UI",system-ui}
.leaflet-popup-content table{border-collapse:collapse;margin-top:4px}
.leaflet-popup-content td{padding:1px 0}
.leaflet-popup-content td:first-child{color:#6b6b66;padding-right:10px}
.pv{border-collapse:collapse;margin-top:6px;font-size:12px;
      font-variant-numeric:tabular-nums;max-height:220px}
.pv th{text-align:right;font-weight:500;color:var(--dim);
      border-bottom:1px solid var(--line);padding:2px 0 2px 10px}
.pv th:first-child,.pv td:first-child{text-align:left;padding-left:0}
.pv td{text-align:right;padding:1px 0 1px 10px}
.leaflet-popup-content .pv td:first-child{color:var(--txt)}
@media (prefers-color-scheme:dark){
 :root:not([data-theme=light]){--bg:#1c1c1a;--panel:#232321;--line:#38382f;
   --txt:#f0efe9;--dim:#a3a39b;--acc:#4ade80;--warn:#fbbf24}
 :root:not([data-theme=light]) .gr:hover{background:#2a2a27}
 :root:not([data-theme=light]) .g.on>.gr{background:#26322a}
 :root:not([data-theme=light]) input,:root:not([data-theme=light]) select,
 :root:not([data-theme=light]) button{background:#2a2a27}
 :root:not([data-theme=light]) #note{background:#2e2a1c;color:#fde68a}
 :root:not([data-theme=light]) .lbl{background:rgba(28,28,26,.9)}
}
</style></head><body>
<div id="wrap">
 <div id="panel">
  <header><h1>Hromadné převody</h1><div class="sub" id="stat"></div></header>
  __NOTE__
  <div id="tools">
   <input type="search" id="q" placeholder="území, druh, cena…">
   <select id="f">
    <option value="">vše</option>
    <option value="0">nezatříděné</option>
    <option value="1">zatříděné</option>
   </select>
  </div>
  <div id="list"></div>
 </div>
 <div id="map"></div>
</div>

<script>
const STAV    = __STAV__;
const SKUPINY = __SKUPINY__;
const GEO     = __GEO__;
const VKLADY  = __VKLADY__;
const TYPY    = __TYPY__;
const BARVY   = __BARVY__;
const KN      = __KN__;

const barva = s => BARVY[s.typ_jevu] || BARVY["null"];
const otevrene = new Set();          /* rozbalené skupiny */
let aktivni = null;                  /* zvýrazněná na mapě */
const hlaska = {};                   /* potvrzení zápisu */

/* ---------- mapa ---------- */
const map = L.map("map", {preferCanvas:true}).setView([49.8, 15.3], 7);
const T = (u, o) => L.tileLayer(u, Object.assign(
  {maxZoom:23, attribution:"&copy; ČÚZK"}, o));

const orto = T(__ORTO__, {maxNativeZoom:21}).addTo(map);
const podklady = {
  "Ortofoto ČÚZK": orto,
  "Základní mapa ČÚZK": T(__ZM__, {maxNativeZoom:18}),
};
const prekryvy = {};
if (KN.mapa)    podklady["Katastrální mapa ČÚZK"] =
  T(KN.mapa, {maxNativeZoom:20});
if (KN.hranice) prekryvy["Hranice parcel"] =
  T(KN.hranice, {maxNativeZoom:20});
L.control.layers(podklady, prekryvy,
  {position:"topright", collapsed:false}).addTo(map);

const kc = n => n == null ? "—" :
  n.toLocaleString("cs-CZ", {maximumFractionDigits:0});
const m2 = n => n == null ? "—" : kc(n) + " m²";

const KNURL = "https://nahlizenidokn.cuzk.gov.cz/ZobrazObjekt.aspx"
            + "?&typ=parcela&id=";
const odkaz = p => p.gml
  ? `<a href="${KNURL}${p.gml}" target="_blank" rel="noopener">`
    + `${p.parcela} ↗</a>`
  : p.parcela;

/* u vkladu jednotky je parcela jen poloha domu */
const jednotka = p => p.kl === "JC_JEDNOTKA";

/* V-30922/2022-101 -> 30922/2022; plné číslo zůstává v title */
const kratkyVklad = v => String(v || "")
  .replace(/^V-/, "").replace(/-\d+$/, "");

/* "jiný nebytový prostor" se do sloupce nevejde */
const kratkyTyp = t => {
  if (!t) return "";
  if (t.length <= 9) return t;
  return t.split(" ")[0].slice(0, 8) + "…";
};

/* na jedné parcele leží u jednotek i dvanáct vkladů — popup je
   proto vypíše všechny, ne jen jeden */
const popis = p => {
  const v = (VKLADY[p.k] || []).filter(x => x.gml === p.gml);
  return `<b>${p.ku} ${odkaz(p)}</b>
 <table>
  <tr><td>předmět vkladů</td><td>${jednotka(p)
    ? "<b>jednotky</b> — parcela je jen poloha domu" : p.druh}</td></tr>
  <tr><td>výměra parcely</td><td>${m2(p.vymera)}</td></tr>
  <tr><td>jedn. cena</td><td><b>${kc(p.jc)} Kč/m²</b></td></tr>
  <tr><td>vkladů na parcele</td><td><b>${v.length}</b></td></tr>
 </table>
 ${v.length ? `<table class="pv"><thead><tr>
   ${jednotka(p) ? "<th>jednotka</th>" : "<th>vklad</th>"}
   <th>m²</th><th>cena</th><th>Kč/m²</th><th>zplatnění</th>
   </tr></thead><tbody>
   ${v.map(x => `<tr title="${x.vklad}">
     <td>${jednotka(p) ? (x.jedn || x.vklad) : kratkyVklad(x.vklad)}</td>
     <td>${kc(x.plocha)}</td><td>${kc(x.cena)}</td>
     <td>${kc(x.jc)}</td><td>${x.datum}</td></tr>`).join("")}
   </tbody></table>` : ""}`;
};

const index = {};
SKUPINY.forEach(s => index[s.klic] = s);

const vrstva = L.geoJSON(GEO, {
  style: f => {
    const s = index[f.properties.k];
    const c = s ? barva(s) : BARVY["null"];
    return {color:c, weight:1.5, opacity:.9, fillColor:c, fillOpacity:.22};
  },
  onEachFeature: (f, l) => l.bindPopup(popis(f.properties)),
}).addTo(map);

const vrstvy = {};
vrstva.eachLayer(l => {
  const k = l.feature.properties.k;
  (vrstvy[k] = vrstvy[k] || []).push(l);
});

const popisky = L.layerGroup().addTo(map);
function vykresliPopisky() {
  popisky.clearLayers();
  if (!aktivni || map.getZoom() < 14) return;
  (vrstvy[aktivni] || []).forEach(l => {
    const p = l.feature.properties;
    L.tooltip({permanent:true, direction:"center", className:"lbl",
               interactive:true})
      .setLatLng(l.getBounds().getCenter())
      .setContent(p.gml ? `<a href="${KNURL}${p.gml}" target="_blank"`
        + ` rel="noopener">${p.parcela}</a>` : p.parcela)
      .addTo(popisky);
  });
}
map.on("zoomend", vykresliPopisky);

function styluj() {
  vrstva.eachLayer(l => {
    const s = index[l.feature.properties.k];
    const c = s ? barva(s) : BARVY["null"];
    const vl = l.feature.properties.k === aktivni;
    l.setStyle({color:c, fillColor:c,
      weight: vl ? 3 : 1,
      opacity: vl ? 1 : (aktivni ? .35 : .9),
      fillOpacity: vl ? .45 : (aktivni ? .08 : .22)});
    if (vl) l.bringToFront();
  });
}

function naMapu(k) {
  aktivni = k;
  styluj();
  const a = vrstvy[k];
  if (a && a.length)
    map.fitBounds(L.featureGroup(a).getBounds().pad(0.35), {maxZoom:18});
  vykresliPopisky();
}

/* ---------- seznam vkladů skupiny ----------
   Řádek je VKLAD, ne parcela. U jednotek leží desítky vkladů na
   jedné parcele, takže řazení po parcelách vypadalo, jako by
   parcel bylo dvanáct.                                        */
const parcely = {};
GEO.features.forEach(f => {
  const k = f.properties.k;
  (parcely[k] = parcely[k] || []).push(f.properties);
});

function tabulkaVkladu(k) {
  const a = VKLADY[k];
  if (!a || !a.length)
    return `<div class="pn">Bez parcel s geometrií v katastru.</div>`;
  const par = parcely[k] || [];
  const jed = a.length && par.length && jednotka(par[0]);
  return `<table class="pt">
   <thead><tr><th>vklad</th>
     ${jed ? "<th>jednotka</th><th>typ</th>" : "<th>parcela</th>"}
     <th>m²</th><th>cena</th><th>Kč/m²</th><th>zplatnění</th></tr></thead>
   <tbody>${a.map(x => `<tr title="${x.vklad}${x.typ
       ? "  ·  " + x.typ : ""}  ·  parcela ${x.parcela}">
     <td>${kratkyVklad(x.vklad)}</td>
     ${jed ? `<td><b>${x.jedn || "—"}</b></td>
              <td>${kratkyTyp(x.typ)}</td>`
           : `<td>${odkaz(x)}</td>`}
     <td>${kc(x.plocha)}</td><td>${kc(x.cena)}</td>
     <td><b>${kc(x.jc)}</b></td><td>${x.datum}</td></tr>`).join("")}</tbody>
   </table>
   <div class="pn">${a.length} vkladů na ${par.length} parcel${jed
     ? ` · parcela ${par.map(p => odkaz(p)).join(", ")} je poloha domu`
     : ""}</div>`;
}

/* ---------- zápis do databáze ---------- */
async function uloz(s, typ, el) {
  el.textContent = "ukládám…";
  el.className = "ok";
  const stop = new AbortController();
  const hodiny = setTimeout(() => stop.abort(), 40000);
  try {
    const r = await fetch("/zatridit", {
      method:"POST", headers:{"Content-Type":"application/json"},
      body: JSON.stringify({klic:s.klic, typ:typ}),
      signal: stop.signal,
    });
    clearTimeout(hodiny);
    const d = await r.json();
    if (!r.ok || !d.ok) throw new Error(d.chyba || ("HTTP " + r.status));
    s.typ_jevu = typ || null;
    hlaska[s.klic] = typ
      ? `zapsáno do databáze: ${typ}`
      : "zatřídění zrušeno v databázi";
    styluj(); kresli();
  } catch (e) {
    clearTimeout(hodiny);
    el.className = "ok err";
    el.textContent = e.name === "AbortError"
      ? "nezapsáno: databáze neodpověděla do 40 s — zkus znovu"
      : "nezapsáno: " + e.message;
  }
}

/* ---------- panel ---------- */
const list = document.getElementById("list");
const stat = document.getElementById("stat");

function kresli() {
  const q = document.getElementById("q").value.trim().toLowerCase();
  const f = document.getElementById("f").value;
  list.innerHTML = "";

  const zat = SKUPINY.filter(s => s.typ_jevu).length;
  stat.textContent = `${zat} ze ${SKUPINY.length} zatříděno · `
    + `načteno ${STAV}`;

  SKUPINY.forEach(s => {
    const t = s.typ_jevu;
    if (f === "0" && t) return;
    if (f === "1" && !t) return;
    if (q && !`${s.kat_uzemi} ${s.druh} ${s.jc} ${s.klasifikace}`
             .toLowerCase().includes(q)) return;

    const open = otevrene.has(s.klic);
    const d = document.createElement("div");
    d.className = "g" + (s.klic === aktivni ? " on" : "")
                + (s.parcel ? "" : " nogeo");

    const roky = s.rok_max > s.rok_min ? `${s.rok_min}–${s.rok_max}`
                                       : `${s.rok_min}`;
    const plochy = s.pl_min == null ? "—"
      : (s.pl_min === s.pl_max ? m2(s.pl_min)
         : `${kc(s.pl_min)}–${kc(s.pl_max)} m²`);

    d.innerHTML = `
     <div class="gr">
      <span class="tw">${open ? "▾" : "▸"}</span>
      <span class="dot" style="background:${barva(s)}"></span>
      <span class="gi">
       <span class="gt">${s.kat_uzemi}</span>
       <span class="gd">${s.druh}</span>
       <div class="gq">${kc(s.jc)} Kč/m² · ${s.vkladu} vkladů${t
         ? " · " + t : ""}</div>
      </span>
     </div>
     ${open ? `<div class="gb">
      <dl class="gm">
       <dt>medián území</dt><dd>${kc(s.median)}${s.pomer!=null
         ? `  ·  poměr ${s.pomer.toFixed(2)}` : ""}</dd>
       <dt>plochy</dt><dd>${plochy}</dd>
       <dt>ceny</dt><dd>${kc(s.cena_min)}–${kc(s.cena_max)} Kč</dd>
       <dt>roky</dt><dd>${roky}${s.katastru > 1
         ? `  ·  táž cena v ${s.katastru} k.ú.` : ""}</dd>
      </dl>
      <select>
       <option value="">— nezatříděno —</option>
       ${TYPY.map(x => `<option value="${x.typ}"${x.typ===t
         ? " selected":""}>${x.typ}${x.do_medianu
         ? " (zůstává v mediánu)" : ""}</option>`).join("")}
      </select>
      <div class="ok">${hlaska[s.klic] || ""}</div>
      ${tabulkaVkladu(s.klic)}
     </div>` : ""}`;

    /* rozbalení a sbalení nezávisle na mapě */
    d.querySelector(".gr").addEventListener("click", () => {
      if (otevrene.has(s.klic)) { otevrene.delete(s.klic); }
      else { otevrene.add(s.klic); naMapu(s.klic); }
      kresli();
    });

    const sel = d.querySelector("select");
    if (sel) {
      sel.addEventListener("click", e => e.stopPropagation());
      sel.addEventListener("change", e =>
        uloz(s, e.target.value, d.querySelector(".ok")));
    }
    list.appendChild(d);
  });
}

document.getElementById("q").addEventListener("input", kresli);
document.getElementById("f").addEventListener("change", kresli);

kresli();
if (GEO.features.length) map.fitBounds(vrstva.getBounds().pad(0.08));
</script></body></html>
"""


# ---------------------------------------------------------------
# 4. SERVER
# ---------------------------------------------------------------

def diagnostika(ku):
    """Vypíše přesně to, co jde do stránky, pro jedno území."""
    print(f"Verze skriptu: s diagnostikou a časem načtení\n")
    skupiny, typy, prvky, vklady = nacti()

    moje = [s for s in skupiny if s["kat_uzemi"] == ku]
    if not moje:
        print(f"\nV území {ku} není žádná skupina. Dostupná území:")
        uz = sorted({s["kat_uzemi"] for s in skupiny})
        print("  " + ", ".join(uz[:40]))
        return

    print(f"\n{'=' * 66}")
    print(f"SKUPINY V {ku.upper()}")
    print(f"{'=' * 66}")
    for s in moje:
        print(f"\nskupina {s['druh']} / {s['jc']:.2f} Kč/m²"
              f"  ({s['vkladu']} vkladů, {s['parcel']} parcel)")
        print(f"  klíč: {s['klic']}")
        print(f"  typ:  {s['typ_jevu'] or '(nezatříděno)'}")

        g = [f["properties"] for f in prvky
             if f["properties"]["k"] == s["klic"]]
        print(f"  parcely nakreslené na mapě ({len(g)}):")
        for p in g:
            print(f"    {p['parcela']:<12} gml {p['gml']:<14}"
                  f" {p['vymera']:>9.0f} m²  vkladů {p['vkladu']}")

        v = vklady.get(s["klic"], [])
        print(f"  vklady v tabulce ({len(v)}), prvních 5:")
        for x in v[:5]:
            print(f"    {x['vklad']:<20} parcela {x['parcela']:<12}"
                  f" {x['datum']}")
    print(f"\n{'=' * 66}")
    print("Je-li tu všude správná parcela a v prohlížeči jiná,")
    print("posílá stránku jiný program nebo jiná verze skriptu.")
    print(f"{'=' * 66}")


def stranka(kn, note):
    """Složí HTML z aktuálního stavu databáze."""
    skupiny, typy, prvky, vklady = nacti(tise=True)
    stav = (f"{datetime.now():%H:%M:%S} · {len(prvky)} parcel · "
            f"{sum(len(v) for v in vklady.values())} vkladů")
    return (HTML
        .replace("__STAV__", json.dumps(stav))
        .replace("__SKUPINY__", json.dumps(skupiny, ensure_ascii=False,
                                           default=str))
        .replace("__GEO__", json.dumps(
            {"type": "FeatureCollection", "features": prvky},
            ensure_ascii=False))
        .replace("__VKLADY__", json.dumps(vklady, ensure_ascii=False,
                                          default=str))
        .replace("__TYPY__", json.dumps(typy, ensure_ascii=False))
        .replace("__BARVY__", json.dumps(
            {("null" if k is None else k): v for k, v in BARVY.items()}))
        .replace("__ORTO__", json.dumps(ORTOFOTO))
        .replace("__ZM__", json.dumps(ZAKLADNI))
        .replace("__KN__", json.dumps(kn, ensure_ascii=False))
        .replace("__NOTE__", note)).encode("utf-8")


class Server(ThreadingHTTPServer):
    # Na Windows smí při allow_reuse_address poslouchat na jednom
    # portu několik procesů naráz a požadavky se mezi ně rozdělují
    # nepředvídatelně. Zapomenutý starý běh pak odpovídá starými
    # daty a vypadá to jako chyba v datech. Tohle to zakáže:
    # druhý server na témže portu rovnou spadne.
    allow_reuse_address = False


class Handler(BaseHTTPRequestHandler):
    kn = {}             # šablony dlaždic ČÚZK, zjištěné při startu
    note = ""

    def log_message(self, *a):
        pass

    def _posli(self, kod, typ, telo):
        self.send_response(kod)
        self.send_header("Content-Type", typ)
        self.send_header("Content-Length", str(len(telo)))
        # bez tohohle prohlížeč podstrčí při refreshi starou stránku
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.end_headers()
        self.wfile.write(telo)

    def do_GET(self):
        if self.path.split("?")[0] not in ("/", "/index.html"):
            self._posli(404, "text/plain; charset=utf-8", b"neni")
            return
        try:
            # Všechno se čte teď, ne při startu serveru. Dřív se při
            # startu načetla i geometrie, takže po smazání cizích
            # parcel kreslil refresh dál ty staré.
            self._posli(200, "text/html; charset=utf-8",
                        stranka(self.kn, self.note))
        except Exception as e:
            print(f"  CHYBA čtení: {e}")
            self._posli(500, "text/html; charset=utf-8",
                        f"<h1>Databáze nedostupná</h1><pre>{e}</pre>"
                        .encode("utf-8"))

    def do_HEAD(self):
        self._posli(200, "text/html; charset=utf-8", b"")

    def do_POST(self):
        if self.path != "/zatridit":
            self._posli(404, "application/json", b'{"ok":false}')
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            d = json.loads(self.rfile.read(n) or b"{}")
            radku = zapis(d.get("klic", ""), d.get("typ", ""))
            if radku != 1:
                raise RuntimeError(f"UPDATE změnil {radku} řádků, čekal 1")
            print(f"  zapsáno: {d['klic']} -> "
                  f"{d.get('typ') or '(nezatříděno)'}")
            odp = {"ok": True, "radku": radku}
        except Exception as e:
            print(f"  CHYBA zápisu: {e}")
            odp = {"ok": False, "chyba": str(e)}
        telo = json.dumps(odp, ensure_ascii=False).encode()
        self._posli(200 if odp["ok"] else 500,
                    "application/json; charset=utf-8", telo)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8111)
    ap.add_argument("--bez-prohlizece", action="store_true")
    ap.add_argument("--diagnostika", metavar="KU",
                    help="vypíše, co se posílá do stránky pro to "
                         "katastrální území, a skončí")
    a = ap.parse_args()

    if a.diagnostika:
        diagnostika(a.diagnostika)
        return

    try:
        skupiny, typy, prvky, vklady = nacti()
    except pyodbc.ProgrammingError as e:
        if "typ_jevu" in str(e) or "median_lokality" in str(e) \
                or "CIS_typy_hromadneho_prevodu" in str(e):
            sys.exit("Chybí sloupce nebo číselník z kroku 23b.\n"
                     "Spusť nejdřív 23b_zatrideni_prevodu.sql.")
        raise
    if not skupiny:
        sys.exit("Valuo_hromadne_prevody je prázdná — spusť "
                 "23_hromadne_prevody.sql.")

    print("Načítám vrstvy katastrální mapy ČÚZK…")
    kn = sablony_kn()
    print(f"  {kn['info']}")
    note = "" if kn["mapa"] else (
        f'<div id="note">Katastrální mapa ČÚZK nedostupná: '
        f'{kn["info"]}. Ortofoto a základní mapa fungují.</div>')

    # Vrstvy ČÚZK se zjišťují jednou (síťový dotaz), data z databáze
    # při každém načtení stránky.
    Handler.kn = kn
    Handler.note = note

    adresa = f"http://127.0.0.1:{a.port}/"
    try:
        srv = Server(("127.0.0.1", a.port), Handler)
    except OSError as e:
        sys.exit(f"Port {a.port} už někdo obsadil ({e}).\n"
                 f"Nejspíš tam běží starší spuštění tohoto skriptu —\n"
                 f"ukonči ho, nebo zvol jiný port:\n"
                 f"    python 23c_mapa_prevodu.py --port {a.port + 1}")
    print(f"\nMapa běží na {adresa}")
    print("Zatřídění se zapisuje do databáze hned při výběru.")
    print("Zastavíš Ctrl+C.\n")

    if not getattr(a, "bez_prohlizece", False):
        threading.Timer(0.6, lambda: webbrowser.open(adresa)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nKonec.")
        srv.shutdown()


if __name__ == "__main__":
    main()
