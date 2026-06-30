#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
report_file="${root_dir}/.shell-quality-report.txt"
files=(
  "$root_dir/install.sh"
  "$root_dir/uninstall.sh"
  "$root_dir/src/gnome-power-profile-automation"
  "$root_dir/tools/watch-power-profile-backend.sh"
)

: > "$report_file"

for file in "${files[@]}"; do
  if ! bash -n "$file" 2>> "$report_file"; then
    printf 'Bash syntax check failed for: %s\n' "$file" >&2
    cat "$report_file" >&2
    exit 1
  fi
  printf 'syntax OK: %s\n' "$file"
done

if command -v shellcheck >/dev/null 2>&1; then
  if ! shellcheck --severity=warning --format=gcc "${files[@]}" >> "$report_file"; then
    printf 'ShellCheck reported findings:\n' >&2
    cat "$report_file" >&2
    exit 1
  fi
  printf 'shellcheck OK\n'
else
  printf 'shellcheck not installed; skipped static lint.\n'
fi

rm -f "$report_file"
