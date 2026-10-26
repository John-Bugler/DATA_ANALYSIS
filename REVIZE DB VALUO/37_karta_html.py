# -*- coding: utf-8 -*-
"""
37_karta_html.py — karta vkladu jako HTML stránka
=================================================
Databáze: VALUO        Krok: 37        Datum: 24. 10. 2026

K čemu to je
------------
Vezme jeden nebo více vkladů, načte je z databáze a uloží ke každému
HTML kartu — tu interaktivní s přepínatelnými mapovými vrstvami. Dosud
se karty generovaly z ručně vypsaných ukázkových dat; tohle čte přímo
z v_Valuo_karta_vkladu, takže funguje na libovolný vklad.

Je to zároveň první polovina plánované aplikace: vykreslení karty.
Druhá polovina, tedy výběr vkladů v mapě a koš, přijde nad tímto.

Předpoklad
----------
Pro daný vklad musí být spočítaná karta, jinak nemá parcely:

    EXEC dbo.sp_prepocet_karty_okoli @kod_ku = ...   -- jednou za k. ú.
    EXEC dbo.sp_prepocet_karty @cislo_vkladu = ...
    EXEC dbo.sp_prepocet_karty_tvar

Proč běží na počítači znalce
----------------------------
Potřebuje databázi. Mapové podklady se stahují až v prohlížeči, takže
samotné generování je rychlé.

Stavby po parcelách
-------------------
Která budova stojí na které parcele se bere z RÚIAN přes parcela_id,
ne prostorovým průnikem. Prostorový dotaz vracel u řadovek osm domů
na jednu parcelu, protože STIntersects chytá i sousedy přes společnou
zeď, a navíc RUIAN_stavebni_objekty nemá prostorový index, takže to
skenovalo celou tabulku. Řetěz KN.gml_id -> RUIAN_parcely.kod_parcely
-> RUIAN_stavebni_objekty.parcela_id jede po indexech a vrací přesně
tu budovu, kterou RÚIAN k parcele vede.

Spuštění
--------
    python 37_karta_html.py V-76414/2024-101
    python 37_karta_html.py V-20873/2025-101 V-24135/2024-101 --slozka karty

Pozor: otevřít výslednou stránku rovnou ze souboru (file://) prohlížeč
nemusí zvládnout kvůli CORS. Ve složce s kartami spusť
    python -m http.server 8000
a otevři http://localhost:8000/.

Závislosti: sqlalchemy nebo pyodbc (sdílí je s 35_export_word.py).
"""

import argparse
import datetime
import decimal
import importlib.util
import io
import json
import os
import re
import sys

ZDE = os.path.dirname(os.path.abspath(__file__))


def nacti_export():
    """Datovou vrstvu sdílí s 35_export_word.py, ať je SQL na jednom místě."""
    cesta = os.path.join(ZDE, "35_export_word.py")
    if not os.path.exists(cesta):
        raise SystemExit(f"Vedle tohoto skriptu chybí 35_export_word.py ({cesta}).")
    spec = importlib.util.spec_from_file_location("export_word", cesta)
    modul = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modul)
    return modul


EX = nacti_export()

SQL_STAVBY = """
SELECT kp.parcel_number, so.kod_so,
       ts.nazev  AS typ,        zv.nazev  AS vyuziti,
       so.dokonceni,
       so.zastavena_plocha AS zp, so.podlahova_plocha AS pp,
       so.obestaveny_prostor AS op,
       so.pocet_podlazi AS podlazi, so.pocet_bytu AS bytu,
       dk.nazev  AS konstrukce,  vyt.nazev AS vytapeni, vzd.nazev AS vytah,
       pvo.nazev AS voda,        pka.nazev AS kanalizace, ppl.nazev AS plyn,
       so.pomer_pp_op AS pomer
FROM dbo.Valuo_karta_parcely kp
JOIN dbo.KN_parcel_data kn   ON kn.id = kp.kn_id
JOIN dbo.RUIAN_parcely rp    ON rp.gml_id = kn.gml_id
JOIN dbo.RUIAN_stavebni_objekty so ON so.parcela_id = rp.kod_parcely
LEFT JOIN dbo.CIS_RUIAN ts  ON ts.ciselnik  = 'TypStavebnihoObjektu' AND ts.kod  = so.typ_so_kod
LEFT JOIN dbo.CIS_RUIAN zv  ON zv.ciselnik  = 'ZpusobVyuzitiObjektu' AND zv.kod  = so.zpusob_vyuziti_kod
LEFT JOIN dbo.CIS_RUIAN dk  ON dk.ciselnik  = 'DruhKonstrukce'       AND dk.kod  = so.druh_konstrukce_kod
LEFT JOIN dbo.CIS_RUIAN vyt ON vyt.ciselnik = 'ZpusobVytapeni'       AND vyt.kod = so.zpusob_vytapeni_kod
LEFT JOIN dbo.CIS_RUIAN vzd ON vzd.ciselnik = 'VybaveniVytahem'      AND vzd.kod = so.vybaveni_vytahem_kod
LEFT JOIN dbo.CIS_RUIAN pvo ON pvo.ciselnik = 'PripojeniVody'        AND pvo.kod = so.pripojeni_vodovod_kod
LEFT JOIN dbo.CIS_RUIAN pka ON pka.ciselnik = 'PripojeniKanalizace'  AND pka.kod = so.pripojeni_kanalizace_kod
LEFT JOIN dbo.CIS_RUIAN ppl ON ppl.ciselnik = 'PripojeniPlynu'       AND ppl.kod = so.pripojeni_plyn_kod
WHERE kp.cislo_vkladu = :v
ORDER BY so.zastavena_plocha DESC
"""


def _json_prevod(x):
    """Databáze vrací decimal.Decimal a datum; json ani jedno neumí."""
    if isinstance(x, decimal.Decimal):
        return float(x)
    if isinstance(x, (datetime.date, datetime.datetime)):
        return x.isoformat()
    raise TypeError(f"json neumí {type(x).__name__}")


def _cislo(x):
    """Decimal -> float, ať se s tím dá počítat i ve formátovacích řetězcích."""
    return float(x) if isinstance(x, decimal.Decimal) else x


def _d(h, k, vychozi=None):
    v = h.get(k, vychozi)
    return vychozi if v is None else v


# Registr zdrojů plochy, naplní ho volající (aplikace nebo export) před
# sestavením karty. Prázdno není chyba — jen se tabulka nevypíše.
PLOCHY = {}


