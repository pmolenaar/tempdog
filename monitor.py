#!/usr/bin/env python3
"""
Tempdog Monitor - MQTT subscriber die Zigbee2MQTT temperatuurdata logt,
bewaakt en bij significante afwijkingen e-mailalerts verstuurt.
"""

import json
import logging
import smtplib
import sqlite3
import sys
import time
from datetime import datetime, timedelta
from email.mime.text import MIMEText
from pathlib import Path

import paho.mqtt.client as mqtt
import yaml

# ---------------------------------------------------------------------------
# Configuratie
# ---------------------------------------------------------------------------

def load_config(path: str = "/etc/tempdog/config.yaml") -> dict:
    with open(path) as f:
        return yaml.safe_load(f)

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

def init_db(db_path: str) -> sqlite3.Connection:
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS readings (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            sensor     TEXT    NOT NULL,
            temperature REAL   NOT NULL,
            humidity   REAL,
            battery    INTEGER,
            ts         TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now','localtime'))
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_readings_sensor_ts ON readings(sensor, ts)
    """)
    conn.commit()
    return conn

def store_reading(conn: sqlite3.Connection, sensor: str, temp: float,
                  humidity: float | None, battery: int | None):
    conn.execute(
        "INSERT INTO readings (sensor, temperature, humidity, battery) VALUES (?,?,?,?)",
        (sensor, temp, humidity, battery),
    )
    conn.commit()

def get_last_reading(conn: sqlite3.Connection, sensor: str) -> float | None:
    row = conn.execute(
        "SELECT temperature FROM readings WHERE sensor=? ORDER BY id DESC LIMIT 1 OFFSET 1",
        (sensor,),
    ).fetchone()
    return row[0] if row else None

def get_latest_per_sensor(conn: sqlite3.Connection) -> dict[str, float]:
    rows = conn.execute("""
        SELECT sensor, temperature
        FROM readings
        WHERE id IN (SELECT MAX(id) FROM readings GROUP BY sensor)
    """).fetchall()
    return {r[0]: r[1] for r in rows}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------

class Alerter:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.last_alert: dict[str, datetime] = {}

    def _cooldown_ok(self, key: str) -> bool:
        cd = self.cfg["alerting"]["cooldown_seconds"]
        last = self.last_alert.get(key)
        if last and datetime.now() - last < timedelta(seconds=cd):
            return False
        return True

    def _send_email(self, subject: str, body: str):
        smtp_cfg = self.cfg["alerting"]["smtp"]
        msg = MIMEText(body, "plain", "utf-8")
        msg["Subject"] = f"[Tempdog] {subject}"
        msg["From"] = smtp_cfg["from"]
        msg["To"] = ", ".join(smtp_cfg["to"])

        try:
            with smtplib.SMTP(smtp_cfg["host"], smtp_cfg["port"]) as s:
                if smtp_cfg.get("use_tls"):
                    s.starttls()
                s.login(smtp_cfg["username"], smtp_cfg["password"])
                s.sendmail(smtp_cfg["from"], smtp_cfg["to"], msg.as_string())
            logging.info("Alert e-mail verstuurd: %s", subject)
        except Exception:
            logging.exception("Kan alert e-mail niet versturen")

    def check_delta(self, sensor: str, current: float, previous: float | None):
        if previous is None:
            return
        delta = abs(current - previous)
        threshold = self.cfg["alerting"]["delta_threshold"]
        if delta >= threshold:
            key = f"delta:{sensor}"
            if not self._cooldown_ok(key):
                return
            self.last_alert[key] = datetime.now()
            direction = "gestegen" if current > previous else "gedaald"
            self._send_email(
                f"Temperatuur {direction} op {sensor}",
                f"Sensor: {sensor}\n"
                f"Vorige meting: {previous:.1f} °C\n"
                f"Huidige meting: {current:.1f} °C\n"
                f"Delta: {delta:.1f} °C (drempel: {threshold:.1f} °C)\n"
                f"Tijdstip: {datetime.now():%Y-%m-%d %H:%M:%S}",
            )

    def check_cross_sensor(self, latest: dict[str, float]):
        threshold = self.cfg["alerting"]["cross_sensor_threshold"]
        sensors = list(latest.items())
        for i, (s1, t1) in enumerate(sensors):
            for s2, t2 in sensors[i + 1:]:
                delta = abs(t1 - t2)
                if delta >= threshold:
                    key = f"cross:{s1}:{s2}"
                    if not self._cooldown_ok(key):
                        continue
                    self.last_alert[key] = datetime.now()
                    self._send_email(
                        f"Groot verschil tussen {s1} en {s2}",
                        f"{s1}: {t1:.1f} °C\n"
                        f"{s2}: {t2:.1f} °C\n"
                        f"Verschil: {delta:.1f} °C (drempel: {threshold:.1f} °C)\n"
                        f"Tijdstip: {datetime.now():%Y-%m-%d %H:%M:%S}",
                    )

# ---------------------------------------------------------------------------
# MQTT
# ---------------------------------------------------------------------------

def make_on_message(cfg, conn, alerter):
    sensor_names = {s["name"] for s in cfg["sensors"]}
    prefix = cfg["mqtt"]["topic_prefix"]

    def on_message(_client, _userdata, msg):
        # Zigbee2MQTT publiceert op <prefix>/<friendly_name>
        parts = msg.topic.split("/")
        if len(parts) < 2:
            return
        sensor = parts[1]
        if sensor not in sensor_names:
            return

        try:
            payload = json.loads(msg.payload)
        except json.JSONDecodeError:
            logging.warning("Ongeldig JSON payload op %s", msg.topic)
            return

        temp = payload.get("temperature")
        if temp is None:
            return

        humidity = payload.get("humidity")
        battery = payload.get("battery")
        logging.info("%s: %.1f °C  humidity=%s  battery=%s", sensor, temp, humidity, battery)

        previous = get_last_reading(conn, sensor)
        store_reading(conn, sensor, temp, humidity, battery)

        alerter.check_delta(sensor, temp, previous)
        latest = get_latest_per_sensor(conn)
        alerter.check_cross_sensor(latest)

    return on_message

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else "/etc/tempdog/config.yaml"
    cfg = load_config(config_path)

    log_path = cfg["logging"]["path"]
    Path(log_path).parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=cfg["logging"]["level"],
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(log_path),
            logging.StreamHandler(),
        ],
    )
    logging.info("Tempdog monitor gestart")

    conn = init_db(cfg["database"]["path"])
    alerter = Alerter(cfg)

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_message = make_on_message(cfg, conn, alerter)

    topic = f"{cfg['mqtt']['topic_prefix']}/#"
    logging.info("Verbinden met MQTT %s:%d, topic %s",
                 cfg["mqtt"]["host"], cfg["mqtt"]["port"], topic)

    client.connect(cfg["mqtt"]["host"], cfg["mqtt"]["port"])
    client.subscribe(topic)
    client.loop_forever()


if __name__ == "__main__":
    main()
