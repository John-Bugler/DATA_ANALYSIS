"""
VALUO — KROK 23g: ODSTRANĚNÍ CIZÍCH PARCEL

Smaže z KN_parcel_data vazby na parcely, které v popisu
nemovitosti nejsou uvedené.

    python 23g_cizi_parcely.py              rozbor, nic nemaže
    python 23g_cizi_parcely.py --smazat     provede mazání

Bez --smazat skript jen spočítá a vypíše, co by smazal. Mazání
je proto nutné potvrdit vědomě.

================================================================
NÁLEZ
================================================================
Jeden řádek Valuo_data má v KN_parcel_data navázané dvě parcely,
z nichž jedna k němu nepatří. Doložený případ:

    Valuo_data.id = 94800, vklad V-30922/2022-101

    popis: jednotka č. 6390012, byt v budově č.p. 639, část
           obce Nusle, na parcele 1340 Nusle, podíl na
           společných částech domu a pozemku 11814/228411

    KN_parcel_data:
        CP.2093018101   parcela 1340     614 m2   správně
        CP.2091480101   parcela    2   5 258 m2   nepatří tam

Parcela 2 v popisu vůbec není a leží 600 m od toho domu.

----------------------------------------------------------------
ROZSAH
----------------------------------------------------------------
    jednotka   83 378 parcel, 10 607 není v popisu
    budova        650 parcel,     26 není v popisu
    parcela    45 009 parcel,      0 není v popisu

U pozemků je to tedy čisté — každý řádek má právě jednu parcelu
a ta je z popisu. Jednotkové ceny pozemků, cenové hladiny podle
funkčního využití ani detekce hromadných převodů u JC_PARCELY
zasažené nejsou.

Vetřelci jsou z 10 342 případů jednociferné parcely 2 až 10:

    parcela 4   3 646x        parcela  2    529x
    parcela 8   2 259x        parcela  3    137x
    parcela 7   1 884x        parcela  6    108x
    parcela 5     901x        parcela  9     82x
    parcela 10    796x

Každý vetřelec má vlastní gml_id a výměru, takže jde o parcely,
které v tom katastrálním území skutečně existují — jen s jiným
číslem, než popis uvádí:

    popis na parcele 262/4 Komořany   ->  parcela  4 Komořany
    popis na parcele  46/6 Cholupice  ->  parcela  4 Cholupice
    popis na parcele 814/2 Kunratice  ->  parcela  4 Kunratice

Takhle výrazný vzor znamená chybu při párování, ne náhodu.
Vzniklo to při původním plnění KN_parcel_data, před krokem 17 —
ten parcely jen doplňoval tam, kde chyběly nebo byly z cizího
území, a nic nemazal. Přesnou příčinu z dat určit nelze.

----------------------------------------------------------------
CO SE ZMĚNÍ A CO NE
----------------------------------------------------------------
NEZMĚNÍ se žádná jednotková cena. Všech 25 429 vkladů jednotek
s jednotkovou cenou má plochu jednotky, žádný nespoléhá na
plochu parcel, a u pozemků vetřelci nejsou. Skupiny v tabulce
Valuo_hromadne_prevody tedy zůstanou stejné a ruční zatřídění
platí dál.

ZMĚNÍ se souřadnice vkladů jednotek v pohledu v_Valuo_vzorek,
protože se počítají z parcel — zpřesní se. Mapa hromadných
převodů po restartu nakreslí správné parcely.

Materializované Valuo_data.LAT, LON a geo_bod se nepřepočítají
samy; pokud je někdy budeš chtít srovnat s opravenou sadou
parcel, patří to ke kroku 18.

----------------------------------------------------------------
BEZPEČNOSTNÍ PRAVIDLO
----------------------------------------------------------------
Maže se jen tam, kde parser v popisu NAŠEL alespoň jednu parcelu
a parcela z databáze mezi nalezenými není. Nerozumí-li parser
popisu vůbec, řádek se nechá být — opačné pravidlo by při
nezvládnutém tvaru popisu smazalo platné vazby.

Smazané řádky se nejdřív zkopírují do tabulky
KN_parcel_data_zaloha_23g, odkud se dají vrátit.

KN_parcel_UP nemá na KN_parcel_data cizí klíč, takže by tam po
mazání zůstaly osiřelé vazby na funkční využití. Skript je maže
spolu s parcelami.
================================================================
"""

