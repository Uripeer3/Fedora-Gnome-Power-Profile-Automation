#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only system D-Bus service for GNOME Power Mode Automation."""

from __future__ import annotations

import os
from pathlib import Path
import signal
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from backend_core import (  # noqa: E402
    API_VERSION,
    Configuration,
    ConfigurationError,
    build_status,
    load_configuration,
)


BUS_NAME = "io.github.Uripeer3.GnomePowerProfileAutomation1"
OBJECT_PATH = "/io/github/Uripeer3/GnomePowerProfileAutomation1"
INTERFACE = BUS_NAME
PROPERTIES_INTERFACE = "org.freedesktop.DBus.Properties"

UP_DEST = "org.freedesktop.UPower"
UP_PATH = "/org/freedesktop/UPower"
UP_IFACE = "org.freedesktop.UPower"
UP_DISPLAY_PATH = "/org/freedesktop/UPower/devices/DisplayDevice"
UP_DEVICE_IFACE = "org.freedesktop.UPower.Device"

PPD_DEST = "net.hadess.PowerProfiles"
PPD_PATH = "/net/hadess/PowerProfiles"
PPD_IFACE = "net.hadess.PowerProfiles"

PROPERTY_TO_STATUS = {
    "BackendState": "backend-state",
    "PowerSource": "power-source",
    "PolicyState": "policy-state",
    "ActiveProfile": "active-profile",
    "DesiredProfile": "desired-profile",
    "LastError": "last-error",
}

STATUS_SIGNATURES = {
    "api-version": "u",
    "backend-state": "s",
    "power-source": "s",
    "policy-state": "s",
    "active-profile": "s",
    "desired-profile": "s",
    "battery-percentage": "d",
    "battery-warning-level": "u",
    "last-error": "s",
}

CONFIG_SIGNATURES = {
    "schema-version": "u",
    "ac-profile": "s",
    "battery-profile": "s",
    "low-battery-profile": "s",
    "low-battery-warning-level": "u",
    "lid-close-on-battery": "s",
    "lid-close-on-ac": "s",
}


def variant_document(document: dict[str, object], signatures: dict[str, str]) -> dict[str, GLib.Variant]:
    return {key: GLib.Variant(signatures[key], value) for key, value in document.items()}


