# VERZE 4 - Kompletní integrace cen, jednotkových cen (JC) a ÚP do DataFrame a Excelu
# AUTOMATIZOVANÉ STAŽENÍ A VYKRESLENÍ PARCEL (RÚIAN / WFS INSPIRE)

import re
import requests
import pandas as pd
from lxml import etree
from pyproj import Transformer
import folium
from shapely.geometry import Polygon
from branca.element import MacroElement
from jinja2 import Template
from folium.map import Layer
from IPython.display import HTML, display
import urllib.parse
from sqlalchemy import create_engine

# =============================================================================
# 0. PŘIPOJENÍ K DATABÁZI A POMOCNÉ FUNKCE PRO HISTORII
# =============================================================================

# Připojení k DB Valuo pomocí SQLAlchemy
params_conn = urllib.parse.quote_plus(
    "Driver={ODBC Driver 17 for SQL Server};"
    "Server=localhost;"
    "Database=VALUO;"
    "Trusted_Connection=yes;"
)
connection_url = f"mssql+pyodbc:///?odbc_connect={params_conn}"
engine = create_engine(connection_url)

def get_valuo_history(okres: str, ku: str, parcelni_cislo: str, db_engine) -> dict:
    """
    Vyhledá historii parcely v DB Valuo.
    Vrací slovník s HTML výstupem pro popup, zjištěným kódem UP, max cenou a jednotkovou cenou (JC).
    """
    vystup = {
        "html": "<i style='color:gray;'>Záznam v databázi Valuo nenalezen.</i>",
        "up": "Nezjištěno",
        "max_cena": None,
        "jc": None  # NOVÉ: Inicializace jednotkové ceny
    }

    db_okres = okres
    if okres.lower().strip() in ["praha", "hlavni metro praha", "praha-mesto", "praha město"]:
        db_okres = "Hlavní město Praha"
        
    def zformatuj_parcely(kombi_series, max_zobrazeno=5):
        items = set([str(i).strip() for i in kombi_series.dropna() if str(i).strip() and str(i).strip() != '|'])
        if not items:
            return ""
        
        links = []
        for item in sorted(items, key=lambda x: x.split('|')[0]):
            parts = item.split('|')
            p_num = parts[0]
            p_kod = parts[1] if len(parts) > 1 else ""
            
            if p_kod and p_kod.isdigit():
                url = f"https://nahlizenidokn.cuzk.gov.cz/ZobrazObjekt.aspx?&typ=parcela&id={p_kod}"
                links.append(f"<a href='{url}' target='_blank' style='color:#0066cc; text-decoration:none; font-weight:bold;' title='Otevřít v KN'>{p_num}</a>")
            else:
                links.append(p_num)
                
        plny_seznam = ", ".join(links)
        
        if len(links) > max_zobrazeno:
            nahled = ", ".join(links[:max_zobrazeno])
            zbyva = len(links) - max_zobrazeno
            return (
                f"<details style='cursor: pointer; margin-top: 2px;'>"
                f"<summary style='outline: none; color: #555;'>{nahled} ... <b style='color: #d9534f;'>(+ {zbyva} rozbalit)</b></summary>"
                f"<div style='margin-top: 4px; padding: 6px; border-left: 2px solid #d9534f; background: #f4f4f4; color: #333; line-height: 1.4; word-wrap: break-word;'>"
                f"{plny_seznam}</div>"
                f"</details>"
            )
        return plny_seznam
    
    # 1. Krok: Získání čísel vkladů
    query_vklady = f"""
        SELECT DISTINCT v.cislo_vkladu
        FROM Valuo_data v
        JOIN KN_parcel_data p ON v.id = p.id_valuo
        WHERE v.okres = '{db_okres}' 
          AND v.kat_uzemi = '{ku}' 
          AND p.parcel_number = '{parcelni_cislo}'
    """
    try:
        df_vklady = pd.read_sql(query_vklady, db_engine)
    except Exception as e:
        vystup["html"] = f"<div style='color:red;'>Chyba prvního dotazu: {e}</div>"
        return vystup
        
    if df_vklady.empty:
        return vystup
        
    vklady_list = tuple(df_vklady['cislo_vkladu'].tolist())
    vklady_str = f"('{vklady_list[0]}')" if len(vklady_list) == 1 else str(vklady_list)
        
    # 2. Krok: Dotaz pro detaily vkladu, GML_ID a ÚZEMNÍ PLÁN (UP)
    query_details = f"""
                SELECT DISTINCT 
                    v.id, 
                    p.id_UP_FVU_data,
                    v.cislo_vkladu, 
                    CONVERT(VARCHAR(10), v.datum_podani, 104) AS datum_podani, 
                    CAST(v.cenovy_udaj AS FLOAT) AS cenovy_udaj, 
                    v.nemovitost, 
                    CAST(v.plocha AS FLOAT) AS plocha,
                    CAST(p.parcel_number AS VARCHAR(100)) + '|' + ISNULL(REPLACE(CAST(p.gml_id AS VARCHAR(100)), 'CP.', ''), '') AS parcel_data_kombi,
                    u.POPIS_Z as UP
                FROM Valuo_data v
                LEFT JOIN KN_parcel_data p ON v.id = p.id_valuo
                LEFT JOIN [dbo].[UP_FVU_data] u ON p.id_UP_FVU_data = u.id
                WHERE v.cislo_vkladu IN {vklady_str}
    """
    
    try:
        df_details = pd.read_sql(query_details, db_engine)
    except Exception as e:
        vystup["html"] = f"<div style='color:red;'>Chyba pro stahování detailů vkladu: {e}</div>"
        return vystup
    
    if df_details.empty:
        return vystup

    # Extrakce kódu územního plánu (UP)
    up_kod = "Nezjištěno"
    for _, r in df_details.iterrows():
        kombi = str(r.get('parcel_data_kombi', ''))
        p_num = kombi.split('|')[0].strip()
        if p_num == str(parcelni_cislo).strip() and pd.notnull(r.get('UP')):
            up_kod = str(r['UP']).strip()
            break
    vystup["up"] = up_kod

    max_cena = df_details['cenovy_udaj'].max()
    vystup["max_cena"] = max_cena
    
    # 3. Krok: Zpracování HTML výstupu a extrakce JC
    html_output = ""
    jc_pro_max_cenu = None

    for vklad, group in df_details.groupby('cislo_vkladu'):
        datum = str(group['datum_podani'].iloc[0]) if pd.notnull(group['datum_podani'].iloc[0]) else "Neznámé"
        cena = float(group['cenovy_udaj'].max()) 
        
        stats = group.groupby('nemovitost').agg(
            pocet=('id', 'count'),
            plocha_sum=('plocha', 'sum'),
            seznam_parcel=('parcel_data_kombi', lambda x: zformatuj_parcely(x, max_zobrazeno=5))
        ).reset_index()
        
        celkova_plocha = stats['plocha_sum'].sum()
        jc = cena / celkova_plocha if celkova_plocha > 0 else 0
        
        # Pokud se jedná o hlavní/nejvyšší transakci, uložíme její jednotkovou cenu pro Excel
        if cena == max_cena:
            jc_pro_max_cenu = jc
        
        html_output += f"<div style='background: #f9f9f9; border: 1px solid #ccc; padding: 5px; margin-bottom: 5px;'>"
        url_rizeni = "https://nahlizenidokn.cuzk.gov.cz/VyberRizeni.aspx"
        odkaz_vklad = f"<a href='{url_rizeni}' target='_blank' style='color:#0066cc; text-decoration:none; font-weight:bold;'>{vklad}</a>"
        html_output += f"<b>Řízení:</b> {odkaz_vklad} (ze dne {datum})<br>"
        html_output += f"<b>Kupní cena:</b> {cena:,.0f} Kč<br>".replace(',', ' ')
        html_output += f"<b>JC: {jc:,.0f} Kč/m²</b> (z plochy {celkova_plocha:,.0f} m²)<br>".replace(',', ' ')
        html_output += "<i style='font-size: 11px;'>Složení transakce:</i><br>"
        
        for _, r in stats.iterrows():
            html_output += f"<span style='font-size: 11px;'>- {r['nemovitost']}: {r['pocet']}x ({r['plocha_sum']:,.0f} m²)</span><br>".replace(',', ' ')
            if r['seznam_parcel']:
                html_output += f"<div style='font-size: 10px; margin-left: 12px; margin-top: 1px; margin-bottom: 4px;'>Parc. č.: {r['seznam_parcel']}</div>"
        html_output += "</div>"
        
    vystup["html"] = html_output
    vystup["jc"] = jc_pro_max_cenu  # Zápis JC do návratové struktury
    return vystup

