#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
netmon.py - sonda pro diagnostiku opakovaných výpadků (RB5009 za dvojitým NAT)
E:\\DATA_ANALYSIS\\NETMON\\netmon.py

POUŽITÍ (běží v terminálu VS Code, Ctrl+C ukončí):

    python netmon.py --init     # jednorázově: založí DB NetMon + tabulky a pohledy
    python netmon.py            # sběr dat; nechte okno otevřené, jak dlouho chcete
    python netmon.py --test     # jeden cyklus, vypíše výsledek a skončí (ověření nastavení)

Přerušení sběru nevadí - v datech vznikne mezera, analýza si s tím poradí.

Co měří v každém cyklu (paralelně, aby byl snímek okamžiku konzistentní):
  1) DNS přes router (192.168.88.1) i přímo na 1.1.1.1
  2) DNS s vynucením plné rekurze (náhodná subdoména -> NXDOMAIN je ÚSPĚCH),
     aby se neměřily jen zásahy do cache routeru
  3) TCP handshake na 443 i na 80, na pevné IP i na jména, plus LAN kontrolu
  4) ping na 192.168.88.1 / 192.168.11.1 / 8.8.8.8 (ztrátovost + RTT)
  5) stav RB5009 přes REST API: počet spojení v conntrack, CPU, ether1, DHCP klient

Instalace závislostí:
    pip install pyodbc dnspython requests
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import random
import re
import socket
import string
import subprocess
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import dns.resolver
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

BASE_DIR = Path(__file__).resolve().parent          # E:\DATA_ANALYSIS\NETMON

# ======================================================================
# KONFIGURACE - jediné místo, kde je potřeba něco měnit
# ======================================================================

# --- MS SQL ---------------------------------------------------------
SQL_DRIVER   = "ODBC Driver 17 for SQL Server"
SQL_SERVER   = "localhost"          # pojmenovaná instance: r"localhost\SQLEXPRESS"
SQL_DATABASE = "NetMon"

def sql_conn_str(database: str = SQL_DATABASE) -> str:
    return (f"Driver={{{SQL_DRIVER}}};"
            f"Server={SQL_SERVER};"
            f"Database={database};"
            f"Trusted_Connection=yes;")

# --- RB5009 REST API ------------------------------------------------
ROUTER_BASE = "http://192.168.88.1"          # nebo https://192.168.88.1 při www-ssl
ROUTER_USER = "monitor"
ROUTER_PASS = "JeTe_Monitor"                             # <-- doplnit heslo uživatele 'monitor'
                                             #     (prázdné = REST se přeskočí)

CONFIG = {
    "interval_s": 30,          # 30 s = ~20 vzorků uvnitř 10minutového výpadku

    "dns_servers": {
        "router": "192.168.88.1",
        "cloudflare": "1.1.1.1",
    },
    "dns_names": ["www.idnes.cz", "www.novinky.cz", "www.seznam.cz"],
    "dns_nocache_domain": "idnes.cz",
    "dns_timeout_s": 3.0,

    # (host, port, popis); IP cíle nezávisí na DNS = čistá kontrola
    "tcp_targets": [
        ("1.1.1.1",        443, "ip"),      # kontrola bez DNS
        ("8.8.8.8",        443, "ip"),
        ("1.1.1.1",         80, "ip80"),    # rozliší "padá jen 443" vs "padá každé nové TCP"
        ("www.idnes.cz",   443, "name"),
        ("www.novinky.cz", 443, "name"),
        ("192.168.88.1",  8291, "lan"),     # WinBox port = kontrola lokálního stacku
    ],
    "tcp_timeout_s": 4.0,

    "ping_targets": ["192.168.88.1", "192.168.11.1", "8.8.8.8"],
    "ping_count": 4,
    "ping_timeout_ms": 1000,

    "router_wan_if": "ether1",
    "router_timeout_s": 5.0,

    "fallback_file": BASE_DIR / "netmon_fallback.jsonl",
    "schema_file":   BASE_DIR / "netmon_schema.sql",
}

