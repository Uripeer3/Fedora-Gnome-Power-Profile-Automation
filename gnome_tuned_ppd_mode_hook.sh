#!/usr/bin/env bash
#
# gnome_tuned_ppd_mode_hook.sh
#
# A small Fedora GNOME power-mode automation installer.
# It changes the *visible* GNOME Power Mode after real power-state
# transitions: AC connected, normal battery, and UPower low battery.
#
# Intended for Fedora systems using tuned + tuned-ppd.
#
# This program intentionally does not alter /etc/tuned/ppd.conf.

set -Eeuo pipefail

APP="gnome-power-profile-automation"
VERSION="1.0.0"
RUNTIME="/usr/local/libexec/${APP}"
CONFIG="/etc/${APP}.conf"
UNIT="/etc/systemd/system/${APP}.service"
STATE_DIR="/run/${APP}"

DEFAULT_AC_PROFILE="performance"
DEFAULT_BATTERY_PROFILE="balanced"
DEFAULT_LOW_BATTERY_PROFILE="power-saver"
DEFAULT_LOW_WARNING_LEVEL="3"

ASSUME_YES=false
RECONFIGURE=false
MODE="install"

# -----------------------------------------------------------------------------
# Terminal presentation
# -----------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]] && command -v tput >/dev/null 2>&1; then
    BOLD="$(tput bold)"
    DIM="$(tput dim)"
    BLUE="$(tput setaf 4)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    RED="$(tput setaf 1)"
    RESET="$(tput sgr0)"
else
    BOLD=""
    DIM=""
    BLUE=""
    GREEN=""
    YELLOW=""
    RED=""
    RESET=""
fi

say() {
    printf '%s\n' "$*"
}

rule() {
    printf '%s\n' "------------------------------------------------------------"
}

title() {
    printf '\n%s%s%s\n' "${BOLD}${BLUE}" "$1" "${RESET}"
    rule
}

section() {
    printf '\n%s%s%s\n' "${BOLD}" "$1" "${RESET}"
}

info() {
    printf '%sINFO:%s %s\n' "${BLUE}" "${RESET}" "$*"
}

success() {
    printf '%sOK:%s %s\n' "${GREEN}" "${RESET}" "$*"
}

warn() {
    printf '%sWARNING:%s %s\n' "${YELLOW}" "${RESET}" "$*" >&2
}

error() {
    printf '%sERROR:%s %s\n' "${RED}" "${RESET}" "$*" >&2
}

# -----------------------------------------------------------------------------
# General helpers
# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
${BOLD}GNOME Power Mode Automation ${VERSION}${RESET}

Usage:
  sudo bash $(basename "$0") [OPTIONS]

This installer creates a small system service that changes the visible GNOME
Power Mode when the laptop moves between these physical power states:

  1. Charger connected
  2. Normal battery use
  3. Low battery, as reported by UPower

Options:
  -y, --yes
      Install without questions using the recommended defaults on a fresh
      installation:
        Charger connected  -> Performance
        Normal battery     -> Balanced
        Low battery        -> Power Saver
        Low-battery trigger -> UPower "Low" warning

      An existing configuration is kept unless --reconfigure is also passed.

  --reconfigure
      Open the guided configuration menu again. With --yes, reset the
      configuration to the recommended defaults without prompting.

  --status
      Print the detected power state, configured target, and current visible
      GNOME Power Mode.

  --apply
      Apply the configured policy once immediately. This intentionally
      overrides a temporary manual GNOME choice.

  --uninstall
      Remove the service and installed runtime script. Your configuration file
      is kept so it can be reused later.

  --version
      Print the version number.

  -h, --help
      Print this help text.

Examples:
  sudo bash $(basename "$0")
  sudo bash $(basename "$0") --yes
  sudo bash $(basename "$0") --reconfigure
  sudo bash $(basename "$0") --status
EOF
}

require_root() {
    if (( EUID != 0 )); then
        error "Run this command with sudo."
        say "Example: sudo bash $0"
        exit 1
    fi
}

require_interactive_terminal() {
    if [[ ! -t 0 ]]; then
        error "Interactive configuration needs a terminal."
        say "Use --yes for a non-interactive installation."
        exit 1
    fi
}

