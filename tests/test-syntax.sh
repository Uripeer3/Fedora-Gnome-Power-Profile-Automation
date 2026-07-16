#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
report_file="${root_dir}/.shell-quality-report.txt"
export GNOME_POWER_PROFILE_AUTOMATION_LIB_DIR="${root_dir}/src/lib"
export GNOME_POWER_PROFILE_AUTOMATION_CONFIG_LIB="${root_dir}/src/lib/config.sh"
export GNOME_POWER_PROFILE_AUTOMATION_POLICY_LIB="${root_dir}/src/lib/policy.sh"
shell_executable_files=(
  "$root_dir/install.sh"
  "$root_dir/uninstall.sh"
  "$root_dir/src/gnome-power-profile-automation"
  "$root_dir/tools/watch-power-profile-backend.sh"
)
python_executable_files=(
  "$root_dir/src/gnome-power-profile-automation-backend"
  "$root_dir/tests/test-backend-core.py"
)
executable_files=("${shell_executable_files[@]}" "${python_executable_files[@]}")
library_files=(
  "$root_dir/src/lib/config.sh"
  "$root_dir/src/lib/cli.sh"
  "$root_dir/src/lib/lid.sh"
  "$root_dir/src/lib/monitor.sh"
  "$root_dir/src/lib/platform.sh"
  "$root_dir/src/lib/policy.sh"
  "$root_dir/tests/test-config.sh"
  "$root_dir/tests/test-policy.sh"
  "$root_dir/tests/test-runtime-modules.sh"
)
files=("${shell_executable_files[@]}" "${library_files[@]}")

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

test_install_restarts_installed_runtimes() (
  # shellcheck source=../install.sh
  source "$root_dir/install.sh"

  local -a calls=()
  systemctl() {
    calls+=("$*")
  }

  activate_services

  [[ "${calls[0]:-}" == "daemon-reload" ]] \
    || fail "Expected systemd units to be reloaded first."
  [[ "${calls[1]:-}" == "reload dbus-broker.service" ]] \
    || fail "Expected the installed system D-Bus policy to be reloaded."
  [[ "${calls[2]:-}" == "enable ${APP}.service ${APP}-backend.service" ]] \
    || fail "Expected both services to be enabled."
  [[ "${calls[3]:-}" == "restart ${APP}.service ${APP}-backend.service" ]] \
    || fail "Expected installation and upgrades to restart both services."
  (( ${#calls[@]} == 4 )) \
    || fail "Unexpected systemctl calls while activating the services."
)

test_configure_restarts_active_monitor
test_configure_leaves_inactive_monitor_stopped
test_install_restarts_installed_runtimes
printf 'service refresh tests OK\n'

python3 - <<PY
import ast
from pathlib import Path

for path in (
    Path("$root_dir/src/gnome-power-profile-automation-backend"),
    Path("$root_dir/src/backend/backend_core.py"),
    Path("$root_dir/src/backend/backend_service.py"),
    Path("$root_dir/tests/test-backend-core.py"),
):
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    print(f"python syntax OK: {path}")
PY

bash "$root_dir/tests/test-policy.sh"
bash "$root_dir/tests/test-config.sh"
bash "$root_dir/tests/test-runtime-modules.sh"
python3 "$root_dir/tests/test-backend-core.py"

rm -f "$report_file"
