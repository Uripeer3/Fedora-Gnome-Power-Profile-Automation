#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Pure power-policy decisions. This file performs no system or filesystem I/O.

policy_state_for_inputs() {
    local battery_state="$1" warning_level="$2" low_threshold="$3"

    case "$battery_state" in
        true|false) ;;
        *) return 2 ;;
    esac
    [[ "$warning_level" =~ ^[0-5]$ ]] || return 2
    [[ "$low_threshold" =~ ^[3-5]$ ]] || return 2

    if [[ "$battery_state" == false ]]; then
        printf 'ac\n'
    elif (( warning_level >= low_threshold )); then
        printf 'low-battery\n'
    else
        printf 'battery\n'
    fi
}

policy_profile_for_state() {
    local state="$1" ac_profile="$2" battery_profile="$3" low_profile="$4"

    case "$state" in
        ac) printf '%s\n' "$ac_profile" ;;
        battery) printf '%s\n' "$battery_profile" ;;
        low-battery) printf '%s\n' "$low_profile" ;;
        *) return 2 ;;
    esac
}

policy_should_apply_state() {
    local force="$1" state="$2" last_state="$3"
    [[ "$force" == "--force" || "$state" != "$last_state" ]]
}
