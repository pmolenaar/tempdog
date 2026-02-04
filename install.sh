#!/usr/bin/env bash
# =============================================================================
# Tempdog Installer
# Installeert het volledige temperatuurmonitoringsysteem op Raspberry Pi OS.
#
# Gebruik:
#   sudo bash install.sh
#
# Wat wordt geinstalleerd:
#   - Mosquitto (MQTT broker)
#   - Zigbee2MQTT (Zigbee coordinator)
#   - Tempdog monitor + web dashboard
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Kleuren
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Controles
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "Dit script moet als root worden uitgevoerd (sudo)."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detecteer of systemd actief is (niet het geval in een chroot)
SYSTEMD_ACTIVE=false
if [ -d /run/systemd/system ]; then
    SYSTEMD_ACTIVE=true
fi

info "Tempdog installer gestart"
info "Bronbestanden: ${SCRIPT_DIR}"
${SYSTEMD_ACTIVE} || info "Chroot-modus gedetecteerd: services worden ingeschakeld maar niet gestart"

# ---------------------------------------------------------------------------
# 1. Systeempakketten
# ---------------------------------------------------------------------------
info "Systeempakketten bijwerken..."
apt-get update -qq
apt-get install -y -qq \
    python3 python3-venv python3-pip \
    mosquitto mosquitto-clients \
    git curl wget jq \
    sqlite3

# ---------------------------------------------------------------------------
# 2. Node.js (voor Zigbee2MQTT)
# ---------------------------------------------------------------------------
if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 18 ]]; then
    info "Node.js 20 LTS installeren..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
fi
info "Node.js versie: $(node -v)"

# ---------------------------------------------------------------------------
# 3. Zigbee2MQTT
# ---------------------------------------------------------------------------
Z2M_DIR="/opt/zigbee2mqtt"
if [[ ! -d "${Z2M_DIR}" ]]; then
    info "Zigbee2MQTT installeren..."
    git clone --depth 1 https://github.com/Koenkk/zigbee2mqtt.git "${Z2M_DIR}"
    cd "${Z2M_DIR}"
    npm ci --production
    cd "${SCRIPT_DIR}"
else
    info "Zigbee2MQTT is al aanwezig, overslaan."
fi

# Zigbee2MQTT configuratie (minimaal)
Z2M_DATA="${Z2M_DIR}/data"
mkdir -p "${Z2M_DATA}"
if [[ ! -f "${Z2M_DATA}/configuration.yaml" ]]; then
    info "Zigbee2MQTT basisconfiguratie aanmaken..."
    cat > "${Z2M_DATA}/configuration.yaml" <<'YAML'
# Zigbee2MQTT configuratie
# Pas het serial-pad aan naar je Zigbee coordinator.
# Veelgebruikte paden:
#   Sonoff ZBDongle-P (CC2652P):  /dev/ttyUSB0
#   Sonoff ZBDongle-E (EFR32):    /dev/ttyACM0
#   Conbee II:                     /dev/ttyACM0
homeassistant: false
permit_join: false
mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://localhost
serial:
  port: /dev/ttyACM0
frontend:
  port: 8081
advanced:
  log_level: info
  network_key: GENERATE
YAML
    warn "BELANGRIJK: Controleer /opt/zigbee2mqtt/data/configuration.yaml"
    warn "  - Pas 'serial.port' aan naar het pad van je Zigbee USB-stick"
fi

# Zigbee2MQTT systemd service
if [[ ! -f /etc/systemd/system/zigbee2mqtt.service ]]; then
    info "Zigbee2MQTT systemd service aanmaken..."
    cat > /etc/systemd/system/zigbee2mqtt.service <<EOF
[Unit]
Description=Zigbee2MQTT
After=network.target mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
User=root
WorkingDirectory=${Z2M_DIR}
ExecStart=$(command -v node) index.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
fi

# ---------------------------------------------------------------------------
# 4. Tempdog applicatie
# ---------------------------------------------------------------------------
INSTALL_DIR="/opt/tempdog"
CONFIG_DIR="/etc/tempdog"
DATA_DIR="/var/lib/tempdog"
LOG_DIR="/var/log/tempdog"

info "Tempdog installeren naar ${INSTALL_DIR}..."