import argparse
import re
import sys

import pyodbc

CONN = (
    "Driver={ODBC Driver 17 for SQL Server};"
    "Server=localhost;"
    "Database=VALUO;"
    "Trusted_Connection=yes;"
)

DAVKA = 2000


# ---------------------------------------------------------------
# PARSER POPISU — shodný s krokem 17, vrací jen čísla parcel
# ---------------------------------------------------------------

ZAVORKY = re.compile(r"\([^)]*\)")
VZOR_SEZNAM = re.compile(r"(?i)\b(?:na|k)\s+parcele\s+(.+)$")
VZOR_PREFIX = re.compile(r"^(?i:(stavební|PK|GP)\s+)?č\.\s+(.+)$")
VZOR_SEGMENT = re.compile(r"(?i)^(st\.\s*)?(\d+(?:/\d+)?)(?:\s+(.+))?$")


def normalizuj(cislo):
    """'st.736' i 'st.  736' -> 'st. 736', jak je to v databázi."""
    c = re.sub(r"\s+", " ", cislo).strip()
    return re.sub(r"(?i)^st\.\s*", "st. ", c)


def cisla_parcel(popis):
    """Vrátí (mnozina_cisel, duvod_proc_nic). Prázdná množina
       s důvodem znamená, že se nemá mazat nic."""
    if not popis:
        return set(), "bez_popisu"

    p = re.sub(r"\s+", " ", ZAVORKY.sub(" ", popis)).strip().rstrip(",")
    st_vsude = False

    # tvar '… na parcele 1340 Nusle, podíl …'
    m = VZOR_SEZNAM.search(p)
    if m:
        zbytek = m.group(1)
    else:
        # tvar 'č. 1340 Nusle' nebo 'stavební č. 3/1 Ostrov u Stříbra'
        m = VZOR_PREFIX.match(p)
        if not m:
            return set(), "neznamy_tvar"
        druh = (m.group(1) or "").lower()
        if druh in ("pk", "gp"):
            return set(), "PK_GP_neni_v_KN"
        zbytek = m.group(2)
        st_vsude = (druh == "stavební")

    # Zbytek se dělí po čárkách i u tvaru s 'č. ', protože i tam
    # může být seznam: 'č. 2342/504, 2342/505, 2342/506 Stodůlky'.
    # Segmenty, které nezačínají číslem, se přeskakují — jsou to
    # 'podíl na společných částech …' a 'díl 2'.
    najdene = set()
    for seg in (s.strip() for s in zbytek.split(",")):
        if not seg:
            continue
        sm = VZOR_SEGMENT.match(seg)
        if not sm:
            continue
        cislo = ("st. " if (sm.group(1) or st_vsude) else "") + sm.group(2)
        najdene.add(normalizuj(cislo))

    if najdene:
        return najdene, None
    return set(), "seznam_neparsovan"


# ---------------------------------------------------------------
# ROZBOR
# ---------------------------------------------------------------

DOTAZ = """
SELECT v.id, v.nemovitost, v.cislo_vkladu, v.popis,
       k.id AS kn_id, k.parcel_number
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data k ON k.id_valuo = v.id
ORDER BY v.id
"""


