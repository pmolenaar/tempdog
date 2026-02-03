# Tempdog

Temperatuurmonitoring voor kantoorgebouwen met Zigbee sensoren op een Raspberry Pi. Logt metingen, toont een realtime dashboard en stuurt e-mailalerts bij significante temperatuurafwijkingen.

## Architectuur

```
Zigbee sensoren  →  USB-stick  →  Zigbee2MQTT  →  Mosquitto (MQTT)
                                                        │
                                                   monitor.py
                                                    │       │
                                               SQLite DB  E-mail alerts
                                                    │
                                                  web.py
                                               (dashboard)
```

## Hardware

| Component | Aanbeveling | Indicatieprijs |
|---|---|---|
| Single-board computer | Raspberry Pi 4 of 5 | ~50 EUR |
| Zigbee coordinator | Sonoff ZBDongle-P (CC2652P) of ZBDongle-E | ~15 EUR |
| Temperatuursensoren (2-3x) | Aqara WSDCGQ11LM (temp + vocht + druk) | ~12 EUR/stuk |

## Installatie

Kopieer het project naar de Pi en voer het installatiescript uit:

```bash
git clone https://github.com/pmolenaar/tempdog.git
cd tempdog
sudo bash install.sh
```

Het script installeert automatisch Mosquitto, Node.js, Zigbee2MQTT, Python dependencies en alle systemd services.

### Na installatie

1. **Zigbee USB-stick configureren** -- controleer het serial port en pas het aan indien nodig:

   ```bash
   ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
   sudo nano /opt/zigbee2mqtt/data/configuration.yaml
   sudo systemctl start zigbee2mqtt
   ```

2. **Sensoren pairen** -- open de Zigbee2MQTT frontend op `http://<pi-ip>:8081`, schakel "Permit join" in en zet de sensor in pairing-modus (zie handleiding van de sensor). Hernoem elke sensor naar de naam uit de config, bijvoorbeeld `kantoor_begane_grond`.

3. **E-mailalerts instellen** -- vul de SMTP-gegevens in:

   ```bash
   sudo nano /etc/tempdog/config.yaml
   sudo systemctl restart tempdog-monitor
   ```

## Dashboard benaderen

Het webdashboard draait als service op de Pi en is bereikbaar via elke browser op het lokale netwerk.

### URL

```
http://<ip-adres-van-de-pi>:8080
```

Het IP-adres van de Pi vind je door op de Pi zelf te draaien:

```bash
hostname -I
```

Of kijk in de DHCP-lijst van je router. Als het IP-adres bijvoorbeeld `192.168.1.42` is, ga je naar:

```
http://192.168.1.42:8080
```

### Wat toont het dashboard

- **Kaarten per sensor** -- actuele temperatuur, luchtvochtigheid en batterijpercentage met een statusindicator:
  - Groen: meting < 15 minuten oud
  - Oranje: meting 15-60 minuten oud
  - Rood: meting > 60 minuten oud (sensor mogelijk offline)
- **Grafieken per sensor** -- temperatuur- en luchtvochtigheidsverloop over tijd, met knoppen om het bereik te wisselen (6 uur, 24 uur, 3 dagen, 7 dagen)

Het dashboard ververst automatisch elke 30 seconden.

### API endpoints

Het dashboard biedt ook JSON endpoints die je kunt gebruiken voor eigen integraties:

| Endpoint | Beschrijving |
|---|---|
| `GET /api/current` | Laatste meting per sensor |
| `GET /api/history/<sensor>` | Laatste ~2880 metingen van een sensor |
| `GET /api/history/<sensor>/<uren>` | Metingen van de afgelopen N uur |

### Vast IP-adres instellen (optioneel)

Om te voorkomen dat het IP-adres van de Pi verandert, kun je een vast adres instellen:

```bash
sudo nmcli con mod "Wired connection 1" \
  ipv4.addresses 192.168.1.42/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns 192.168.1.1 \
  ipv4.method manual
sudo nmcli con up "Wired connection 1"
```

## Alerting

Er worden e-mails verstuurd in twee situaties:

- **Snelle temperatuurverandering** op een sensor (standaard >= 2 graden C verschil met de vorige meting)
- **Groot verschil tussen sensoren** (standaard >= 5 graden C tussen twee meetpunten)

Alle drempelwaarden en de cooldown (standaard 15 minuten) zijn instelbaar in `/etc/tempdog/config.yaml`.

## Configuratie

Het configuratiebestand staat op de Pi in `/etc/tempdog/config.yaml`. De belangrijkste secties:

| Sectie | Wat het regelt |
|---|---|
| `sensors` | Lijst van sensornamen en labels |
| `alerting.delta_threshold` | Drempel voor snelle verandering per sensor (°C) |
| `alerting.cross_sensor_threshold` | Drempel voor verschil tussen sensoren (°C) |
| `alerting.cooldown_seconds` | Minimale tijd tussen herhaalde alerts |
| `alerting.smtp` | SMTP-server, credentials en ontvangers |
| `web.port` | Poort van het dashboard (standaard 8080) |

Herstart na wijzigingen:

```bash
sudo systemctl restart tempdog-monitor
sudo systemctl restart tempdog-web
```

## Logs bekijken

```bash
journalctl -u tempdog-monitor -f
journalctl -u tempdog-web -f
journalctl -u zigbee2mqtt -f
```

## Licentie

MIT
