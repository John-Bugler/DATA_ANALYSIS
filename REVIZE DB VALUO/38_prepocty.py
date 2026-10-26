# -*- coding: utf-8 -*-
"""
38_prepocty.py — naplnění karet vkladu v databázi
=================================================
Databáze: VALUO        Krok: 38        Datum: 24. 10. 2026

K čemu to je
------------
Karta vkladu se nepočítá za běhu — role parcel, komponenty a tvar se
ukládají do tabulek. Dokud to pro daný vklad neproběhne, je ve view
v_Valuo_karta_vkladu většina sloupců prázdná: parcel_celkem, výměry,
Kč/m² pozemku i PP index.

Tenhle skript to naplní. Jede v pěti krocích, v tomhle pořadí:

  1. okolí po katastrálních územích   sp_prepocet_karty_okoli
     Prostorové vztahy mezi parcelami. Hotovo: 40 329 parcel v 826 k. ú.
  2. karty po vkladech                sp_prepocet_karet_davka
     Zhruba 3,6 vkladu za vteřinu, u 49 788 vkladů tedy kolem 4 hodin.
  3. tvar celku                       sp_prepocet_karty_tvar
     Rychlé, běží nad hotovými kartami.
  4. registr ploch a nosná nemovitost sp_prepocet_ploch
     Zlomky podílu z popisu, registr všech známých ploch po jednotkách
     a nosná nemovitost vkladu u jednotek, budov i pozemků. Běží PŘED
     mapou, protože mapa z toho čte. Jednotky sekund.
  5. podklad pro mapu                 sp_prepocet_mapy
     Plochý výtah pro mapovou aplikaci: bod, kategorie, jednotková cena,
     příznaky nálezů. Pohled v_Valuo_karta_vkladu je na překreslování mapy
     moc pomalý. Je JEDINÝM vlastníkem Valuo_mapa a musí být poslední.

     Do kroku 46 bylo pořadí obrácené a sp_prepocet_ploch si do mapy na
     konci dolepovala vlastní příznaky. Tím se mapa rozešla sama se sebou:
     plocha z nového přepočtu vedle ceny ze starého (nalezl znalec
     25. 10. 2026 na V-23039/2026-101). Jeden vlastník tabulky to vylučuje.

Pouští se i z importu: `30_import_valuo.py --dopocty` nebo `--vse`.

Všech pět kroků je přerušitelných a navazují. Když to spadne nebo to
zavřeš, spusť znovu — dopočítá se jen to, co chybí. Proto ten --limit
a časové stropy uvnitř procedur.

Spuštění
--------
    python 38_prepocty.py                 # vše, co chybí
    python 38_prepocty.py --krok karty    # jen druhý krok
    python 38_prepocty.py --prepocitat    # znovu i to, co už je hotové

Závislosti: sdílí připojení s 35_export_word.py.
"""

import argparse
import datetime
import importlib.util
import os
import sys

ZDE = os.path.dirname(os.path.abspath(__file__))


def nacti_export():
    cesta = os.path.join(ZDE, "35_export_word.py")
    if not os.path.exists(cesta):
        raise SystemExit(f"Vedle tohoto skriptu chybí 35_export_word.py ({cesta}).")
    spec = importlib.util.spec_from_file_location("export_word", cesta)
    modul = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modul)
    return modul


EX = nacti_export()


def cas(sekund):
    sekund = int(sekund)
    if sekund < 90:
        return f"{sekund} s"
    if sekund < 5400:
        return f"{sekund // 60} min"
    return f"{sekund / 3600:.1f} h"


def krok_okoli(conn, sqlalchemy, prepocitat):
    print("\n[1/5] Okolí po katastrálních územích")
    jen_nove = 0 if prepocitat else 1
    celkem_ku = 0
    zacatek = datetime.datetime.now()
    while True:
        r = conn.execute(sqlalchemy.text(
            "EXEC dbo.sp_prepocet_karty_okoli @kod_ku = NULL, @jen_nove = :jn, "
            "@limit_ku = 400, @max_sekund = 600, @podrobne = 0"),
            {"jn": jen_nove}).mappings().first()
        conn.commit()
        if r is None:
            break
        celkem_ku += r["zpracovano_ku"] or 0
        zbyva = r["zbyva_ku"] or 0
        print(f"      hotovo {celkem_ku} k. ú., zbývá {zbyva}"
              f"   ({cas((datetime.datetime.now() - zacatek).total_seconds())})")
        if zbyva == 0 or (r["zpracovano_ku"] or 0) == 0:
            break
        jen_nove = 1          # další kolo už jen to, co chybí
    print("      okolí hotové")