def rozbor(cur):
    """Vrátí (vazby_navic, vazby_osamele). Rozdíl je podstatný:

       NAVÍC    řádek má i správnou parcelu z popisu, cizí je
                jen přívažek — smazáním se nic neztratí
       OSAMĚLÁ  řádek má JEN cizí parcelu, správná v databázi
                vůbec není — po smazání zůstane bez parcely
    """
    print("Čtu vazby parcel…")
    cur.execute(DOTAZ)

    # nejdřív posbírat po řádcích Valuo_data
    radky = {}
    duvody = {}
    nezparsovano = {}
    radku = 0

    for r in cur.fetchall():
        radku += 1
        nalezene, duvod = cisla_parcel(r.popis)
        if duvod:
            nezparsovano[r.nemovitost] = \
                nezparsovano.get(r.nemovitost, 0) + 1
            duvody[duvod] = duvody.get(duvod, 0) + 1
            continue
        z = radky.setdefault(r.id, {"nem": r.nemovitost, "ok": [],
                                    "cizi": []})
        if normalizuj(r.parcel_number) in nalezene:
            z["ok"].append(r.parcel_number)
        else:
            z["cizi"].append((r.kn_id, r.id, r.parcel_number,
                              r.cislo_vkladu, r.popis))

    navic, osamele = [], []
    st = {}
    for z in radky.values():
        s = st.setdefault(z["nem"], [0, 0, 0])
        if not z["cizi"]:
            s[0] += 1
        elif z["ok"]:
            s[1] += 1
            navic.extend(z["cizi"])
        else:
            s[2] += 1
            osamele.extend(z["cizi"])

    print(f"  vazeb celkem: {radku}, řádků Valuo_data: {len(radky)}\n")
    print(f"  {'nemovitost':<12} {'vše z popisu':>13} {'cizí navíc':>11}"
          f" {'jen cizí':>9} {'nezparsováno':>13}")
    for nem in sorted(st, key=lambda x: -sum(st[x])):
        s = st[nem]
        print(f"  {str(nem):<12} {s[0]:>13} {s[1]:>11} {s[2]:>9}"
              f" {nezparsovano.get(nem, 0):>13}")

    if duvody:
        print("\n  popisy, kterým parser nerozumí (nechávají se být):")
        for d, n in sorted(duvody.items(), key=lambda x: -x[1]):
            print(f"    {d:<22} {n:>7}")

    print(f"\n  vazeb k smazání: {len(navic)} cizích navíc,"
          f" {len(osamele)} osamělých")
    return navic, osamele


def ukazky(k_smazani, nadpis):
    if not k_smazani:
        return
    print(f"\n  {nadpis} — ukázky:")
    for kn_id, id_v, parcela, vklad, popis in k_smazani[:5]:
        kratky = re.sub(r"\s+", " ", popis)[:94]
        print(f"    id_valuo {id_v:>7}  parcela {parcela:<10} {vklad}")
        print(f"      {kratky}")

    podle_cisla = {}
    for _, _, parcela, _, _ in k_smazani:
        podle_cisla[parcela] = podle_cisla.get(parcela, 0) + 1
    print(f"    nejčastější: ", end="")
    print(", ".join(f"{p} ({n}x)" for p, n in
                    sorted(podle_cisla.items(), key=lambda x: -x[1])[:8]))


# ---------------------------------------------------------------
# MAZÁNÍ
# ---------------------------------------------------------------

# KN_parcel_data.id je IDENTITY a SELECT * INTO tu vlastnost
# zkopíruje, takže vkládání s původními id pak skončí chybou
#   An explicit value for the identity column ... can only be
#   specified when a column list is used and IDENTITY_INSERT is ON
# UNION ALL to obejde: nad spojením dvou dotazů SQL Server IDENTITY
# neurčí a sloupec vznikne jako obyčejný int. Prázdná tabulka
# s existující IDENTITY se zahodí a vytvoří znovu.
ZALOHA = """
IF OBJECT_ID('dbo.KN_parcel_data_zaloha_23g') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.KN_parcel_data_zaloha_23g)
    DROP TABLE dbo.KN_parcel_data_zaloha_23g;

IF OBJECT_ID('dbo.KN_parcel_data_zaloha_23g') IS NULL
    SELECT * INTO dbo.KN_parcel_data_zaloha_23g FROM (
        SELECT * FROM dbo.KN_parcel_data WHERE 1 = 0
        UNION ALL
        SELECT * FROM dbo.KN_parcel_data WHERE 1 = 0
    ) x;
"""


