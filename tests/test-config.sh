#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../src/lib/config.sh
source "$root_dir/src/lib/config.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1" actual="$2" description="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$description: expected '$expected', got '$actual'"
}

current="$tmp_dir/current.conf"
config_render performance balanced power-saver 3 suspend ignore > "$current"
assert_equal current "$(config_detect_format "$current")" "Current format detection"
config_parse_current "$current" || fail "Rendered configuration did not parse."
assert_equal 1 "$CONFIG_VERSION" "Schema version"
assert_equal performance "$AC_PROFILE" "AC profile"
assert_equal balanced "$BATTERY_PROFILE" "Battery profile"
assert_equal power-saver "$LOW_BATTERY_PROFILE" "Low-battery profile"
assert_equal 3 "$LOW_BATTERY_WARNING_LEVEL" "Warning threshold"
assert_equal suspend "$LID_CLOSE_ON_BATTERY" "Battery lid action"
assert_equal ignore "$LID_CLOSE_ON_AC" "AC lid action"

legacy="$tmp_dir/legacy.conf"
cat > "$legacy" <<'EOF'
# Legacy shell-style data. It must be parsed, never evaluated.
AC_PROFILE="performance"
BATTERY_PROFILE="balanced"
LOW_BATTERY_PROFILE="power-saver"
LOW_BATTERY_WARNING_LEVEL=4
EOF
assert_equal legacy "$(config_detect_format "$legacy")" "Legacy format detection"
LID_CLOSE_ON_BATTERY=suspend
LID_CLOSE_ON_AC=suspend
config_parse_legacy "$legacy" || fail "Valid legacy configuration did not parse."
assert_equal 4 "$LOW_BATTERY_WARNING_LEVEL" "Migrated warning threshold"
assert_equal suspend "$LID_CLOSE_ON_BATTERY" "Default legacy battery lid action"

malicious="$tmp_dir/malicious.conf"
marker="$tmp_dir/should-not-exist"
cat > "$malicious" <<EOF
AC_PROFILE="\$(touch $marker)"
BATTERY_PROFILE="balanced"
LOW_BATTERY_PROFILE="power-saver"
LOW_BATTERY_WARNING_LEVEL=3
EOF
if config_parse_legacy "$malicious"; then
    fail "Executable legacy value was accepted."
fi
[[ ! -e "$marker" ]] || fail "Legacy configuration content was executed."

duplicate="$tmp_dir/duplicate.conf"
config_render performance balanced power-saver 3 suspend suspend > "$duplicate"
printf 'ACProfile=balanced\n' >> "$duplicate"
if config_parse_current "$duplicate"; then
    fail "Duplicate current-format key was accepted."
fi

unknown="$tmp_dir/unknown.conf"
config_render performance balanced power-saver 3 suspend suspend > "$unknown"
printf 'UnexpectedKey=value\n' >> "$unknown"
if config_parse_current "$unknown"; then
    fail "Unknown current-format key was accepted."
fi

future="$tmp_dir/future.conf"
sed 's/^Version=1$/Version=2/' "$current" > "$future"
if config_parse_current "$future"; then
    fail "Unsupported future schema version was accepted."
fi

printf 'configuration format tests OK\n'