# =============================================================================
# 1. TŘÍDY A FUNKCE PRO VYKRESLOVÁNÍ MAPY (FOLIUM)
# =============================================================================

class BindClickRemove(MacroElement):
    def __init__(self, fg_poly_name: str, fg_text_name: str, gj_name: str, mk_name: str):
        super().__init__()
        self.fg_poly_name = fg_poly_name
        self.fg_text_name = fg_text_name
        self.gj_name = gj_name
        self.mk_name = mk_name
        self._template = Template(
            """
            {% macro script(this, kwargs) %}
            {{ this.gj_name }}.on('contextmenu', function(e) {
                {{ this.fg_poly_name }}.removeLayer({{ this.gj_name }});
                {{ this.fg_text_name }}.removeLayer({{ this.mk_name }});
            });
            {% endmacro %}
            """
        )

class DynamicArcGISTileLayer(Layer):
    _template = Template(u"""
        {% macro script(this, kwargs) %}
            var {{ this.get_name() }} = new (L.TileLayer.extend({
                getTileUrl: function(coords) {
                    var tileSize = 1024; 
                    var initialResolution = 2 * Math.PI * 6378137 / tileSize;
                    var originShift = 2 * Math.PI * 6378137 / 2.0;
                    var resolution = initialResolution / Math.pow(2, coords.z);
                    
                    var minx = coords.x * tileSize * resolution - originShift;
                    var maxx = (coords.x + 1) * tileSize * resolution - originShift;
                    var miny = originShift - (coords.y + 1) * tileSize * resolution;
                    var maxy = originShift - coords.y * tileSize * resolution;
                    var bbox = [minx, miny, maxx, maxy].join(",");
                    
                    return "{{ this.url }}?bbox=" + bbox +
                           "&bboxSR=102100&imageSR=102100&size=" + tileSize + "," + tileSize +
                           "&format=png32&transparent=true&layers=show:0&f=image";
                }
            }))({
                opacity: {{ this.opacity }},
                minZoom: {{ this.min_zoom }},
                maxZoom: {{ this.max_zoom }},
                tileSize: 1024
            });
            {{ this.get_name() }}.addTo({{ this._parent.get_name() }});
        {% endmacro %}
    """)
    
    def __init__(self, url, opacity=0.5, min_zoom=10, max_zoom=18):
        super().__init__()
        self._name = 'DynamicArcGISTileLayer'
        self.url = url
        self.opacity = opacity
        self.min_zoom = min_zoom
        self.max_zoom = max_zoom

DISTINCT_COLORS = [
    "#e6194b", "#3cb44b", "#ffe119", "#4363d8", "#f58231",
    "#911eb4", "#46f0f0", "#f032e6", "#bcf60c", "#fabebe",
    "#008080", "#e6beff", "#9a6324", "#fffac8", "#800000",
    "#aaffc3", "#808000", "#ffd8b1", "#000075", "#808080"
]

