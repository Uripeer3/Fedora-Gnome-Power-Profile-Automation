#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Terminal presentation and interactive policy configuration.
# Shared configuration, formatting, and output helpers are provided by the entrypoint.
# shellcheck disable=SC2154

usage() {
    cat <<EOF
${BOLD}GNOME Power Mode Automation ${VERSION}${RESET}

Usage:
  sudo ${APP} <command> [options]

Commands:
  configure [--yes]   Open the guided policy configuration menu.
  status              Show power state, target profile, and lid policy.
  apply               Force the configured power-profile policy once now.
  sync-lid-policy     Apply configured lid-close actions through systemd-logind.
  migrate-config      Safely migrate the legacy shell-style configuration.
  monitor             Run the UPower event monitor (used by systemd).
  help                Show this help text.

The monitor preserves a temporary manual GNOME choice while the physical
power state is unchanged. It applies profile policy again only on AC, battery,
or low-battery state transitions. Lid-close policy is applied by systemd-logind
and does not add another background monitor.
EOF
}

profile_to_choice() {
    case "$1" in
        performance) printf 1 ;;
        balanced) printf 2 ;;
        power-saver) printf 3 ;;
        *) printf 2 ;;
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

warning_to_choice() {
    case "$1" in
        3) printf 1 ;;
        4) printf 2 ;;
        5) printf 3 ;;
        *) printf 1 ;;
    esac
}

choice_to_warning() {
    case "$1" in
        1) printf 3 ;;
        2) printf 4 ;;
        3) printf 5 ;;
        *) return 1 ;;
    esac
}

lid_action_to_choice() {
    case "$1" in
        suspend) printf 1 ;;
        hibernate) printf 2 ;;
        lock) printf 3 ;;
        ignore) printf 4 ;;
        *) printf 1 ;;
    esac
}

choice_to_lid_action() {
    case "$1" in
        1) printf 'suspend' ;;
        2) printf 'hibernate' ;;
        3) printf 'lock' ;;
        4) printf 'ignore' ;;
        *) return 1 ;;
    esac
}

show_status() {
    local state target active warning percentage
    load_config
    require_ppd_api
    state="$(desired_state)"
    target="$(profile_for_state "$state")"
    active="$(current_profile)"
    warning="$(warning_level)"
    percentage="$(battery_percentage)"

    say "GNOME Power Mode Automation"
    say "------------------------------------------------------------"
    printf 'Detected power state   : %s\n' "$state"
    printf 'Battery percentage     : %s\n' "$percentage"
    printf 'UPower warning level   : %s (%s)\n' "$warning" "$(warning_label "$warning")"
    printf 'Configured target      : %s\n' "$(profile_label "$target")"
    printf 'Current GNOME mode     : %s\n' "$(profile_label "$active")"
    printf 'Lid close on battery   : %s\n' "$(lid_action_label "$LID_CLOSE_ON_BATTERY")"
    printf 'Lid close on AC        : %s\n' "$(lid_action_label "$LID_CLOSE_ON_AC")"
}

SELECTED_PROFILE=""
SELECTED_WARNING=""
SELECTED_LID_ACTION=""

choose_profile() {
    local heading="$1" explanation="$2" current="$3" default choice selected
    default="$(profile_to_choice "$current")"

    say
    say "${BOLD}${heading}${RESET}"
    say "$explanation"
    say
    say "  1) Performance"
    say "     Maximum responsiveness for compiling, containers, and heavy work."
    say "  2) Balanced"
    say "     Recommended general-purpose mode with moderate power use."
    say "  3) Power Saver"
    say "     Prioritizes battery runtime, lower heat, and quieter operation."
    say

    while true; do
        printf 'Choose 1, 2, or 3 [default: %s]: ' "$default"
        read -r choice
        choice="${choice:-$default}"
        if selected="$(choice_to_profile "$choice")"; then
            SELECTED_PROFILE="$selected"
            return
        fi
        warn "Please enter 1, 2, or 3."
    done
}

choose_warning() {
    local current="$1" default choice selected
    default="$(warning_to_choice "$current")"

    say
    say "${BOLD}When should low-battery mode activate?${RESET}"
    say "This follows UPower's system warning state, not a fixed percentage."
    say
    say "  1) Low battery (recommended)"
    say "  2) Critical battery"
    say "  3) Final action state"
    say

    while true; do
        printf 'Choose 1, 2, or 3 [default: %s]: ' "$default"
        read -r choice
        choice="${choice:-$default}"
        if selected="$(choice_to_warning "$choice")"; then
            SELECTED_WARNING="$selected"
            return
        fi
        warn "Please enter 1, 2, or 3."
    done
}

