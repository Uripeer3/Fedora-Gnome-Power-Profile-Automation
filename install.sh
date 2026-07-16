#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install GNOME Power Mode Automation on Fedora.

set -Eeuo pipefail

APP="gnome-power-profile-automation"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SOURCE="${ROOT_DIR}/src/${APP}"
LIBRARY_SOURCE_DIR="${ROOT_DIR}/src/lib"
SERVICE_SOURCE="${ROOT_DIR}/systemd/${APP}.service"
BACKEND_RUNTIME_SOURCE="${ROOT_DIR}/src/${APP}-backend"
BACKEND_LIBRARY_SOURCE_DIR="${ROOT_DIR}/src/backend"
BACKEND_SERVICE_SOURCE="${ROOT_DIR}/systemd/${APP}-backend.service"
DBUS_NAME="io.github.Uripeer3.GnomePowerProfileAutomation1"
DBUS_XML_SOURCE="${ROOT_DIR}/dbus/${DBUS_NAME}.xml"
DBUS_POLICY_SOURCE="${ROOT_DIR}/dbus/${DBUS_NAME}.conf"
CONFIG_SOURCE="${ROOT_DIR}/config/${APP}.conf.example"
RUNTIME_DEST="/usr/local/libexec/${APP}"
LIBRARY_DEST_DIR="/usr/local/libexec/${APP}.d"
BACKEND_RUNTIME_DEST="/usr/local/libexec/${APP}-backend"
BACKEND_LIBRARY_DEST_DIR="/usr/local/libexec/${APP}-backend.d"
COMMAND_DEST="/usr/local/sbin/${APP}"
SERVICE_DEST="/etc/systemd/system/${APP}.service"
BACKEND_SERVICE_DEST="/etc/systemd/system/${APP}-backend.service"
DBUS_XML_DEST="/usr/share/dbus-1/interfaces/${DBUS_NAME}.xml"
DBUS_POLICY_DEST="/usr/share/dbus-1/system.d/${DBUS_NAME}.conf"
CONFIG_DEST="/etc/${APP}.conf"

LIBRARY_NAMES=(config.sh policy.sh platform.sh lid.sh monitor.sh cli.sh)
BACKEND_LIBRARY_NAMES=(backend_core.py backend_service.py)

ASSUME_YES=false
RECONFIGURE=false
CONFIG_CREATED=false

usage() {
    cat <<EOF
Usage:
  sudo ./install.sh [OPTIONS]

Options:
  -y, --yes          Install without prompts. On a new installation, use the
                     recommended policy. Existing configuration is preserved.
  --reconfigure      Open the guided setup after installation. With --yes,
                     reset the policy to the recommended defaults.
  -h, --help         Show this help text.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
    (( EUID == 0 )) || die "Run this installer with sudo."
}

check_source_files() {
    local library
    # install(1) sets the executable mode at the installed destination.
    [[ -r "$RUNTIME_SOURCE" ]] || die "Missing runtime: $RUNTIME_SOURCE"
    for library in "${LIBRARY_NAMES[@]}"; do
        [[ -r "${LIBRARY_SOURCE_DIR}/${library}" ]] \
            || die "Missing runtime library: ${LIBRARY_SOURCE_DIR}/${library}"
    done
    [[ -r "$SERVICE_SOURCE" ]] || die "Missing systemd unit: $SERVICE_SOURCE"
    [[ -r "$BACKEND_RUNTIME_SOURCE" ]] || die "Missing backend runtime: $BACKEND_RUNTIME_SOURCE"
    for library in "${BACKEND_LIBRARY_NAMES[@]}"; do
        [[ -r "${BACKEND_LIBRARY_SOURCE_DIR}/${library}" ]] \
            || die "Missing backend library: ${BACKEND_LIBRARY_SOURCE_DIR}/${library}"
    done
    [[ -r "$BACKEND_SERVICE_SOURCE" ]] || die "Missing backend systemd unit: $BACKEND_SERVICE_SOURCE"
    [[ -r "$DBUS_XML_SOURCE" ]] || die "Missing D-Bus interface: $DBUS_XML_SOURCE"
    [[ -r "$DBUS_POLICY_SOURCE" ]] || die "Missing D-Bus policy: $DBUS_POLICY_SOURCE"
    [[ -r "$CONFIG_SOURCE" ]] || die "Missing config template: $CONFIG_SOURCE"
}