profile_label() {
    case "$1" in
        performance) printf 'Performance' ;;
        balanced) printf 'Balanced' ;;
        power-saver) printf 'Power Saver' ;;
        *) printf '%s' "$1" ;;
    esac
}

profile_to_choice() {
    case "$1" in
        performance) printf '1' ;;
        balanced) printf '2' ;;
        power-saver) printf '3' ;;
        *) printf '2' ;;
    esac
}

choice_to_profile() {
    case "$1" in
        1) printf 'performance' ;;
        2) printf 'balanced' ;;
        3) printf 'power-saver' ;;
        *) return 1 ;;
    esac
}

warning_level_to_choice() {
    case "$1" in
        3) printf '1' ;;
        4) printf '2' ;;
        5) printf '3' ;;
        *) printf '1' ;;
    esac
}

choice_to_warning_level() {
    case "$1" in
        1) printf '3' ;;
        2) printf '4' ;;
        3) printf '5' ;;
        *) return 1 ;;
    esac
}

confirm() {
    local prompt="$1"
    local reply

    printf '%s [Y/n]: ' "$prompt"
    read -r reply
    reply="${reply:-Y}"

    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Configuration UI
# -----------------------------------------------------------------------------

SELECTED_PROFILE=""
SELECTED_WARNING_LEVEL=""

choose_profile() {
    local heading="$1"
    local description="$2"
    local current_profile="$3"
    local default_choice
    local choice

    default_choice="$(profile_to_choice "$current_profile")"

    section "$heading"
    say "$description"
    say
    say "  1) Performance"
    say "     Highest responsiveness and the most eager CPU boosting."
    say "     Best for compiling, containers, local servers, and heavy work."
    say "     Uses more power and can increase heat and fan noise."
    say
    say "  2) Balanced"
    say "     Recommended everyday mode. It remains responsive while avoiding"
    say "     unnecessary power draw during lighter work."
    say
    say "  3) Power Saver"
    say "     Prioritizes battery runtime, lower heat, and quieter operation."
    say "     Heavy work can feel less responsive."
    say

    while true; do
        printf 'Choose 1, 2, or 3 [default: %s]: ' "$default_choice"
        read -r choice
        choice="${choice:-$default_choice}"

        if SELECTED_PROFILE="$(choice_to_profile "$choice")"; then
            return 0
        fi

        warn "Please enter 1, 2, or 3."
    done
}

choose_low_battery_trigger() {
    local current_level="$1"
    local default_choice
    local choice

    default_choice="$(warning_level_to_choice "$current_level")"

    section "When should low-battery mode activate?"
    say "This follows UPower's warning state. It does not use a hard-coded"
    say "battery percentage, so it follows the policy your system reports."
    say
    say "  1) Low battery (recommended)"
    say "     Switch early enough to preserve useful runtime."
    say
    say "  2) Critical battery"
    say "     Keep the normal battery mode for longer, with less reserve."
    say
    say "  3) Final action state"
    say "     Switch only very late, shortly before the system may suspend or"
    say "     request immediate charging."
    say

    while true; do
        printf 'Choose 1, 2, or 3 [default: %s]: ' "$default_choice"
        read -r choice
        choice="${choice:-$default_choice}"

        if SELECTED_WARNING_LEVEL="$(choice_to_warning_level "$choice")"; then
            return 0
        fi

        warn "Please enter 1, 2, or 3."
    done
}

load_existing_config_values() {
    CURRENT_AC_PROFILE="$DEFAULT_AC_PROFILE"
    CURRENT_BATTERY_PROFILE="$DEFAULT_BATTERY_PROFILE"
    CURRENT_LOW_BATTERY_PROFILE="$DEFAULT_LOW_BATTERY_PROFILE"
    CURRENT_LOW_WARNING_LEVEL="$DEFAULT_LOW_WARNING_LEVEL"

    [[ -r "$CONFIG" ]] || return 0

    # The config is created by this script and root-owned. It is intentionally
    # shell syntax so quoted values can be used without a custom parser.
    # shellcheck disable=SC1090
    source "$CONFIG"

    CURRENT_AC_PROFILE="${AC_PROFILE:-$CURRENT_AC_PROFILE}"
    CURRENT_BATTERY_PROFILE="${BATTERY_PROFILE:-$CURRENT_BATTERY_PROFILE}"
    CURRENT_LOW_BATTERY_PROFILE="${LOW_BATTERY_PROFILE:-$CURRENT_LOW_BATTERY_PROFILE}"
    CURRENT_LOW_WARNING_LEVEL="${LOW_BATTERY_WARNING_LEVEL:-$CURRENT_LOW_WARNING_LEVEL}"
}

write_config() {
    local ac_profile="$1"
    local battery_profile="$2"
    local low_battery_profile="$3"
    local low_warning_level="$4"

    install -d -m 0755 /etc

    cat > "$CONFIG" <<EOF
# ${APP} configuration
#
# Edit this file manually only if you understand shell assignments, then run:
#   sudo systemctl restart ${APP}.service
#
# Allowed profile values: performance, balanced, power-saver
# UPower warning levels: 3=Low, 4=Critical, 5=Action

AC_PROFILE="${ac_profile}"
BATTERY_PROFILE="${battery_profile}"
LOW_BATTERY_PROFILE="${low_battery_profile}"
LOW_BATTERY_WARNING_LEVEL=${low_warning_level}
EOF

    chmod 0644 "$CONFIG"
}

show_policy_summary() {
    local ac_profile="$1"
    local battery_profile="$2"
    local low_battery_profile="$3"
    local low_warning_level="$4"
    local trigger_label

    case "$low_warning_level" in
        3) trigger_label="Low battery" ;;
        4) trigger_label="Critical battery" ;;
        5) trigger_label="Final action state" ;;
        *) trigger_label="Unknown" ;;
    esac

    title "Selected policy"
    printf '  Charger connected : %s\n' "$(profile_label "$ac_profile")"
    printf '  Normal battery    : %s\n' "$(profile_label "$battery_profile")"
    printf '  Low battery       : %s\n' "$(profile_label "$low_battery_profile")"
    printf '  Low trigger       : %s\n' "$trigger_label"
    say
    say "A temporary manual change in GNOME is preserved while this physical"
    say "power state remains unchanged. The policy applies again at the next"
    say "AC, battery, or low-battery state transition."
}

