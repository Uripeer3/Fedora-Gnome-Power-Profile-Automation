#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remove GNOME Power Mode Automation from Fedora.

set -Eeuo pipefail

APP="gnome-power-profile-automation"
RUNTIME_DEST="/usr/local/libexec/${APP}"
COMMAND_DEST="/usr/local/sbin/${APP}"
SERVICE_DEST="/etc/systemd/system/${APP}.service"
CONFIG_DEST="/etc/${APP}.conf"
PURGE_CONFIG=false

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
    rm -f "$SERVICE_DEST" "$RUNTIME_DEST" "$COMMAND_DEST"
    rm -rf "/run/${APP}"

    if "$PURGE_CONFIG"; then
        rm -f "$CONFIG_DEST"
        printf 'Removed configuration: %s\n' "$CONFIG_DEST"
    else
        printf 'Kept configuration: %s\n' "$CONFIG_DEST"
    fi

    systemctl daemon-reload
    printf 'Removed %s.\n' "$APP"
}

main "$@"
