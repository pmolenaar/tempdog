#!/usr/bin/env python3
"""
Tempdog Web - Lichtgewicht Flask dashboard voor temperatuurvisualisatie.
"""

import sqlite3
import sys
from pathlib import Path

import yaml
from flask import Flask, g, jsonify, render_template

from util import is_ieee_address

# ---------------------------------------------------------------------------
# Configuratie
# ---------------------------------------------------------------------------

config_path = sys.argv[1] if len(sys.argv) > 1 else "/etc/tempdog/config.yaml"
with open(config_path) as f:
    CFG = yaml.safe_load(f)

DB_PATH = CFG["database"]["path"]
SENSOR_LABELS = {s["name"]: s["label"] for s in CFG["sensors"]}

app = Flask(__name__, template_folder="/opt/tempdog/templates")

# ---------------------------------------------------------------------------
# Database helper
# ---------------------------------------------------------------------------

def get_db() -> sqlite3.Connection:
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
    return g.db

@app.teardown_appcontext
def close_db(_exc):
    db = g.pop("db", None)
    if db:
        db.close()

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
def dashboard():
    return render_template("dashboard.html")

@app.route("/api/sensors")
def api_sensors():
    """Retourneert alle bekende sensoren (config + auto-discovered uit DB)."""
    db = get_db()
    rows = db.execute("SELECT DISTINCT sensor FROM readings").fetchall()
    # Start met sensoren uit config (behoud volgorde en custom labels)
    sensors = dict(SENSOR_LABELS)
    # Voeg auto-discovered sensoren toe (naam = label), filter IEEE-adressen
    for row in rows:
        name = row[0]
        if name not in sensors and not is_ieee_address(name):
            sensors[name] = name
    return jsonify(sensors)

@app.route("/api/current")
def api_current():
    db = get_db()
    rows = db.execute("""
        SELECT sensor, temperature, humidity, battery, ts
        FROM readings
        WHERE id IN (SELECT MAX(id) FROM readings GROUP BY sensor)
    """).fetchall()
    return jsonify([dict(r) for r in rows])

@app.route("/api/history/<sensor>")
def api_history(sensor):
    db = get_db()
    rows = db.execute("""
        SELECT temperature, humidity, ts
        FROM readings
        WHERE sensor = ?
        ORDER BY id DESC
        LIMIT 2880
    """, (sensor,)).fetchall()
    # Chronologisch (oudste eerst)
    data = [dict(r) for r in reversed(rows)]
    return jsonify(data)

@app.route("/api/history/<sensor>/<int:hours>")
def api_history_hours(sensor, hours):
    db = get_db()
    rows = db.execute("""
        SELECT temperature, humidity, ts
        FROM readings
        WHERE sensor = ?
          AND ts >= datetime('now', 'localtime', ?)
        ORDER BY ts ASC
    """, (sensor, f"-{hours} hours")).fetchall()
    return jsonify([dict(r) for r in rows])

@app.route("/api/history/<sensor>/workday")
def api_history_workday(sensor):
    """Retourneert alleen metingen van vandaag tussen 7:00 en 18:00."""
    db = get_db()
    rows = db.execute("""
        SELECT temperature, humidity, ts
        FROM readings
        WHERE sensor = ?
          AND date(ts) = date('now', 'localtime')
          AND cast(strftime('%H', ts) as integer) >= 7
          AND cast(strftime('%H', ts) as integer) < 18
        ORDER BY ts ASC
    """, (sensor,)).fetchall()
    return jsonify([dict(r) for r in rows])

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app.run(
        host=CFG["web"]["host"],
        port=CFG["web"]["port"],
        debug=False,
    )