# Gebruiker aanmaken
if ! id tempdog &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin tempdog
fi

# Directories
mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}"

# Bestanden kopieren
cp "${SCRIPT_DIR}/monitor.py" "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/web.py"     "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/requirements.txt" "${INSTALL_DIR}/"
cp -r "${SCRIPT_DIR}/templates" "${INSTALL_DIR}/"

# Configuratie (alleen als er nog geen is)
if [[ ! -f "${CONFIG_DIR}/config.yaml" ]]; then
    cp "${SCRIPT_DIR}/config.yaml" "${CONFIG_DIR}/config.yaml"
    warn "Pas de configuratie aan: ${CONFIG_DIR}/config.yaml"
    warn "  - Stel SMTP-gegevens in voor e-mailalerts"
    warn "  - Controleer sensornamen na pairing"
fi

# Python virtual environment
info "Python virtual environment aanmaken..."
python3 -m venv "${INSTALL_DIR}/venv"
"${INSTALL_DIR}/venv/bin/pip" install --quiet --upgrade pip
"${INSTALL_DIR}/venv/bin/pip" install --quiet -r "${INSTALL_DIR}/requirements.txt"

# Rechten
chown -R tempdog:tempdog "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}"
chown -R tempdog:tempdog "${CONFIG_DIR}"

# Systemd services
info "Systemd services installeren..."
cp "${SCRIPT_DIR}/systemd/tempdog-monitor.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/systemd/tempdog-web.service"     /etc/systemd/system/

# ---------------------------------------------------------------------------
# 5. Services activeren
# ---------------------------------------------------------------------------
info "Services activeren..."

if ${SYSTEMD_ACTIVE}; then
    systemctl daemon-reload
fi

systemctl enable mosquitto
systemctl enable zigbee2mqtt
systemctl enable tempdog-monitor
systemctl enable tempdog-web

if ${SYSTEMD_ACTIVE}; then
    systemctl start mosquitto

    # Zigbee2MQTT nog niet starten als config nog default is
    if grep -q "/dev/ttyACM0" "${Z2M_DATA}/configuration.yaml"; then
        warn "Zigbee2MQTT is geconfigureerd met de standaard serial port (/dev/ttyACM0)."
        warn "Controleer of dit klopt voor jouw Zigbee USB-stick voordat je start:"
        warn "  sudo systemctl start zigbee2mqtt"
    else
        systemctl start zigbee2mqtt
    fi

    systemctl start tempdog-monitor
    systemctl start tempdog-web
fi

# ---------------------------------------------------------------------------
# 6. Samenvatting
# ---------------------------------------------------------------------------
PI_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
PI_IP=${PI_IP:-"<ip-adres>"}

echo ""
echo "============================================================================="
info "Installatie voltooid!"
echo "============================================================================="
echo ""
echo "  Tempdog dashboard:     http://${PI_IP}:8080"
echo "  Zigbee2MQTT frontend:  http://${PI_IP}:8081"
echo ""
echo "  Volgende stappen:"
echo "    1. Controleer de Zigbee USB-stick serial port:"
echo "         ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null"
echo "         nano /opt/zigbee2mqtt/data/configuration.yaml"
echo ""
echo "    2. Start Zigbee2MQTT:"
echo "         sudo systemctl start zigbee2mqtt"
echo ""
echo "    3. Pair sensoren via de Zigbee2MQTT frontend (http://${PI_IP}:8081):"
echo "         - Klik 'Permit join' aan"
echo "         - Zet de sensor in pairing-modus (zie handleiding sensor)"
echo "         - Hernoem de sensor naar de naam in config.yaml"
echo "           (bv. kantoor_begane_grond)"
echo ""
echo "    4. Configureer e-mail alerts:"
echo "         sudo nano /etc/tempdog/config.yaml"
echo ""
echo "    5. Herstart na configuratiewijzigingen:"
echo "         sudo systemctl restart tempdog-monitor"
echo ""
echo "  Logs bekijken:"
echo "    journalctl -u tempdog-monitor -f"
echo "    journalctl -u tempdog-web -f"
echo "    journalctl -u zigbee2mqtt -f"
echo ""
echo "============================================================================="