configure_interactively() {
    local ac_profile="$1"
    local battery_profile="$2"
    local low_battery_profile="$3"
    local low_warning_level="$4"

    title "GNOME Power Mode Automation"
    say "This guided setup selects the GNOME mode shown after each real power"
    say "state transition. No TuneD profile mapping is modified."
    say

    choose_profile \
        "1 of 3: Charger connected" \
        "Choose the visible GNOME Power Mode when AC power is connected." \
        "$ac_profile"
    ac_profile="$SELECTED_PROFILE"

    choose_profile \
        "2 of 3: Normal battery use" \
        "Choose the visible GNOME Power Mode after AC power is disconnected." \
        "$battery_profile"
    battery_profile="$SELECTED_PROFILE"

    choose_profile \
        "3 of 3: System-reported low battery" \
        "Choose the visible GNOME Power Mode when UPower reports low battery." \
        "$low_battery_profile"
    low_battery_profile="$SELECTED_PROFILE"

    choose_low_battery_trigger "$low_warning_level"
    low_warning_level="$SELECTED_WARNING_LEVEL"

    show_policy_summary \
        "$ac_profile" \
        "$battery_profile" \
        "$low_battery_profile" \
        "$low_warning_level"

    if confirm "Save and activate this policy?"; then
        write_config \
            "$ac_profile" \
            "$battery_profile" \
            "$low_battery_profile" \
            "$low_warning_level"
        success "Configuration saved to $CONFIG"
    else
        warn "Cancelled. No configuration changes were made."
        exit 0
    fi
}