def v_z_view(r, parcel_celkem):
    """Řádek pohledu -> slovník, se kterým umí pracovat šablona karty."""
    datum = r.get("datum_zplatneni")
    jednotka = r.get("jednotka_oznaceni")
    druh = r.get("hlavni_druh") or ""
    if jednotka:
        druh = f"{druh}, jednotka č. {jednotka}".strip(", ")
    return {
        "klas": r.get("klasifikace") or "",
        "druh": druh or "pozemek",
        "adresa": r.get("hlavni_adresa") or "",
        "ku": r.get("kat_uzemi") or "",
        "obec": r.get("obec") or "",
        "datum": datum.strftime("%d. %m. %Y") if datum else "—",
        "cena": r.get("cena_Kc"),
        "nem": r.get("nemovitosti_ve_vkladu"),
        "pozn": r.get("hlavni_popis") or "",
        "slozeni": r.get("slozeni_vkladu") or "",
        "budov": r.get("pocet_budov"), "jednotek": r.get("pocet_jednotek"),
        "parcel": parcel_celkem,
        "v_celek": r.get("vymera_vyhradni_celek"),
        "v_mimo": r.get("vymera_vyhradni_mimo"),
        "v_podil": r.get("vymera_podilova"),
        "v_dle_podilu": r.get("vymera_podilova_dle_podilu"),
        "v_neoveren": r.get("vymera_neoverena"),
        "v_vse": r.get("vymera_pozemku_vse"),
        "p_podil": r.get("parcel_podilovych"),
        "rok": r.get("ruian_rok"), "rok_presny": r.get("ruian_rok_presny"),
        "zp": r.get("ruian_zastavena_plocha"), "pp": r.get("ruian_podlahova_plocha"),
        "op": r.get("ruian_obestaveny_prostor"),
        "podlazi": r.get("ruian_pocet_podlazi"), "bytu": r.get("ruian_pocet_bytu"),
        "konstrukce": r.get("ruian_druh_konstrukce"),
        "vytapeni": r.get("ruian_vytapeni"), "vytah": r.get("ruian_vytah"),
        "vod": r.get("pripojeni_vodovod_kod"),
        "kan": r.get("pripojeni_kanalizace_kod"),
        "plyn": r.get("pripojeni_plyn_kod"),
        "pasmo": r.get("ruian_pasmo"), "pomer": r.get("ruian_pomer_pp_op"),
        "jc_pp": r.get("jc_Kc_m2_podlahova"),
        "jc_nosne": r.get("jc_Kc_m2_nosne_vymery"),
        "jc_s_podilem": r.get("jc_Kc_m2_s_podilem"),
        "jc_celek": r.get("jc_Kc_m2_vyhradni_celek"),
        "jc_vse": r.get("jc_Kc_m2_vsech_pozemku"),
        "jc_m3": r.get("jc_Kc_m3"),
        "nosna_nemovitost": r.get("nosna_nemovitost"),
        "vymera_nosna": r.get("vymera_nosna"),
        "parcel_nosnych": r.get("parcel_nosnych"),
        "vymera_podilu": r.get("vymera_podilu"),
        "nalez_vice_nosnych": r.get("nalez_vice_nosnych"),
        "nalez_bez_plochy": r.get("nalez_bez_plochy"),
        "plocha_karty": r.get("plocha_podlahova_karty"),
        "plocha_zdroj": r.get("plocha_podlahova_zdroj"),
        "pouzitelnost": r.get("pouzitelnost"),
        "pouzitelnost_duvod": r.get("pouzitelnost_duvod"),
        "plocha_rucne": r.get("plocha_rucne"),
        "plocha_rucne_zdroj": r.get("plocha_rucne_zdroj"),
        "nalez_plocha_cely_dum": r.get("nalez_plocha_cely_dum"),
        "nalez_plocha_z_podilu": r.get("nalez_plocha_z_podilu"),
        "plocha_z_podilu": r.get("plocha_z_podilu"),
        "plocha_na_byt": r.get("plocha_na_byt"),
        "nalez_skala": r.get("nalez_skala"),
        "plocha_navrh": r.get("plocha_navrh"),
        "plocha_navrh_zdroj": r.get("plocha_navrh_zdroj"),
        "nosna_skupina": r.get("nosna_skupina"),
        "nosny_typ": r.get("nosny_typ"),
        "radku_nosnych": r.get("radku_nosnych"),
        "radku_mimo": r.get("radku_mimo"),
        "rozpusteno": r.get("rozpusteno"),
        "jc_verdikt": r.get("jc_verdikt"),
        "jc_median_ku": r.get("jc_median_ku"),
        "jc_vzorku_ku": r.get("jc_vzorku_ku"),
        "nalez_plocha_mimo_ocekavani": r.get("nalez_plocha_mimo_ocekavani"),
        "nalezu_rucne": r.get("nalezu_rucne"),
        "poznamek": r.get("poznamek"),
        "je_jednotka": bool(r.get("pocet_jednotek") or 0) or r.get("klasifikace") == "JC_JEDNOTKA",
        "tvar": {
            "pp_celku": r.get("pp_index_celku"), "pp_vse": r.get("pp_index_vse"),
            "plocha_celku": r.get("plocha_celku_m2"), "obvod_celku": r.get("obvod_celku_m"),
            "casti_celku": r.get("casti_celku"), "casti_vse": r.get("casti_vse"),
        },
    }


def par_z_view(radky):
    """Řádky parcel -> n-tice v pořadí, které šablona rozbaluje."""
    out = []
    for p in radky:
        wkt = (p.get("wkt") or "")
        wkt = wkt.replace("POLYGON ((", "").replace("MULTIPOLYGON (((", "")
        wkt = wkt.split("))")[0].split(")")[0]
        out.append((
            p["parcel_number"], _cislo(p.get("vymera_m2")), EX.druh_parcely(p),
            p.get("vlastnictvi"), p.get("prostorova_role"), p.get("je_kotva"),
            p.get("komponenta"), p.get("hlavnich_nemovitosti"),
            p.get("vkladu_s_parcelou"), p.get("je_druh_komunikace"),
            _cislo(p.get("kompaktnost")), _cislo(p.get("prum_sirka_m")),
            p.get("tvar_cesty"), p.get("cizich_se_stavbou"),
            _cislo(p.get("podil_odhad")), _cislo(p.get("vymera_dle_podilu")),
            _cislo(p.get("vzdalenost_od_kotvy_m")),
            p.get("sporna"), p.get("duvod"), p.get("gml_id"), wkt))
    return out


def fvu_z_view(radky):
    out = {}
    for f in radky:
        out.setdefault(f["parcel_number"], []).append(
            (f.get("fvu_kod"), f.get("POPIS_Z"), f.get("skupina"),
             _cislo(f.get("podil_pct")), _cislo(f.get("prunik_m2"))))
    return out


def stavby_z_view(radky):
    """Na parcele může stát víc budov; bere se ta s největší zastavěnou plochou."""
    out = {}
    for s in radky:
        pn = s["parcel_number"]
        if pn in out:
            continue
        dok = s.get("dokonceni")
        out[pn] = dict(
            kod_so=s.get("kod_so"), typ=s.get("typ"), vyuziti=s.get("vyuziti"),
            dokonceni=dok.strftime("%d. %m. %Y") if dok else None,
            zp=s.get("zp"), pp=s.get("pp"), op=s.get("op"),
            podlazi=s.get("podlazi"), bytu=s.get("bytu"),
            konstrukce=s.get("konstrukce"), vytapeni=s.get("vytapeni"),
            vytah=s.get("vytah"), voda=s.get("voda"),
            kanalizace=s.get("kanalizace"), plyn=s.get("plyn"),
            pomer=s.get("pomer"))
    return out


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


def kc(v, des=0):
    if v is None: return "—"
    s = f"{v:,.{des}f}".replace(",", " ").replace(".", ",")
    return s

def m2(v):
    return "—" if v is None else kc(v) + " m²"

BARVY = {
  ("výhradní","kotva"):     ("#0F6E56", "Dům / hlavní nemovitost"),
  ("výhradní","celek"):     ("#1D9E75", "Výhradní, funkční celek"),
  ("výhradní","oddělená"):  ("#378ADD", "Výhradní, mimo celek"),
  ("podílová","celek"):     ("#BA7517", "Podíl, přilehlá"),
  ("podílová","oddělená"):  ("#EF9F27", "Podíl, nepřilehlá"),
  ("neověřeno","celek"):    ("#A32D2D", "Neověřeno"),
  ("neověřeno","oddělená"): ("#A32D2D", "Neověřeno"),
}
def barva(vl, pr):
    return BARVY.get((vl, pr), ("#888780", "Ostatní"))[0]