def smaz(cn, k_smazani):
    cur = cn.cursor()
    cur.execute(ZALOHA)
    cn.commit()

    # kontrola, že se do zálohy opravdu dá vkládat s původními id
    cur.execute("""SELECT COUNT(*) FROM sys.identity_columns
                   WHERE object_id =
                         OBJECT_ID('dbo.KN_parcel_data_zaloha_23g')""")
    if cur.fetchone()[0]:
        sys.exit("Záložní tabulka má IDENTITY na id a nedá se do ní "
                 "vkládat.\nZahoď ji a spusť znovu:\n"
                 "    DROP TABLE dbo.KN_parcel_data_zaloha_23g;")

    ids = [r[0] for r in k_smazani]
    zalohovano = smazano_up = smazano = 0

    for i in range(0, len(ids), DAVKA):
        davka = ids[i:i + DAVKA]
        otazniky = ",".join("?" * len(davka))

        cur.execute(
            f"INSERT INTO dbo.KN_parcel_data_zaloha_23g "
            f"SELECT * FROM dbo.KN_parcel_data WHERE id IN ({otazniky})",
            davka)
        zalohovano += cur.rowcount

        cur.execute(
            f"DELETE FROM dbo.KN_parcel_UP WHERE kn_id IN ({otazniky})",
            davka)
        smazano_up += cur.rowcount

        cur.execute(
            f"DELETE FROM dbo.KN_parcel_data WHERE id IN ({otazniky})",
            davka)
        smazano += cur.rowcount

        cn.commit()
        print(f"  {min(i + DAVKA, len(ids))} / {len(ids)}", end="\r")

    print(f"\n  zálohováno do KN_parcel_data_zaloha_23g: {zalohovano}")
    print(f"  smazáno vazeb na funkční využití:         {smazano_up}")
    print(f"  smazáno parcel:                           {smazano}")


KONTROLA = """
SELECT v.nemovitost, COUNT(*) AS vazeb,
       COUNT(DISTINCT v.id) AS radku_valuo
FROM dbo.Valuo_data v
JOIN dbo.KN_parcel_data k ON k.id_valuo = v.id
GROUP BY v.nemovitost ORDER BY COUNT(*) DESC
"""

KONTROLA_94800 = """
SELECT p.parcel_number, p.kat_uzemi,
       CAST(p.areaValue_m2 AS decimal(12,0)) AS vymera
FROM dbo.v_KN_parcely p WHERE p.id_valuo = 94800
"""


def kontrola(cur):
    print("\nStav po opravě:")
    cur.execute(KONTROLA)
    for r in cur.fetchall():
        print(f"  {str(r[0]):<12} {r[1]:>8} vazeb na {r[2]:>7} řádků")

    print("\n  doložený případ id_valuo 94800 — má zůstat jen 1340:")
    cur.execute(KONTROLA_94800)
    radky = cur.fetchall()
    for r in radky:
        print(f"    parcela {r[0]:<10} {r[1]:<20} {r[2]:>8} m2")
    if len(radky) == 1 and radky[0][0] == "1340":
        print("    v pořádku")
    else:
        print("    POZOR: nečekaný výsledek")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--smazat", action="store_true",
                    help="smaže cizí parcely navíc u řádků, které mají "
                         "i správnou parcelu z popisu")
    ap.add_argument("--i-osamele", action="store_true",
                    help="smaže i tam, kde je cizí parcela jediná a "
                         "řádek po smazání zůstane bez parcely")
    a = ap.parse_args()

    with pyodbc.connect(CONN) as cn:
        cur = cn.cursor()
        navic, osamele = rozbor(cur)

        if not navic and not osamele:
            print("\nŽádné cizí vazby. Nic k mazání.")
            return

        ukazky(navic, "CIZÍ NAVÍC (řádek má i správnou parcelu)")
        ukazky(osamele, "JEN CIZÍ (správná parcela v databázi není)")

        ke_smazani = list(navic)
        if a.i_osamele:
            ke_smazani += osamele

        if not a.smazat:
            print(f"\n{'=' * 64}")
            print("NIC SE NESMAZALO. Co by se smazalo:")
            print(f"    --smazat                {len(navic)} vazeb "
                  f"(cizí navíc)")
            print(f"    --smazat --i-osamele    {len(navic) + len(osamele)}"
                  f" vazeb (i osamělé)")
            print()
            print("Osamělé smaž jen vědomě: ten řádek pak nebude mít")
            print("žádnou parcelu, dokud se správná nedotáhne z katastru")
            print("krokem 17.")
            print(f"{'=' * 64}")
            return

        if not ke_smazani:
            print("\nNic k mazání ve zvoleném režimu.")
            return

        print(f"\nMažu {len(ke_smazani)} vazeb"
              f"{' včetně osamělých' if a.i_osamele else ''}…")
        smaz(cn, ke_smazani)
        kontrola(cn.cursor())
        if not a.i_osamele and osamele:
            print(f"\n{len(osamele)} osamělých cizích vazeb zůstalo "
                  f"nedotčených.")
        print("\nHotovo. Mapu hromadných převodů restartuj, "
              "ať se překreslí.")


if __name__ == "__main__":
    main()