# heslo lze přebít proměnnou prostředí, ať nemusí být v gitu
ROUTER_PASS = os.environ.get("NETMON_ROUTER_PASS") or ROUTER_PASS

SOURCE_HOST = socket.gethostname()
IS_WINDOWS = platform.system() == "Windows"
IS_MAC = platform.system() == "Darwin"


# ======================================================================
# SONDY
# ======================================================================

def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)


def probe_dns(server: str, name: str, kind: str = "dns") -> dict:
    """Dotaz na A záznam přes konkrétní resolver.
    U kind='dns_nocache' je NXDOMAIN očekávaný a bere se jako ÚSPĚCH -
    prokazuje, že proběhla celá rekurze až k autoritativnímu serveru."""
    r = dns.resolver.Resolver(configure=False)
    r.nameservers = [server]
    r.timeout = CONFIG["dns_timeout_s"]
    r.lifetime = CONFIG["dns_timeout_s"]
    t0 = time.perf_counter()
    try:
        ans = r.resolve(name, "A")
        ms = (time.perf_counter() - t0) * 1000
        return dict(Kind=kind, Target=f"{server}|{name}", Ok=1, LatencyMs=ms,
                    Detail=",".join(a.address for a in ans)[:400])
    except dns.resolver.NXDOMAIN:
        ms = (time.perf_counter() - t0) * 1000
        ok = 1 if kind == "dns_nocache" else 0
        return dict(Kind=kind, Target=f"{server}|{name}", Ok=ok, LatencyMs=ms,
                    Detail="NXDOMAIN (očekáváno)" if ok else "NXDOMAIN")
    except Exception as e:
        ms = (time.perf_counter() - t0) * 1000
        return dict(Kind=kind, Target=f"{server}|{name}", Ok=0, LatencyMs=ms,
                    Detail=f"{type(e).__name__}: {e}"[:400])


def probe_tcp(host: str, port: int, tag: str) -> dict:
    """Čistý TCP handshake (SYN -> SYN/ACK -> ACK), bez TLS.
    Selhání = zahozený SYN, přesně to, co ukázalo předchozí měření."""
    t0 = time.perf_counter()
    try:
        with socket.create_connection((host, port), timeout=CONFIG["tcp_timeout_s"]):
            ms = (time.perf_counter() - t0) * 1000
            return dict(Kind="tcp", Target=f"{host}:{port}", Ok=1, LatencyMs=ms, Detail=tag)
    except Exception as e:
        ms = (time.perf_counter() - t0) * 1000
        return dict(Kind="tcp", Target=f"{host}:{port}", Ok=0, LatencyMs=ms,
                    Detail=f"{tag} | {type(e).__name__}: {e}"[:400])


_PING_MS = re.compile(r"[=<]\s*(\d+(?:[.,]\d+)?)\s*ms", re.IGNORECASE)