def html_karta(vk, v, par):
    body = []
    polys = []
    for (pn, vym, druh, vl, pr, kotva, kompc, hl, vkl, kom, kmp, sir, tvar,
         stav, podil, dle_p, vzd, sporna, duvod, gml, wkt) in par:
        coords = [[float(b), float(a)] for a, b in
                  (p.split() for p in wkt.split(","))]
        polys.append(dict(pn=pn, vym=vym, druh=druh, vl=vl, pr=pr, kotva=bool(kotva),
            fvu=(FVU.get(vk) or {}).get(pn) or [],
            stavba=(STAVBY.get(vk) or {}).get(pn),
            kompc=kompc, hl=hl, vkl=vkl, kom=bool(kom), kmp=kmp, sir=sir,
            tvar=bool(tvar), stav=stav, podil=podil, dle_p=dle_p, vzd=vzd,
            sporna=bool(sporna), duvod=duvod, gml=gml,
            barva=barva(vl, pr), coords=coords))

    # --- metriky ---
    # Hlavička se řídí tím, co se prodávalo. U souboru pozemků nemá smysl
    # ukazovat podlahovou plochu a výhradní celek — byly by tam tři pomlčky
    # a jediná spočtená cena by zůstala schovaná dole v tabulce.
    tv = v["tvar"] or {}
    cena_tile = ("Cena vkladu", kc(v["cena"]) + " Kč")
    if v["je_jednotka"]:
        met = [cena_tile,
               ("Plocha jednotky", m2(v["plocha_karty"]) if v.get("plocha_karty") else "—"),
               ("Kč/m² podlahové", kc(v["jc_pp"]) if v["jc_pp"] else "—"),
               ("Dům — bytů", kc(v["bytu"]) if v["bytu"] else "—"),
               ("Pozemek domu", m2(v["v_vse"]))]
    elif not (v["pp"] or v["zp"] or v["rok"]):          # samotné pozemky
        met = [cena_tile,
               ("Výměra pozemků", m2(v["v_vse"])),
               ("Kč/m² pozemků", kc(v["jc_vse"]) if v["jc_vse"] else "—"),
               ("Parcel", kc(v["parcel"]) if v["parcel"] else "—"),
               ("Samostatných částí",
                kc(tv.get("casti_vse")) if tv.get("casti_vse") else "—")]
    else:
        met = [cena_tile,
               ("Podlahová plocha", m2(v["pp"]) if v["pp"] else "—"),
               ("Kč/m² podlahové", kc(v["jc_pp"]) if v["jc_pp"] else "—"),
               ("Výhradní celek", m2(v["v_celek"])),
               ("Pozemky vše", m2(v["v_vse"]))]
    met_html = "".join(
        f'<div class="mt"><div class="ml">{l}</div><div class="mv">{x}</div></div>'
        for l, x in met)

    # --- predmet vkladu: pet polozek ---
    rows = []
    popis_hl = ", ".join(x for x in (v["druh"], v["adresa"]) if x)
    rows.append(("Hlavní nemovitost", popis_hl, None))
    if (v["budov"] or 0) > 1 or (v["jednotek"] or 0) > 1:
        vedlejsi = ", ".join(sorted({p["druh"] for p in polys
                                     if p["kotva"] and p["druh"] != v["druh"]})) or v["slozeni"]
        rows.append(("Vedlejší stavby", vedlejsi, None))
    if v["v_celek"]:
        rows.append(("Výhradní pozemky v celku", m2(v["v_celek"]),
                     pocet(len([p for p in polys if p["vl"]=="výhradní" and p["pr"] in ("kotva","celek")]), "parcela", "parcely", "parcel")))
    elif not v["je_jednotka"]:
        # Rozptýlený soubor pozemků nemá jeden funkční celek, rubrika by byla
        # prázdná. Místo ní se uvede, z kolika samostatných částí se skládá.
        casti = (v["tvar"] or {}).get("casti_vse")
        rows.append(("Pozemky bez souvislého celku", m2(v["v_vse"]),
                     pocet(casti, "samostatná část", "samostatné části", "samostatných částí") or "nesouvislé"))
    if v["v_mimo"]:
        rows.append(("Výhradní pozemky mimo celek", m2(v["v_mimo"]),
                     pocet(len([p for p in polys if p["vl"]=="výhradní" and p["pr"]=="oddělená"]), "parcela", "parcely", "parcel")))
    if v["v_podil"]:
        rows.append(("Podíly na společných pozemcích", m2(v["v_podil"]),
                     pocet(v["p_podil"], "parcela", "parcely", "parcel") + f', dle odhadu podílu {m2(v["v_dle_podilu"])}'))
    if v["v_neoveren"]:
        rows.append(("Neověřené", m2(v["v_neoveren"]), "vyžaduje posouzení"))
    predmet = "".join(
        f'<tr><th>{i}. {a}</th><td>{b}</td><td class="pozn">{c or ""}</td></tr>'
        for i, (a, b, c) in enumerate(rows, 1))

    # --- stavba dle RUIAN ---
    VODA = {1: "S vodovodem", 2: "Bez vodovodu"}
    KANAL = {1: "Přípoj na kanalizační síť", 2: "Vlastní čistička odpadních vod",
             3: "Žumpa, jímka, septik"}
    PLYN = {1: "Plyn z veřejné sítě", 2: "Plyn z domovního zásobníku", 3: "Bez plynu"}
    staveb = len(STAVBY.get(vk) or {})
    st = [("Staveb ve vkladu dle RÚIAN", staveb or "—"),
          ("Rok dokončení", f'{v["rok"]}' + ("" if v["rok_presny"] else " (jen rok)")),
          ("Pásmo stáří", v["pasmo"]),
          ("Zastavěná plocha", m2(v["zp"])),
          ("Podlahová plocha", m2(v["pp"])),
          ("Obestavěný prostor", "—" if not v["op"] else kc(v["op"]) + " m³"),
          ("Počet podlaží", v["podlazi"] or "—"),
          ("Počet bytů", v["bytu"] or "—"),
          ("Druh konstrukce", v["konstrukce"]),
          ("Vytápění", v["vytapeni"]),
          ("Výtah", v["vytah"]),
          ("Vodovod", VODA.get(v["vod"], "—")),
          ("Kanalizace", KANAL.get(v["kan"], "—")),
          ("Plyn", PLYN.get(v["plyn"], "—")),
          ("Poměr PP/OP", "—" if v["pomer"] is None else str(v["pomer"]).replace(".", ","))]
    pozn_souhrn = ("Součet za všechny stavby ve vkladu; údaje k jednotlivé stavbě "
                   "se zobrazí po kliknutí na parcelu."
                   if staveb > 1 else "Údaje k jediné stavbě ve vkladu.")
    stavba = "".join(f'<tr><th>{a}</th><td>{b}</td></tr>' for a, b in st)
    # U jednotky popisuje RÚIAN celý dům, ne prodávaný byt — musí to být
    # v nadpisu, jinak čtenář vezme zastavěnou plochu domu za plochu bytu.
    # U souboru pozemků žádná stavba není a prázdná tabulka jen mate.
    if v["je_jednotka"]:
        nadpis_stavba = "Stavba dle RÚIAN — dům, v němž jednotka leží"
        pozn_souhrn = ("Údaje popisují celou budovu, nikoli prodávanou jednotku. "
                       "Plocha jednotky je uvedena u jednotkových cen.")
    else:
        nadpis_stavba = "Stavba dle RÚIAN — souhrn za vklad"
    ma_stavbu = bool(staveb or v["zp"] or v["rok"] or v["op"])
    # --- co znalec zjistil ručně; v kartě i v exportu do Wordu musí být
    #     oddělené od údajů z katastru, aby bylo poznat, co je čí ---
    POUZ = {"vhodny": "vhodný", "s_vyhradou": "s výhradou",
            "nepouzitelny": "nepoužitelný"}
    zj = []
    if v.get("pouzitelnost"):
        zj.append(("Použitelnost vzorku",
                   POUZ.get(v["pouzitelnost"], v["pouzitelnost"]),
                   v.get("pouzitelnost_duvod") or ""))
    if v.get("plocha_rucne") is not None:
        zj.append(("Plocha ověřená znalcem", m2(v["plocha_rucne"]),
                   v.get("plocha_rucne_zdroj") or ""))
    if v.get("nalez_plocha_cely_dum"):
        zj.append(("Nález databáze", "plocha jednotky odpovídá celému domu",
                   "Valuo uvedlo u jednotky podlahovou plochu celého domu;"
                   " v domě jsou aspoň dvě jednotky, takže cena za m² by"
                   " vyšla násobně nižší, než má být"))
    if v.get("nalez_skala"):
        zj.append(("Nález databáze", "rozpor ve škále čitatele podílu",
                   "čitatel podílu přepočtený škálou domu se od Valuovy"
                   " plochy liší o celý řád; v registru ploch níže je"
                   " u dotčené jednotky uvedeno, zda se plocha přepsala"
                   " a čím je to doloženo"))
    if v.get("nalez_vice_nosnych"):
        zj.append(("Nález databáze", "více nosných nemovitostí stejného druhu",
                   f"ve vkladu je {v.get('radku_nosnych') or '?'}×"
                   f" {v.get('nosny_typ') or 'nosná nemovitost'} a žádná z nich"
                   " není hlavní; cena se dělí součtem jejich ploch, takže"
                   " jednotková cena je průměr za všechny, ne cena jedné"))
    if v.get("nalez_bez_plochy"):
        zj.append(("Nález databáze", "nosná nemovitost nemá podlahovou plochu",
                   "aspoň jedna nosná nemovitost plochu nemá, proto se nic"
                   " nedělí a uvádí se jen celková cena; u budov je to běžné —"
                   " Valuo dává do pole plocha výměru parcely a RÚIAN tu stavbu"
                   " často nezná"))
    if v.get("rozpusteno"):
        zj.append(("Složení vkladu", "v ceně je i " + str(v["rozpusteno"]),
                   "do plochy se sčítají jen řádky nosné nemovitosti"
                   f" ({v.get('nosny_typ') or '—'}), ostatní jednotky jsou"
                   " v ceně rozpuštěné a jednotkovou cenu tím snižují"))
    if v.get("jc_verdikt") == "k prověření" and v.get("jc_median_ku"):
        zj.append(("Kontrola ceny", "mimo pásmo mediánu v katastrálním území",
                   f"medián skupiny „{v.get('nosna_skupina') or '—'}“ v k.ú. je"
                   f" {kc(v['jc_median_ku'])} Kč/m² z {v.get('jc_vzorku_ku') or 0}"
                   " vzorků; je to jen vodítko, kde se vyplatí plochu prověřit"
                   " v listině, plochu to nevybírá"))
    if v.get("nalez_plocha_mimo_ocekavani"):
        zj.append(("Nález databáze", "plocha se vymyká ploše domu na jednotku",
                   f"dle RÚIANu vychází {kc(v.get('plocha_na_byt'), 1)} m²"
                   " na jednu jednotku; v domě ale bývají i garáže a nebytové"
                   " prostory a dům se může skládat z více čísel popisných"))
    if v.get("nalezu_rucne"):
        zj.append(("Zaznamenaných nálezů", str(v["nalezu_rucne"]),
                   "podrobnosti v aplikaci"))
    if v.get("poznamek"):
        zj.append(("Poznámek ke vkladu", str(v["poznamek"]),
                   "podrobnosti v aplikaci"))
    if zj:
        blok_zjisteni = ('<div class="box"><h2>Co zjistil znalec</h2><div class="in">'
                         '<table>' + "".join(
            f'<tr><th>{a}</th><td>{b}</td><td class="pozn">{c}</td></tr>'
            for a, b, c in zj) + '</table>'
            '<div class="zdroj" style="margin-top:8px">Tyto údaje nepocházejí '
            'z katastru ani z Valua — doplnil je znalec a přepočet je '
            'upřednostňuje před daty ze zdroje.</div></div></div>')
    else:
        blok_zjisteni = ""

    # --- registr zdrojů plochy: všechny známé plochy vedle sebe ---
    zdroje = PLOCHY.get(vk) or []
    if zdroje:
        radky, skupina = [], object()
        for z in zdroje:
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
                radky.append('<tr class="skupina"><th colspan="3">'
                             + nadp + "</th></tr>")
            pozn = z.get("poznamka") or ("" if z.get("pro_cenu") else "jen kontrola řádu")
            if z.get("pouzito"):
                pozn = (pozn + " — " if pozn else "") + "použito"
            tr = '<tr class="pouzito">' if z.get("pouzito") else "<tr>"
            hvezda = " \u2605" if z.get("autoritativni") else ""
            radky.append(
                tr
                + f'<th>{z.get("nazev")}{hvezda}</th>'
                + f'<td>{kc(z.get("plocha"), 1)} m²</td>'
                + f'<td class="pozn">{pozn}</td></tr>')
        blok_plochy = (
            '<div class="box"><h2>Z čeho se počítá cena za m²</h2><div class="in">'
            '<table>' + "".join(radky) + '</table>'
            '<div class="zdroj" style="margin-top:8px">Plochy ze všech známých '
            'zdrojů, u každé jednotky vkladu zvlášť; použitá je označena a '
            'poznámka u ní říká proč. Plocha vkladu je součet použitých ploch '
            'nosné nemovitosti — jednotky označené „rozpuštěno v ceně“ se do ní '
            'nesčítají, ačkoli v kupní ceně zahrnuté jsou. Nic se nepřepisuje: '
            'všichni kandidáti zůstávají v registru. Hvězdička označuje údaj '
            'ověřený znalcem, který má přednost přede všemi ostatními.'
            '</div></div></div>')
    else:
        blok_plochy = ""

    if ma_stavbu:
        blok_stavba = ('<div class="box"><h2>' + nadpis_stavba + '</h2><div class="in">'
                       '<table>' + stavba + '</table>'
                       '<div class="zdroj" style="margin-top:8px">' + pozn_souhrn
                       + '</div></div></div>')
    else:
        blok_stavba = ('<div class="box"><h2>Stavby</h2><div class="in">'
                       '<div class="zdroj">Ve vkladu není žádná stavba — '
                       'předmětem jsou pouze pozemky.</div></div></div>')

    # --- jednotkove ceny ---
    popis_pp = (v.get("plocha_zdroj") or "podlahová plocha stavby")
    # Skoro všechny plochy jednotek ve Valuu jsou dopočtené z podílu na
    # společných částech, ne změřené. Pro porovnávací metodu je to podstatné,
    # proto to stojí přímo u ceny.
    if v.get("nalez_plocha_z_podilu") and "ověřeno" not in popis_pp:
        popis_pp += " — dopočet z podílu, nikoli změřená plocha"
    if v["je_jednotka"] and v.get("plocha_karty"):
        popis_pp = f'{popis_pp}, {m2(v["plocha_karty"])}'
    # Nosná výměra pozemku: výhradní parcely bez tvaru pásu a bez druhu
    # komunikace. U pozemkového vkladu je to hlavní metrika — podíly na
    # komunikacích by ji jinak rozmělnily. U vkladu se stavbou doplňující.
    popis_nosne = "výhradní parcely bez komunikací a pásů"
    if v.get("parcel_nosnych"):
        popis_nosne += f', {v["parcel_nosnych"]}\u00d7, {m2(v.get("vymera_nosna"))}'
    popis_podil = "nosná výměra plus podíl na ostatních parcelách"
    if v.get("vymera_podilu"):
        popis_podil += f' ({m2(v.get("vymera_podilu"))})'
    jc = [("Kč/m² podlahové plochy", v["jc_pp"], popis_pp),
          ("Kč/m² nosné výměry", v.get("jc_nosne"), popis_nosne),
          ("Kč/m² včetně podílu", v.get("jc_s_podilem"), popis_podil),
          ("Kč/m² výhradního celku", v["jc_celek"], "jen výhradní pozemky v celku"),
          ("Kč/m² všech pozemků", v["jc_vse"], "celý předmět vkladu"),
          ("Kč/m³ obestavěného prostoru", v["jc_m3"], "kubatura dle RÚIAN")]
    # --- funkční využití dle ÚP (jen Praha) ---
    fvu_radky = []
    for p in polys:
        for i, (kod, popis_z, skup, pct, prunik) in enumerate(p["fvu"]):
            fvu_radky.append(
                f'<tr><td>{p["pn"] if i == 0 else ""}</td><td>{popis_z}</td>'
                f'<td>{skup.lower()}</td>'
                f'<td style="text-align:right">{("%.1f" % pct).replace(".", ",")}&nbsp;%</td>'
                f'<td style="text-align:right">{kc(prunik, 1)}&nbsp;m²</td></tr>')
    souhrn = {}
    for p in polys:
        for kod, popis_z, skup, pct, prunik in p["fvu"]:
            souhrn[popis_z] = souhrn.get(popis_z, 0) + (prunik or 0)
    souhrn_txt = ", ".join(f'{k} {kc(x, 0)}\u00a0m²'
                           for k, x in sorted(souhrn.items(), key=lambda y: -y[1]))
    fvu_box = ("" if not fvu_radky else
        '<div class="box"><h2>Funkční využití dle územního plánu</h2><div class="in">'
        '<table class="par"><thead><tr><th>Parcela</th><th>Plocha dle ÚP</th>'
        '<th>Cenová skupina</th><th>Podíl parcely</th><th>Výměra průniku</th></tr></thead>'
        '<tbody>' + "".join(fvu_radky) + '</tbody></table>'
        f'<div class="zdroj" style="margin-top:8px">Souhrn za vklad: {souhrn_txt}.<br>'
        'Územní plán sídelního útvaru hl. m. Prahy z roku 1999 ve znění změn, '
        'prostorově provázaný na parcely. Parcela může ležet ve více plochách; '
        'uvádí se podíl její výměry v každé z nich. Název kódu plochy databáze '
        'neobsahuje, cenová skupina je vlastní členění podle cenové hladiny.</div>'
        '</div></div>')

    t = v.get("tvar") or {}
    tvar_rows = [
        ("Kompaktnost výhradního celku (PP index)", t.get("pp_celku")),
        ("Plocha celku (sloučená)", t.get("plocha_celku")),
        ("Obvod celku", t.get("obvod_celku")),
    ]
    if t.get("pp_vse") is not None and t.get("pp_vse") != t.get("pp_celku"):
        tvar_rows += [("Kompaktnost všech pozemků vkladu (PP index)", t.get("pp_vse")),
                      ("Plocha všech pozemků (sloučená)", t.get("plocha_vse")),
                      ("Obvod všech pozemků", t.get("obvod_vse"))]
    def _fm(lab, x):
        if x is None: return "—"
        if lab.startswith("Kompaktnost"): return f"{x:.3f}".replace(".", ",")
        if lab.startswith("Obvod"): return kc(x, 1) + "\u00a0m"
        return kc(x, 1) + "\u00a0m²"
    tvar_html = "".join(f'<tr><th>{a}</th><td class="num">{_fm(a, b)}</td></tr>'
                        for a, b in tvar_rows)
    casti = t.get("casti_celku")
    casti_pozn = ("" if not casti or casti <= 1 else
        f' <b>Celek je ze {casti} nesouvislých částí</b> — index tvaru je u takového'
        f' útvaru jen orientační.')
    jc_html = "".join(
        f'<tr><th>{a}</th><td class="num">{kc(b) if b else "—"}</td><td class="pozn">{c}</td></tr>'
        for a, b, c in jc)

    # --- legenda ---
    pouzite = []
    for (vl, pr), (col, lab) in BARVY.items():
        n = len([p for p in polys if p["vl"] == vl and p["pr"] == pr])
        if n:
            pouzite.append(f'<span class="lg"><i style="background:{col}"></i>{lab} ({n})</span>')
    legenda = "".join(pouzite)

    radky_parcel = "".join(
        f'<tr class="{"k" if p["kotva"] else ""}" data-pn="{p["pn"]}">'
        f'<td>{p["pn"]}</td><td style="text-align:right">{kc(p["vym"])}\u00a0m²</td>'
        f'<td>{p["druh"]}</td>'
        f'<td style="text-align:right">{"—" if p["kmp"] is None else ("%.3f" % p["kmp"]).replace(".", ",")}</td>'
        f'<td style="text-align:right">{"—" if p["sir"] is None else ("%.1f" % p["sir"]).replace(".", ",") + "&nbsp;m"}</td>'
        f'<td><span class="tag" style="background:{p["barva"]}">{p["vl"]}</span></td>'
        f'<td>{p["pr"]}</td><td class="pozn">{p["duvod"] or "—"}</td></tr>'
        for p in polys)

    data_js = json.dumps(polys, ensure_ascii=False, default=_json_prevod)

    return f"""<!doctype html>
<html lang="cs"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Karta vkladu {vk} — {v['ku']}</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
<style>
:root {{ --b:#dcdad2; --t:#1a1a19; --t2:#5f5e5a; --bg:#faf9f6; --card:#fff; }}
* {{ box-sizing:border-box }}
body {{ margin:0; font:14px/1.55 -apple-system,"Segoe UI",Roboto,Arial,sans-serif;
  color:var(--t); background:var(--bg) }}
header {{ background:var(--card); border-bottom:1px solid var(--b); padding:14px 20px }}
.hrow {{ display:flex; justify-content:space-between; align-items:baseline; flex-wrap:wrap; gap:10px }}
h1 {{ font-size:19px; margin:0; font-weight:600 }}
.sub {{ color:var(--t2); font-size:13px; margin-top:3px }}
.klas {{ font-size:12px; border:1px solid var(--b); border-radius:4px; padding:2px 8px; color:var(--t2) }}
.wrap {{ max-width:1400px; margin:0 auto; padding:16px 20px 40px }}
.metriky {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:10px; margin-bottom:16px }}
.mt {{ background:var(--card); border:1px solid var(--b); border-radius:8px; padding:10px 12px }}
.ml {{ font-size:12px; color:var(--t2) }}
.mv {{ font-size:17px; font-weight:600; margin-top:2px }}
.grid2 {{ display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:16px }}
@media (max-width:1000px) {{ .grid2 {{ grid-template-columns:1fr }} }}
.box {{ background:var(--card); border:1px solid var(--b); border-radius:8px; margin-bottom:16px }}
.box h2 {{ font-size:14px; margin:0; padding:10px 14px; border-bottom:1px solid var(--b);
  font-weight:600; background:#f6f5f1; border-radius:8px 8px 0 0 }}
.box .in {{ padding:12px 14px }}
table {{ width:100%; border-collapse:collapse; font-size:13px }}
th {{ text-align:left; font-weight:500; color:var(--t2); padding:5px 14px 5px 0; vertical-align:top; width:42% }}
td {{ padding:5px 0; vertical-align:top }}
td.num {{ text-align:right; font-variant-numeric:tabular-nums; font-weight:600; width:110px; padding-right:12px; white-space:nowrap }}
.pozn {{ color:var(--t2); font-size:12px }}
tr.skupina th {{ background:#f0f0f0; color:#333; font-size:11px;
                 text-transform:uppercase; letter-spacing:.4px; padding-top:7px }}
tr.pouzito th, tr.pouzito td {{ background:#eef5ee; font-weight:600 }}
tr.pouzito .pozn {{ font-weight:500; color:#2a5 }}
#mapa {{ height:580px; border-radius:8px 8px 0 0 }}
.nastroje {{ padding:8px 14px; border-top:1px solid var(--b); display:flex; gap:8px; flex-wrap:wrap; align-items:center }}
button {{ font:13px inherit; padding:5px 11px; border:1px solid #b9b7ae; background:#fff;
  border-radius:5px; cursor:pointer }}
button.off {{ background:#eceae3; color:var(--t2) }}
.legenda {{ padding:8px 14px; border-top:1px solid var(--b); display:flex; gap:14px; flex-wrap:wrap; font-size:12px; color:var(--t2) }}
.lg i {{ display:inline-block; width:11px; height:11px; border-radius:2px; margin-right:5px; vertical-align:-1px }}
table.par {{ font-size:12.5px }}
table.par th {{ width:auto; color:var(--t); font-weight:600; border-bottom:1px solid var(--b); padding:6px 8px 6px 0 }}
table.par td {{ padding:5px 8px 5px 0; border-bottom:1px solid #f0eee7 }}
table.par tr.k td {{ font-weight:600 }}
table.par tr.vybrano td {{ background:#EEF4FB }}
#detail .pop b {{ font-size:15px }}
#detail table {{ width:100% }}
.tag {{ font-size:11px; padding:1px 6px; border-radius:3px; white-space:nowrap; color:#fff }}
.pop b {{ display:block; font-size:14px; margin-bottom:4px }}
.pop table {{ font-size:12px }}
.pop th {{ width:44%; padding:3px 8px 3px 0 }}
.vysv {{ font-size:11px; color:var(--t2); line-height:1.45; margin:2px 0 4px }}
.pop td {{ padding:2px 0 }}
.popisek {{ pointer-events:none; font-size:11px; font-weight:600; color:#1a1a19; text-shadow:0 0 3px #fff,0 0 3px #fff,0 0 3px #fff; white-space:nowrap }}
.popisek-ikona {{ pointer-events:none }}
.upoz {{ background:#FAEEDA; border:1px solid #EF9F27; border-radius:6px; padding:9px 12px;
  font-size:12.5px; margin-bottom:14px; color:#633806 }}
.zdroj {{ color:var(--t2); font-size:11.5px; margin-top:10px; line-height:1.5 }}
</style></head><body>
<header><div class="hrow">
  <div><h1>{vk} &nbsp;<span class="klas">{v['klas']}</span></h1>
  <div class="sub">{v['druh']} · {v['adresa']} · {v['ku']}, {v['obec']} · zplatněno {v['datum']}</div></div>
  <div style="text-align:right"><div style="font-size:19px;font-weight:600">{kc(v['cena'])}&nbsp;Kč</div>
  <div class="sub">{v['nem']} nemovitostí ve vkladu</div></div>
</div></header>
<div class="wrap">
<div class="upoz"><b>Poznámka ke vzorku:</b> {v['pozn']}</div>
<div class="metriky">{met_html}</div>
<div class="grid2">
  <div class="box"><h2>Předmět vkladu</h2><div class="in">
    <table>{predmet}</table></div></div>
  {blok_stavba}
</div>

<div class="box">
  <h2>Parcely vkladu na mapě</h2>
  <div id="mapa"></div>
  <div class="nastroje">
    <button id="bPoly">Polygony</button>
    <button id="bPopis">Popisky</button>
    <button id="bFit">Vycentrovat</button>
    <span class="pozn">Klik na parcelu zobrazí její údaje pod mapou.</span>
  </div>
  <div class="legenda">{legenda}</div>
  <div id="vady" style="display:none; padding:8px 14px; border-top:1px solid var(--b);
    background:#FCEBEB; color:#791F1F; font-size:12.5px"></div>
</div>

<div class="grid2">
  <div class="box"><h2>Detail vybrané parcely</h2><div class="in" id="detail">
    <div class="pozn">Klikni na parcelu v mapě nebo na řádek v rozpisu.</div>
  </div></div>
  <div class="box"><h2>Stavba na vybrané parcele</h2><div class="in" id="stavbaParcely">
    <div class="pozn">Klikni na parcelu v mapě nebo na řádek v rozpisu.</div>
  </div></div>
</div>

<div class="box"><h2>Rozpis parcel — role a její důvod</h2><div class="in" style="overflow-x:auto">
  <table class="par"><thead><tr><th>Parcela</th><th>Výměra</th><th>Druh</th>
  <th>Kompaktnost<br>(PP index)</th><th>Prům. šířka</th><th>Vlastnictví</th><th>Poloha</th>
  <th>Z čeho role vychází</th></tr></thead><tbody>
  {radky_parcel}
  </tbody></table>
  <div class="zdroj" style="margin-top:10px">
  <b>Kompaktnost (PP index)</b>, tedy Polsby-Popperův index 4&#960;A/O², poměřuje výměru s plochou
  kruhu o stejném obvodu: 1,0 je kruh, nižší hodnoty členitější nebo protáhlejší tvar.
  <b>Průměrná šířka</b> 2A/O je orientační šířka útvaru.
  <b>Vlastnictví</b> je odhad dopočtený z dat, nikoli údaj z katastru: za podílovou se
  bere parcela, která se prodávala společně s několika různými hlavními nemovitostmi.
  <b>Poloha</b> — kotva nese hlavní nemovitost, celek s ní sousedí, oddělená nesousedí.
  </div></div></div>

{fvu_box}

<div class="grid2">
  <div class="box"><h2>Tvar pozemku — kompaktnost (PP index)</h2><div class="in">
    <table>{tvar_html}</table>
    <div class="zdroj">Počítá se ze <b>sloučené</b> geometrie, ne jako součet za
    jednotlivé parcely — rozhoduje obrys toho, co kupující dostal.{casti_pozn}</div></div></div>
  <div class="box"><h2>Jednotkové ceny</h2><div class="in">
    <table>{jc_html}</table>
    <div class="zdroj">Jmenovatel je u každé ceny uveden. Cena je vždy za celý vklad;
    rozpad na jednotlivé nemovitosti data neobsahují.</div></div></div>
</div>

{blok_plochy}
{blok_zjisteni}
<div class="box"><h2>Zdroje</h2><div class="in"><div class="zdroj">
  Cenový údaj: sbírka listin katastru nemovitostí.<br>
  Parcely, výměry a geometrie: katastr nemovitostí, služba INSPIRE CP, ČÚZK.<br>
  Technickoekonomické atributy stavby a parcely okolí: RÚIAN, výměnný formát VFR, ČÚZK.<br>
  Funkční využití: Územní plán SÚ hl. m. Prahy 1999, IPR Praha.<br>
  Role parcel určuje databáze z vodítek uvedených v rozpisu.
</div></div></div>
</div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/proj4js/2.9.2/proj4.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/proj4leaflet/1.0.2/proj4leaflet.min.js"></script>
<script>
var PARCELY = {data_js};
var CUZK  = "https://ags.cuzk.gov.cz/arcgis1/rest/services";
var MPP_T = "https://tiles.arcgis.com/tiles/SBTXIEUGWbqzUecw/arcgis/rest/services";
var IPR   = "https://gs-pub.praha.eu/arcgis/rest/services";
var DMVS  = "https://dmvs.cuzk.gov.cz/api/wms";
var KNWMS = "https://services.cuzk.gov.cz/wms/local-km-wms.asp";

/* =========================================================================
   Mapa běží v NATIVNÍM S-JTSK (EPSG:5514), ne ve Web Mercatoru.
   Důvod: výkresy Metropolitního plánu mají capabilities "Map,TilesOnly" —
   neumí nic než své dlaždice v mřížce s počátkem -33 699 800 / 33 699 800.
   Přepočet té mřížky do Web Mercatoru nemůže lícovat a projevuje se právě
   rozházenými čtverci při zoomu. V nativní projekci je MPP přesný a ostatní
   vrstvy se doplní přes export / WMS, které renderují na libovolný výřez.
   Cenou je Google Maps — ty existují jen ve Web Mercatoru a v této mapě být
   nemohou.
   Rozlišení 0-13 jsou mřížka MPP; 14-18 jsou dopočtená půlením, aby šlo
   zoomovat na drobné parcely. MPP se na nich zvětšuje (maxNativeZoom 13),
   ostatní vrstvy renderují ostře.
   ========================================================================= */
var RES = [198.43789687579377, 132.2919312505292, 92.60435187537043,
  52.91677250021167, 39.687579375158755, 26.458386250105836,
  19.843789687579378, 13.229193125052918, 6.614596562526459,
  5.291677250021167, 3.9687579375158752, 2.6458386250105836,
  1.9843789687579376, 1.3229193125052918,
  0.66145965625264590, 0.33072982812632295,
  0.16536491406316148, 0.08268245703158074];

var CRS5514 = new L.Proj.CRS("EPSG:5514",
  "+proj=krovak +lat_0=49.5 +lon_0=24.8333333333333 +alpha=30.2881397527778 " +
  "+k=0.9999 +x_0=0 +y_0=0 +ellps=bessel " +
  "+towgs84=570.8,85.7,462.8,4.998,1.587,5.261,3.56 +units=m +no_defs",
  {{ origin: [-33699800, 33699800], resolutions: RES }});

/* --- ArcGIS "export": server vyrenderuje přesně požadovaný výřez v 5514 --- */
var ArcGISExport = L.TileLayer.extend({{
  options: {{ tileSize: 512, dpi: 192, format: "png32", transparent: true }},
  getTileUrl: function (coords) {{
    var crs = this._map.options.crs,
        b = this._tileCoordsToNwSe(coords),
        p1 = crs.project(b[0]), p2 = crs.project(b[1]),
        ts = this.getTileSize(),
        u = this._url + "?bbox=" +
            [Math.min(p1.x,p2.x), Math.min(p1.y,p2.y),
             Math.max(p1.x,p2.x), Math.max(p1.y,p2.y)].join(",") +
            "&bboxSR=5514&imageSR=5514&size=" + ts.x + "," + ts.y +
            "&format=" + this.options.format +
            "&transparent=" + this.options.transparent +
            "&dpi=" + this.options.dpi + "&f=image";
    if (this.options.layers) u += "&layers=" + this.options.layers;
    return u;
  }}
}});
function ags(url, o) {{ return new ArcGISExport(url, o || {{}}); }}

/* --- Cenová mapa: vrstva "Hranice skupin pozemků" má minScale 20 000, takže
   ji služba při oddálení přestane kreslit — nejdřív zmizí ceny, pak polygony.
   Parametr mapScale to obejde, ale ArcGIS z něj zároveň odvodí VÝŘEZ, takže
   by se podklad rozešel s mapou. Řešení: vnutit měřítko 19 000 a zároveň si
   vyžádat obrázek právě takové velikosti, aby při tom měřítku vyšel přesně
   požadovaný výřez. Ověřeno 24. 10. 2026 na živé službě. --- */
var CenovaMapa = ArcGISExport.extend({{
  options: {{ tileSize: 512, dpi: 96, format: "png32", transparent: true,
              vnuceneMeritko: 19000, maxPx: 2048 }},
  getTileUrl: function (coords) {{
    var crs = this._map.options.crs,
        b = this._tileCoordsToNwSe(coords),
        p1 = crs.project(b[0]), p2 = crs.project(b[1]),
        minx = Math.min(p1.x, p2.x), maxx = Math.max(p1.x, p2.x),
        miny = Math.min(p1.y, p2.y), maxy = Math.max(p1.y, p2.y),
        sirkaM = maxx - minx, vyskaM = maxy - miny,
        ts = this.getTileSize(),
        mNaPx = this.options.dpi === 0 ? 1 : (0.0254 / this.options.dpi),
        meritko = sirkaM / (ts.x * mNaPx),
        w = ts.x, h = ts.y, ms = null;
    if (meritko > this.options.vnuceneMeritko) {{
      ms = this.options.vnuceneMeritko;
      var krok = ms * mNaPx;                 // metrů na pixel při vnuceném měřítku
      w = Math.round(sirkaM / krok);
      h = Math.round(vyskaM / krok);
      if (w > this.options.maxPx || h > this.options.maxPx) {{
        ms = null; w = ts.x; h = ts.y;       // příliš daleko, necháme na službě
      }}
    }}
    var u = this._url + "?bbox=" + [minx, miny, maxx, maxy].join(",") +
      "&bboxSR=5514&imageSR=5514&size=" + w + "," + h +
      "&format=" + this.options.format +
      "&transparent=" + this.options.transparent +
      "&dpi=" + this.options.dpi + "&f=image";
    if (this.options.layers) u += "&layers=" + this.options.layers;
    if (ms) u += "&mapScale=" + ms;
    return u;
  }}
}});

/* --- WMS 1.1.1: pořadí os je vždy x,y, u 1.3.0 se u S-JTSK liší --- */
function wms(url, layers, o) {{
  return L.tileLayer.wms(url, Object.assign({{
    layers: layers, format: "image/png", transparent: true,
    version: "1.3.0", crs: CRS5514, tileSize: 512, maxZoom: 18
  }}, o || {{}}));
}}

/* --- Metropolitní plán: nativní dlaždice, žádný přepočet --- */
function mpp(sluzba) {{
  return L.tileLayer(MPP_T + "/" + sluzba + "/MapServer/tile/{{z}}/{{y}}/{{x}}",
    {{ tileSize: 512, opacity: 0.6, maxNativeZoom: 13, maxZoom: 18,
       attribution: "&copy; IPR Praha" }});
}}

var mrizka = "data:image/svg+xml;charset=UTF-8," +
  "%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='40'%3E" +
  "%3Crect width='40' height='40' fill='%23f5f5f0'/%3E" +
  "%3Cpath d='M40 0H0V40' fill='none' stroke='%23dddad0' stroke-width='1'/%3E%3C/svg%3E";

var mapa = L.map("mapa", {{ crs: CRS5514, minZoom: 0, maxZoom: 17 }});

var podklady = {{
  "Ortofotomapa (ČÚZK)": ags(CUZK + "/ORTOFOTO/MapServer/export",
      {{ attribution: "&copy; ČÚZK", transparent: false, format: "jpg" }}),
  "Základní topografická mapa (ČÚZK)": ags(CUZK + "/ZTM/MapServer/export",
      {{ attribution: "&copy; ČÚZK", transparent: false }}),
  "Přehledová mapa (ČÚZK)": ags(CUZK + "/PrehledovaMapa/MapServer/export",
      {{ attribution: "&copy; ČÚZK", transparent: false }}),
  "Čisté pozadí (bez mapy)": L.tileLayer(mrizka, {{ attribution: "", maxZoom: 18 }})
}};
podklady["Ortofotomapa (ČÚZK)"].addTo(mapa);

var prekryvy = {{
  /* Názvy vrstev jsou PLOCHÉ, bez cesty skupinou: ověřeno v GetCapabilities
     24. 10. 2026. "KN/rst_kmd" vrací ServiceException, "KN" vrátí obrázek.
     Skupina "KN" kreslí rastr i vektor, "vb" obě skupiny věcných břemen. */
  "Katastrální mapa (ČÚZK)": wms(KNWMS, "KN", {{ attribution: "&copy; ČÚZK" }}),
  "Věcná břemena (ČÚZK)": wms(KNWMS, "vb,vb_linie",
      {{ attribution: "&copy; ČÚZK", opacity: 0.85 }}),
  "DTM — sítě (technická infrastruktura)": wms(DMVS + "/dtm_ti_ver",
      "el_ved,el_kom,plyn,voda,kan,teplo,produkt,odp_hosp"),
  /* Přípojky bývají prázdné — obce je do DTM předaly zatím jen zčásti. */
  "DTM — domovní přípojky (často bez dat)": wms(DMVS + "/dtm_pripojky",
      "el_ved_prip,plyn_prip,vod_prip,kan_prip"),
  "DTM — dopravní infrastruktura": wms(DMVS + "/dtm_di_ver",
      "siln_dopr,dr_dopr,vod_dopr,dopr_st_skup"),
  "DTM — ZPS plochy (barevná)": wms(DMVS + "/dtm_zps_plochy_bar",
      "bud,dopr_st,vod_dila,prum_st,rek_kult_st,prisl_st,vod_veg", {{ opacity: 0.7 }}),
  "ÚP SÚ HMP 1999 — ve znění změn": ags(IPR + "/pup/uzemni_plan_platny/MapServer/export",
      {{ opacity: 0.55, attribution: "&copy; IPR Praha" }}),
  "ÚP SÚ HMP 1999 — původní znění": ags(IPR + "/pup/uzemni_plan_99/MapServer/export",
      {{ opacity: 0.55, attribution: "&copy; IPR Praha" }}),
  "Cenová mapa stavebních pozemků HMP": new CenovaMapa(
      IPR + "/sed/cenova_mapa/MapServer/export",
      {{ layers: "show:0,1", opacity: 0.6, attribution: "&copy; IPR Praha" }}),
  "MPP Z01 — základní členění území": mpp("Z01_Vykres_zakladniho_cleneni_uzemi_NkV_2605"),
  "MPP Z02 — hlavní výkres (funkční využití)": mpp("Z02_Hlavni_vykres_struktury_NkV_2605"),
  "MPP Z03 — hlavní výkres infrastruktury": mpp("Z03_Hlavni_vykres_infrastruktury_NkV_2605"),
  "MPP Z04 — veřejně prospěšné stavby": mpp("Z04_Vykres_verejne_prospesnych_staveb_opatreni_a_asanaci_NkV_2605"),
  "MPP S03 — schéma výškové regulace": mpp("S03_Schema_vyskove_regulace_NkV_2605"),
  "MPP O01 — koordinační výkres": mpp("O01_Koordinacni_vykres_NkV_2605")
}};

/* --- diagnostika: která vrstva nevrací dlaždice --- */
var hlaseno = {{}};
function hlidej(nazev, vrstva) {{
  vrstva.on("tileerror", function (e) {{
    if (hlaseno[nazev]) return;
    hlaseno[nazev] = true;
    console.error("[vrstva nefunguje] " + nazev + " — " +
      (e.tile && e.tile.src ? e.tile.src : "?"));
    vypis();
  }});
  /* "load" nastane i když všechny dlaždice selžou, proto se hlášení ruší
     teprve úspěšně načtenou dlaždicí */
  vrstva.on("tileload", function () {{
    if (hlaseno[nazev]) {{ delete hlaseno[nazev]; vypis(); }}
  }});
}}
function vypis() {{
  var box = document.getElementById("vady");
  if (!box) return;
  var z = Object.keys(hlaseno);
  if (!z.length) {{ box.style.display = "none"; return; }}
  box.style.display = "block";
  box.innerHTML = "<b>Nenačetly se vrstvy:</b> " + z.join(", ");
}}
Object.keys(podklady).forEach(function (k) {{ hlidej(k, podklady[k]); }});
Object.keys(prekryvy).forEach(function (k) {{ hlidej(k, prekryvy[k]); }});

var vrstvaPoly = L.featureGroup().addTo(mapa);
var vrstvaPopis = L.featureGroup().addTo(mapa);

function radek(a, b, pozn) {{
  if (b === null || b === undefined || b === "") return "";
  return "<tr><th>" + a + "</th><td>" + b +
    (pozn ? '<div class="vysv">' + pozn + "</div>" : "") + "</td></tr>";
}}
function cis(x, d) {{ return x === null || x === undefined ? null :
  Number(x).toLocaleString("cs-CZ", {{minimumFractionDigits:d||0, maximumFractionDigits:d||0}}); }}

function vyber(pn) {{
  var cil = null;
  PARCELY.forEach(function (q) {{
    var vybrana = q.pn === pn;
    if (vybrana) cil = q;
    if (q._poly) q._poly.setStyle({{ weight: vybrana ? 4 : 2,
      fillOpacity: vybrana ? 0.55 : 0.3 }});
  }});
  document.querySelectorAll("table.par tbody tr").forEach(function (tr) {{
    tr.classList.toggle("vybrano", tr.dataset.pn === pn);
  }});
  var box = document.getElementById("detail");
  if (box && cil) box.innerHTML = cil._html;
  var bs = document.getElementById("stavbaParcely");
  if (bs && cil) bs.innerHTML = cil._stavba;
}}

PARCELY.forEach(function(p) {{
  var poly = L.polygon(p.coords, {{color:p.barva, weight:2, fillColor:p.barva,
      fillOpacity:0.3}}).addTo(vrstvaPoly);
  var h = '<div class="pop"><b>Parcela ' + p.pn + '</b><table>' +
    radek("Výměra dle katastru", cis(p.vym) + " m²") +
    radek("Druh", p.druh, "Druh pozemku tak, jak je uveden u záznamu o prodeji.") +
    radek("Vlastnictví", p.vl === "podílová" ? "pravděpodobně podílová"
          : p.vl === "výhradní" ? "pravděpodobně výhradní" : p.vl,
      "Odhad vypočtený z dat, nikoli údaj z katastru. Za podílovou se bere parcela, " +
      "která se v datech prodávala společně s několika různými hlavními nemovitostmi.") +
    radek("Poloha vůči celku", p.pr,
      "Kotva nese hlavní nemovitost; celek s ní sousedí; oddělená s ní nesousedí.") +
    radek("Komponenta", p.kompc,
      "Pořadové číslo souvislé skupiny parcel v rámci vkladu. Parcely se stejným " +
      "číslem spolu sousedí a tvoří jeden kus.") +
    radek("Hlavních nemovitostí", p.hl,
      "U kolika různých hlavních nemovitostí tato parcela v datech vystupuje. " +
      "Více než jedna ukazuje na spoluvlastnictví.") +
    radek("Vkladů s parcelou", p.vkl,
      "V kolika různých vkladech se parcela v datech objevuje.") +
    radek("Vedena jako komunikace", p.kom ? "ano" : "ne",
      "Zda má parcela druh ostatní komunikace.") +
    radek("Kompaktnost (PP index)", cis(p.kmp, 3),
      "4&#960;A/O² — poměr výměry k ploše kruhu o stejném obvodu. 1,0 je kruh, " +
      "nižší hodnoty členitější nebo protáhlejší tvar.") +
    radek("Průměrná šířka", cis(p.sir, 1) + " m",
      "2A/O — orientační šířka útvaru, dopočtená z výměry a obvodu.") +
    radek("Tvar pásu", p.tvar ? "ano" : "ne",
      "Ano znamená, že je parcela zároveň protáhlá i úzká, tedy tvarem odpovídá " +
      "cestě nebo pásu zeleně.") +
    radek("Cizích staveb v okolí", p.stav,
      "Počet sousedních cizích parcel, na nichž podle RÚIAN stojí stavba.") +
    radek("Odhad velikosti podílu", p.podil ? cis(p.podil*100, 2) + " %" : null,
      "Dopočet 1 / počet hlavních nemovitostí. Skutečnou velikost podílu data " +
      "neobsahují, je ji třeba ověřit na listu vlastnictví.") +
    radek("Výměra připadající na podíl", p.dle_p ? cis(p.dle_p, 1) + " m²" : null,
      "Výměra parcely vynásobená odhadem podílu.") +
    radek("Vzdálenost od kotvy", p.vzd === null ? null : cis(p.vzd, 1) + " m",
      "Nejkratší vzdálenost k parcele s hlavní nemovitostí.") +
    (p.fvu && p.fvu.length
      ? radek("Funkční využití dle ÚP",
          p.fvu.map(function (f) {{
            return f[1] + " — " + f[3].toLocaleString("cs-CZ",
              {{minimumFractionDigits:1, maximumFractionDigits:1}}) + " %";
          }}).join("<br>"),
          "Plocha územního plánu z roku 1999, do níž parcela zasahuje, " +
          "a podíl její výměry v této ploše.")
      : "") +
    radek("Z čeho role vychází", p.duvod) +
    radek("Identifikátor ČÚZK", p.gml) +
    '</table><div style="margin-top:6px"><a href="https://nahlizenidokn.cuzk.gov.cz/ZobrazObjekt.aspx?&typ=parcela&id=' +
    p.gml.replace("CP.","") + '" target="_blank">Nahlížení do KN</a></div></div>';
  p._html = h;
  var sv = p.stavba;
  p._stavba = !sv
    ? '<div class="pozn">Na této parcele není v RÚIAN evidována žádná stavba.</div>'
    : '<div class="pop"><b>' + (sv.vyuziti || "stavba") + " na parcele " + p.pn +
      '</b><table>' +
      radek("Typ stavebního objektu", sv.typ) +
      radek("Způsob využití", sv.vyuziti) +
      radek("Dokončení", sv.dokonceni) +
      radek("Zastavěná plocha", sv.zp === null ? null : cis(sv.zp) + " m²") +
      radek("Podlahová plocha", sv.pp === null ? null : cis(sv.pp) + " m²",
        "RÚIAN ji eviduje jen asi u pětiny staveb.") +
      radek("Obestavěný prostor", sv.op === null ? null : cis(sv.op) + " m³") +
      radek("Počet podlaží", sv.podlazi === null ? null : String(sv.podlazi),
        "Včetně podzemních; obyvatelné podkroví se počítá jako nadzemní podlaží.") +
      radek("Počet bytů", sv.bytu === null ? null : String(sv.bytu)) +
      radek("Druh konstrukce", sv.konstrukce) +
      radek("Vytápění", sv.vytapeni) +
      radek("Výtah", sv.vytah) +
      radek("Vodovod", sv.voda) +
      radek("Kanalizace", sv.kanalizace) +
      radek("Plyn", sv.plyn) +
      radek("Poměr PP/OP", sv.pomer === null ? null : cis(sv.pomer, 3),
        "Trojnásobek podlahové plochy k obestavěnému prostoru; hodnoty mimo " +
        "0,35 až 1,50 ukazují na nevěrohodný údaj.") +
      radek("Kód stavebního objektu", String(sv.kod_so)) +
      "</table></div>";
  p._poly = poly;
  poly.bindTooltip(p.pn + " · " + cis(p.vym) + " m² — klikni pro detail");
  poly.on("click", function () {{ vyber(p.pn); }});
  var c = poly.getBounds().getCenter();
  L.marker(c, {{interactive:false, keyboard:false,
    icon: L.divIcon({{className:"popisek-ikona", html:'<div class="popisek">' + p.pn +
    "<br>" + cis(p.vym) + " m²</div>", iconSize:[80,30], iconAnchor:[40,15]}})
  }}).addTo(vrstvaPopis);
}});

L.control.layers(podklady, prekryvy, {{collapsed:true, position:"topright"}}).addTo(mapa);
L.control.scale({{imperial:false, metric:true}}).addTo(mapa);
function fit() {{ mapa.fitBounds(vrstvaPoly.getBounds().pad(0.35)); }}
fit();
document.querySelectorAll("table.par tbody tr").forEach(function (tr) {{
  tr.style.cursor = "pointer";
  tr.onclick = function () {{ vyber(tr.dataset.pn); }};
}});
var kotva = PARCELY.filter(function (q) {{ return q.kotva; }})[0] || PARCELY[0];
if (kotva) vyber(kotva.pn);

function prepinac(id, vrstva) {{
  var b = document.getElementById(id);
  b.onclick = function() {{
    if (mapa.hasLayer(vrstva)) {{ mapa.removeLayer(vrstva); b.classList.add("off"); }}
    else {{ mapa.addLayer(vrstva); b.classList.remove("off"); }}
  }};
}}
prepinac("bPoly", vrstvaPoly);
prepinac("bPopis", vrstvaPopis);
document.getElementById("bFit").onclick = fit;

if (location.protocol === "file:") {{
  console.warn("[karta] Stránka je otevřená ze souboru (file://). Dlaždice " +
    "Metropolitního plánu a vrstvy IPR může prohlížeč zablokovat kvůli CORS " +
    "(ERR_BLOCKED_BY_ORB), i když server odpovídá správně. Spusť ve složce " +
    "'python -m http.server 8000' a otevři přes http://localhost:8000/.");
}}
</script></body></html>
"""


