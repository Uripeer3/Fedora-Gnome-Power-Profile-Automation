#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Strict parsers and renderer for the versioned policy configuration format.

CONFIG_SCHEMA_VERSION=1

config_detect_format() {
    local file="$1" line

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        case "$line" in
            '[Policy]') printf 'current\n'; return 0 ;;
            AC_PROFILE=*|BATTERY_PROFILE=*|LOW_BATTERY_PROFILE=*|LOW_BATTERY_WARNING_LEVEL=*|LID_CLOSE_ON_BATTERY=*|LID_CLOSE_ON_AC=*)
                printf 'legacy\n'
                return 0
                ;;
            *) return 2 ;;
        esac
    done < "$file"

    return 2
}

config_parse_current() {
    local file="$1" line key value in_policy=false
    local -A seen=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == '[Policy]' ]]; then
            "$in_policy" && return 2
            in_policy=true
            continue
        fi

        "$in_policy" || return 2
        [[ "$line" == *=* ]] || return 2
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || return 2
        [[ "$value" =~ ^[A-Za-z0-9-]+$ ]] || return 2
        [[ -z "${seen[$key]:-}" ]] || return 2
        seen["$key"]=1

        # These variables are the parser's output API and are consumed by callers.
        # shellcheck disable=SC2034
        case "$key" in
            Version) CONFIG_VERSION="$value" ;;
            ACProfile) AC_PROFILE="$value" ;;
            BatteryProfile) BATTERY_PROFILE="$value" ;;
            LowBatteryProfile) LOW_BATTERY_PROFILE="$value" ;;
            LowBatteryWarningLevel) LOW_BATTERY_WARNING_LEVEL="$value" ;;
            LidCloseOnBattery) LID_CLOSE_ON_BATTERY="$value" ;;
            LidCloseOnAC) LID_CLOSE_ON_AC="$value" ;;
            *) return 2 ;;
        esac
    done < "$file"

    "$in_policy" || return 2
    local required
    for required in Version ACProfile BatteryProfile LowBatteryProfile \
        LowBatteryWarningLevel LidCloseOnBattery LidCloseOnAC; do
        [[ -n "${seen[$required]:-}" ]] || return 2
    done
    [[ "$CONFIG_VERSION" == "$CONFIG_SCHEMA_VERSION" ]] || return 2
}

config_decode_legacy_value() {
    local raw="$1" value

    case "$raw" in
        \"*\") value="${raw:1:${#raw}-2}" ;;
        \'*\') value="${raw:1:${#raw}-2}" ;;
        *) value="$raw" ;;
    esac
    [[ "$value" =~ ^[A-Za-z0-9-]+$ ]] || return 2
    printf '%s\n' "$value"
}

config_parse_legacy() {
    local file="$1" line key raw value
    local -A seen=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || return 2
        key="${line%%=*}"
        raw="${line#*=}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 2
        [[ -z "${seen[$key]:-}" ]] || return 2
        value="$(config_decode_legacy_value "$raw")" || return 2
        seen["$key"]=1

        case "$key" in
            AC_PROFILE) AC_PROFILE="$value" ;;
            BATTERY_PROFILE) BATTERY_PROFILE="$value" ;;
            LOW_BATTERY_PROFILE) LOW_BATTERY_PROFILE="$value" ;;
            LOW_BATTERY_WARNING_LEVEL) LOW_BATTERY_WARNING_LEVEL="$value" ;;
            LID_CLOSE_ON_BATTERY) LID_CLOSE_ON_BATTERY="$value" ;;
            LID_CLOSE_ON_AC) LID_CLOSE_ON_AC="$value" ;;
            *) return 2 ;;
        esac
    done < "$file"

    local required
    for required in AC_PROFILE BATTERY_PROFILE LOW_BATTERY_PROFILE LOW_BATTERY_WARNING_LEVEL; do
        [[ -n "${seen[$required]:-}" ]] || return 2
    done
}

config_render() {
    local ac="$1" battery="$2" low="$3" warning="$4" lid_battery="$5" lid_ac="$6"

    cat <<EOF
# GNOME Power Mode Automation configuration
[Policy]
Version=${CONFIG_SCHEMA_VERSION}
ACProfile=${ac}
BatteryProfile=${battery}
LowBatteryProfile=${low}
LowBatteryWarningLevel=${warning}
LidCloseOnBattery=${lid_battery}
LidCloseOnAC=${lid_ac}
EOF
}
