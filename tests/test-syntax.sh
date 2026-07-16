#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
report_file="${root_dir}/.shell-quality-report.txt"
executable_files=(
  "$root_dir/install.sh"
  "$root_dir/uninstall.sh"
  "$root_dir/src/gnome-power-profile-automation"
  "$root_dir/tools/watch-power-profile-backend.sh"
)
library_files=(
  "$root_dir/src/lib/config.sh"
  "$root_dir/src/lib/policy.sh"
  "$root_dir/tests/test-config.sh"
  "$root_dir/tests/test-policy.sh"
)
files=("${executable_files[@]}" "${library_files[@]}")

: > "$report_file"

for file in "${executable_files[@]}"; do
  if [[ ! -x "$file" ]]; then
    printf 'Expected an executable Git file mode: %s\n' "$file" >> "$report_file"
  fi
done

for file in "${files[@]}"; do
  if ! bash -n "$file" 2>> "$report_file"; then
    printf 'Bash syntax check failed for: %s\n' "$file" >&2
    cat "$report_file" >&2
    exit 1
  fi

  printf 'syntax OK: %s\n' "$file"
done

if [[ -s "$report_file" ]]; then
  cat "$report_file" >&2
  exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
  if ! shellcheck --severity=warning --format=gcc "${files[@]}" > "$report_file"; then
    printf 'ShellCheck reported warnings or errors:\n' >&2
    cat "$report_file" >&2
    exit 1
  fi
  printf 'shellcheck OK\n'
else
  printf 'shellcheck not installed; skipped static lint.\n'
fi

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test_configure_restarts_active_monitor() (
  # shellcheck source=../src/gnome-power-profile-automation
  source "$root_dir/src/gnome-power-profile-automation"

  local -a calls=()
  systemctl() {
    calls+=("$*")
    return 0
  }

  restart_monitor_if_active >/dev/null

  [[ "${calls[0]:-}" == "is-active --quiet ${APP}.service" ]] \
    || fail "Expected an active-service check before refreshing configuration."
  [[ "${calls[1]:-}" == "restart ${APP}.service" ]] \
    || fail "Expected the active monitor to be restarted."
  (( ${#calls[@]} == 2 )) \
    || fail "Unexpected systemctl calls while refreshing configuration."
)

test_configure_leaves_inactive_monitor_stopped() (
  # shellcheck source=../src/gnome-power-profile-automation
  source "$root_dir/src/gnome-power-profile-automation"

  local -a calls=()
  systemctl() {
    calls+=("$*")
    [[ "$1" != "is-active" ]]
  }

  restart_monitor_if_active >/dev/null

  [[ "${calls[0]:-}" == "is-active --quiet ${APP}.service" ]] \
    || fail "Expected an inactive-service check."
  (( ${#calls[@]} == 1 )) \
    || fail "An inactive monitor must not be started by configure."
)

test_install_restarts_installed_runtime() (
  # shellcheck source=../install.sh
  source "$root_dir/install.sh"

  local -a calls=()
  systemctl() {
    calls+=("$*")
  }

  activate_service

  [[ "${calls[0]:-}" == "daemon-reload" ]] \
    || fail "Expected systemd units to be reloaded first."
  [[ "${calls[1]:-}" == "enable ${APP}.service" ]] \
    || fail "Expected the service to be enabled."
  [[ "${calls[2]:-}" == "restart ${APP}.service" ]] \
    || fail "Expected installation and upgrades to restart the service."
  (( ${#calls[@]} == 3 )) \
    || fail "Unexpected systemctl calls while activating the service."
)

test_configure_restarts_active_monitor
test_configure_leaves_inactive_monitor_stopped
test_install_restarts_installed_runtime
printf 'service refresh tests OK\n'

bash "$root_dir/tests/test-policy.sh"
bash "$root_dir/tests/test-config.sh"

rm -f "$report_file"