configure() {
    load_existing_config_values

    if [[ -f "$CONFIG" && "$RECONFIGURE" == false ]]; then
        if "$ASSUME_YES"; then
            info "Keeping existing configuration: $CONFIG"
            return 0
        fi

        title "Existing configuration found"
        say "A configuration already exists at: $CONFIG"
        say
        say "  1) Keep it and reinstall or repair the service"
        say "  2) Open the guided configuration menu"
        say "  3) Exit without making changes"
        say

        local action
        while true; do
            printf 'Choose 1, 2, or 3 [default: 1]: '
            read -r action
            action="${action:-1}"

            case "$action" in
                1)
                    info "Keeping existing configuration."
                    return 0
                    ;;
                2)
                    break
                    ;;
                3)
                    info "Nothing changed."
                    exit 0
                    ;;
                *)
                    warn "Please enter 1, 2, or 3."
                    ;;
            esac
        done
    fi

    if "$ASSUME_YES"; then
        write_config \
            "$DEFAULT_AC_PROFILE" \
            "$DEFAULT_BATTERY_PROFILE" \
            "$DEFAULT_LOW_BATTERY_PROFILE" \
            "$DEFAULT_LOW_WARNING_LEVEL"
        success "Configured recommended defaults in $CONFIG"
        return 0
    fi

    require_interactive_terminal
    configure_interactively \
        "$CURRENT_AC_PROFILE" \
        "$CURRENT_BATTERY_PROFILE" \
        "$CURRENT_LOW_BATTERY_PROFILE" \
        "$CURRENT_LOW_WARNING_LEVEL"
}

# -----------------------------------------------------------------------------
# Installation and validation
# -----------------------------------------------------------------------------

check_requirements() {
    local missing=()

    rpm -q tuned >/dev/null 2>&1 || missing+=("tuned")
    rpm -q tuned-ppd >/dev/null 2>&1 || missing+=("tuned-ppd")
    command -v upower >/dev/null 2>&1 || missing+=("upower")
    command -v busctl >/dev/null 2>&1 || missing+=("busctl (from systemd)")

    if (( ${#missing[@]} > 0 )); then
        error "Required components are missing: ${missing[*]}"
        say
        say "Install Fedora's power-profile backend and UPower with:"
        say "  sudo dnf install tuned tuned-ppd upower"
        exit 1
    fi
}

install_runtime() {
    install -d -m 0755 /usr/local/libexec

    cat > "$RUNTIME" <<'RUNTIME_EOF'
#!/usr/bin/env bash
# Runtime component installed by gnome_tuned_ppd_mode_hook.sh.

set -Eeuo pipefail

APP="gnome-power-profile-automation"
CONFIG="/etc/${APP}.conf"
STATE_DIR="/run/${APP}"
STATE_FILE="${STATE_DIR}/last-state"

UP_DEST="org.freedesktop.UPower"
UP_PATH="/org/freedesktop/UPower"
UP_IFACE="org.freedesktop.UPower"
UP_DISPLAY_PATH="/org/freedesktop/UPower/devices/DisplayDevice"
UP_DEVICE_IFACE="org.freedesktop.UPower.Device"

PPD_DEST="net.hadess.PowerProfiles"
PPD_PATH="/net/hadess/PowerProfiles"
PPD_IFACE="net.hadess.PowerProfiles"

log() {
    logger -t "$APP" -- "$*"
}

die() {
    printf '%s: %s\n' "$APP" "$*" >&2
    log "ERROR: $*"
    exit 1
}

load_config() {
    [[ -r "$CONFIG" ]] || die "Missing configuration file: $CONFIG"

    # The installer writes this root-owned file.
    # shellcheck disable=SC1090
    source "$CONFIG"

    for profile in "$AC_PROFILE" "$BATTERY_PROFILE" "$LOW_BATTERY_PROFILE"; do
        case "$profile" in
            performance|balanced|power-saver) ;;
            *) die "Invalid profile in $CONFIG: $profile" ;;
        esac
    done

    [[ "$LOW_BATTERY_WARNING_LEVEL" =~ ^[3-5]$ ]] || \
        die "LOW_BATTERY_WARNING_LEVEL must be 3, 4, or 5"
}

require_power_profiles_api() {
    busctl --system get-property \
        "$PPD_DEST" \
        "$PPD_PATH" \
        "$PPD_IFACE" \
        ActiveProfile \
        >/dev/null 2>&1 || die "Cannot reach ${PPD_DEST}. Ensure tuned-ppd is installed and running."
}

on_battery() {
    local value

    value="$(
        busctl --system get-property \
            "$UP_DEST" \
            "$UP_PATH" \
            "$UP_IFACE" \
            OnBattery | awk '{print $2}'
    )"

    [[ "$value" == "true" ]]
}

warning_level() {
    local value

    value="$(
        busctl --system get-property \
            "$UP_DEST" \
            "$UP_DISPLAY_PATH" \
            "$UP_DEVICE_IFACE" \
            WarningLevel 2>/dev/null | awk '{print $2}' || true
    )"

    if [[ "$value" =~ ^[0-5]$ ]]; then
        printf '%s\n' "$value"
    else
        # Treat an unavailable value as no warning. This is safer than
        # applying the low-battery policy due to a transient D-Bus failure.
        printf '1\n'
    fi
}

