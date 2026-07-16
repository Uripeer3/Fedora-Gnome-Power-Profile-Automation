#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Power-state orchestration and the event-driven monitor.
# Shared configuration and output helpers are provided by the entrypoint.
# shellcheck disable=SC2154

STATE_DIR="/run/${APP}"
STATE_FILE="${STATE_DIR}/last-state"

desired_state() {
    local battery_state warning
    if on_battery; then
        battery_state=true
    else
        battery_state=false
    fi
    warning="$(warning_level)"
    policy_state_for_inputs "$battery_state" "$warning" "$LOW_BATTERY_WARNING_LEVEL" \
        || die "Could not classify power state from UPower values."
}

profile_for_state() {
    policy_profile_for_state "$1" "$AC_PROFILE" "$BATTERY_PROFILE" "$LOW_BATTERY_PROFILE" \
        || die "Unknown state: $1"
}

apply_policy() {
    local force="${1:-}" state target last_state=""
    install -d -m 0755 "$STATE_DIR"
    state="$(desired_state)"
    target="$(profile_for_state "$state")"
    [[ -r "$STATE_FILE" ]] && last_state="$(<"$STATE_FILE")"

    # Avoid clobbering a manual GNOME choice while the physical state is unchanged.
    if ! policy_should_apply_state "$force" "$state" "$last_state"; then
        return 0
    fi

    set_profile "$target"
    printf '%s\n' "$state" > "$STATE_FILE"
    log "state=$state active-profile=$target"
}

restart_monitor_if_active() {
    require_command systemctl

    if systemctl is-active --quiet "${APP}.service"; then
        systemctl restart "${APP}.service" \
            || die "Configuration was saved, but the running power-profile monitor could not be restarted."
        success "Restarted the power-profile monitor with the new configuration."
    fi
}

monitor() {
    require_command upower
    require_command busctl
    load_config
    require_ppd_api
    apply_policy --force

    while true; do
        while IFS= read -r _event; do
            apply_policy || log "Could not apply policy after UPower event"
        done < <(upower --monitor-detail)
        sleep 2
    done
}
