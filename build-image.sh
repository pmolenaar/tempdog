#!/usr/bin/env bash
# =============================================================================
# Tempdog Image Builder
#
# Genereert een kant-en-klaar Raspberry Pi OS image met alles voorgeinstalleerd.
# Draait op macOS (of Linux) via Docker.
#
# Vereisten:
#   - Docker Desktop (draaiend)
#
# Gebruik:
#   bash build-image.sh
#
# Output:
#   tempdog-YYYYMMDD.img  (klaar om te flashen naar SD-kaart)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuratie
# ---------------------------------------------------------------------------
PI_OS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz"
PI_OS_ARCHIVE="raspios-bookworm-arm64-lite.img.xz"
PI_OS_IMG="raspios-bookworm-arm64-lite.img"
IMAGE_SIZE_GB=6
OUTPUT_IMG="tempdog-$(date +%Y%m%d).img"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Kleuren
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Controles
# ---------------------------------------------------------------------------
if ! docker info &>/dev/null; then
    error "Docker is niet beschikbaar. Start Docker Desktop en probeer opnieuw."
fi
info "Docker is beschikbaar"

# ---------------------------------------------------------------------------
# 2. Pi model selecteren
# ---------------------------------------------------------------------------
echo ""
echo "Op welk Raspberry Pi model gaat Tempdog draaien?"
echo ""
echo "  1) Raspberry Pi 3 (1 GB RAM)"
echo "  2) Raspberry Pi 4 / 5 (2+ GB RAM)"
echo ""
read -rp "Keuze [2]: " PI_MODEL_CHOICE
PI_MODEL_CHOICE="${PI_MODEL_CHOICE:-2}"

ENABLE_SWAP=false
if [[ "${PI_MODEL_CHOICE}" == "1" ]]; then
    ENABLE_SWAP=true
    info "Pi 3 geselecteerd: 512 MB swapfile wordt geconfigureerd"
else
    info "Pi 4/5 geselecteerd: geen extra swap nodig"
fi

# ---------------------------------------------------------------------------
# 3. Raspberry Pi OS image downloaden
# ---------------------------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/${PI_OS_IMG}" ]]; then
    info "Pi OS image gevonden (cache): ${PI_OS_IMG}"
elif [[ -f "${SCRIPT_DIR}/${PI_OS_ARCHIVE}" ]]; then
    info "Pi OS archief gevonden, uitpakken..."
    xz -dk "${SCRIPT_DIR}/${PI_OS_ARCHIVE}"
else
    info "Raspberry Pi OS Lite (64-bit) downloaden..."
    curl -L -o "${SCRIPT_DIR}/${PI_OS_ARCHIVE}" "${PI_OS_URL}"
    info "Uitpakken..."
    xz -dk "${SCRIPT_DIR}/${PI_OS_ARCHIVE}"
fi

# Maak werkkopie
info "Werkkopie aanmaken: ${OUTPUT_IMG}"
cp "${SCRIPT_DIR}/${PI_OS_IMG}" "${SCRIPT_DIR}/${OUTPUT_IMG}"