battery_percentage() {
    local value

    value="$(
        busctl --system get-property \
            "$UP_DEST" \
            "$UP_DISPLAY_PATH" \
            "$UP_DEVICE_IFACE" \
            Percentage 2>/dev/null | awk '{print $2}' || true
    )"

    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s\n' "$value"
    else
        printf 'unknown\n'
    fi
}

desired_state() {
    local warning

    if ! on_battery; then
        printf 'ac\n'
        return
    fi

    warning="$(warning_level)"
    if (( warning >= LOW_BATTERY_WARNING_LEVEL )); then
        printf 'low-battery\n'
    else
        printf 'battery\n'
    fi
}

profile_for_state() {
    case "$1" in
        ac) printf '%s\n' "$AC_PROFILE" ;;
        battery) printf '%s\n' "$BATTERY_PROFILE" ;;
        low-battery) printf '%s\n' "$LOW_BATTERY_PROFILE" ;;
        *) die "Unknown state: $1" ;;
    esac
}

current_profile() {
    busctl --system get-property \
        "$PPD_DEST" \
        "$PPD_PATH" \
        "$PPD_IFACE" \
        ActiveProfile \
    | sed -n 's/.*"\([^"]*\)".*/\1/p'
}

set_profile() {
    local profile="$1"

    busctl --system set-property \
        "$PPD_DEST" \
        "$PPD_PATH" \
        "$PPD_IFACE" \
        ActiveProfile s "$profile"
}

apply_policy() {
    local force="${1:-}"
    local state
    local target
    local last_state=""

    install -d -m 0755 "$STATE_DIR"

    state="$(desired_state)"
    target="$(profile_for_state "$state")"

    [[ -r "$STATE_FILE" ]] && last_state="$(<"$STATE_FILE")"

    # Do not overwrite a temporary manual GNOME selection while the laptop
    # stays in the same physical state. Reapply only after a state transition,
    # or when the administrator explicitly requests a forced apply.
    if [[ "$force" != "--force" && "$state" == "$last_state" ]]; then
        return 0
    fi

    set_profile "$target"
    printf '%s\n' "$state" > "$STATE_FILE"
    log "state=$state active-profile=$target"
}

warning_label() {
    case "$1" in
        0) printf 'Unknown' ;;
        1) printf 'None' ;;
        2) printf 'Discharging (UPS only)' ;;
        3) printf 'Low' ;;
        4) printf 'Critical' ;;
        5) printf 'Action' ;;
        *) printf 'Unknown' ;;
    esac
}

profile_label() {
    case "$1" in
        performance) printf 'Performance' ;;
        balanced) printf 'Balanced' ;;
        power-saver) printf 'Power Saver' ;;
        *) printf '%s' "$1" ;;
    esac
}

show_status() {
    local state
    local target
    local active
    local warning
    local percentage

    require_power_profiles_api

    state="$(desired_state)"
    target="$(profile_for_state "$state")"
    active="$(current_profile)"
    warning="$(warning_level)"
    percentage="$(battery_percentage)"

    printf 'GNOME Power Mode Automation\n'
    printf '%s\n' '------------------------------------------------------------'
    printf 'Detected power state : %s\n' "$state"
    printf 'Battery percentage   : %s\n' "$percentage"
    printf 'UPower warning level : %s (%s)\n' "$warning" "$(warning_label "$warning")"
    printf 'Configured target    : %s\n' "$(profile_label "$target")"
    printf 'Current GNOME mode   : %s\n' "$(profile_label "$active")"
    printf 'State memory         : %s\n' "${STATE_FILE}"
}

