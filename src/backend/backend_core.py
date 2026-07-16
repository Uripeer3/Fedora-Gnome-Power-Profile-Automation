#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pure configuration and status logic for the read-only D-Bus backend."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import stat
from typing import Final, Mapping


API_VERSION: Final = 1
SCHEMA_VERSION: Final = 1

PROFILES: Final = frozenset({"performance", "balanced", "power-saver"})
LID_ACTIONS: Final = frozenset({"suspend", "hibernate", "lock", "ignore"})

INI_KEYS: Final = (
    "Version",
    "ACProfile",
    "BatteryProfile",
    "LowBatteryProfile",
    "LowBatteryWarningLevel",
    "LidCloseOnBattery",
    "LidCloseOnAC",
)

DBUS_KEYS: Final = {
    "Version": "schema-version",
    "ACProfile": "ac-profile",
    "BatteryProfile": "battery-profile",
    "LowBatteryProfile": "low-battery-profile",
    "LowBatteryWarningLevel": "low-battery-warning-level",
    "LidCloseOnBattery": "lid-close-on-battery",
    "LidCloseOnAC": "lid-close-on-ac",
}

DEFAULT_VALUES: Final = {
    "Version": "1",
    "ACProfile": "performance",
    "BatteryProfile": "balanced",
    "LowBatteryProfile": "power-saver",
    "LowBatteryWarningLevel": "3",
    "LidCloseOnBattery": "suspend",
    "LidCloseOnAC": "suspend",
}


class ConfigurationError(ValueError):
    """The policy document cannot be accepted by the backend."""


@dataclass(frozen=True)
class Configuration:
    schema_version: int
    ac_profile: str
    battery_profile: str
    low_battery_profile: str
    low_battery_warning_level: int
    lid_close_on_battery: str
    lid_close_on_ac: str

    def as_dbus_document(self) -> dict[str, object]:
        return {
            "schema-version": self.schema_version,
            "ac-profile": self.ac_profile,
            "battery-profile": self.battery_profile,
            "low-battery-profile": self.low_battery_profile,
            "low-battery-warning-level": self.low_battery_warning_level,
            "lid-close-on-battery": self.lid_close_on_battery,
            "lid-close-on-ac": self.lid_close_on_ac,
        }


def default_configuration() -> Configuration:
    return configuration_from_values(DEFAULT_VALUES)


def parse_configuration(text: str) -> Configuration:
    """Parse the strict schema-1 INI subset used by the Bash runtime."""
    values: dict[str, str] = {}
    in_policy = False

    for raw_line in text.splitlines():
        line = raw_line.removesuffix("\r")
        if not line or line.startswith("#"):
            continue

        if line == "[Policy]":
            if in_policy:
                raise ConfigurationError("duplicate [Policy] section")
            in_policy = True
            continue

        if not in_policy or "=" not in line:
            raise ConfigurationError("content must be inside one [Policy] section")

        key, value = line.split("=", 1)
        if key not in INI_KEYS:
            raise ConfigurationError(f"unknown configuration key: {key}")
        if key in values:
            raise ConfigurationError(f"duplicate configuration key: {key}")
        if not value or not all(
            character.isascii() and (character.isalnum() or character == "-")
            for character in value
        ):
            raise ConfigurationError(f"invalid value syntax for {key}")
        values[key] = value

    if not in_policy:
        raise ConfigurationError("missing [Policy] section")

    missing = [key for key in INI_KEYS if key not in values]
    if missing:
        raise ConfigurationError(f"missing configuration key: {missing[0]}")

    return configuration_from_values(values)


def configuration_from_values(values: Mapping[str, str]) -> Configuration:
    try:
        version = int(values["Version"])
        warning_level = int(values["LowBatteryWarningLevel"])
    except (KeyError, ValueError) as error:
        raise ConfigurationError("configuration contains a non-integer version or warning level") from error

    if version != SCHEMA_VERSION:
        raise ConfigurationError(f"unsupported configuration version: {version}")

    for key in ("ACProfile", "BatteryProfile", "LowBatteryProfile"):
        if values[key] not in PROFILES:
            raise ConfigurationError(f"unsupported profile for {key}: {values[key]}")

    if warning_level not in {3, 4, 5}:
        raise ConfigurationError("LowBatteryWarningLevel must be 3, 4, or 5")

    for key in ("LidCloseOnBattery", "LidCloseOnAC"):
        if values[key] not in LID_ACTIONS:
            raise ConfigurationError(f"unsupported lid action for {key}: {values[key]}")

    return Configuration(
        schema_version=version,
        ac_profile=values["ACProfile"],
        battery_profile=values["BatteryProfile"],
        low_battery_profile=values["LowBatteryProfile"],
        low_battery_warning_level=warning_level,
        lid_close_on_battery=values["LidCloseOnBattery"],
        lid_close_on_ac=values["LidCloseOnAC"],
    )


def load_configuration(path: Path) -> Configuration:
    """Load a safe root-owned document, or defaults when it does not exist."""
    try:
        metadata = path.stat()
    except FileNotFoundError:
        return default_configuration()

    if metadata.st_uid != 0:
        raise ConfigurationError(f"configuration is not owned by root: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise ConfigurationError(f"configuration is group- or world-writable: {path}")

    try:
        return parse_configuration(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ConfigurationError(f"cannot read configuration: {path}") from error


def policy_state_for_inputs(on_battery: bool, warning_level: int, low_threshold: int) -> str:
    if not on_battery:
        return "ac"
    if warning_level >= low_threshold:
        return "low-battery"
    return "battery"


def profile_for_state(configuration: Configuration, policy_state: str) -> str:
    profiles = {
        "ac": configuration.ac_profile,
        "battery": configuration.battery_profile,
        "low-battery": configuration.low_battery_profile,
    }
    try:
        return profiles[policy_state]
    except KeyError as error:
        raise ValueError(f"unknown policy state: {policy_state}") from error


def build_status(
    *,
    configuration: Configuration | None,
    on_battery: bool | None,
    warning_level: int | None,
    battery_percentage: float | None,
    active_profile: str | None,
    errors: tuple[str, ...] = (),
) -> dict[str, object]:
    """Build one internally consistent API-v1 status snapshot."""
    power_source = "unknown" if on_battery is None else ("battery" if on_battery else "ac")
    policy_state = "unknown"
    desired_profile = ""

    if (
        configuration is not None
        and on_battery is not None
        and warning_level is not None
        and 0 <= warning_level <= 5
    ):
        policy_state = policy_state_for_inputs(
            on_battery,
            warning_level,
            configuration.low_battery_warning_level,
        )
        desired_profile = profile_for_state(configuration, policy_state)

    valid_percentage = (
        float(battery_percentage)
        if battery_percentage is not None and 0.0 <= battery_percentage <= 100.0
        else -1.0
    )
    valid_warning = warning_level if warning_level is not None and 0 <= warning_level <= 5 else 0
    valid_active = active_profile if active_profile in PROFILES else ""

    return {
        "api-version": API_VERSION,
        "backend-state": "degraded" if errors else "ready",
        "power-source": power_source,
        "policy-state": policy_state,
        "active-profile": valid_active,
        "desired-profile": desired_profile,
        "battery-percentage": valid_percentage,
        "battery-warning-level": valid_warning,
        "last-error": "; ".join(errors),
    }