def krok_karty(conn, sqlalchemy, prepocitat):
    print("\n[2/5] Karty po vkladech — tohle je ta dlouhá část")
    jen_nove = 0 if prepocitat else 1
    celkem = chyb = 0
    zbyva_minule = None
    zacatek = datetime.datetime.now()
    while True:
        r = conn.execute(sqlalchemy.text(
            "EXEC dbo.sp_prepocet_karet_davka @jen_nove = :jn, "
            "@limit = 100000, @max_sekund = 600"),
            {"jn": jen_nove}).mappings().first()
        conn.commit()
        if r is None:
            break
        celkem += r["zpracovano"] or 0
        chyb += r["chyb"] or 0
        zbyva = r["zbyva"] or 0
        ubehlo = (datetime.datetime.now() - zacatek).total_seconds()
        odhad = (f", odhad zbývá {cas(zbyva / (celkem / ubehlo))}"
                 if celkem and ubehlo > 0 and zbyva else "")
        print(f"      hotovo {celkem} vkladů, zbývá {zbyva}"
              f"   ({cas(ubehlo)}{odhad})")
        if zbyva == 0 or (r["zpracovano"] or 0) == 0:
            break
        # Pojistka proti zacyklení: když se počet zbývajících nehne, nemá
        # smysl kolo opakovat. V noci na 25. 10. 2026 takhle běh devět hodin
        # dokola přepočítával 138 vkladů, které kartu nemohly dostat.
        if zbyva_minule is not None and zbyva >= zbyva_minule:
            print(f"      [!] počet zbývajících se nemění ({zbyva}) — končím, "
                  f"aby se běh nezacyklil")
            break
        zbyva_minule = zbyva
        jen_nove = 1
    if chyb:
        print(f"      [!] {chyb} vkladů se nepodařilo spočítat")
    bez = r["bez_karty_celkem"] if r is not None and "bez_karty_celkem" in r.keys() else None
    if bez:
        print(f"      karty hotové; {bez} vkladů kartu nemá — jejich parcely "
              f"nejsou v KN_parcel_data")
    else:
        print("      karty hotové")


def krok_tvar(conn, sqlalchemy, prepocitat):
    print("\n[3/5] Tvar celku (PP index)")
    jen_nove = 0 if prepocitat else 1
    celkem = 0
    zbyva_minule = None
    zacatek = datetime.datetime.now()
    while True:
        r = conn.execute(sqlalchemy.text(
            "EXEC dbo.sp_prepocet_karty_tvar @cislo_vkladu = NULL, "
            "@jen_nove = :jn, @limit = 2000, @max_sekund = 600"),
            {"jn": jen_nove}).mappings().first()
        conn.commit()
        if r is None:
            break
        celkem += r["radku_tvaru"] or 0
        zbyva = r["zbyva"] or 0
        print(f"      hotovo {celkem} vkladů, zbývá {zbyva}"
              f"   ({cas((datetime.datetime.now() - zacatek).total_seconds())})")
        if zbyva == 0 or (r["radku_tvaru"] or 0) == 0:
            break
        if zbyva_minule is not None and zbyva >= zbyva_minule:
            print(f"      [!] počet zbývajících se nemění ({zbyva}) — končím")
            break
        zbyva_minule = zbyva
        jen_nove = 1          # další kola už jen to, co chybí
    print("      tvar hotový")