# ---------------------------------------------------------------------------
# 3. Docker container script
# ---------------------------------------------------------------------------
# Dit script draait BINNEN de Docker container
INNER_SCRIPT=$(cat <<'INNERSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

IMG="/work/output.img"
MNT="/mnt/pi"
PROJECT="/work/project"
IMAGE_SIZE_GB="${IMAGE_SIZE_GB}"
ENABLE_SWAP="${ENABLE_SWAP}"

# --- Tools installeren ---
info "Container-tools installeren..."
apt-get update -qq
apt-get install -y -qq \
    qemu-user-static binfmt-support \
    parted e2fsprogs dosfstools \
    kpartx util-linux \
    curl wget xz-utils git ca-certificates \
    file

# --- binfmt registreren voor aarch64 ---
info "ARM64 emulatie registreren..."
update-binfmts --enable qemu-aarch64 2>/dev/null || true
# Fallback: handmatig registreren
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F' \
        > /proc/sys/fs/binfmt_misc/register 2>/dev/null || warn "binfmt registratie overgeslagen (mogelijk al actief)"
fi

# --- Image vergroten ---
info "Image vergroten naar ${IMAGE_SIZE_GB} GB..."
CURRENT_SIZE=$(stat -c%s "${IMG}")
TARGET_SIZE=$((IMAGE_SIZE_GB * 1024 * 1024 * 1024))
if [ "${CURRENT_SIZE}" -lt "${TARGET_SIZE}" ]; then
    truncate -s "${IMAGE_SIZE_GB}G" "${IMG}"
fi

# --- Partities opzetten ---
info "Partitietabel bijwerken..."
# Lees de start van de rootfs partitie
ROOT_START=$(parted -ms "${IMG}" unit s print 2>/dev/null | grep "^2:" | cut -d: -f2 | tr -d 's')
# Verwijder partitie 2 en maak opnieuw tot einde schijf
parted -s "${IMG}" rm 2
parted -s "${IMG}" mkpart primary ext4 "${ROOT_START}s" 100%

# Loop device opzetten
info "Loop device configureren..."
LOOP=$(losetup --find --show --partscan "${IMG}")
info "Loop device: ${LOOP}"

# Wacht op partitie-devices
sleep 2
partprobe "${LOOP}" 2>/dev/null || true
sleep 1

BOOT_PART="${LOOP}p1"
ROOT_PART="${LOOP}p2"

# Controleer dat partities bestaan
if [ ! -b "${ROOT_PART}" ]; then
    # Fallback: kpartx gebruiken
    kpartx -av "${IMG}"
    LOOP_NAME=$(basename "${LOOP}")
    BOOT_PART="/dev/mapper/${LOOP_NAME}p1"
    ROOT_PART="/dev/mapper/${LOOP_NAME}p2"
fi

# --- Filesystem resizen ---
info "Filesystem uitbreiden..."
e2fsck -fy "${ROOT_PART}" || true
resize2fs "${ROOT_PART}"

# --- Mounten ---
info "Partities mounten..."
mkdir -p "${MNT}"
mount "${ROOT_PART}" "${MNT}"
mount "${BOOT_PART}" "${MNT}/boot/firmware" 2>/dev/null \
    || mount "${BOOT_PART}" "${MNT}/boot" 2>/dev/null \
    || warn "Boot partitie mount overgeslagen"

# Bind mounts voor chroot
mount --bind /dev     "${MNT}/dev"
mount --bind /dev/pts "${MNT}/dev/pts"
mount --bind /proc    "${MNT}/proc"
mount --bind /sys     "${MNT}/sys"

# --- qemu binary kopieren naar chroot ---
QEMU_BIN=$(which qemu-aarch64-static 2>/dev/null || echo "/usr/bin/qemu-aarch64-static")
if [ -f "${QEMU_BIN}" ]; then
    cp "${QEMU_BIN}" "${MNT}/usr/bin/qemu-aarch64-static"
    info "qemu-aarch64-static gekopieerd naar chroot"
fi

# --- DNS resolver beschikbaar maken in chroot ---
cp /etc/resolv.conf "${MNT}/etc/resolv.conf"

# --- Tempdog bronbestanden kopieren ---
info "Tempdog bronbestanden kopieren naar chroot..."
CHROOT_SRC="/tmp/tempdog-src"
mkdir -p "${MNT}${CHROOT_SRC}"
cp "${PROJECT}/install.sh"       "${MNT}${CHROOT_SRC}/"
cp "${PROJECT}/monitor.py"       "${MNT}${CHROOT_SRC}/"
cp "${PROJECT}/web.py"           "${MNT}${CHROOT_SRC}/"
cp "${PROJECT}/config.yaml"      "${MNT}${CHROOT_SRC}/"
cp "${PROJECT}/requirements.txt" "${MNT}${CHROOT_SRC}/"
cp "${PROJECT}/firstboot.sh"     "${MNT}${CHROOT_SRC}/"
cp -r "${PROJECT}/templates"     "${MNT}${CHROOT_SRC}/"
cp -r "${PROJECT}/systemd"       "${MNT}${CHROOT_SRC}/"

# --- Chroot: install.sh uitvoeren ---
info "=== Chroot gestart: installatie uitvoeren ==="
chroot "${MNT}" /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C
    export LANG=C

    cd /tmp/tempdog-src
    bash install.sh
"
info "=== Chroot installatie voltooid ==="

# --- SSH inschakelen ---
info "SSH inschakelen..."
# Raspberry Pi OS: ssh service enablen
chroot "${MNT}" /bin/bash -c "systemctl enable ssh 2>/dev/null || true"
# Bookworm methode: touch bestand in boot partitie
BOOT_DIR=""
if mountpoint -q "${MNT}/boot/firmware"; then
    BOOT_DIR="${MNT}/boot/firmware"
elif mountpoint -q "${MNT}/boot"; then
    BOOT_DIR="${MNT}/boot"
fi
if [ -n "${BOOT_DIR}" ]; then
    touch "${BOOT_DIR}/ssh"
    info "SSH marker aangemaakt in boot partitie"
fi

# --- Hostname instellen ---
info "Hostname instellen op 'tempdog'..."
echo "tempdog" > "${MNT}/etc/hostname"
sed -i 's/127\.0\.1\.1.*/127.0.1.1\ttempdog/' "${MNT}/etc/hosts"

# --- Standaard gebruiker aanmaken (pi/tempdog) ---
info "Standaard gebruiker configureren (pi, wachtwoord: tempdog)..."
if [ -n "${BOOT_DIR}" ]; then
    # Raspberry Pi OS bookworm: userconf.txt in boot partitie
    # Formaat: gebruikersnaam:encrypted-password
    ENCRYPTED_PW=$(openssl passwd -6 "tempdog")
    echo "pi:${ENCRYPTED_PW}" > "${BOOT_DIR}/userconf.txt"
fi

# --- Swap configureren (Pi 3) ---
if [ "${ENABLE_SWAP}" = "true" ]; then
    info "Swapfile configureren voor Pi 3 (512 MB)..."
    # dphys-swapfile is standaard aanwezig in Pi OS, configuratie aanpassen
    if [ -f "${MNT}/etc/dphys-swapfile" ]; then
        sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' "${MNT}/etc/dphys-swapfile"
        sed -i 's/^#CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' "${MNT}/etc/dphys-swapfile"
    else
        echo "CONF_SWAPSIZE=512" > "${MNT}/etc/dphys-swapfile"
    fi
    chroot "${MNT}" /bin/bash -c "systemctl enable dphys-swapfile 2>/dev/null || true"
    info "Swapfile van 512 MB wordt aangemaakt bij eerste boot"
else
    info "Geen extra swap geconfigureerd"
fi

# --- Firstboot service installeren ---
info "Firstboot service installeren..."
cp "${PROJECT}/firstboot.sh" "${MNT}/opt/tempdog/firstboot.sh"
chmod +x "${MNT}/opt/tempdog/firstboot.sh"
cp "${PROJECT}/systemd/tempdog-firstboot.service" "${MNT}/etc/systemd/system/"
chroot "${MNT}" /bin/bash -c "systemctl enable tempdog-firstboot.service"

# --- Opruimen in chroot ---
info "Opruimen..."
chroot "${MNT}" /bin/bash -c "
    apt-get clean
    rm -rf /var/cache/apt/archives/*.deb
    rm -rf /tmp/tempdog-src
    rm -f /usr/bin/qemu-aarch64-static
"

# --- Unmounten ---
info "Unmounten..."
sync
umount -lf "${MNT}/dev/pts" 2>/dev/null || true
umount -lf "${MNT}/dev"     2>/dev/null || true
umount -lf "${MNT}/proc"    2>/dev/null || true
umount -lf "${MNT}/sys"     2>/dev/null || true
umount -lf "${MNT}/boot/firmware" 2>/dev/null || true
umount -lf "${MNT}/boot"    2>/dev/null || true
umount -lf "${MNT}"         2>/dev/null || true

# --- Loop device vrijgeven ---
losetup -d "${LOOP}" 2>/dev/null || true
kpartx -d "${IMG}" 2>/dev/null || true

# --- PiShrink (image verkleinen) ---
info "Image verkleinen met PiShrink..."
if [ ! -f /usr/local/bin/pishrink.sh ]; then
    curl -fsSL https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh \
        -o /usr/local/bin/pishrink.sh
    chmod +x /usr/local/bin/pishrink.sh
fi
/usr/local/bin/pishrink.sh -s "${IMG}" || warn "PiShrink overgeslagen"

info "=== Image build voltooid ==="
INNERSCRIPT
)

# ---------------------------------------------------------------------------
# 4. Docker container starten
# ---------------------------------------------------------------------------
info "Docker container starten voor image build..."
info "Dit kan lang duren (packages downloaden + compileren in ARM emulatie)"

# Schrijf inner script naar tijdelijk bestand
INNER_SCRIPT_FILE="${SCRIPT_DIR}/.build-inner.sh"
echo "${INNER_SCRIPT}" > "${INNER_SCRIPT_FILE}"
chmod +x "${INNER_SCRIPT_FILE}"

docker run --rm --privileged \
    -v "${SCRIPT_DIR}/${OUTPUT_IMG}:/work/output.img" \
    -v "${SCRIPT_DIR}:/work/project:ro" \
    -v "${INNER_SCRIPT_FILE}:/work/build.sh:ro" \
    -e "IMAGE_SIZE_GB=${IMAGE_SIZE_GB}" \
    -e "ENABLE_SWAP=${ENABLE_SWAP}" \
    debian:bookworm \
    bash /work/build.sh

# Opruimen
rm -f "${INNER_SCRIPT_FILE}"

# ---------------------------------------------------------------------------
# 5. Resultaat
# ---------------------------------------------------------------------------
IMG_SIZE=$(ls -lh "${SCRIPT_DIR}/${OUTPUT_IMG}" | awk '{print $5}')

echo ""
echo "============================================================================="
info "Image succesvol gegenereerd!"
echo "============================================================================="
echo ""
echo "  Bestand: ${OUTPUT_IMG}"
echo "  Grootte: ${IMG_SIZE}"
echo ""
echo "  Flashen naar SD-kaart:"
echo "    Optie 1 - Raspberry Pi Imager:"
echo "      Kies 'Use custom' en selecteer ${OUTPUT_IMG}"
echo ""
echo "    Optie 2 - dd (geavanceerd):"
echo "      diskutil list                           # vind SD-kaart"
echo "      diskutil unmountDisk /dev/diskN         # unmount"
echo "      sudo dd if=${OUTPUT_IMG} of=/dev/rdiskN bs=4m status=progress"
echo ""
echo "  Na het booten:"
echo "    SSH:       ssh pi@tempdog.local  (wachtwoord: tempdog)"
echo "    Dashboard: http://tempdog.local:8080"
echo "    Zigbee2MQTT: http://tempdog.local:8081"
echo ""
echo "  BELANGRIJK: Wijzig het standaard wachtwoord na eerste login!"
echo "    passwd"
echo ""
echo "============================================================================="