def plot_parcels_on_map(df_parcel_data: pd.DataFrame) -> folium.Map:
    transformer = Transformer.from_crs("EPSG:5514", "EPSG:4326", always_xy=True)

    if "LV" not in df_parcel_data.columns:
        df_parcel_data["LV"] = "Neznámé"

    unique_lvs = df_parcel_data["LV"].astype(str).unique()
    lv_color_map = {lv: DISTINCT_COLORS[i % len(DISTINCT_COLORS)] for i, lv in enumerate(unique_lvs)}

    items = []
    legend_list_items = "" 

    for idx, row in df_parcel_data.iterrows():
        posList_str = row.get("geometry_posList")
        if not posList_str or pd.isna(posList_str):
            continue

        coords = list(map(float, posList_str.split()))
        xy_pairs = list(zip(coords[0::2], coords[1::2]))
        lon_lat_pairs = [transformer.transform(x, y) for x, y in xy_pairs]

        poly = Polygon(lon_lat_pairs)
        if not poly.is_valid or poly.is_empty:
            continue

        centroid = (poly.centroid.y, poly.centroid.x)
        parc_label = row.get("label", "")
        area = row.get("areaValue_m2", None)
        lv = str(row.get("LV", "Neznámé"))
        okres = row.get("okres_nazev", "Neznámý")
        ku = row.get("ku_nazev", "Neznámé")
        ku_kod = row.get("ku_kod", "")
        obec_nazev = row.get("obec_nazev", "Neznámá")
        obec_kod = row.get("obec_kod", "")
        info_text = str(row.get("info", "")) 
        druh_pozemku = row.get("druh_pozemku", "Nezjištěno")
        
        up_code = row.get("UP", "Nezjištěno")
        db_info_html = row.get("valuo_html", "")

        color = lv_color_map[lv]
        area_str = f"{float(area):,.0f}".replace(",", " ") if pd.notna(area) else "neznámá výměra"

        gml_id_raw = str(row.get("gml_id", ""))
        clean_id = gml_id_raw.replace("CP.", "")
        url_kn = f"https://nahlizenidokn.cuzk.gov.cz/ZobrazObjekt.aspx?&typ=parcela&id={clean_id}"
        
        popup_html = f"""
        <div style='font-family: sans-serif; font-size: 13px; width: 340px; line-height: 1.4;'>
            <h4 style='margin: 0 0 5px 0; border-bottom: 2px solid {color}; padding-bottom: 3px;'>
                Parcela č. <a href='{url_kn}' target='_blank' style='color:#0066cc; text-decoration:none;'>{parc_label}</a> (LV: {lv} | UP: {up_code})
            </h4>
            <b>Druh pozemku:</b> {druh_pozemku}<br>
            <b>Výměra:</b> {area_str} m²<br>
            <b>K.Ú.:</b> {ku} ({ku_kod})<br>
            <b>Obec:</b> {obec_nazev} ({obec_kod})<br>
            <b>Okres:</b> {okres}<br>
            <hr style='border: 0; border-top: 1px solid #ccc; margin: 8px 0;'>
            <h5 style='margin: 0 0 5px 0;'>Historie transakcí (Valuo DB)</h5>
            {db_info_html}
        </div>
        """
       # Popisek polygonu v mapě-------------------------------------
        #label_html = f"LV č. {lv}<br>{parc_label}<br>{area_str} m²"
        label_html = f"vklad č. {lv}<br>{parc_label}<br>{area_str} m²"

        items.append((poly, centroid, label_html, color, popup_html))


        # LEGENDA - vymena popisu jako LV / vklad atd     
        legend_list_items += (
            f"<li style='margin-bottom: 12px; border-bottom: 1px solid #e0e0e0; padding-bottom: 6px;'>"
            f"<span style='display:inline-block; width:14px; height:14px; background-color:{color}; border:1px solid #333; margin-right:8px; vertical-align:middle;'></span>"
            f"<span style='vertical-align:middle; font-family:sans-serif;'>"
            f"LV č.{lv}, parc.č. <a href='{url_kn}' target='_blank' style='font-weight:bold; color:#0066cc; text-decoration:none;'>{parc_label}</a>, {area_str} m², okres {okres}, k.ú. {ku} [ÚP: {up_code}]"
            f"</span>"
            f"<div style='margin-left: 26px; margin-top: 4px; font-size: 11.5px; color: #444; font-style: italic; line-height: 1.4;'>{info_text}</div>"
            f"</li>"
        )

    if not items:
        print("Nebyla nalezena žádná validní geometrie, vracím defaultní mapu ČR.")
        return folium.Map(location=[49.8, 15.5], zoom_start=7)

    m = folium.Map(location=[sum(c[0] for _, c, _, _, _ in items) / len(items), sum(c[1] for _, c, _, _, _ in items) / len(items)], zoom_start=18, tiles=None, width="100%", height="100%", closePopupOnClick=False)

    folium.TileLayer("CartoDB positron", name="Základní mapa (světlá)", control=True).add_to(m)
    folium.raster_layers.TileLayer(tiles="https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}", attr="© Google", name="Google Maps", overlay=False, control=True).add_to(m)
    folium.raster_layers.TileLayer(tiles="https://ags.cuzk.gov.cz/arcgis1/rest/services/ORTOFOTO_WM/MapServer/tile/{z}/{y}/{x}", name="ČÚZK Ortofoto", attr="© ČÚZK", overlay=False, control=True, max_zoom=20, min_zoom=6, show=False).add_to(m)
    folium.raster_layers.TileLayer(tiles="https://ags.cuzk.gov.cz/arcgis1/rest/services/ZTM_WM/MapServer/tile/{z}/{y}/{x}", attr="© ČÚZK", name="Základní topografická mapa (ČÚZK)", overlay=False, control=True, show=False).add_to(m)

    arcgis_url = "https://gs-pub.praha.eu/arcgis/rest/services/pup/uzemni_plan_platny/MapServer/export"
    dynamic_fg = folium.FeatureGroup(name="Územní plán Prahy – plán využití", overlay=True, control=True, show=False)
    dynamic_fg.add_child(DynamicArcGISTileLayer(arcgis_url, opacity=0.5, min_zoom=10, max_zoom=19))
    m.add_child(dynamic_fg)

    fg_poly = folium.FeatureGroup(name="Polygony parcel", show=True)
    fg_text = folium.FeatureGroup(name="Popisky parcel (text)", show=True)
    fg_poly_name = fg_poly.get_name()
    fg_text_name = fg_text.get_name()

    for poly, centroid, label_html, color, popup_html in items:
        popup_okno = folium.Popup(html=popup_html, max_width=420, max_height=350, auto_close=False)
        gj = folium.GeoJson(data=poly.__geo_interface__, style_function=lambda feature, c=color: {"fillColor": c, "color": c, "weight": 2, "fillOpacity": 0.4}, tooltip="<b>Levý klik:</b> Detaily <br><b>Pravý klik:</b> Smazat polygon", popup=popup_okno).add_to(fg_poly)
        mk = folium.Marker(location=centroid, draggable=True, icon=folium.DivIcon(icon_size=(150, 54), icon_anchor=(75, 27), html=(f'<div style="font-size:10px; font-weight:bold; line-height: 1.2; text-align:center; color: black; text-shadow: 2px 2px 4px white, -1px -1px 0 white, 1px -1px 0 white, -1px 1px 0 white, 1px 1px 0 white;">{label_html}</div>'))).add_to(fg_text)
        gj.add_child(BindClickRemove(fg_poly_name=fg_poly_name, fg_text_name=fg_text_name, gj_name=gj.get_name(), mk_name=mk.get_name()))

    fg_poly.add_to(m)
    fg_text.add_to(m)
    folium.LayerControl(collapsed=False).add_to(m)

    legend_html_container = f"""
    <div style="position: fixed; bottom: 30px; left: 30px; width: auto; max-width: 1250px; max-height: 1000px; background-color: rgba(255, 255, 255, 0.95); border: 2px solid #aaa; z-index: 9999; overflow-y: auto; padding: 10px; border-radius: 8px; box-shadow: 3px 3px 10px rgba(0,0,0,0.3);"><h4 style="margin-top: 0; margin-bottom: 10px; font-family: sans-serif; border-bottom: 2px solid #444; padding-bottom: 5px;">Zobrazené pozemky</h4><ul style="list-style-type: none; padding-left: 0; margin: 0; font-size: 10px;">{legend_list_items}</ul></div>
    """
    m.get_root().html.add_child(folium.Element(legend_html_container))
    return m

