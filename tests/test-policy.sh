#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../src/lib/policy.sh
source "$root_dir/src/lib/policy.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1" actual="$2" description="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$description: expected '$expected', got '$actual'"
}

assert_state() {
    local expected="$1" battery_state="$2" warning="$3" threshold="$4"
    local actual
    actual="$(policy_state_for_inputs "$battery_state" "$warning" "$threshold")" \
        || fail "State classification rejected valid inputs."
    assert_equal "$expected" "$actual" \
        "battery=$battery_state warning=$warning threshold=$threshold"
}

assert_apply_decision() {
    local expected="$1" force="$2" state="$3" last_state="$4" actual=false
    if policy_should_apply_state "$force" "$state" "$last_state"; then
        actual=true
    fi
    assert_equal "$expected" "$actual" \
        "force='$force' state=$state last-state='$last_state'"
}

# AC always wins over a stale battery warning value.
assert_state ac false 1 3
assert_state ac false 5 3

# Normal battery remains active below the configured UPower threshold.
assert_state battery true 1 3
assert_state battery true 3 4
assert_state battery true 4 5

# The configured threshold and every more severe warning select low battery.
assert_state low-battery true 3 3
assert_state low-battery true 4 3
assert_state low-battery true 4 4
assert_state low-battery true 5 5

assert_equal performance \
    "$(policy_profile_for_state ac performance balanced power-saver)" \
    "AC profile selection"
assert_equal balanced \
    "$(policy_profile_for_state battery performance balanced power-saver)" \
    "Battery profile selection"
assert_equal power-saver \
    "$(policy_profile_for_state low-battery performance balanced power-saver)" \
    "Low-battery profile selection"

# Manual choices are preserved until the physical state changes.
assert_apply_decision false "" battery battery
assert_apply_decision true "" low-battery battery
assert_apply_decision true --force battery battery

if policy_state_for_inputs unknown 1 3 >/dev/null; then
    fail "Invalid battery state was accepted."
fi
if policy_state_for_inputs true 6 3 >/dev/null; then
    fail "Invalid warning level was accepted."
fi
if policy_state_for_inputs true 3 2 >/dev/null; then
    fail "Invalid low-battery threshold was accepted."
fi
if policy_profile_for_state unknown performance balanced power-saver >/dev/null; then
    fail "Unknown physical state was accepted for profile selection."
fi

printf 'policy behavior tests OK\n'