monitor() {
    load_config
    require_power_profiles_api

    # At boot/service start the configured policy becomes authoritative.
    apply_policy --force

    # UPower emits events for adapter changes and battery state changes.
    # The state file prevents ordinary percentage updates from clobbering a
    # manual GNOME mode choice during an unchanged physical power state.
    while true; do
        while IFS= read -r _event; do
            apply_policy || log "Could not apply policy after an UPower event"
        done < <(upower --monitor-detail)

        # Reconnect the monitor if UPower was restarted.
        sleep 2
    done
}

case "${1:-monitor}" in
    monitor)
        monitor
        ;;
    apply)
        load_config
        require_power_profiles_api
        apply_policy --force
        ;;
    status)
        load_config
        show_status
        ;;
    *)
        printf 'Usage: %s {monitor|apply|status}\n' "$0" >&2
        exit 2
        ;;
esac
RUNTIME_EOF

    chmod 0755 "$RUNTIME"

    cat > "$UNIT" <<EOF
[Unit]
Description=Visible GNOME Power Mode automation from AC and UPower state
After=upower.service tuned.service tuned-ppd.service
Wants=upower.service tuned.service tuned-ppd.service

[Service]
Type=simple
ExecStart=${RUNTIME} monitor
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

ensure_backend_is_ready() {
    local attempt

    # tuned is normally enabled by Fedora. Starting it here is harmless and
    # makes a manual installation less surprising.
    systemctl enable --now tuned.service >/dev/null 2>&1 || \
        warn "Could not enable tuned.service automatically."

    # tuned-ppd may be D-Bus activated. Try starting it explicitly as well.
    systemctl start tuned-ppd.service >/dev/null 2>&1 || true

    for attempt in {1..5}; do
        if busctl --system get-property \
            net.hadess.PowerProfiles \
            /net/hadess/PowerProfiles \
            net.hadess.PowerProfiles \
            ActiveProfile \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    error "The Power Profiles D-Bus interface did not become available."
    say "Check these commands:"
    say "  systemctl status tuned.service tuned-ppd.service"
    say "  busctl --system status net.hadess.PowerProfiles"
    exit 1
}

install_or_update() {
    check_requirements
    configure
    install_runtime

    systemctl daemon-reload
    ensure_backend_is_ready
    systemctl enable --now "${APP}.service"

    title "Installation complete"
    success "Service is enabled and running."
    say
    say "Useful commands:"
    say "  sudo bash $0 --status"
    say "  sudo bash $0 --reconfigure"
    say "  journalctl -u ${APP}.service -f"
}

uninstall() {
    title "Uninstall GNOME Power Mode Automation"

    systemctl disable --now "${APP}.service" 2>/dev/null || true
    rm -f "$UNIT" "$RUNTIME"
    rm -rf "$STATE_DIR"
    systemctl daemon-reload

    success "Removed the service and installed runtime script."
    say "Your configuration was kept at: $CONFIG"
    say "Remove it manually to discard the saved policy."
}

run_runtime_command() {
    local command="$1"

    if [[ ! -x "$RUNTIME" ]]; then
        error "Automation is not installed. Run this script without --status or --apply first."
        exit 1
    fi

    exec "$RUNTIME" "$command"
}

parse_args() {
    local argument

    while (( $# > 0 )); do
        argument="$1"
        case "$argument" in
            -y|--yes)
                ASSUME_YES=true
                ;;
            --reconfigure)
                RECONFIGURE=true
                ;;
            --status)
                MODE="status"
                ;;
            --apply)
                MODE="apply"
                ;;
            --uninstall)
                MODE="uninstall"
                ;;
            --version)
                printf '%s\n' "$VERSION"
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $argument"
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"
    require_root

    case "$MODE" in
        install)
            install_or_update
            ;;
        status)
            run_runtime_command status
            ;;
        apply)
            run_runtime_command apply
            ;;
        uninstall)
            uninstall
            ;;
        *)
            error "Internal error: unsupported mode '$MODE'."
            exit 2
            ;;
    esac
}

main "$@"
