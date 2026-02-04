#!/usr/bin/env bash
# =============================================================================
# Tempdog First Boot
# Draait eenmalig bij de eerste keer opstarten van de Pi.
# =============================================================================

set -euo pipefail

LOG="/var/log/tempdog-firstboot.log"
exec > >(tee -a "$LOG") 2>&1

echo "[firstboot] $(date): Eerste boot configuratie gestart"

# ---------------------------------------------------------------------------
# 1. Filesystem uitbreiden naar volledige SD-kaart
# ---------------------------------------------------------------------------
ROOT_PART="$(findmnt -n -o SOURCE /)"
ROOT_DEV="$(lsblk -no PKNAME "${ROOT_PART}")"
PART_NUM="$(echo "${ROOT_PART}" | grep -o '[0-9]*$')"

echo "[firstboot] Root partitie: ${ROOT_PART} op /dev/${ROOT_DEV}, partitie ${PART_NUM}"

# Verwijder de partitielimiet en maak hem zo groot als de schijf
growpart "/dev/${ROOT_DEV}" "${PART_NUM}" || true
resize2fs "${ROOT_PART}" || true

echo "[firstboot] Filesystem uitgebreid"

# ---------------------------------------------------------------------------
# 2. SSH host keys regenereren (veiligheid: elke Pi moet unieke keys hebben)
# ---------------------------------------------------------------------------
echo "[firstboot] SSH host keys regenereren..."
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A
systemctl restart ssh || systemctl restart sshd || true

# ---------------------------------------------------------------------------
# 3. Machine-id regenereren (uniek per installatie)
# ---------------------------------------------------------------------------
echo "[firstboot] Machine-id regenereren..."
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup

# ---------------------------------------------------------------------------
# 4. Zigbee2MQTT network key genereren (als nog op GENERATE staat)
# ---------------------------------------------------------------------------
Z2M_CONFIG="/opt/zigbee2mqtt/data/configuration.yaml"
if [ -f "${Z2M_CONFIG}" ] && grep -q "network_key: GENERATE" "${Z2M_CONFIG}"; then
    echo "[firstboot] Zigbee2MQTT network_key wordt gegenereerd bij eerste start"
fi

# ---------------------------------------------------------------------------
# 5. Zichzelf uitschakelen
# ---------------------------------------------------------------------------
echo "[firstboot] Eerste boot configuratie voltooid, service uitschakelen"
systemctl disable tempdog-firstboot.service

echo "[firstboot] $(date): Klaar"
