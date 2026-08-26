#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
netmon_report.py - vytáhne data z MS SQL a vygeneruje interaktivní HTML graf.
E:\\DATA_ANALYSIS\\NETMON\\netmon_report.py

    pip install pyodbc pandas plotly
    python netmon_report.py          # posledních 24 h
    python netmon_report.py 48       # posledních 48 h

Výstup: netmon_report.html ve stejné složce, otevře se automaticky v prohlížeči.
Čtyři pásma nad sebou se sdílenou časovou osou, takže je vidět, co selhalo první:
    1) selhání TCP handshake (443 vs 80 vs LAN)
    2) selhání a latence DNS (včetně necachované rekurze)
    3) ztrátovost pingu na tři cíle
    4) počet spojení v conntrack RB5009 + CPU
Červené svislé pruhy = minuty se selhaným TCP handshakem.
"""

import sys
import warnings
import webbrowser
from pathlib import Path

import pandas as pd
import plotly.graph_objects as go
import pyodbc
from plotly.subplots import make_subplots

warnings.filterwarnings("ignore", message=".*pandas only supports SQLAlchemy.*")

BASE_DIR = Path(__file__).resolve().parent

# --- musí odpovídat nastavení v netmon.py ---
SQL_DRIVER   = "ODBC Driver 17 for SQL Server"
SQL_SERVER   = "localhost"
SQL_DATABASE = "NetMon"
CONN = (f"Driver={{{SQL_DRIVER}}};Server={SQL_SERVER};"
        f"Database={SQL_DATABASE};Trusted_Connection=yes;")

hours = int(sys.argv[1]) if len(sys.argv) > 1 else 24

cn = pyodbc.connect(CONN, timeout=10)
probe = pd.read_sql(f"""
    SELECT RunTsUtc, Kind, Target, Ok, LatencyMs, LossPct, Detail
    FROM dbo.NetMon_Probe
    WHERE RunTsUtc > DATEADD(hour, -{hours}, SYSUTCDATETIME())
""", cn)
router = pd.read_sql(f"""
    SELECT RunTsUtc, ConnTotal, CpuLoad, Reachable
    FROM dbo.NetMon_Router
    WHERE RunTsUtc > DATEADD(hour, -{hours}, SYSUTCDATETIME())
""", cn)
cn.close()

if probe.empty:
    sys.exit(f"Žádná data za posledních {hours} h. Běžel netmon.py?")

# UTC -> místní čas (Praha)
for df in (probe, router):
    if not df.empty:
        df["Ts"] = (pd.to_datetime(df["RunTsUtc"]).dt.tz_localize("UTC")
                      .dt.tz_convert("Europe/Prague").dt.tz_localize(None))

fig = make_subplots(rows=4, cols=1, shared_xaxes=True, vertical_spacing=0.04,
                    subplot_titles=("TCP handshake – selhání (1 = zahozený SYN)",
                                    "DNS – latence (ms), křížek = selhání",
                                    "Ping – ztrátovost (%)",
                                    "RB5009 – spojení v conntrack a CPU (%)"))

# --- 1) TCP ---
for tgt, g in probe[probe.Kind == "tcp"].groupby("Target"):
    fig.add_trace(go.Scatter(x=g.Ts, y=(1 - g.Ok), mode="markers", name=f"TCP {tgt}",
                             marker=dict(size=6), hovertext=g.Detail), row=1, col=1)

# --- 2) DNS ---
dns = probe[probe.Kind.str.startswith("dns")]
for tgt, g in dns.groupby("Target"):
    ok = g[g.Ok == 1]
    fig.add_trace(go.Scatter(x=ok.Ts, y=ok.LatencyMs, mode="lines",
                             name=f"DNS {tgt}", line=dict(width=1)), row=2, col=1)
bad = dns[dns.Ok == 0]
if not bad.empty:
    fig.add_trace(go.Scatter(x=bad.Ts, y=bad.LatencyMs, mode="markers",
                             name="DNS selhání", marker=dict(symbol="x", size=10),
                             hovertext=bad.Target + " | " + bad.Detail), row=2, col=1)

# --- 3) ping ---
for tgt, g in probe[probe.Kind == "ping"].groupby("Target"):
    fig.add_trace(go.Scatter(x=g.Ts, y=g.LossPct, mode="lines+markers",
                             name=f"ping {tgt}", line=dict(width=1)), row=3, col=1)

# --- 4) router ---
if not router.empty:
    fig.add_trace(go.Scatter(x=router.Ts, y=router.ConnTotal, mode="lines",
                             name="conntrack"), row=4, col=1)
    fig.add_trace(go.Scatter(x=router.Ts, y=router.CpuLoad, mode="lines",
                             name="CPU %", line=dict(dash="dot")), row=4, col=1)

# svislé pruhy v minutách, kdy selhalo TCP
for ts in probe[(probe.Kind == "tcp") & (probe.Ok == 0)].Ts.dt.floor("min").unique():
    fig.add_vrect(x0=ts, x1=pd.Timestamp(ts) + pd.Timedelta(minutes=1),
                  fillcolor="red", opacity=0.10, line_width=0)

fig.update_layout(height=1100, hovermode="x unified",
                  title=f"NetMon – posledních {hours} h (čas Europe/Prague)")

out = BASE_DIR / "netmon_report.html"
fig.write_html(out, include_plotlyjs="cdn")
print(f"Hotovo: {out}")

# --- textové shrnutí do konzole ---
tcp = probe[probe.Kind == "tcp"]
print("\nÚspěšnost TCP handshake podle cíle:")
summary = (tcp.groupby("Target")
              .agg(Pokusu=("Ok", "size"), Selhani=("Ok", lambda s: int((s == 0).sum())))
              .assign(PctSelhani=lambda d: (100 * d.Selhani / d.Pokusu).round(2))
              .sort_values("PctSelhani", ascending=False))
print(summary.to_string())

webbrowser.open(out.as_uri())
