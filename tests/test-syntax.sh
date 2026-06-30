#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
files=(
  "$root_dir/install.sh"
  "$root_dir/uninstall.sh"
  "$root_dir/src/gnome-power-profile-automation"
)

for file in "${files[@]}"; do
  bash -n "$file"
  printf 'syntax OK: %s\n' "$file"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning "${files[@]}"
  printf 'shellcheck OK\n'
else
  printf 'shellcheck not installed; skipped static lint.\n'
fi