# =============================================================================
# 2. FUNKCE PRO DOTAZOVÁNÍ RÚIAN A INSPIRE
# =============================================================================

def convert_to_gps(x: float, y: float, source_epsg: str = "EPSG:5514") -> tuple[float, float]:
    transformer = Transformer.from_crs(source_epsg, "EPSG:4326", always_xy=True)
    return transformer.transform(x, y)

def get_parcel_data(okres_nazev: str, kat_uzemi_nazev: str, parcel_number: str) -> pd.DataFrame:
    PRAGUE_OBEC_KOD = 554782
    PRAGUE_VUSC_KOD = 19
    PRAGUE_ALIASES = {"praha", "hlavni metro praha", "hlavní město praha", "praha-mesto", "praha město"}

    def _norm(s: str) -> str: return (s or "").strip().lower()
    def _is_prague_okres(name: str) -> bool: return _norm(name) in PRAGUE_ALIASES
    def _sql_escape(s: str) -> str: return (s or "").replace("'", "''")

    base_url_candidates = ["https://ags.cuzk.gov.cz/arcgis/rest/services/RUIAN/Prohlizeci_sluzba_nad_daty_RUIAN/MapServer", "https://ags.cuzk.cz/ArcGIS/rest/services/RUIAN/MapServer"]
    session = requests.Session()

    def arcgis_query(base_url: str, layer_id: int, where: str, out_fields: str = "*") -> dict:
        params = {"where": where, "outFields": out_fields, "returnGeometry": "false", "f": "json"}
        r = session.get(f"{base_url}/{layer_id}/query", params=params, timeout=30)
        r.raise_for_status()
        data = r.json()
        if isinstance(data, dict) and data.get("error"): raise RuntimeError(f"ArcGIS error: {data['error'].get('message')}")
        return data

    def arcgis_query_first_ok(layer_id: int, where: str, out_fields: str = "*") -> dict:
        last_err = None
        for base_url in base_url_candidates:
            try: return arcgis_query(base_url, layer_id, where, out_fields=out_fields)
            except Exception as e: last_err = e
        raise RuntimeError(f"Chyba RÚIAN ArcGIS: {last_err}")

    praha_mode = _is_prague_okres(okres_nazev)
    okres_kod = None

    if not praha_mode:
        okres_data = arcgis_query_first_ok(layer_id=15, where=f"nazev = '{_sql_escape(okres_nazev)}'", out_fields="*")
        if not okres_data.get("features"): raise ValueError(f"Okres '{okres_nazev}' nebyl nalezen.")
        okres_kod = okres_data["features"][0]["attributes"].get("kod")

    ku_data = arcgis_query_first_ok(layer_id=7, where=f"nazev LIKE '{_sql_escape(kat_uzemi_nazev)}%'", out_fields="kod,nazev,obec")
    if not ku_data.get("features"): raise ValueError(f"K.Ú. '{kat_uzemi_nazev}' nebylo nalezeno.")

    valid_ku = []
    for f in ku_data["features"]:
        ku_atr = f["attributes"]
        obec_kod = ku_atr.get("obec")
        if obec_kod is None: continue
        obec_data = arcgis_query_first_ok(layer_id=12, where=f"kod = {int(obec_kod)}", out_fields="kod,nazev,okres")
        if not obec_data.get("features"): continue
        obec_atr = obec_data["features"][0]["attributes"]

        if praha_mode and int(obec_atr.get("kod", -1)) == PRAGUE_OBEC_KOD:
            valid_ku.append({"ku_kod": ku_atr.get("kod"), "ku_nazev": ku_atr.get("nazev"), "obec_kod": obec_atr.get("kod"), "obec_nazev": obec_atr.get("nazev")})
        elif not praha_mode and obec_atr.get("okres") == okres_kod:
            valid_ku.append({"ku_kod": ku_atr.get("kod"), "ku_nazev": ku_atr.get("nazev"), "obec_kod": obec_atr.get("kod"), "obec_nazev": obec_atr.get("nazev")})

    if not valid_ku: raise ValueError(f"Nebylo nalezeno žádné platné K.Ú.")
    selected_ku = valid_ku[0]

    if praha_mode:
        vusc_data = arcgis_query_first_ok(layer_id=17, where=f"kod = {PRAGUE_VUSC_KOD}", out_fields="kod,nazev")
        vusc_attrs = vusc_data["features"][0]["attributes"]
        okres_kod_out, okres_nazev_out = None, okres_nazev
    else:
        okres2 = arcgis_query_first_ok(layer_id=15, where=f"kod = {int(okres_kod)}", out_fields="kod,nazev,vusc")
        okres_attrs = okres2["features"][0]["attributes"]
        vusc_data = arcgis_query_first_ok(layer_id=17, where=f"kod = {int(okres_attrs.get('vusc'))}", out_fields="kod,nazev")
        vusc_attrs = vusc_data["features"][0]["attributes"]
        okres_kod_out, okres_nazev_out = okres_attrs.get("kod"), okres_attrs.get("nazev")

    params_wfs = {"service": "WFS", "version": "2.0.0", "request": "GetFeature", "storedQuery_id": "GetParcel", "UPPER_ZONING_ID": selected_ku["ku_kod"], "TEXT": parcel_number}
    resp_wfs = session.get("https://services.cuzk.cz/wfs/inspire-CP-wfs.asp", params=params_wfs, timeout=30)
    resp_wfs.raise_for_status()

    tree = etree.fromstring(resp_wfs.content)
    ns = {"wfs": "http://www.opengis.net/wfs/2.0", "gml": "http://www.opengis.net/gml/3.2", "CP": "http://inspire.ec.europa.eu/schemas/cp/4.0", "base": "http://inspire.ec.europa.eu/schemas/base/3.3"}
    parcel_elem = tree.find(".//CP:CadastralParcel", namespaces=ns)
    if parcel_elem is None: raise ValueError(f"Parcela {parcel_number} nebyla nalezena.")

    def get_text(elem, path):
        sub = elem.find(path, namespaces=ns)
        return sub.text.strip() if sub is not None and sub.text else None

    parcel_data = {
        "gml_id": parcel_elem.get("{http://www.opengis.net/gml/3.2}id"), "areaValue_m2": float(get_text(parcel_elem, "CP:areaValue") or 0),
        "beginLifespanVersion": get_text(parcel_elem, "CP:beginLifespanVersion"), "endLifespanVersion": get_text(parcel_elem, "CP:endLifespanVersion"),
        "label": get_text(parcel_elem, "CP:label"), "nationalCadastralReference": get_text(parcel_elem, "CP:nationalCadastralReference"),
        "inspire_localId": get_text(parcel_elem, "CP:inspireId/base:Identifier/base:localId"), "inspire_namespace": get_text(parcel_elem, "CP:inspireId/base:Identifier/base:namespace"),
        "refPoint_x": None, "refPoint_y": None, "refPoint_lon": None, "refPoint_lat": None,
        "geometry_posList": get_text(parcel_elem, "CP:geometry/gml:Polygon/gml:exterior/gml:LinearRing/gml:posList"),
        "ku_kod": selected_ku["ku_kod"], "ku_nazev": selected_ku["ku_nazev"], "obec_kod": selected_ku["obec_kod"], "obec_nazev": selected_ku["obec_nazev"],
        "okres_kod": okres_kod_out, "okres_nazev": okres_nazev_out, "vusc_kod": vusc_attrs.get("kod"), "vusc_nazev": vusc_attrs.get("nazev"),
    }

    ref_point = get_text(parcel_elem, "CP:referencePoint/gml:Point/gml:pos")
    if ref_point:
        coords = ref_point.split()
        if len(coords) >= 2:
            parcel_data["refPoint_x"], parcel_data["refPoint_y"] = float(coords[0]), float(coords[1])
            parcel_data["refPoint_lon"], parcel_data["refPoint_lat"] = convert_to_gps(float(coords[0]), float(coords[1]))

    druh_pozemku_text = "Nezjištěno"
    try:
        raw_id = parcel_data.get("inspire_localId", "") or parcel_data.get("gml_id", "")
        match_id = re.search(r'\d+', raw_id)
        if match_id:
            url_kn = f"https://nahlizenidokn.cuzk.gov.cz/ZobrazObjekt.aspx?&typ=parcela&id={match_id.group()}"
            res_kn = session.get(url_kn, headers={"User-Agent": "Mozilla/5.0"}, timeout=10)
            if res_kn.status_code == 200:
                match_druh = re.search(r'Druh pozemku:[\s\S]*?<td[^>]*>(.*?)</td>', res_kn.text, re.IGNORECASE)
                if match_druh: druh_pozemku_text = re.sub(r'<[^>]+>', '', match_druh.group(1)).strip()
    except Exception as e: print(f"Chyba stahování druhu pozemku: {e}")

    parcel_data["druh_pozemku"] = druh_pozemku_text
    return pd.DataFrame([parcel_data])

