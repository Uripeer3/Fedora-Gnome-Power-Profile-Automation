#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for the read-only backend without requiring a running system bus."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src" / "backend"))

from backend_core import (  # noqa: E402
    ConfigurationError,
    build_status,
    default_configuration,
    parse_configuration,
    policy_state_for_inputs,
)


VALID_CONFIGURATION = """\
# GNOME Power Mode Automation configuration
[Policy]
Version=1
ACProfile=performance
BatteryProfile=balanced
LowBatteryProfile=power-saver
LowBatteryWarningLevel=3
LidCloseOnBattery=suspend
LidCloseOnAC=ignore
"""


class ConfigurationTests(unittest.TestCase):
    def test_parses_schema_one_document(self) -> None:
        configuration = parse_configuration(VALID_CONFIGURATION)

        self.assertEqual(configuration.schema_version, 1)
        self.assertEqual(configuration.ac_profile, "performance")
        self.assertEqual(configuration.lid_close_on_ac, "ignore")
        self.assertEqual(
            configuration.as_dbus_document()["low-battery-warning-level"],
            3,
        )

    def test_rejects_unknown_duplicate_missing_and_unsafe_values(self) -> None:
        invalid_documents = (
            VALID_CONFIGURATION + "Unknown=value\n",
            VALID_CONFIGURATION.replace("ACProfile=performance", "ACProfile=performance\nACProfile=balanced"),
            VALID_CONFIGURATION.replace("BatteryProfile=balanced\n", ""),
            VALID_CONFIGURATION.replace("ACProfile=performance", "ACProfile=$(command)"),
            VALID_CONFIGURATION.replace("Version=1", "Version=2"),
        )

        for document in invalid_documents:
            with self.subTest(document=document):
                with self.assertRaises(ConfigurationError):
                    parse_configuration(document)


class PolicyTests(unittest.TestCase):
    def test_classifies_all_three_policy_states(self) -> None:
        self.assertEqual(policy_state_for_inputs(False, 5, 3), "ac")
        self.assertEqual(policy_state_for_inputs(True, 2, 3), "battery")
        self.assertEqual(policy_state_for_inputs(True, 3, 3), "low-battery")

    def test_matches_the_legacy_pure_policy_core(self) -> None:
        policy_library = ROOT / "src" / "lib" / "policy.sh"

        for on_battery in (False, True):
            for warning_level in range(6):
                for threshold in (3, 4, 5):
                    shell_result = subprocess.run(
                        [
                            "bash",
                            "-c",
                            'source "$1"; policy_state_for_inputs "$2" "$3" "$4"',
                            "bash",
                            str(policy_library),
                            str(on_battery).lower(),
                            str(warning_level),
                            str(threshold),
                        ],
                        check=True,
                        capture_output=True,
                        text=True,
                    ).stdout.strip()
                    python_result = policy_state_for_inputs(
                        on_battery,
                        warning_level,
                        threshold,
                    )
                    self.assertEqual(python_result, shell_result)

    def test_builds_ready_coherent_status(self) -> None:
        status = build_status(
            configuration=default_configuration(),
            on_battery=True,
            warning_level=3,
            battery_percentage=18.5,
            active_profile="balanced",
        )

        self.assertEqual(status["backend-state"], "ready")
        self.assertEqual(status["power-source"], "battery")
        self.assertEqual(status["policy-state"], "low-battery")
        self.assertEqual(status["desired-profile"], "power-saver")
        self.assertEqual(status["active-profile"], "balanced")

    def test_builds_degraded_status_without_inventing_values(self) -> None:
        status = build_status(
            configuration=None,
            on_battery=None,
            warning_level=None,
            battery_percentage=None,
            active_profile=None,
            errors=("provider unavailable",),
        )

        self.assertEqual(status["backend-state"], "degraded")
        self.assertEqual(status["power-source"], "unknown")
        self.assertEqual(status["policy-state"], "unknown")
        self.assertEqual(status["battery-percentage"], -1.0)
        self.assertEqual(status["last-error"], "provider unavailable")


class IntrospectionTests(unittest.TestCase):
    def test_pr_six_exports_only_the_read_only_contract(self) -> None:
        root = ET.parse(
            ROOT / "dbus" / "io.github.Uripeer3.GnomePowerProfileAutomation1.xml"
        ).getroot()
        interface = root.find("interface")
        self.assertIsNotNone(interface)
        assert interface is not None

        methods = {element.attrib["name"] for element in interface.findall("method")}
        properties = {element.attrib["name"] for element in interface.findall("property")}

        self.assertEqual(methods, {"GetStatus", "GetConfiguration"})
        self.assertNotIn("SetConfiguration", methods)
        self.assertNotIn("ApplyPolicy", methods)
        self.assertEqual(
            properties,
            {
                "ApiVersion",
                "BackendState",
                "PowerSource",
                "PolicyState",
                "ActiveProfile",
                "DesiredProfile",
                "LastError",
            },
        )


if __name__ == "__main__":
    unittest.main()
