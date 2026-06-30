#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Deprecated compatibility entry point.
#
# The project is now split into ordinary, reviewable files:
#   install.sh, src/, systemd/, config/, tests/
#
# Use:
#   sudo ./install.sh
#
# This wrapper keeps the old filename working for users who run it from a
# cloned repository.

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${ROOT_DIR}/install.sh"

if [[ -x "$INSTALLER" ]]; then
    printf '%s\n' "NOTE: gnome_tuned_ppd_mode_hook.sh is deprecated; forwarding to install.sh."
    exec "$INSTALLER" "$@"
fi

cat >&2 <<'EOF'
This legacy entry point no longer contains the full installer.

Clone or download the current repository and run:
  sudo ./install.sh
EOF
exit 1