def probe_ping(host: str) -> dict:
    """Ping přes systémový příkaz. Parsuje se regulárním výrazem na 'čas=12ms' /
    'time=12ms' - funguje na české i anglické Windows i na macOS."""
    n = CONFIG["ping_count"]
    if IS_WINDOWS:
        cmd = ["ping", "-n", str(n), "-w", str(CONFIG["ping_timeout_ms"]), host]
    elif IS_MAC:
        cmd = ["ping", "-c", str(n), "-W", str(CONFIG["ping_timeout_ms"]), host]
    else:
        cmd = ["ping", "-c", str(n), "-W",
               str(max(1, CONFIG["ping_timeout_ms"] // 1000)), host]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=n * 2 + 5,
                             encoding="utf-8", errors="replace").stdout

        times = []
        for line in out.splitlines():
            low = line.lower()
            if "ttl=" not in low:          # souhrnná statistika TTL neobsahuje
                continue

            m = _PING_MS.search(line)
            if m:
                times.append(float(m.group(1).replace(",", ".")))
            elif "<1" in line or "<1ms" in low:
                times.append(0.5)          # "time<1ms" = pod rozlišením


        
        loss = 100.0 * (n - len(times)) / n
        avg = sum(times) / len(times) if times else None
        return dict(Kind="ping", Target=host, Ok=1 if times else 0,
                    LatencyMs=avg, LossPct=loss, Detail=f"{len(times)}/{n} odpovědí")
    except Exception as e:
        return dict(Kind="ping", Target=host, Ok=0, LatencyMs=None, LossPct=100.0,
                    Detail=f"{type(e).__name__}: {e}"[:400])


def probe_router() -> dict:
    """Stav RB5009 přes REST API (RouterOS 7). Vrací řádek do NetMon_Router."""
    if not ROUTER_PASS:
        return {}
    base = ROUTER_BASE.rstrip("/")
    to = CONFIG["router_timeout_s"]
    row = dict(Reachable=0)
    try:
        s = requests.Session()
        s.auth = (ROUTER_USER, ROUTER_PASS)
        s.verify = False

        # conntrack: total-entries / max-entries = klíčový ukazatel pro hypotézu
        ct = s.get(f"{base}/rest/ip/firewall/connection/tracking", timeout=to).json()
        if isinstance(ct, list):
            ct = ct[0] if ct else {}
        row["ConnTotal"] = int(ct.get("total-entries", 0) or 0)
        row["ConnMax"] = int(ct.get("max-entries", 0) or 0)

        res = s.get(f"{base}/rest/system/resource", timeout=to).json()
        if isinstance(res, list):
            res = res[0] if res else {}
        row["CpuLoad"] = int(res.get("cpu-load", 0) or 0)
        row["FreeMemory"] = int(res.get("free-memory", 0) or 0)
        row["Uptime"] = str(res.get("uptime", ""))[:32]

        wan = s.get(f"{base}/rest/interface/{CONFIG['router_wan_if']}", timeout=to).json()
        if isinstance(wan, list):
            wan = wan[0] if wan else {}
        row["Ether1Running"] = 1 if str(wan.get("running", "")).lower() == "true" else 0
        row["Ether1RxByte"] = int(wan.get("rx-byte", 0) or 0)
        row["Ether1TxByte"] = int(wan.get("tx-byte", 0) or 0)

        # link-downs je dostupné jen přes monitor; když selže, není to fatální
        try:
            mon = s.post(f"{base}/rest/interface/ethernet/monitor",
                         json={"numbers": CONFIG["router_wan_if"], "once": ""},
                         timeout=to).json()
            if isinstance(mon, list):
                mon = mon[0] if mon else {}
            row["Ether1LinkDowns"] = int(mon.get("link-downs", 0) or 0)
        except Exception:
            row["Ether1LinkDowns"] = None

        dhcp = s.get(f"{base}/rest/ip/dhcp-client", timeout=to).json()
        if isinstance(dhcp, list) and dhcp:
            dhcp = dhcp[0]
            row["DhcpStatus"] = str(dhcp.get("status", ""))[:32]
            row["DhcpExpires"] = str(dhcp.get("expires-after", ""))[:32]

        row["Reachable"] = 1
    except Exception as e:
        row["Error"] = f"{type(e).__name__}: {e}"[:300]
    return row


# ======================================================================
# ZALOŽENÍ DATABÁZE  (python netmon.py --init)
# ======================================================================

def init_database() -> None:
    import pyodbc
    sql_path = CONFIG["schema_file"]
    if not sql_path.exists():
        sys.exit(f"Nenalezen soubor se schématem: {sql_path}")
    text = sql_path.read_text(encoding="utf-8")
    # rozdělit na dávky podle samostatných řádků 'GO'
    batches = [b.strip() for b in re.split(r"(?im)^\s*GO\s*$", text) if b.strip()]
    # připojit se k master - CREATE DATABASE nelze spustit z jiné DB
    conn = pyodbc.connect(sql_conn_str("master"), autocommit=True, timeout=10)
    cur = conn.cursor()
    for i, batch in enumerate(batches, 1):
        try:
            cur.execute(batch)
        except Exception as e:
            print(f"  ! dávka {i} selhala: {e}", file=sys.stderr)
    cur.close()
    conn.close()
    print(f"Databáze {SQL_DATABASE} a objekty jsou připraveny "
          f"(schéma: {sql_path.name}).")


# ======================================================================
# ZÁPIS DO MS SQL (s bezpečnostní sítí do souboru)
# ======================================================================

PROBE_SQL = """
INSERT INTO dbo.NetMon_Probe
    (RunTsUtc, ProbeTsUtc, SourceHost, Kind, Target, Ok, LatencyMs, LossPct, Detail)
VALUES (?,?,?,?,?,?,?,?,?)
"""

ROUTER_SQL = """
INSERT INTO dbo.NetMon_Router
    (RunTsUtc, Reachable, ConnTotal, ConnMax, CpuLoad, FreeMemory, Uptime,
     Ether1Running, Ether1LinkDowns, Ether1RxByte, Ether1TxByte,
     DhcpStatus, DhcpExpires, Error)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
"""


class Writer:
    def __init__(self, fallback: Path):
        self.fallback = Path(fallback)
        self.conn = None

    def _connect(self):
        import pyodbc
        self.conn = pyodbc.connect(sql_conn_str(), timeout=5, autocommit=True)

    def write(self, run_ts, probes, router) -> bool:
        payload = {"run_ts": run_ts.isoformat(), "probes": probes, "router": router}
        try:
            if self.conn is None:
                self._connect()
            cur = self.conn.cursor()
            cur.executemany(PROBE_SQL, [
                (run_ts, p["ProbeTs"], SOURCE_HOST, p["Kind"], p["Target"],
                 p["Ok"], p.get("LatencyMs"), p.get("LossPct"), p.get("Detail"))
                for p in probes
            ])
            if router:
                cur.execute(ROUTER_SQL, (
                    run_ts, router.get("Reachable", 0), router.get("ConnTotal"),
                    router.get("ConnMax"), router.get("CpuLoad"), router.get("FreeMemory"),
                    router.get("Uptime"), router.get("Ether1Running"),
                    router.get("Ether1LinkDowns"), router.get("Ether1RxByte"),
                    router.get("Ether1TxByte"), router.get("DhcpStatus"),
                    router.get("DhcpExpires"), router.get("Error")))
            cur.close()
            self._flush_fallback()
            return True
        except Exception as e:
            self.conn = None
            print(f"  [SQL nedostupné: {e}] -> ukládám do {self.fallback.name}",
                  file=sys.stderr)
            with self.fallback.open("a", encoding="utf-8") as f:
                f.write(json.dumps(payload, default=str, ensure_ascii=False) + "\n")
            return False

    def _flush_fallback(self):
        """Po obnovení SQL doplní data nasbíraná během výpadku."""
        if not self.fallback.exists() or self.fallback.stat().st_size == 0:
            return
        lines = self.fallback.read_text(encoding="utf-8").splitlines()
        cur = self.conn.cursor()
        for line in lines:
            try:
                rec = json.loads(line)
                rts = dt.datetime.fromisoformat(rec["run_ts"])
                cur.executemany(PROBE_SQL, [
                    (rts, dt.datetime.fromisoformat(p["ProbeTs"]), SOURCE_HOST,
                     p["Kind"], p["Target"], p["Ok"], p.get("LatencyMs"),
                     p.get("LossPct"), p.get("Detail")) for p in rec["probes"]])
                r = rec.get("router") or {}
                if r:
                    cur.execute(ROUTER_SQL, (
                        rts, r.get("Reachable", 0), r.get("ConnTotal"), r.get("ConnMax"),
                        r.get("CpuLoad"), r.get("FreeMemory"), r.get("Uptime"),
                        r.get("Ether1Running"), r.get("Ether1LinkDowns"),
                        r.get("Ether1RxByte"), r.get("Ether1TxByte"),
                        r.get("DhcpStatus"), r.get("DhcpExpires"), r.get("Error")))
            except Exception:
                continue
        cur.close()
        self.fallback.unlink()
        print(f"  [doplněno {len(lines)} cyklů z {self.fallback.name}]")


# ======================================================================
# HLAVNÍ SMYČKA
# ======================================================================

def build_tasks():
    tasks = []
    for srv in CONFIG["dns_servers"].values():
        for name in CONFIG["dns_names"]:
            tasks.append((probe_dns, (srv, name, "dns")))
    rnd = "".join(random.choices(string.ascii_lowercase + string.digits, k=12))
    tasks.append((probe_dns, (CONFIG["dns_servers"]["router"],
                              f"{rnd}.{CONFIG['dns_nocache_domain']}", "dns_nocache")))
    for host, port, tag in CONFIG["tcp_targets"]:
        tasks.append((probe_tcp, (host, port, tag)))
    for host in CONFIG["ping_targets"]:
        tasks.append((probe_ping, (host,)))
    return tasks


def run_cycle(writer: Writer | None, stats: Counter):
    run_ts = _now().replace(microsecond=0)
    tasks = build_tasks()
    probes = []
    with ThreadPoolExecutor(max_workers=len(tasks) + 1) as ex:
        fut_router = ex.submit(probe_router)
        futs = [ex.submit(fn, *args) for fn, args in tasks]
        for f in futs:
            try:
                r = f.result()
            except Exception as e:
                r = dict(Kind="err", Target="-", Ok=0, Detail=str(e)[:400])
            r["ProbeTs"] = _now()
            probes.append(r)
        try:
            router = fut_router.result()
        except Exception as e:
            router = dict(Reachable=0, Error=str(e)[:300])

    fails = [p for p in probes if p["Ok"] == 0]
    stats["cycles"] += 1
    stats["probes"] += len(probes)
    for p in fails:
        stats[f"fail:{p['Kind']}"] += 1

    stamp = dt.datetime.now().strftime("%H:%M:%S")
    conn = router.get("ConnTotal", "-")
    if fails:
        print(f"{stamp}  ! {len(fails)}/{len(probes)} SELHÁNÍ   conn={conn}")
        for p in fails:
            print(f"           {p['Kind']:<12} {p['Target']:<30} {str(p.get('Detail',''))[:80]}")
    else:
        print(f"{stamp}  ok  {len(probes)} sond   conn={conn}")

    if writer is not None:
        writer.write(run_ts, probes, router)


def main():
    ap = argparse.ArgumentParser(description="NetMon - sonda pro diagnostiku výpadků")
    ap.add_argument("--init", action="store_true",
                    help="založí databázi NetMon, tabulky a pohledy, pak skončí")
    ap.add_argument("--test", action="store_true",
                    help="jeden cyklus bez zápisu do SQL, pro ověření nastavení")
    ap.add_argument("--interval", type=int, default=None, help="perioda v sekundách")
    args = ap.parse_args()

    if args.init:
        init_database()
        return

    if args.interval:
        CONFIG["interval_s"] = args.interval

    print(f"NetMon | zdroj: {SOURCE_HOST} | složka: {BASE_DIR}")
    print(f"        SQL: {SQL_SERVER}/{SQL_DATABASE} přes {SQL_DRIVER}")
    if not ROUTER_PASS:
        print("        ! heslo k RB5009 není vyplněné - REST API routeru se přeskočí")

    if args.test:
        run_cycle(None, Counter())
        return

    print(f"        interval {CONFIG['interval_s']} s | Ctrl+C ukončí\n")
    writer = Writer(CONFIG["fallback_file"])
    stats = Counter()
    t_start = time.time()
    try:
        while True:
            t0 = time.time()
            try:
                run_cycle(writer, stats)
            except Exception as e:
                print(f"  [chyba cyklu] {type(e).__name__}: {e}", file=sys.stderr)
            time.sleep(max(1.0, CONFIG["interval_s"] - (time.time() - t0)))
    except KeyboardInterrupt:
        mins = (time.time() - t_start) / 60
        print(f"\nUkončeno. Běželo {mins:.0f} min, {stats['cycles']} cyklů, "
              f"{stats['probes']} sond.")
        fails = {k.split(':')[1]: v for k, v in stats.items() if k.startswith("fail:")}
        print("Selhání:", fails if fails else "žádná")


if __name__ == "__main__":
    main()
