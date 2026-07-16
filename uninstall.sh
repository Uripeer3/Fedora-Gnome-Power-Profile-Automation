#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Remove GNOME Power Mode Automation from Fedora.

set -Eeuo pipefail

APP="gnome-power-profile-automation"
RUNTIME_DEST="/usr/local/libexec/${APP}"
LIBRARY_DEST_DIR="/usr/local/libexec/${APP}.d"
COMMAND_DEST="/usr/local/sbin/${APP}"
SERVICE_DEST="/etc/systemd/system/${APP}.service"
CONFIG_DEST="/etc/${APP}.conf"
CONFIG_BACKUP_DEST="${CONFIG_DEST}.legacy.bak"
LID_DROPIN_DEST="/etc/systemd/logind.conf.d/90-${APP}-lid.conf"
PURGE_CONFIG=false

LIBRARY_NAMES=(config.sh policy.sh platform.sh lid.sh monitor.sh cli.sh)
LIBRARY_DESTS=()
for library in "${LIBRARY_NAMES[@]}"; do
    LIBRARY_DESTS+=("${LIBRARY_DEST_DIR}/${library}")
done

usage() {
    cat <<EOF
Usage:
  sudo ./uninstall.sh [OPTIONS]

Options:
  --purge-config      Remove the saved configuration as well.
  -h, --help          Show this help text.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

main() {
    while (( $# > 0 )); do
        case "$1" in
            --purge-config) PURGE_CONFIG=true ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done

    (( EUID == 0 )) || die "Run this uninstaller with sudo."

    systemctl disable --now "${APP}.service" 2>/dev/null || true
    rm -f "$SERVICE_DEST" "$RUNTIME_DEST" "$COMMAND_DEST" "$LID_DROPIN_DEST" "${LIBRARY_DESTS[@]}"
    rmdir "$LIBRARY_DEST_DIR" 2>/dev/null || true
    rm -rf "/run/${APP}"

    if "$PURGE_CONFIG"; then
        rm -f "$CONFIG_DEST" "$CONFIG_BACKUP_DEST"
        printf 'Removed configuration and migration backup.\n'
    else
        printf 'Kept configuration: %s\n' "$CONFIG_DEST"
    fi

    systemctl daemon-reload
    systemctl reload systemd-logind.service 2>/dev/null || true
    printf 'Removed %s.\n' "$APP"
}

main "$@"
