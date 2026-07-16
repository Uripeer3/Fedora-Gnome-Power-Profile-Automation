#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Strict parsers and renderer for the versioned policy configuration format.
# The application identity and output helpers are provided by the entrypoint.
# shellcheck disable=SC2154

CONFIG_SCHEMA_VERSION=1
CONFIG="/etc/gnome-power-profile-automation.conf"

DEFAULT_AC_PROFILE="performance"
DEFAULT_BATTERY_PROFILE="balanced"
DEFAULT_LOW_PROFILE="power-saver"
DEFAULT_WARNING_LEVEL="3"
DEFAULT_LID_CLOSE_ON_BATTERY="suspend"
DEFAULT_LID_CLOSE_ON_AC="suspend"

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

        # These variables are the parser's output API and are consumed by callers.
        # shellcheck disable=SC2034
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

validate_profile() {
    case "$1" in
        performance|balanced|power-saver) ;;
        *) die "Unsupported profile: $1" ;;
    esac
}

validate_lid_action() {
    case "$1" in
        suspend|hibernate|lock|ignore) ;;
        *) die "Unsupported lid-close action: $1" ;;
    esac
}

validate_config_permissions() {
    local owner mode

    owner="$(stat -c '%u' "$CONFIG")" || die "Cannot read configuration ownership: $CONFIG"
    mode="$(stat -c '%a' "$CONFIG")" || die "Cannot read configuration mode: $CONFIG"

    [[ "$owner" == "0" ]] || die "Configuration must be owned by root: $CONFIG"
    (( (8#$mode & 8#022) == 0 )) || die "Configuration must not be group- or world-writable: $CONFIG"
}

set_config_defaults() {
    AC_PROFILE="$DEFAULT_AC_PROFILE"
    BATTERY_PROFILE="$DEFAULT_BATTERY_PROFILE"
    LOW_BATTERY_PROFILE="$DEFAULT_LOW_PROFILE"
    LOW_BATTERY_WARNING_LEVEL="$DEFAULT_WARNING_LEVEL"
    LID_CLOSE_ON_BATTERY="$DEFAULT_LID_CLOSE_ON_BATTERY"
    LID_CLOSE_ON_AC="$DEFAULT_LID_CLOSE_ON_AC"
}

validate_loaded_config() {
    validate_profile "$AC_PROFILE"
    validate_profile "$BATTERY_PROFILE"
    validate_profile "$LOW_BATTERY_PROFILE"
    [[ "$LOW_BATTERY_WARNING_LEVEL" =~ ^[3-5]$ ]] || die "LOW_BATTERY_WARNING_LEVEL must be 3, 4, or 5"
    validate_lid_action "$LID_CLOSE_ON_BATTERY"
    validate_lid_action "$LID_CLOSE_ON_AC"
}

load_config() {
    local format
    set_config_defaults

    [[ -r "$CONFIG" ]] || return 0
    validate_config_permissions
    format="$(config_detect_format "$CONFIG")" || die "Invalid configuration format: $CONFIG"
    [[ "$format" == current ]] \
        || die "Legacy configuration detected. Run: sudo ${APP} migrate-config"
    config_parse_current "$CONFIG" || die "Invalid versioned configuration: $CONFIG"
    validate_loaded_config
}

write_config() {
    local ac="$1" battery="$2" low="$3" warning="$4" lid_battery="$5" lid_ac="$6" temporary
    validate_profile "$ac"
    validate_profile "$battery"
    validate_profile "$low"
    [[ "$warning" =~ ^[3-5]$ ]] || die "Invalid UPower warning level: $warning"
    validate_lid_action "$lid_battery"
    validate_lid_action "$lid_ac"

    temporary="$(mktemp "${CONFIG}.XXXXXX")" || die "Could not create a temporary configuration file."
    config_render "$ac" "$battery" "$low" "$warning" "$lid_battery" "$lid_ac" > "$temporary"
    chown root:root "$temporary"
    chmod 0644 "$temporary"
    mv -f "$temporary" "$CONFIG"
}

migrate_config() {
    local format backup

    [[ -r "$CONFIG" ]] || return 0
    validate_config_permissions
    format="$(config_detect_format "$CONFIG")" || die "Invalid configuration format: $CONFIG"

    if [[ "$format" == current ]]; then
        set_config_defaults
        config_parse_current "$CONFIG" || die "Invalid versioned configuration: $CONFIG"
        validate_loaded_config
        return 0
    fi

    set_config_defaults
    config_parse_legacy "$CONFIG" || die "Legacy configuration could not be migrated safely: $CONFIG"
    validate_loaded_config

    backup="${CONFIG}.legacy.bak"
    [[ ! -e "$backup" ]] || die "Migration backup already exists: $backup"
    install -m 0600 -o root -g root "$CONFIG" "$backup"
    write_config "$AC_PROFILE" "$BATTERY_PROFILE" "$LOW_BATTERY_PROFILE" \
        "$LOW_BATTERY_WARNING_LEVEL" "$LID_CLOSE_ON_BATTERY" "$LID_CLOSE_ON_AC"
    success "Migrated configuration to schema version ${CONFIG_SCHEMA_VERSION}. Backup: $backup"
}
