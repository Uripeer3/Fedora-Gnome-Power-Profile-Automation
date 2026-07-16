#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1" actual="$2" context="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "${context}: expected '${expected}', got '${actual}'"
}

source_runtime() {
    export GNOME_POWER_PROFILE_AUTOMATION_LIB_DIR="${root_dir}/src/lib"
    export GNOME_POWER_PROFILE_AUTOMATION_CONFIG_LIB="${root_dir}/src/lib/config.sh"
    export GNOME_POWER_PROFILE_AUTOMATION_POLICY_LIB="${root_dir}/src/lib/policy.sh"
    # shellcheck source=../src/gnome-power-profile-automation
    source "$root_dir/src/gnome-power-profile-automation"
}

test_runtime_loads_all_modules() (
    source_runtime

    local function_name
    for function_name in \
        load_config current_profile sync_lid_policy apply_policy show_status configure; do
        declare -F "$function_name" >/dev/null \
            || fail "Runtime did not load module function: ${function_name}"
    done
)

test_platform_reads_bus_values() (
    source_runtime

    busctl() {
        case "$*" in
            "--system get-property ${PPD_DEST} ${PPD_PATH} ${PPD_IFACE} ActiveProfile")
                printf 's "balanced"\n'
                ;;
            "--system get-property ${UP_DEST} ${UP_PATH} ${UP_IFACE} OnBattery")
                printf 'b true\n'
                ;;
            "--system get-property ${UP_DEST} ${UP_DISPLAY_PATH} ${UP_DEVICE_IFACE} WarningLevel")
                printf 'u 4\n'
                ;;
            "--system get-property ${UP_DEST} ${UP_DISPLAY_PATH} ${UP_DEVICE_IFACE} Percentage")
                printf 'd 42.5\n'
                ;;
            *) fail "Unexpected busctl call: $*" ;;
        esac
    }

    assert_equal balanced "$(current_profile)" "Active profile parsing"
    on_battery || fail "Expected UPower OnBattery=true to return success"
    assert_equal 4 "$(warning_level)" "Warning level parsing"
    assert_equal 42.5 "$(battery_percentage)" "Battery percentage parsing"
)

test_platform_sets_validated_profile() (
    source_runtime

    local call_file
    call_file="$(mktemp)"
    trap 'rm -f "$call_file"' EXIT

    busctl() {
        printf '%s\n' "$*" > "$call_file"
    }

    set_profile power-saver
    assert_equal \
        "--system set-property ${PPD_DEST} ${PPD_PATH} ${PPD_IFACE} ActiveProfile s power-saver" \
        "$(<"$call_file")" \
        "Power Profiles property update"
)

test_monitor_preserves_manual_choice_until_transition() (
    source_runtime

    local temporary current_state applied_file
    local -a applied_profiles=()
    temporary="$(mktemp -d)"
    trap 'rm -rf "$temporary"' EXIT
    STATE_DIR="${temporary}/state"
    STATE_FILE="${STATE_DIR}/last-state"
    applied_file="${temporary}/applied"
    current_state=ac

    desired_state() {
        printf '%s\n' "$current_state"
    }
    profile_for_state() {
        case "$1" in
            ac) printf 'performance\n' ;;
            battery) printf 'balanced\n' ;;
            *) return 2 ;;
        esac
    }
    set_profile() {
        printf '%s\n' "$1" >> "$applied_file"
    }
    log() { :; }

    apply_policy --force
    apply_policy
    current_state=battery
    apply_policy

    mapfile -t applied_profiles < "$applied_file"
    (( ${#applied_profiles[@]} == 2 )) \
        || fail "Expected one forced application and one state-transition application"
    assert_equal performance "${applied_profiles[0]}" "Forced AC profile"
    assert_equal balanced "${applied_profiles[1]}" "Battery transition profile"
    assert_equal battery "$(<"$STATE_FILE")" "Persisted policy state"
)

test_cli_choice_mappings() (
    source_runtime

    assert_equal performance "$(choice_to_profile 1)" "Profile choice"
    assert_equal 4 "$(choice_to_warning 2)" "Warning choice"
    assert_equal ignore "$(choice_to_lid_action 4)" "Lid-action choice"
)

test_runtime_loads_all_modules
test_platform_reads_bus_values
test_platform_sets_validated_profile
test_monitor_preserves_manual_choice_until_transition
test_cli_choice_mappings
printf 'runtime module tests OK\n'
