#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Management of the project-owned systemd-logind lid policy.
# Shared paths, configuration, and output helpers are provided by the entrypoint.
# shellcheck disable=SC2154

LOGIND_DROPIN_DIR="/etc/systemd/logind.conf.d"
LOGIND_DROPIN="${LOGIND_DROPIN_DIR}/90-${APP}-lid.conf"

lid_action_label() {
    case "$1" in
        suspend) printf 'Suspend' ;;
        hibernate) printf 'Hibernate' ;;
        lock) printf 'Lock screen' ;;
        ignore) printf 'Do nothing' ;;
        *) printf '%s' "$1" ;;
    esac
}

write_lid_dropin() {
    local battery_action="$1" ac_action="$2" temporary
    validate_lid_action "$battery_action"
    validate_lid_action "$ac_action"

    install -d -m 0755 "$LOGIND_DROPIN_DIR"
    temporary="$(mktemp "${LOGIND_DROPIN}.XXXXXX")" || die "Could not create a temporary lid policy file."

    cat > "$temporary" <<EOF
# Managed by ${APP}. Edit ${CONFIG}, then run:
#   sudo ${APP} sync-lid-policy
[Login]
HandleLidSwitch=${battery_action}
HandleLidSwitchExternalPower=${ac_action}
EOF

    chown root:root "$temporary"
    chmod 0644 "$temporary"
    mv -f "$temporary" "$LOGIND_DROPIN"

    if ! systemctl reload systemd-logind.service; then
        warn "Lid policy was written, but systemd-logind could not be reloaded. Reboot to apply it."
    fi
}

sync_lid_policy() {
    require_command systemctl
    load_config
    write_lid_dropin "$LID_CLOSE_ON_BATTERY" "$LID_CLOSE_ON_AC"
    success "Applied lid-close policy: battery=$(lid_action_label "$LID_CLOSE_ON_BATTERY"), AC=$(lid_action_label "$LID_CLOSE_ON_AC")"
}
