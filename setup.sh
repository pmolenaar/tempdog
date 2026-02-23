#!/usr/bin/env bash
# =============================================================================
# Tempdog Setup
#
# Draait direct op een Raspberry Pi met een verse Raspberry Pi OS installatie.
# Installeert en configureert het volledige temperatuurmonitoringsysteem.
#
# Vereisten:
#   - Raspberry Pi met Raspberry Pi OS Lite (64-bit / Bookworm)
#   - Internetverbinding
#   - Zigbee USB-stick (bv. Sonoff ZBDongle-P of -E)
#
# Gebruik:
#   sudo bash setup.sh
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
[[ $EUID -ne 0 ]] && error "Dit script moet als root worden uitgevoerd: sudo bash setup.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Controleer dat we op een Pi (of ARM64 Linux) draaien
ARCH="$(uname -m)"
if [[ "${ARCH}" != "aarch64" && "${ARCH}" != "arm64" && "${ARCH}" != "armv7l" ]]; then
    warn "Dit systeem is geen ARM-architectuur (${ARCH})."
    warn "Dit script is bedoeld voor Raspberry Pi."
    read -rp "Toch doorgaan? [j/N]: " CONFIRM
    [[ "${CONFIRM}" =~ ^[jJyY]$ ]] || exit 1
fi

echo ""
echo "============================================================================="
echo "  Tempdog Setup - Kantoor Temperatuur Monitoring"
echo "============================================================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Pi model selecteren
# ---------------------------------------------------------------------------
echo "Op welk Raspberry Pi model draait dit systeem?"
echo ""
echo "  1) Raspberry Pi 3 (1 GB RAM)"
echo "  2) Raspberry Pi 4 / 5 (2+ GB RAM)"
echo ""
read -rp "Keuze [2]: " PI_MODEL_CHOICE
PI_MODEL_CHOICE="${PI_MODEL_CHOICE:-2}"

if [[ "${PI_MODEL_CHOICE}" == "1" ]]; then
    info "Pi 3 geselecteerd: swap wordt geconfigureerd"
    # Swap vergroten naar 512 MB
    if [ -f /etc/dphys-swapfile ]; then
        sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
        sed -i 's/^#CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
    else
        echo "CONF_SWAPSIZE=512" > /etc/dphys-swapfile
    fi
    systemctl restart dphys-swapfile 2>/dev/null || true
    info "Swapfile ingesteld op 512 MB"
else
    info "Pi 4/5 geselecteerd"
fi

# ---------------------------------------------------------------------------
# 2. Hostname instellen
# ---------------------------------------------------------------------------
info "Hostname instellen op 'tempdog'..."
echo "tempdog" > /etc/hostname
sed -i 's/127\.0\.1\.1.*/127.0.1.1\ttempdog/' /etc/hosts
hostname tempdog

# ---------------------------------------------------------------------------
# 3. WiFi power management uitschakelen (voorkomt connectiviteitsproblemen)
# ---------------------------------------------------------------------------
info "WiFi power management uitschakelen..."
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf <<EOF
[connection]
wifi.powersave = 2
EOF
systemctl restart NetworkManager 2>/dev/null || true
info "WiFi power saving uitgeschakeld"

# ---------------------------------------------------------------------------
# 4. Installatie uitvoeren
# ---------------------------------------------------------------------------
info "Tempdog installatie starten..."
bash "${SCRIPT_DIR}/install.sh"

# ---------------------------------------------------------------------------
# 5. Samenvatting
# ---------------------------------------------------------------------------
PI_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
PI_IP=${PI_IP:-"<ip-adres>"}

echo ""
echo "============================================================================="
info "Setup voltooid!"
echo "============================================================================="
echo ""
echo "  Tempdog dashboard:     http://${PI_IP}:8080"
echo "  Zigbee2MQTT frontend:  http://${PI_IP}:8081"
echo "  Of via hostname:       http://tempdog.local:8080"
echo ""
echo "  Volgende stappen:"
echo "    1. Sluit de Zigbee USB-stick aan en controleer het pad:"
echo "         ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null"
echo ""
echo "    2. Pas zo nodig de serial port aan:"
echo "         sudo nano /opt/zigbee2mqtt/data/configuration.yaml"
echo ""
echo "    3. Start Zigbee2MQTT:"
echo "         sudo systemctl start zigbee2mqtt"
echo ""
echo "    4. Pair sensoren via http://${PI_IP}:8081"
echo "         - Klik 'Permit join' aan"
echo "         - Zet de sensor in pairing-modus"
echo "         - Hernoem naar de naam in config.yaml"
echo ""
echo "    5. Configureer e-mail alerts:"
echo "         sudo nano /etc/tempdog/config.yaml"
echo ""
echo "    6. Herstart services na wijzigingen:"
echo "         sudo systemctl restart tempdog-monitor"
echo ""
echo "============================================================================="
