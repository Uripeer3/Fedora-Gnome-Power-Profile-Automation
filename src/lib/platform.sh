#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Adapters for UPower and the system Power Profiles API.

UP_DEST="org.freedesktop.UPower"
UP_PATH="/org/freedesktop/UPower"
UP_IFACE="org.freedesktop.UPower"
UP_DISPLAY_PATH="/org/freedesktop/UPower/devices/DisplayDevice"
UP_DEVICE_IFACE="org.freedesktop.UPower.Device"

PPD_DEST="net.hadess.PowerProfiles"
PPD_PATH="/net/hadess/PowerProfiles"
PPD_IFACE="net.hadess.PowerProfiles"

profile_label() {
    case "$1" in
        performance) printf 'Performance' ;;
        balanced) printf 'Balanced' ;;
        power-saver) printf 'Power Saver' ;;
        *) printf '%s' "$1" ;;
    esac
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

require_ppd_api() {
    busctl --system get-property "$PPD_DEST" "$PPD_PATH" "$PPD_IFACE" ActiveProfile \
        >/dev/null 2>&1 || die "Cannot reach the tuned-ppd Power Profiles API."
}

current_profile() {
    busctl --system get-property "$PPD_DEST" "$PPD_PATH" "$PPD_IFACE" ActiveProfile \
        | sed -n 's/.*"\([^" ]*\)".*/\1/p'
}

set_profile() {
    validate_profile "$1"
    busctl --system set-property "$PPD_DEST" "$PPD_PATH" "$PPD_IFACE" ActiveProfile s "$1"
}

on_battery() {
    local value
    value="$(busctl --system get-property "$UP_DEST" "$UP_PATH" "$UP_IFACE" OnBattery | awk '{print $2}')"
    [[ "$value" == "true" ]]
}

warning_level() {
    local value
    value="$(busctl --system get-property "$UP_DEST" "$UP_DISPLAY_PATH" "$UP_DEVICE_IFACE" WarningLevel 2>/dev/null | awk '{print $2}' || true)"
    [[ "$value" =~ ^[0-5]$ ]] && printf '%s\n' "$value" || printf '1\n'
}

battery_percentage() {
    local value
    value="$(busctl --system get-property "$UP_DEST" "$UP_DISPLAY_PATH" "$UP_DEVICE_IFACE" Percentage 2>/dev/null | awk '{print $2}' || true)"
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && printf '%s\n' "$value" || printf 'unknown\n'
}