class BackendService:
    def __init__(self, connection: Gio.DBusConnection, introspection_path: Path, config_path: Path):
        self.connection = connection
        self.config_path = config_path
        self.configuration: Configuration | None = None
        self.status = build_status(
            configuration=None,
            on_battery=None,
            warning_level=None,
            battery_percentage=None,
            active_profile=None,
            errors=("backend is initializing",),
        )
        self._refresh_source = 0
        self._subscriptions: list[int] = []
        self._file_monitor: Gio.FileMonitor | None = None

        xml = introspection_path.read_text(encoding="utf-8")
        self.node_info = Gio.DBusNodeInfo.new_for_xml(xml)
        self.interface_info = self.node_info.lookup_interface(INTERFACE)
        if self.interface_info is None:
            raise RuntimeError(f"introspection XML does not define {INTERFACE}")

    def start(self) -> None:
        self.connection.register_object(
            OBJECT_PATH,
            self.interface_info,
            self._handle_method_call,
            self._handle_get_property,
            None,
        )
        self._subscribe_to_providers()
        self._monitor_configuration()
        self.refresh(emit=False)

    def _get_remote_property(self, destination: str, path: str, interface: str, name: str) -> object:
        reply = self.connection.call_sync(
            destination,
            path,
            PROPERTIES_INTERFACE,
            "Get",
            GLib.Variant("(ss)", (interface, name)),
            GLib.VariantType.new("(v)"),
            Gio.DBusCallFlags.NONE,
            3000,
            None,
        )
        return reply.get_child_value(0).get_variant().unpack()

    def refresh(self, *, emit: bool = True) -> bool:
        previous_configuration = self.configuration
        previous_status = self.status
        errors: list[str] = []

        try:
            configuration = load_configuration(self.config_path)
        except ConfigurationError as error:
            configuration = None
            errors.append(str(error))

        on_battery: bool | None = None
        warning_level: int | None = None
        percentage: float | None = None
        active_profile: str | None = None

        queries = (
            ("UPower power source", UP_DEST, UP_PATH, UP_IFACE, "OnBattery", "on_battery"),
            ("UPower warning level", UP_DEST, UP_DISPLAY_PATH, UP_DEVICE_IFACE, "WarningLevel", "warning"),
            ("UPower battery percentage", UP_DEST, UP_DISPLAY_PATH, UP_DEVICE_IFACE, "Percentage", "percentage"),
            ("Power Profiles active profile", PPD_DEST, PPD_PATH, PPD_IFACE, "ActiveProfile", "profile"),
        )

        for label, destination, path, interface, name, target in queries:
            try:
                value = self._get_remote_property(destination, path, interface, name)
                if target == "on_battery":
                    on_battery = bool(value)
                elif target == "warning":
                    warning_level = int(value)
                    if not 0 <= warning_level <= 5:
                        raise ValueError(f"invalid UPower warning level: {warning_level}")
                elif target == "percentage":
                    percentage = float(value)
                    if not 0.0 <= percentage <= 100.0:
                        raise ValueError(f"invalid battery percentage: {percentage}")
                else:
                    active_profile = str(value)
                    if active_profile not in {"performance", "balanced", "power-saver"}:
                        raise ValueError(f"unsupported active profile: {active_profile}")
            except (GLib.Error, TypeError, ValueError) as error:
                errors.append(f"{label} unavailable: {error.message if isinstance(error, GLib.Error) else error}")

        self.configuration = configuration
        self.status = build_status(
            configuration=configuration,
            on_battery=on_battery,
            warning_level=warning_level,
            battery_percentage=percentage,
            active_profile=active_profile,
            errors=tuple(errors),
        )

        if emit and previous_configuration != self.configuration and self.configuration is not None:
            self._emit_configuration_changed()
        if emit and previous_status != self.status:
            self._emit_status_changed(previous_status)
        return GLib.SOURCE_REMOVE

    def schedule_refresh(self) -> None:
        if self._refresh_source:
            return

        def run_refresh() -> bool:
            self._refresh_source = 0
            return self.refresh()

        self._refresh_source = GLib.idle_add(run_refresh)

    def _subscribe_to_providers(self) -> None:
        for sender, path in ((UP_DEST, None), (PPD_DEST, PPD_PATH)):
            subscription = self.connection.signal_subscribe(
                sender,
                PROPERTIES_INTERFACE,
                "PropertiesChanged",
                path,
                None,
                Gio.DBusSignalFlags.NONE,
                lambda *_arguments: self.schedule_refresh(),
            )
            self._subscriptions.append(subscription)

    def _monitor_configuration(self) -> None:
        directory = Gio.File.new_for_path(str(self.config_path.parent))
        self._file_monitor = directory.monitor_directory(Gio.FileMonitorFlags.NONE, None)

        def changed(
            _monitor: Gio.FileMonitor,
            file: Gio.File,
            other_file: Gio.File | None,
            _event_type: Gio.FileMonitorEvent,
        ) -> None:
            names = {file.get_basename()}
            if other_file is not None:
                names.add(other_file.get_basename())
            if self.config_path.name in names:
                self.schedule_refresh()

        self._file_monitor.connect("changed", changed)

    def _handle_method_call(
        self,
        _connection: Gio.DBusConnection,
        _sender: str,
        _object_path: str,
        _interface_name: str,
        method_name: str,
        _parameters: GLib.Variant,
        invocation: Gio.DBusMethodInvocation,
    ) -> None:
        if method_name == "GetStatus":
            invocation.return_value(
                GLib.Variant("(a{sv})", (variant_document(self.status, STATUS_SIGNATURES),))
            )
            return

        if method_name == "GetConfiguration":
            if self.configuration is None:
                invocation.return_dbus_error(
                    f"{INTERFACE}.Error.InvalidConfiguration",
                    str(self.status["last-error"]),
                )
                return
            document = self.configuration.as_dbus_document()
            invocation.return_value(
                GLib.Variant("(a{sv})", (variant_document(document, CONFIG_SIGNATURES),))
            )
            return

        invocation.return_dbus_error(
            "org.freedesktop.DBus.Error.UnknownMethod",
            f"Unknown read-only backend method: {method_name}",
        )

    def _handle_get_property(
        self,
        _connection: Gio.DBusConnection,
        _sender: str,
        _object_path: str,
        _interface_name: str,
        property_name: str,
    ) -> GLib.Variant:
        if property_name == "ApiVersion":
            return GLib.Variant("u", API_VERSION)
        status_key = PROPERTY_TO_STATUS[property_name]
        return GLib.Variant(STATUS_SIGNATURES[status_key], self.status[status_key])

    def _emit_status_changed(self, previous_status: dict[str, object]) -> None:
        status_document = variant_document(self.status, STATUS_SIGNATURES)
        self.connection.emit_signal(
            None,
            OBJECT_PATH,
            INTERFACE,
            "StatusChanged",
            GLib.Variant("(a{sv})", (status_document,)),
        )

        changed_properties: dict[str, GLib.Variant] = {}
        for property_name, status_key in PROPERTY_TO_STATUS.items():
            if previous_status.get(status_key) != self.status[status_key]:
                changed_properties[property_name] = GLib.Variant(
                    STATUS_SIGNATURES[status_key], self.status[status_key]
                )
        if changed_properties:
            self.connection.emit_signal(
                None,
                OBJECT_PATH,
                PROPERTIES_INTERFACE,
                "PropertiesChanged",
                GLib.Variant("(sa{sv}as)", (INTERFACE, changed_properties, [])),
            )

    def _emit_configuration_changed(self) -> None:
        if self.configuration is None:
            return
        document = variant_document(self.configuration.as_dbus_document(), CONFIG_SIGNATURES)
        self.connection.emit_signal(
            None,
            OBJECT_PATH,
            INTERFACE,
            "ConfigurationChanged",
            GLib.Variant("(a{sv})", (document,)),
        )