def krok_mapa(conn, sqlalchemy, prepocitat):
    """Vynucený přepočet drží @prepocitat = 1 po celou dobu a dávkuje se podle
    @od = začátek běhu: k. ú., které už v tomhle běhu prošlo, se podruhé nebere.

    Do 25. 10. 2026 se po prvním kole přepínalo na @prepocitat = 0 („druhé kolo
    už jen to, co chybí"). U vynuceného přepočtu to znamenalo, že se přepočítalo
    jen prvních 400 k. ú. podle kod_ku, druhé kolo nenašlo nic k doplnění a běh
    ohlásil „mapa hotová" — zbylých 426 k. ú. zůstalo se starými hodnotami.
    Chyba, která se neprojeví jako chyba; proto ten @od."""
    print("\n[5/5] Podklad pro mapovou aplikaci")
    celkem = 0
    minule = None
    cele = False
    zacatek = datetime.datetime.now()
    while True:
        r = conn.execute(sqlalchemy.text(
            # Dávka 50 k. ú., ne 400: celý přepočet má 310 k. ú., takže
            # při 400 byla jedna jediná dávka a výpis přišel teprve po
            # dvanácti minutách — nebylo jak poznat, že to jede (25. 10.
            # 2026). Při 50 přijde postup sedmkrát. Dávkování je od téhož
            # dne bezpečné díky parametru @od.
            "EXEC dbo.sp_prepocet_mapy @prepocitat = :zn, @limit_ku = 50, "
            "@max_sekund = 600, @od = :od"),
            {"zn": 1 if prepocitat else 0,
             "od": zacatek if prepocitat else None}).mappings().first()
        conn.commit()
        if r is None:
            break
        celkem += r["zpracovano_ku"] or 0
        zbyva = r["zbyva_ku"] or 0
        print(f"      hotovo {celkem} k. ú., zbývá {zbyva}"
              f"   ({cas((datetime.datetime.now() - zacatek).total_seconds())})")
        if zbyva == 0:
            cele = True
            break
        if (r["zpracovano_ku"] or 0) == 0:
            break
        # Pojistka proti zacyklení: nezmenší-li se „zbývá", fronta bere k. ú.,
        # která dopočítat nelze, a další kolo by jen zopakovalo totéž.
        # Dřív to skript nepoznal a po 400 k. ú. hlásil „mapa hotová".
        if minule is not None and zbyva >= minule:
            print(f"      ! Zacyklení: „zbývá\u201c se nezmenšuje "
                  f"({minule} \u2192 {zbyva}). Běh zastaven.")
            print("        Fronta bere k. ú., která nelze dopočítat. "
                  "Viz data/ROZHODNUTI.md, „Dvě osy\u201c.")
            break
        minule = zbyva
    if cele:
        print("      mapa hotová")
    else:
        print(f"      mapa NEDOKONČENÁ — zbývá {zbyva} k. ú.")


def krok_plochy(conn, sqlalchemy, prepocitat):
    """Registr zdrojů plochy a nosná nemovitost vkladu (kroky 45 a 46).

    Běží po kartách, protože od kroku 46 čte Valuo_karta_parcely kvůli
    nosné výměře pozemků, a PŘED mapou, protože mapa z toho čte.
    Do Valuo_mapa už nezapisuje nic — jediným vlastníkem té tabulky je
    sp_prepocet_mapy (krok 46). Je rychlý (jednotky sekund), proto nemá
    dávkování ani časový strop jako karty."""
    print("\n[4/5] Registr zdrojů plochy a nosná nemovitost")
    r = conn.execute(sqlalchemy.text(
        "EXEC dbo.sp_prepocet_ploch @prepocitat = :zn"),
        {"zn": 1 if prepocitat else 0}).mappings().first()
    conn.commit()
    if r:
        print(f"      registr {r['radku_registru']} řádků, "
              f"použitých {r['radku_pouzitych']}, "
              f"nových zlomků podílu {r['novych_zlomku']}   ({cas(r['sekund'])})")
        print(f"      nosná nemovitost u {r['vkladu']} vkladů: "
              f"jednotka {r['jednotkovych']}, budova {r['budovovych']}, "
              f"pozemky {r['pozemkovych']}")
        print(f"      podlahová plocha {r['ma_podlahovou']}, "
              f"nosná výměra {r['ma_nosnou_vymeru']}, "
              f"mediánů v k. ú. {r['medianu_ku']}")
        print(f"      nálezy: celý dům {r['nalezu_cely_dum']} "
              f"(přepsáno {r['dum_prepsano']}), "
              f"škála {r['nalezu_skala']} (přepsáno {r['skala_prepsano']}), "
              f"více nosných {r['vice_nosnych']}, "
              f"nosná bez plochy {r['nosna_bez_plochy']}")
        # Nový typ nemovitosti z importu by tiše dostal prioritu 99 a skupinu
        # „ostatní", takže by nikdy nebyl nosný a jeho cena by se nesrovnala
        # se správnou skupinou. Doplň ho do CIS_nemovitost_typ.
        if r.get("typu_mimo_ciselnik"):
            print(f"      POZOR: {r['typu_mimo_ciselnik']} typů nemovitosti "
                  "není v CIS_nemovitost_typ — dostaly prioritu 99 a skupinu "
                  "„ostatní“. Doplň je do číselníku a pusť --krok plochy znovu.")
            print("      Který to je:  SELECT DISTINCT d.nemovitost, d.typ "
                  "FROM dbo.Valuo_data d WHERE d.nemovitost IN "
                  "('jednotka','budova','---') AND NOT EXISTS (SELECT 1 FROM "
                  "dbo.CIS_nemovitost_typ t WHERE t.nemovitost = d.nemovitost "
                  "AND t.typ = d.typ);")
    print("      registr hotový")


