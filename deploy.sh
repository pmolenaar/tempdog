#!/usr/bin/env bash
# =============================================================================
# Tempdog Deploy
#
# Haalt de laatste code op uit git en deployt naar /opt/tempdog.
# Draai dit script op de Raspberry Pi na een push naar GitHub.
#
# Gebruik:
#   sudo bash deploy.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Dit script moet als root worden uitgevoerd: sudo bash deploy.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/tempdog"

# ---------------------------------------------------------------------------
# 1. Git pull (als gewone gebruiker, niet als root)
# ---------------------------------------------------------------------------
info "Laatste code ophalen uit git..."
REPO_OWNER="$(stat -c '%U' "${SCRIPT_DIR}/.git" 2>/dev/null || stat -f '%Su' "${SCRIPT_DIR}/.git")"
sudo -u "${REPO_OWNER}" git -C "${SCRIPT_DIR}" pull

# ---------------------------------------------------------------------------
# 2. Bestanden kopieren
# ---------------------------------------------------------------------------
info "Bestanden deployen naar ${INSTALL_DIR}..."

APP_FILES=(monitor.py web.py util.py)
for f in "${APP_FILES[@]}"; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
        cp "${SCRIPT_DIR}/${f}" "${INSTALL_DIR}/"
        info "  ${f}"
    fi
done

cp -r "${SCRIPT_DIR}/templates" "${INSTALL_DIR}/"
info "  templates/"

# requirements.txt: alleen installeren als gewijzigd
if ! diff -q "${SCRIPT_DIR}/requirements.txt" "${INSTALL_DIR}/requirements.txt" &>/dev/null; then
    info "requirements.txt gewijzigd, dependencies bijwerken..."
    cp "${SCRIPT_DIR}/requirements.txt" "${INSTALL_DIR}/"
    "${INSTALL_DIR}/venv/bin/pip" install --quiet -r "${INSTALL_DIR}/requirements.txt"
fi

# Systemd services: alleen kopieren en herladen als gewijzigd
SERVICES_CHANGED=false
for svc in tempdog-monitor.service tempdog-web.service; do
    if ! diff -q "${SCRIPT_DIR}/systemd/${svc}" "/etc/systemd/system/${svc}" &>/dev/null; then
        cp "${SCRIPT_DIR}/systemd/${svc}" "/etc/systemd/system/"
        SERVICES_CHANGED=true
        info "  systemd/${svc} bijgewerkt"
    fi
done
${SERVICES_CHANGED} && systemctl daemon-reload

# ---------------------------------------------------------------------------
# 3. Rechten herstellen
# ---------------------------------------------------------------------------
chown -R tempdog:tempdog "${INSTALL_DIR}"

# ---------------------------------------------------------------------------
# 4. Services herstarten
# ---------------------------------------------------------------------------
info "Services herstarten..."
systemctl restart tempdog-monitor tempdog-web

sleep 2

if systemctl is-active --quiet tempdog-monitor && systemctl is-active --quiet tempdog-web; then
    info "Deploy voltooid! Beide services draaien."
else
    warn "Een of meer services zijn niet gestart. Controleer met:"
    warn "  journalctl -u tempdog-monitor -n 20"
    warn "  journalctl -u tempdog-web -n 20"
fi