check_requirements() {
    local missing=()
    rpm -q tuned >/dev/null 2>&1 || missing+=("tuned")
    rpm -q tuned-ppd >/dev/null 2>&1 || missing+=("tuned-ppd")
    command -v upower >/dev/null 2>&1 || missing+=("upower")
    command -v busctl >/dev/null 2>&1 || missing+=("busctl")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    python3 -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio, GLib' \
        >/dev/null 2>&1 || missing+=("python3-gobject")

    if (( ${#missing[@]} > 0 )); then
        die "Missing requirements: ${missing[*]}. Install them with: sudo dnf install tuned tuned-ppd upower python3-gobject"
    fi
}

normalize_config_permissions() {
    chown root:root "$CONFIG_DEST"
    chmod go-w "$CONFIG_DEST"
}

install_files() {
    local library
    install -D -m 0755 "$RUNTIME_SOURCE" "$RUNTIME_DEST"
    for library in "${LIBRARY_NAMES[@]}"; do
        install -D -m 0644 \
            "${LIBRARY_SOURCE_DIR}/${library}" \
            "${LIBRARY_DEST_DIR}/${library}"
    done
    install -D -m 0755 "$BACKEND_RUNTIME_SOURCE" "$BACKEND_RUNTIME_DEST"
    for library in "${BACKEND_LIBRARY_NAMES[@]}"; do
        install -D -m 0644 \
            "${BACKEND_LIBRARY_SOURCE_DIR}/${library}" \
            "${BACKEND_LIBRARY_DEST_DIR}/${library}"
    done
    install -D -m 0644 "$SERVICE_SOURCE" "$SERVICE_DEST"
    install -D -m 0644 "$BACKEND_SERVICE_SOURCE" "$BACKEND_SERVICE_DEST"
    install -D -m 0644 "$DBUS_XML_SOURCE" "$DBUS_XML_DEST"
    install -D -m 0644 "$DBUS_POLICY_SOURCE" "$DBUS_POLICY_DEST"
    ln -sfn "$RUNTIME_DEST" "$COMMAND_DEST"

    if [[ ! -e "$CONFIG_DEST" ]]; then
        install -D -m 0644 "$CONFIG_SOURCE" "$CONFIG_DEST"
        CONFIG_CREATED=true
        printf 'Created configuration: %s\n' "$CONFIG_DEST"
    else
        printf 'Keeping existing configuration: %s\n' "$CONFIG_DEST"
    fi

    normalize_config_permissions
}

activate_services() {
    systemctl daemon-reload
    if ! systemctl reload dbus-broker.service 2>/dev/null \
        && ! systemctl reload dbus.service 2>/dev/null; then
        die "Could not reload the system D-Bus policy."
    fi
    systemctl enable "${APP}.service" "${APP}-backend.service"
    # `enable --now` does not restart an already-running service. An explicit
    # restart guarantees that upgrades use the newly installed runtime and
    # configuration immediately.
    systemctl restart "${APP}.service" "${APP}-backend.service"
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            -y|--yes) ASSUME_YES=true ;;
            --reconfigure) RECONFIGURE=true ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done

    require_root
    check_source_files
    check_requirements
    install_files
    "$COMMAND_DEST" migrate-config

    # A first interactive installation should offer the guided policy menu.
    # Existing configurations remain untouched unless --reconfigure is chosen.
    if "$RECONFIGURE" || { "$CONFIG_CREATED" && ! "$ASSUME_YES"; }; then
        if "$ASSUME_YES"; then
            "$COMMAND_DEST" configure --yes
        else
            "$COMMAND_DEST" configure
        fi
    else
        "$COMMAND_DEST" sync-lid-policy
    fi

    activate_services

    printf '\nInstalled %s.\n' "$APP"
    printf 'Configure: sudo %s configure\n' "$APP"
    printf 'Status:    sudo %s status\n' "$APP"
    printf 'Logs:      journalctl -u %s.service -f\n' "$APP"
    printf 'API logs:  journalctl -u %s-backend.service -f\n' "$APP"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
