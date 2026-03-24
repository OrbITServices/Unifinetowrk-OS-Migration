#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# UniFi Network Server -> UniFi OS Server migration helper
# Target: Debian 12+/Ubuntu 23.04+ style systems
#
# Usage:
#   sudo bash migrate-unifi-to-uos.sh "<UOS_INSTALLER_URL>"
#
# Example:
#   sudo bash migrate-unifi-to-uos.sh "https://fw-download.ubnt.com/data/unifi-os-server/...."
#
# Notes:
# - Take an in-app UniFi backup / Site Export BEFORE running this.
# - This script keeps the same VPS / same IP / same DNS.
# - This script does NOT import your site backup automatically.
# =========================================================

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root or with sudo."
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: sudo bash $0 \"<UOS_INSTALLER_URL>\""
  exit 1
fi

UOS_URL="$1"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
WORKDIR="/root/unifi-migration-${TIMESTAMP}"
INSTALLER_PATH="${WORKDIR}/uos-installer.bin"

mkdir -p "${WORKDIR}"

echo "========================================================="
echo " UniFi migration helper"
echo " Working directory: ${WORKDIR}"
echo "========================================================="

log() {
  echo
  echo ">>> $1"
}

warn() {
  echo
  echo "WARNING: $1"
}

# ---------------------------------------------------------
# 0. Basic system info
# ---------------------------------------------------------
log "Collecting basic system info"
uname -a | tee "${WORKDIR}/uname.txt"
cat /etc/os-release | tee "${WORKDIR}/os-release.txt"

# ---------------------------------------------------------
# 1. Check for existing services
# ---------------------------------------------------------
log "Checking for old UniFi service"
OLD_UNIFI_PRESENT="false"
if systemctl list-unit-files | grep -q '^unifi\.service'; then
  OLD_UNIFI_PRESENT="true"
  systemctl status unifi --no-pager || true
fi

log "Checking if UniFi OS Server already exists"
if systemctl list-unit-files | grep -q '^uosserver\.service'; then
  warn "UniFi OS Server service already exists on this machine."
  systemctl status uosserver --no-pager || true
fi

# ---------------------------------------------------------
# 2. Host-level backups
# ---------------------------------------------------------
log "Creating host-level backup copies"

mkdir -p "${WORKDIR}/backup"

# Common UniFi paths on Debian/Ubuntu installs
for path in \
  /var/lib/unifi \
  /usr/lib/unifi \
  /etc/unifi \
  /etc/systemd/system/unifi.service \
  /lib/systemd/system/unifi.service \
  /etc/apt/sources.list.d/100-ubnt-unifi.list \
  /etc/apt/trusted.gpg.d/unifi-repo.gpg
do
  if [[ -e "$path" ]]; then
    echo "Backing up $path"
    tar -cpf "${WORKDIR}/backup/$(echo "$path" | sed 's#/#_#g').tar" "$path" 2>/dev/null || cp -a "$path" "${WORKDIR}/backup/" || true
  fi
done

dpkg -l | tee "${WORKDIR}/dpkg-list.txt" >/dev/null || true
ss -tulpn | tee "${WORKDIR}/ports-before.txt" >/dev/null || true

# Optional Mongo dump if mongodump exists
if command -v mongodump >/dev/null 2>&1; then
  log "mongodump detected, attempting Mongo backup"
  mkdir -p "${WORKDIR}/mongodump"
  mongodump --out "${WORKDIR}/mongodump" || warn "mongodump failed; continuing"
else
  warn "mongodump not installed; skipping Mongo export"
fi

# ---------------------------------------------------------
# 2a. Pre-check OS and Podman version BEFORE uninstalling old UniFi
# ---------------------------------------------------------
log "Checking OS and Podman compatibility for UniFi OS Server"

# Read OS info
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
else
  echo "ERROR: Cannot read /etc/os-release"
  exit 1
fi

OS_NAME="${NAME:-Unknown}"
OS_VERSION_ID="${VERSION_ID:-0}"

echo "Detected OS: ${OS_NAME} ${OS_VERSION_ID}"

# Compare versions using dpkg
version_ge() {
  dpkg --compare-versions "$1" ge "$2"
}

SUPPORTED_OS="false"

