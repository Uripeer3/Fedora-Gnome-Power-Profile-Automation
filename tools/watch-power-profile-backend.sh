#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Live backend monitor for GNOME Power Mode Automation on Fedora.
#
# This tool is read-only. It helps verify that GNOME's visible Power Mode,
# TuneD's active profile, and kernel CPU policy hints are changing together.

set -Eeuo pipefail

APP="gnome-power-profile-automation"
VERSION="1.0.0"
INTERVAL="1"
ONCE=false
USE_COLOR=true

usage() {
    cat <<'EOF'
GNOME Power Mode Backend Monitor

Usage:
  bash tools/watch-power-profile-backend.sh [OPTIONS]

Options:
  -i, --interval SECONDS   Refresh interval. Default: 1 second.
  -1, --once               Render one snapshot, then exit.
      --no-color           Disable ANSI colors.
  -h, --help               Show this help text.
  -V, --version            Show the version.

Examples:
  bash tools/watch-power-profile-backend.sh
  bash tools/watch-power-profile-backend.sh --interval 2
  bash tools/watch-power-profile-backend.sh --once

Press Ctrl+C to stop live monitoring.
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -i|--interval)
                (( $# >= 2 )) || { printf 'ERROR: %s needs a value.\n' "$1" >&2; exit 2; }
                INTERVAL="$2"
                shift
                ;;
            -1|--once)
                ONCE=true
                ;;
            --no-color)
                USE_COLOR=false
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -V|--version)
                printf '%s\n' "$VERSION"
                exit 0
                ;;
            *)
                printf 'ERROR: Unknown option: %s\n\n' "$1" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done

    [[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk "BEGIN { exit !($INTERVAL > 0) }" \
        || { printf 'ERROR: Interval must be a positive number.\n' >&2; exit 2; }
}

if [[ -t 1 && -z "${NO_COLOR:-}" && "$USE_COLOR" == true ]] && command -v tput >/dev/null 2>&1; then
    BOLD="$(tput bold)"
    DIM="$(tput dim)"
    BLUE="$(tput setaf 4)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    RED="$(tput setaf 1)"
    RESET="$(tput sgr0)"
else
    BOLD=""; DIM=""; BLUE=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi

line() {
    printf '%s\n' '----------------------------------------------------------------'
}

heading() {
    printf '%s%s%s\n' "${BOLD}${BLUE}" "$1" "$RESET"
}

ok() {
    printf '%s%s%s' "$GREEN" "$1" "$RESET"
}

warn() {
    printf '%s%s%s' "$YELLOW" "$1" "$RESET"
}

bad() {
    printf '%s%s%s' "$RED" "$1" "$RESET"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

read_bus_property() {
    local destination="$1" path="$2" interface="$3" property="$4"

    busctl --system get-property "$destination" "$path" "$interface" "$property" 2>/dev/null \
        | sed -n 's/^[a-z]* "\(.*\)"$/\1/p; t; s/^[a-z]* \(.*\)$/\1/p'
}

profile_label() {
    case "$1" in
        performance) printf 'Performance' ;;
        balanced) printf 'Balanced' ;;
        power-saver) printf 'Power Saver' ;;
        throughput-performance) printf 'throughput-performance' ;;
        powersave) printf 'powersave' ;;
        "") printf 'unavailable' ;;
        *) printf '%s' "$1" ;;
    esac
}

service_state() {
    local service="$1" state
    state="$(systemctl is-active "$service" 2>/dev/null || true)"

    case "$state" in
        active) ok "$state" ;;
        activating|reloading) warn "$state" ;;
        *) bad "${state:-unavailable}" ;;
    esac
}

upower_state() {
    local on_battery percentage warning

    if ! command_exists busctl; then
        printf 'unavailable'
        return
    fi

    on_battery="$(read_bus_property org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower OnBattery || true)"
    percentage="$(read_bus_property org.freedesktop.UPower /org/freedesktop/UPower/devices/DisplayDevice org.freedesktop.UPower.Device Percentage || true)"
    warning="$(read_bus_property org.freedesktop.UPower /org/freedesktop/UPower/devices/DisplayDevice org.freedesktop.UPower.Device WarningLevel || true)"

    case "$on_battery" in
        true) printf 'battery' ;;
        false) printf 'AC connected' ;;
        *) printf 'unknown' ;;
    esac

    [[ -n "$percentage" ]] && printf ', %s%%' "$percentage"
    case "$warning" in
        3) printf ', UPower: Low' ;;
        4) printf ', UPower: Critical' ;;
        5) printf ', UPower: Action' ;;
    esac
}