def main() -> int:
    introspection_path = Path(os.environ["GNOME_POWER_PROFILE_AUTOMATION_INTROSPECTION_XML"])
    config_path = Path(
        os.environ.get(
            "GNOME_POWER_PROFILE_AUTOMATION_CONFIG",
            "/etc/gnome-power-profile-automation.conf",
        )
    )
    loop = GLib.MainLoop()
    state: dict[str, object] = {"service": None, "failed": False}

    def on_bus_acquired(connection: Gio.DBusConnection, _name: str) -> None:
        try:
            service = BackendService(connection, introspection_path, config_path)
            service.start()
            state["service"] = service
        except (OSError, GLib.Error, RuntimeError) as error:
            print(f"backend initialization failed: {error}", file=sys.stderr)
            state["failed"] = True
            loop.quit()

    def on_name_lost(_connection: Gio.DBusConnection | None, _name: str) -> None:
        print(f"could not own system D-Bus name {BUS_NAME}", file=sys.stderr)
        state["failed"] = True
        loop.quit()

    owner_id = Gio.bus_own_name(
        Gio.BusType.SYSTEM,
        BUS_NAME,
        Gio.BusNameOwnerFlags.NONE,
        on_bus_acquired,
        None,
        on_name_lost,
    )

    def stop() -> bool:
        loop.quit()
        return GLib.SOURCE_REMOVE

    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, stop)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, stop)

    try:
        loop.run()
    finally:
        Gio.bus_unown_name(owner_id)

    return 1 if state["failed"] else 0