choose_lid_action() {
    local heading="$1" explanation="$2" current="$3" default choice selected
    default="$(lid_action_to_choice "$current")"

    say
    say "${BOLD}${heading}${RESET}"
    say "$explanation"
    say
    say "  1) Suspend (recommended)"
    say "     Sleep until the lid opens or another wake event occurs."
    say "  2) Hibernate"
    say "     Save memory to disk, then power down. Requires working hibernation."
    say "  3) Lock screen"
    say "     Keep the system running and ask the desktop session to lock."
    say "  4) Do nothing"
    say "     Leave the system running after the lid closes."
    say

    while true; do
        printf 'Choose 1, 2, 3, or 4 [default: %s]: ' "$default"
        read -r choice
        choice="${choice:-$default}"
        if selected="$(choice_to_lid_action "$choice")"; then
            SELECTED_LID_ACTION="$selected"
            return
        fi
        warn "Please enter 1, 2, 3, or 4."
    done
}

configure() {
    local use_defaults=false ac battery low warning lid_battery lid_ac answer
    while (( $# > 0 )); do
        case "$1" in
            -y|--yes) use_defaults=true ;;
            -h|--help) say "Usage: sudo ${APP} configure [--yes]"; return ;;
            *) die "Unknown configure option: $1" ;;
        esac
        shift
    done

    if "$use_defaults"; then
        write_config \
            "$DEFAULT_AC_PROFILE" \
            "$DEFAULT_BATTERY_PROFILE" \
            "$DEFAULT_LOW_PROFILE" \
            "$DEFAULT_WARNING_LEVEL" \
            "$DEFAULT_LID_CLOSE_ON_BATTERY" \
            "$DEFAULT_LID_CLOSE_ON_AC"
        sync_lid_policy
        restart_monitor_if_active
        success "Configured recommended defaults in $CONFIG"
        return
    fi

    [[ -t 0 ]] || die "Interactive configuration requires a terminal. Use configure --yes instead."
    load_config
    ac="$AC_PROFILE"
    battery="$BATTERY_PROFILE"
    low="$LOW_BATTERY_PROFILE"
    warning="$LOW_BATTERY_WARNING_LEVEL"
    lid_battery="$LID_CLOSE_ON_BATTERY"
    lid_ac="$LID_CLOSE_ON_AC"

    say
    say "${BOLD}${BLUE}GNOME Power Mode Automation${RESET}"
    say "------------------------------------------------------------"
    say "Choose the visible GNOME mode and lid-close action for each state."
    say "Manual GNOME changes are preserved until the next power-state transition."

    choose_profile "1 of 5: Charger connected" "Mode to apply after connecting AC power." "$ac"
    ac="$SELECTED_PROFILE"
    choose_profile "2 of 5: Normal battery" "Mode to apply after disconnecting AC power." "$battery"
    battery="$SELECTED_PROFILE"
    choose_profile "3 of 5: Low battery" "Mode to apply when UPower reports low battery." "$low"
    low="$SELECTED_PROFILE"
    choose_warning "$warning"
    warning="$SELECTED_WARNING"
    choose_lid_action "4 of 5: Lid close on battery" "Action used by systemd-logind while on battery." "$lid_battery"
    lid_battery="$SELECTED_LID_ACTION"
    choose_lid_action "5 of 5: Lid close on AC power" "Action used by systemd-logind while external power is connected." "$lid_ac"
    lid_ac="$SELECTED_LID_ACTION"

    say
    say "${BOLD}Selected policy${RESET}"
    say "------------------------------------------------------------"
    printf '  Charger connected     : %s\n' "$(profile_label "$ac")"
    printf '  Normal battery        : %s\n' "$(profile_label "$battery")"
    printf '  Low battery           : %s\n' "$(profile_label "$low")"
    printf '  Low trigger           : %s\n' "$(warning_label "$warning")"
    printf '  Lid close on battery  : %s\n' "$(lid_action_label "$lid_battery")"
    printf '  Lid close on AC       : %s\n' "$(lid_action_label "$lid_ac")"
    say

    printf 'Save this policy? [Y/n]: '
    read -r answer
    case "${answer:-Y}" in
        y|Y|yes|YES)
            write_config "$ac" "$battery" "$low" "$warning" "$lid_battery" "$lid_ac"
            sync_lid_policy
            restart_monitor_if_active
            success "Configuration saved to $CONFIG"
            ;;
        *) info "Cancelled. No configuration changes were made." ;;
    esac
}