gnome_profile() {
    if ! command_exists busctl; then
        printf 'busctl unavailable'
        return
    fi

    local profile
    profile="$(read_bus_property net.hadess.PowerProfiles /net/hadess/PowerProfiles net.hadess.PowerProfiles ActiveProfile || true)"
    profile_label "$profile"
}

tuned_profile() {
    if ! command_exists tuned-adm; then
        printf 'tuned-adm unavailable'
        return
    fi

    local output profile
    output="$(tuned-adm active 2>/dev/null || true)"
    profile="$(sed -n 's/^Current active profile: //p' <<< "$output")"
    profile_label "$profile"
}

cpu_policy_rows() {
    local policy name governor epp
    local found=false

    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [[ -d "$policy" ]] || continue
        found=true
        name="${policy##*/}"

        if [[ -r "$policy/scaling_governor" ]]; then
            governor="$(<"$policy/scaling_governor")"
        else
            governor="unavailable"
        fi

        if [[ -r "$policy/energy_performance_preference" ]]; then
            epp="$(<"$policy/energy_performance_preference")"
        else
            epp="not exposed"
        fi

        printf '  %-10s governor: %-14s EPP: %s\n' "$name" "$governor" "$epp"
    done

    "$found" || printf '  CPU frequency policy files are not exposed on this system.\n'
}

profile_consistency_note() {
    local gnome="$1" tuned="$2"

    case "${gnome}:${tuned}" in
        performance:throughput-performance|balanced:balanced|power-saver:powersave)
            printf '%s' "$(ok 'Looks consistent')"
            ;;
        *:unavailable|unavailable:*)
            printf '%s' "$(warn 'Cannot compare; one layer is unavailable')"
            ;;
        *)
            printf '%s' "$(warn 'Different names are expected briefly during a transition; persistent mismatch deserves investigation')"
            ;;
    esac
}

render() {
    local gnome tuned

    if ! "$ONCE" && [[ -t 1 ]]; then
        clear
    fi

    heading 'GNOME Power Mode Backend Monitor'
    line
    printf 'Updated:        %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'Host:           %s\n' "$(hostname)"
    printf 'Power source:   %s\n' "$(upower_state)"
    printf 'Refresh:        every %ss\n' "$INTERVAL"
    line

    heading 'GNOME Power Profiles API'
    gnome="$(gnome_profile)"
    printf 'Visible GNOME mode: %s\n' "$gnome"
    line

    heading 'TuneD Backend'
    tuned="$(tuned_profile)"
    printf 'Active TuneD profile: %s\n' "$tuned"
    printf 'Profile handoff:      %s\n' "$(profile_consistency_note "${gnome,,}" "$tuned")"
    printf 'tuned.service:        %s\n' "$(service_state tuned.service)"
    printf 'tuned-ppd.service:    %s\n' "$(service_state tuned-ppd.service)"
    line

    heading 'Kernel CPU Energy / Performance Policy'
    cpu_policy_rows
    line

    heading 'Automation Service'
    printf '%s.service: %s\n' "$APP" "$(service_state "${APP}.service")"
    line

    printf '%s\n' "${DIM}Read-only monitor. Press Ctrl+C to stop.${RESET}"
}

main() {
    parse_args "$@"

    if ! command_exists systemctl; then
        printf 'ERROR: systemctl is required.\n' >&2
        exit 1
    fi

    if ! command_exists busctl; then
        printf 'WARNING: busctl is unavailable; GNOME and UPower sections will be limited.\n' >&2
    fi

    trap 'printf "\n"; exit 0' INT TERM

    if "$ONCE"; then
        render
        return
    fi

    while true; do
        render
        sleep "$INTERVAL"
    done
}

main "$@"