# =============================================================================
# 3. HLAVNÍ BLOK: ZPRACOVÁNÍ VSTUPŮ A VÝSTUP
# =============================================================================

parcely = [

# POZ - Křížkový Újezdec

#pm

("Praha-východ", "Křížkový Újezdec", "834/2", "V-9802/2024-209", "SV - návrh"),
("Praha-východ", "Křížkový Újezdec", "67", "V-10317/2024-209", "SV, SV - návrh"),
("Praha-východ", "Křížkový Újezdec", "68/1", "V-10317/2024-209", "SV, SV - návrh"),

("Praha-východ", "Sulice", "874/99", "V-2687/2025-209", "BI"),
("Praha-východ", "Sulice", "874/16", "V-9676/2024-209", "BI"),
("Praha-východ", "Sulice", "874/101", "V-7112/2024-209", "BI"),
("Praha-východ", "Sulice", "675/5", "V-13792/2023-209", "BI"),
("Praha-východ", "Sulice", "418/30", "V-2373/2023-209", "BI - návrh"),

("Praha-východ", "Radějovice", "301/74", "V-7451/2026-209", "SV"),

("Praha-východ", "Velké Popovice", "69/44", "V-16868/2025-209", "BI"),

#("Praha-východ", "Křížkový Újezdec", "st. 10/1", "3 - rodinný dům č.p.21", "SV - smíšené obytné"),
#("Praha-východ", "Křížkový Újezdec", "14/4", "3 - rodinný dům č.p.21", "SV - smíšené obytné"),

#("Praha-východ", "Křížkový Újezdec", "739", "komunikace (přístup k RD)", "DS - doprava silniční"),

#("Praha-východ", "Křížkový Újezdec", "17/1", "3 - stavební pozemek", "SV - smíšené obytné"),
#("Praha-východ", "Křížkový Újezdec", "793", "3 - stavební pozemek", "SV - smíšené obytné - návrh (Z.2)"),

#("Praha-východ", "Křížkový Újezdec", "14/3", "3 - přírodní / zeleň", "NU - přírodní všeobecné (lokální biokoridor)"),

#("Praha-východ", "Křížkový Újezdec", "888", "3 - přírodní / zeleň", "NU - přírodní všeobecné"),



#("Praha-východ", "Křížkový Újezdec", "st. 149", "3 - zemědělská výroba", "VZ - výroba zemědělská (stavba jiného vlastníka (hala))"),
#("Praha-východ", "Křížkový Újezdec", "st. 151", "3 - zemědělská výroba", "VZ - výroba zemědělská (nezapsaná stavba (ZDŘ))"),
#("Praha-východ", "Křížkový Újezdec", "1003", "3 - zemědělská výroba", "VZ - výroba zemědělská (betonová nádrž)"),
#("Praha-východ", "Křížkový Újezdec", "981", "3 - zemědělská výroba", "VZ - výroba zemědělská"),

#("Praha-východ", "Křížkový Újezdec", "786", "3 - zemědělský pozemek", "AU - zemědělské všeobecné"),

#("Praha-východ", "Křížkový Újezdec", "771", "3 - zemědělský pozemek", "AU - zemědělské všeobecné"),

#("Praha-východ", "Křížkový Újezdec", "877", "3 - zemědělský pozemek", "AU - zemědělské všeobecné"),


#("Praha-východ", "Křížkový Újezdec", "920", "3 - stavební pozemek / zemědělský pozemek", "SV - smíšené obytné - návrh (Z.13b),  AU - zemědělské všeobecné"),

# POZ - Mokrovousy

#("Hradec Králové", "Mokrovousy", "119/62", "580 - stavební", "návrhový plocha pro bydlení BV"),
#("Hradec Králové", "Mokrovousy", "119/109", "580 - stavební", "návrhový plocha pro bydlení BV"),
#("Hradec Králové", "Mokrovousy", "119/110", "580 - stavební", "návrhový plocha pro bydlení BV"),
#("Hradec Králové", "Mokrovousy", "119/111", "580 - stavební", "návrhový plocha pro bydlení BV"),
#("Hradec Králové", "Mokrovousy", "119/112", "580 - stavební", "návrhový plocha pro bydlení BV"),
#("Hradec Králové", "Mokrovousy", "119/113", "580 - stavební", "návrhový plocha pro bydlení BV"),
#("Hradec Králové", "Mokrovousy", "119/114", "580 - stavební", "návrhový plocha pro bydlení BV"),
#("Hradec Králové", "Mokrovousy", "119/127", "580 - komunikace", "návrhový plocha pro bydlení BV"),
#("Hradec Králové", "Mokrovousy", "119/128", "580 - komunikace", "návrhový plocha pro bydlení BV"),
#("Hradec Králové", "Mokrovousy", "119/129", "580 - komunikace", "návrhový plocha pro bydlení BV"),

# POZ - Beroun

#("Beroun", "Beroun", "1410/48", "9744 - stavební", "19 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/49", "9744 - stavební", "18 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/52", "9744 - komunikace", "komunikace"),
#("Beroun", "Beroun", "1410/54", "9744 - stavební", "14 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/55", "9744 - stavební", "13 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/56", "9744 - stavební", "12 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/58", "9744 - stavební", "3 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/59", "9744 - stavební", "4 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/60", "9744 - stavební", "5 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/62", "9744 - komunikace", "komunikace"),
#("Beroun", "Beroun", "1410/65", "9744 - komunikace", "komunikace"),
#("Beroun", "Beroun", "1410/66", "9744 - stavební", "1 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/67", "9744 - stavební", "10 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/69", "9744 - komunikace", "komunikace"),
#("Beroun", "Beroun", "1410/70", "9744 - stavební", "15 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/221", "9744 - stavební", "6 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/222", "9744 - stavební", "7 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/223", "9744 - stavební", "8 - stavební parcela, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "1410/224", "9744 - komunikace", "komunikace"),
#("Beroun", "Beroun", "1410/250", "9744 - stavební", "2 - část stavební parcely, ÚP - rozvojová plocha (P.1a), [BI]"),
#("Beroun", "Beroun", "2272/6", "9744 - komunikace", "komunikace"),


# PM POZ - Smíchov
#("Praha", "Dejvice", "2204", "V-90981/2017-101", "JC = 1037 Kč/m2"),
#("Praha", "Dejvice", "2206/1", "V-90981/2017-101", "JC = 1037 Kč/m2"),


#("Praha", "Hloubětín", "2447", "V-37726/2022-101", "JC = 192 Kč/m2"),
#("Praha", "Hloubětín", "2452", "V-37726/2022-101", "JC = 192 Kč/m2"),
#("Praha", "Hloubětín", "2627", "V-37726/2022-101", "JC = 192 Kč/m2"),
#("Praha", "Hloubětín", "2628", "V-37726/2022-101", "JC = 192 Kč/m2"),


#("Praha", "Horní Počernice", "228/1", "V-69847/2023-101", "JC = 133 Kč/m2"),
#("Praha", "Horní Počernice", "4417/1", "V-69847/2023-101", "JC = 133 Kč/m2"),
#("Praha", "Horní Počernice", "906/15", "V-69847/2023-101", "JC = 133 Kč/m2"),

#("Praha", "Horní Počernice", "3967", "V-74360/2024-101", "JC = 497 Kč/m2"),


#("Praha", "Hostivař", "1714/3", "V-31225/2022-101", "JC = 608 Kč/m2"),

#("Praha", "Hostivař", "1714/3", "V-31226/2022-101", "JC = 608 Kč/m2"),

#("Praha", "Hostivař", "2365/1", "V-75546/2024-101", "JC = 102 Kč/m2"),
#("Praha", "Hostivař", "2365/3", "V-75546/2024-101", "JC = 102 Kč/m2"),
#("Praha", "Hostivař", "2366", "V-75546/2024-101", "JC = 102 Kč/m2"),
#("Praha", "Hostivař", "514/2", "V-75546/2024-101", "JC = 102 Kč/m2"),
#("Praha", "Hostivař", "514/3", "V-75546/2024-101", "JC = 102 Kč/m2"),
#("Praha", "Hostivař", "514/4", "V-75546/2024-101", "JC = 102 Kč/m2"),
#("Praha", "Hostivař", "514/5", "V-75546/2024-101", "JC = 102 Kč/m2"),
#("Praha", "Hostivař", "514/6", "V-75546/2024-101", "JC = 102 Kč/m2"),
#("Praha", "Hostivař", "537/41", "V-75546/2024-101", "JC = 102 Kč/m2"),


#("Praha", "Kunratice", "2340/1", "V-198/2022-101", "JC = 159 Kč/m2"),


#("Praha", "Ruzyně", "1364", "V-59949/2021-101", "JC = 159 Kč/m2"),
#("Praha", "Ruzyně", "1365", "V-59949/2021-101", "JC = 159 Kč/m2"),
#("Praha", "Ruzyně", "1366", "V-59949/2021-101", "JC = 159 Kč/m2"),
#("Praha", "Ruzyně", "1367", "V-59949/2021-101", "JC = 159 Kč/m2"),
#("Praha", "Ruzyně", "1368", "V-59949/2021-101", "JC = 159 Kč/m2"),


#("Praha", "Strašnice", "4089/1", "V-20063/2024-101", "JC = 415 Kč/m2"),
#("Praha", "Strašnice", "4091/1", "V-20063/2024-101", "JC = 415 Kč/m2"),
#("Praha", "Strašnice", "4095/1", "V-20063/2024-101", "JC = 415 Kč/m2"),

#("Praha", "Strašnice", "4092/3", "V-53551/2025-101", "JC = 319 Kč/m2"),


#("Praha", "Šeberov", "1401/106", "V-24012/2025-101", "JC = 216 Kč/m2"),
#("Praha", "Šeberov", "1409/4", "V-24012/2025-101", "JC = 216 Kč/m2"),
#("Praha", "Šeberov", "1409/5", "V-24012/2025-101", "JC = 216 Kč/m2"),
#("Praha", "Šeberov", "718/9", "V-24012/2025-101", "JC = 216 Kč/m2"),


#("Praha", "Vokovice", "1092", "V-31151/2024-101", "JC = 365 Kč/m2"),
#("Praha", "Vokovice", "695/1", "V-31151/2024-101", "JC = 365 Kč/m2"),
#("Praha", "Vokovice", "695/2", "V-31151/2024-101", "JC = 365 Kč/m2"),
#("Praha", "Vokovice", "695/3", "V-31151/2024-101", "JC = 365 Kč/m2"),




# DATACENTRUM Krč
#    ("Praha", "Krč", "2537/3", "551 - Technologická část", "Technologická část"),   # u žel. mostu, přidáno dle požadavku

#    ("Praha", "Krč", "2543/1", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2543/15", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2543/2", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2543/3", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2543/4", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2543/5", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2543/6", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2545/2", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2545/4", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2545/5", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2545/6", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2545/9", "551 - Technologická část", "Technologická část"),

#    ("Praha", "Krč", "2547", "551 - Farma - Zahradnictví", "Farma - Zahradnictví"),
#    ("Praha", "Krč", "2544/2", "551 - Farma - Zahradnictví", "Farma - Zahradnictví"),
#    ("Praha", "Krč", "2545/1", "551 - Technologická část (20 147 m2) + Farma - Zahradnictví (28 900 m2)", "Technologická část (20 147 m2) + Farma - Zahradnictví (28 900 m2)"),        
#    ("Praha", "Krč", "2545/3", "551 - Technologická část", "Technologická část"),
#    ("Praha", "Krč", "2546/1", "551 - Farma - Zahradnictví", "Farma - Zahradnictví"),
#    ("Praha", "Krč", "2546/2", "551 - Farma - Zahradnictví", "Farma - Zahradnictví"),
#    ("Praha", "Krč", "2544/1", "551 - Farma - Zahradnictví", "Farma - Zahradnictví"),        

#    ("Praha", "Braník", "2722/3", "6859 - Technologická část", "Technologická část"),        
#    ("Praha", "Braník", "2722/2", "6859 - Technologická část", "Technologická část"),        
#    ("Praha", "Braník", "2721/2", "6859 - Technologická část", "Technologická část"),        
#    ("Praha", "Braník", "2709/9", "6859 - Technologická část", "Technologická část"),        
#    ("Praha", "Braník", "2709/1", "6859 - Technologická část", "Technologická část"),        

# Smíchov - Skalka
#    ("Praha", "Smíchov", "4606/3", "2981", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4745", "2981", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4759/2", "2981", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4761/3", "10882", "Součková Alena MUDr., - podíl = 251181/2160000"),
#    ("Praha", "Smíchov", "4752/1", "8093", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4671/15", "14715", "Součková Alena MUDr., - podíl = 0/1"),
#    ("Praha", "Smíchov", "4671/16", "14715", "Součková Alena MUDr., - podíl = 0/1"),
#    ("Praha", "Smíchov", "4670/5", "5142", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4688/9", "10881", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4752/2", "12737", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4733/10", "14803", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4669", "2938", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4671/14", "14292", "Součková Alena MUDr., - podíl = 0/1"),
#    ("Praha", "Smíchov", "4748/5", "2820", "Součková Alena MUDr., - podíl = 3240/27864"),
#    ("Praha", "Smíchov", "4761/1", "2820", "Součková Alena MUDr., - podíl = 3240/27864"),
#    ("Praha", "Smíchov", "4735", "13890", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4733/2", "13890", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4744", "13890", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4757", "13890", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4760", "13890", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4758", "13890", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4759/1", "13890", "Součková Alena MUDr., - podíl = 1/9"),
#    ("Praha", "Smíchov", "4761/2", "13890", "Součková Alena MUDr., - podíl = 1/9"),
]