case "${ID:-}" in
  ubuntu)
    if version_ge "$OS_VERSION_ID" "23.04"; then
      SUPPORTED_OS="true"
    fi
    ;;
  debian)
    if version_ge "$OS_VERSION_ID" "12"; then
      SUPPORTED_OS="true"
    fi
    ;;
esac

if [[ "$SUPPORTED_OS" != "true" ]]; then
  echo "ERROR: Unsupported OS version: ${OS_NAME} ${OS_VERSION_ID}"
  echo "UniFi OS Server requires Debian 12+ or Ubuntu 23.04+"
  echo "Aborting before removing the existing UniFi installation."
  exit 1
fi

# Check podman
REQUIRED_PODMAN_VERSION="4.3.1"

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is not installed."
  echo "UniFi OS Server requires podman ${REQUIRED_PODMAN_VERSION}+"
  echo "Aborting before removing the existing UniFi installation."
  exit 1
fi

CURRENT_PODMAN_VERSION="$(podman --version | awk '{print $3}')"
echo "Detected podman version: ${CURRENT_PODMAN_VERSION}"

if ! version_ge "$CURRENT_PODMAN_VERSION" "$REQUIRED_PODMAN_VERSION"; then
  echo "ERROR: Installed podman version ${CURRENT_PODMAN_VERSION} is below the required minimum version ${REQUIRED_PODMAN_VERSION}"
  echo "Aborting before removing the existing UniFi installation."
  exit 1
fi

log "Compatibility checks passed"

# ---------------------------------------------------------
# 3. Stop old UniFi
# ---------------------------------------------------------
if [[ "${OLD_UNIFI_PRESENT}" == "true" ]]; then
  log "Stopping old UniFi service"
  systemctl stop unifi || service unifi stop || true
  systemctl disable unifi || true
else
  warn "Old unifi.service not found; skipping stop/disable"
fi

# Kill any lingering Java processes tied to UniFi
log "Checking for lingering UniFi Java processes"
pgrep -a java || true

# ---------------------------------------------------------
# 4. Remove old UniFi package
# ---------------------------------------------------------
log "Removing old UniFi package if installed"
if dpkg -l | awk '{print $2}' | grep -qx "unifi"; then
  apt-get remove -y unifi || warn "apt remove unifi failed; continuing"
else
  warn "APT package 'unifi' not installed"
fi

log "Autoremoving unused packages"
apt-get autoremove -y || true

# ---------------------------------------------------------
# 5. Install UniFi OS Server prerequisites
# ---------------------------------------------------------
log "Refreshing apt and installing prerequisites"
apt-get update
apt-get install -y curl wget ca-certificates podman slirp4netns

# ---------------------------------------------------------
# 6. Download the official UniFi OS Server installer
# ---------------------------------------------------------
log "Downloading UniFi OS Server installer"
curl -fL "${UOS_URL}" -o "${INSTALLER_PATH}"

log "Making installer executable"
chmod +x "${INSTALLER_PATH}"

# ---------------------------------------------------------
# 7. Run installer
# ---------------------------------------------------------
log "Running UniFi OS Server installer"
"${INSTALLER_PATH}"

# ---------------------------------------------------------
# 8. Enable and start UniFi OS Server
# ---------------------------------------------------------
log "Enabling and starting UniFi OS Server"
systemctl enable uosserver
systemctl restart uosserver

sleep 5

log "Checking UniFi OS Server status"
systemctl status uosserver --no-pager || true

# ---------------------------------------------------------
# 9. Post-install info
# ---------------------------------------------------------
log "Collecting post-install listening ports"
ss -tulpn | tee "${WORKDIR}/ports-after.txt" >/dev/null || true

cat <<EOF

=========================================================
DONE
=========================================================

Next steps:

1. Open your UniFi OS Server in the browser.
2. Sign in and install/open the Network app.
3. Import your UniFi backup or Site Export.
4. Verify devices come online.

Useful service commands:
  sudo systemctl status uosserver
  sudo systemctl restart uosserver
  sudo systemctl stop uosserver
  sudo systemctl start uosserver

Backup folder created:
  ${WORKDIR}

IMPORTANT:
- On Linux, migration may still require restoring a backup or importing a Site Export manually in the UI.
- If you use guest portals, note that captive portal serving changes from port 8843 on old Network Server to 8444 on UniFi OS Server.

EOF