def stav(conn, sqlalchemy):
    r = conn.execute(sqlalchemy.text("""
        SELECT (SELECT COUNT(DISTINCT kod_ku) FROM dbo.Valuo_karta_okoli) AS ku,
               (SELECT COUNT(*) FROM dbo.Valuo_karta_okoli) AS parcel_okoli,
               (SELECT COUNT(DISTINCT cislo_vkladu) FROM dbo.Valuo_karta_parcely) AS karet,
               (SELECT COUNT(*) FROM dbo.Valuo_karta_vklad) AS tvaru,
               (SELECT COUNT(*) FROM dbo.Valuo_mapa) AS v_mape,
               (SELECT COUNT(*) FROM dbo.Valuo_plochy) AS registr,
               (SELECT COUNT(*) FROM dbo.Valuo_vklad_plocha) AS nosna,
               (SELECT COUNT(*) FROM dbo.Valuo_mapa WHERE nalez_skala = 1) AS skala,
               (SELECT COUNT(*) FROM dbo.Valuo_mapa WHERE nalez_vice_nosnych = 1) AS vice,
               (SELECT COUNT(DISTINCT cislo_vkladu) FROM dbo.Valuo_data) AS vkladu
    """)).mappings().first()
    # Posun desetinné čárky se od kroku 45 nehledá — v datech ten jev není,
    # nahradil ho rozpor ve škále čitatele podílu.
    print(f"\nStav: okolí {r['parcel_okoli']} parcel v {r['ku']} k. ú. | "
          f"karty {r['karet']} z {r['vkladu']} vkladů | tvar {r['tvaru']} | "
          f"mapa {r['v_mape']} | registr ploch {r['registr']} | "
          f"nosná nemovitost {r['nosna']} "
          f"(rozpor ve škále {r['skala']}, více nosných {r['vice']})")


def spust(krok="vse", prepocitat=False):
    """Pět kroků dopočtu. Volá se z příkazové řádky i z importního skriptu
    (30_import_valuo.py --dopocty), aby logika byla na jednom místě.

    Všechno je přerušitelné a navazuje: procedury mají vlastní časové stropy
    a berou si jen to, co ještě chybí. Když to spadne nebo to zavřeš, spusť
    znovu — nic se nerozbije a nic se nepočítá dvakrát."""
    import sqlalchemy
    eng = EX.engine()
    zacatek = datetime.datetime.now()
    with eng.connect() as conn:
        stav(conn, sqlalchemy)
        if krok in ("okoli", "vse"):
            krok_okoli(conn, sqlalchemy, prepocitat)
        if krok in ("karty", "vse"):
            krok_karty(conn, sqlalchemy, prepocitat)
        if krok in ("tvar", "vse"):
            krok_tvar(conn, sqlalchemy, prepocitat)
        # Pořadí je závazné: plochy před mapou. Mapa čte z pohledu, který
        # stojí na Valuo_vklad_plocha, a je jediným vlastníkem Valuo_mapa.
        if krok in ("plochy", "vse"):
            krok_plochy(conn, sqlalchemy, prepocitat)
        if krok in ("mapa", "vse"):
            krok_mapa(conn, sqlalchemy, prepocitat)
        stav(conn, sqlalchemy)
    print(f"\nCelkem {cas((datetime.datetime.now() - zacatek).total_seconds())}.")


def main():
    ap = argparse.ArgumentParser(description="Naplnění karet vkladu.")
    ap.add_argument("--krok",
                    choices=["okoli", "karty", "tvar", "mapa", "plochy", "vse"],
                    default="vse")
    ap.add_argument("--prepocitat", action="store_true",
                    help="počítat znovu i to, co už hotové je")
    ap.add_argument("--server", default=None)
    a = ap.parse_args()
    if a.server:
        EX.SERVER = a.server

    spust(krok=a.krok, prepocitat=a.prepocitat)


if __name__ == "__main__":
    main()