dfs = []
print("Načítám data z API ČÚZK...")

for okres, ku, parc, lv, info in parcely:
    try:
        df_one = get_parcel_data(okres, ku, parc)
        df_one["LV"] = str(lv); df_one["info"] = str(info)
        dfs.append(df_one)
    except ValueError as ve: print(f"⚠️ Upozornění: {ve} (k.ú. {ku}) -> Přeskakuji."); continue
    except Exception as e: print(f"❌ Chyba API pro parcelu {parc}: {e} -> Přeskakuji."); continue

if not dfs:
    print("❌ Kritická chyba: Nepodařilo se stáhnout data pro žádnou zadanou parcelu.")
else:
    df_parcel_data = pd.concat(dfs, ignore_index=True)

    print("Dotazuji DB Valuo pro získání cen, jednotkových cen (JC) a kódů územního plánu (UP)...")
    valuo_html_list, up_list, max_cena_list, jc_list = [], [], [], []
    
    for idx, row in df_parcel_data.iterrows():
        vysledek_valuo = get_valuo_history(row.get("okres_nazev", "Neznámý"), row.get("ku_nazev", "Neznámé"), row.get("label", ""), engine)
        
        valuo_html_list.append(vysledek_valuo["html"])
        up_list.append(vysledek_valuo["up"])
        max_cena_list.append(vysledek_valuo["max_cena"])
        jc_list.append(vysledek_valuo["jc"])  # NOVÉ: Sběr JC z databáze

    # Zápis všech dat přímo do hlavního DataFrame
    df_parcel_data["valuo_html"] = valuo_html_list
    df_parcel_data["UP"] = up_list
    df_parcel_data["Valuo_Max_Cena_Kč"] = max_cena_list
    df_parcel_data["Valuo_JC_Kč_m2"] = jc_list  # NOVÉ: Uložení JC do DataFrame

    # Příprava exportního přehledu včetně obou nových ekonomických ukazatelů
    df_export = (
        df_parcel_data
        .assign(parcelni_cislo=lambda d: d["label"], lat=lambda d: d["refPoint_lat"], lon=lambda d: d["refPoint_lon"])
        .loc[:, ["okres_nazev", "ku_nazev", "obec_nazev", "parcelni_cislo", "LV", "UP", "Valuo_Max_Cena_Kč", "Valuo_JC_Kč_m2", "info", "lat", "lon"]]
        .rename(columns={
            "okres_nazev": "okres", "ku_nazev": "katastralni_uzemi", "obec_nazev": "obec",
            "Valuo_Max_Cena_Kč": "max_cena_valuo",
            "Valuo_JC_Kč_m2": "jc_valuo_Kč_m2"  # NOVÉ: Pojmenování sloupce v Excelu
        })
    )

    df_export["lat"] = df_export["lat"].round(8); df_export["lon"] = df_export["lon"].round(8)

    out_path = "parcely_gps.xlsx"
    df_export.to_excel(out_path, index=False, sheet_name="parcely_gps")
    print(f"Data úspěšně uložena do: {out_path} (obsahuje sloupce max_cena_valuo i jc_valuo_Kč_m2)")

    print("Generuji mapu...")
    m = plot_parcels_on_map(df_parcel_data)
    html_file = "mapa_parcel.html"
    m.save(html_file)
    print(f"Interaktivní mapa uložena do: {html_file}")
    display(HTML(m._repr_html_()))