def main():
    ap = argparse.ArgumentParser(description="Karta vkladu jako HTML stránka.")
    ap.add_argument("vklady", nargs="+", help="čísla vkladů")
    ap.add_argument("--slozka", default="karty", help="kam uložit (výchozí: karty)")
    ap.add_argument("--server", default=None, help="SQL Server, jinak jako u 35")
    a = ap.parse_args()
    if a.server:
        EX.SERVER = a.server
    os.makedirs(a.slozka, exist_ok=True)

    import sqlalchemy
    eng = EX.engine()
    with eng.connect() as conn:
        for cislo in a.vklady:
            v_row, parcely, fvu_radky = EX.nacti_vklad(conn, cislo)
            stavby_radky = conn.execute(sqlalchemy.text(SQL_STAVBY),
                                        {"v": cislo}).mappings().all()
            globals()["FVU"] = {cislo: fvu_z_view(fvu_radky)}
            globals()["STAVBY"] = {cislo: stavby_z_view([dict(x) for x in stavby_radky])}
            v = v_z_view(v_row, len(parcely))
            html = html_karta(cislo, v, par_z_view(parcely))
            jmeno = "karta_" + re.sub(r"[^A-Za-z0-9]+", "_", cislo).strip("_") + ".html"
            cesta = os.path.join(a.slozka, jmeno)
            io.open(cesta, "w", encoding="utf-8", newline="\n").write(html)
            print(f"{cislo}: {os.path.abspath(cesta)}  "
                  f"{len(parcely)} parcel, {len(stavby_radky)} staveb, "
                  f"{os.path.getsize(cesta)} B")

    print("\nOtevři přes http, ne ze souboru:")
    print(f"    cd {os.path.abspath(a.slozka)} && python -m http.server 8000")
    print("    http://localhost:8000/")


if __name__ == "__main__":
    main()
