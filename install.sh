#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install GNOME Power Mode Automation on Fedora.

set -Eeuo pipefail

APP="gnome-power-profile-automation"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SOURCE="${ROOT_DIR}/src/${APP}"
POLICY_SOURCE="${ROOT_DIR}/src/lib/policy.sh"
CONFIG_LIB_SOURCE="${ROOT_DIR}/src/lib/config.sh"
SERVICE_SOURCE="${ROOT_DIR}/systemd/${APP}.service"
CONFIG_SOURCE="${ROOT_DIR}/config/${APP}.conf.example"
RUNTIME_DEST="/usr/local/libexec/${APP}"
POLICY_DEST="/usr/local/libexec/${APP}.d/policy.sh"
CONFIG_LIB_DEST="/usr/local/libexec/${APP}.d/config.sh"
COMMAND_DEST="/usr/local/sbin/${APP}"
SERVICE_DEST="/etc/systemd/system/${APP}.service"
CONFIG_DEST="/etc/${APP}.conf"

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
    # install(1) sets the executable mode at the installed destination.
    [[ -r "$RUNTIME_SOURCE" ]] || die "Missing runtime: $RUNTIME_SOURCE"
    [[ -r "$POLICY_SOURCE" ]] || die "Missing policy library: $POLICY_SOURCE"
    [[ -r "$CONFIG_LIB_SOURCE" ]] || die "Missing configuration library: $CONFIG_LIB_SOURCE"
    [[ -r "$SERVICE_SOURCE" ]] || die "Missing systemd unit: $SERVICE_SOURCE"
    [[ -r "$CONFIG_SOURCE" ]] || die "Missing config template: $CONFIG_SOURCE"
}

check_requirements() {
    local missing=()
    rpm -q tuned >/dev/null 2>&1 || missing+=("tuned")
    rpm -q tuned-ppd >/dev/null 2>&1 || missing+=("tuned-ppd")
    command -v upower >/dev/null 2>&1 || missing+=("upower")
    command -v busctl >/dev/null 2>&1 || missing+=("busctl")

    if (( ${#missing[@]} > 0 )); then
        die "Missing requirements: ${missing[*]}. Install them with: sudo dnf install tuned tuned-ppd upower"
    fi
}

normalize_config_permissions() {
    chown root:root "$CONFIG_DEST"
    chmod go-w "$CONFIG_DEST"
}

install_files() {
    install -D -m 0755 "$RUNTIME_SOURCE" "$RUNTIME_DEST"
    install -D -m 0644 "$POLICY_SOURCE" "$POLICY_DEST"
    install -D -m 0644 "$CONFIG_LIB_SOURCE" "$CONFIG_LIB_DEST"
    install -D -m 0644 "$SERVICE_SOURCE" "$SERVICE_DEST"
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

activate_service() {
    systemctl daemon-reload
    systemctl enable "${APP}.service"
    # `enable --now` does not restart an already-running service. An explicit
    # restart guarantees that upgrades use the newly installed runtime and
    # configuration immediately.
    systemctl restart "${APP}.service"
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

    activate_service

    printf '\nInstalled %s.\n' "$APP"
    printf 'Configure: sudo %s configure\n' "$APP"
    printf 'Status:    sudo %s status\n' "$APP"
    printf 'Logs:      journalctl -u %s.service -f\n' "$APP"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
