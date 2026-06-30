> [!NOTE]
> I wanted my **Fedora laptop** to switch GNOME power modes automatically when moving between AC power, battery, and low-battery states, but I could not find a simple built-in configuration for that.
>
> This project is a small helper script that:
> 
> 1. Hooks to UPower for charger and battery-warning state changes.
> 2. Sets GNOME's visible Power Mode through the Power Profiles interface exposed by Fedora's `tuned-ppd`.
>
> It does not modify TuneD profiles or tune the CPU directly; it only automates the same visible GNOME power-mode choice you can make manually.

# GNOME Power Mode Automation for Fedora

A small Fedora utility that automatically selects the **visible GNOME Power Mode** when a laptop moves between AC power, normal battery use, and the system-reported low-battery state.

It is designed for Fedora Workstation systems that use **TuneD** plus `tuned-ppd` for GNOME's Power Profiles compatibility layer.

And the default behavior will get you:

| Physical state | Default visible GNOME mode |
|---|---|
| Charger connected | **Performance** |
| Normal battery | **Balanced** |
| UPower low battery | **Power Saver** |


## Why this exists

GNOME has manual Performance, Balanced, and Power Saver modes, but it does not natively provide an AC/battery policy that visibly switches between them. This project implements that policy by updating the same public Power Profiles API GNOME uses, so the Quick Settings indicator remains meaningful.

## Requirements

- Fedora Workstation with GNOME
- `tuned`
- `tuned-ppd`
- `upower`

Install the dependencies:

```bash
sudo dnf install tuned tuned-ppd upower
```

Fedora uses TuneD with `tuned-ppd` to provide the Power Profiles API used by GNOME. UPower provides the display-battery state and warning level used by this utility. See Fedora's [TuneD change proposal](https://fedoraproject.org/wiki/Changes/TunedAsTheDefaultPowerProfileManagementDaemon) and the [UPower Device API](https://upower.freedesktop.org/docs/Device.html).

## Installation

Clone the repository, review it, and run the installer locally:

```bash
git clone https://github.com/Uripeer3/Fedora-Gnome-Power-Profile-Automation.git
cd Fedora-Gnome-Power-Profile-Automation
sudo ./install.sh
```

The service runs as root because it writes a system-wide D-Bus power-profile property. Avoid blind `curl | sudo bash` installations; this project is meant to be inspected before installation.

### Guided setup

The installer can open the configuration menu immediately:

```bash
sudo ./install.sh --reconfigure
```

The menu explains each choice:

```text
1) Performance
   Maximum responsiveness for compiling, containers, and heavy work.

2) Balanced
   Recommended general-purpose mode with moderate power use.

3) Power Saver
   Prioritizes battery runtime, lower heat, and quieter operation.
```

### Non-interactive installation

Install with the recommended defaults:

```bash
sudo ./install.sh --yes --reconfigure
```

Default policy:

```text
Charger connected  -> Performance
Normal battery     -> Balanced
Low battery        -> Power Saver
Low trigger        -> UPower "Low" warning
```
## Features

- Clear numbered terminal configuration menus; users choose `1`, `2`, or `3`, not internal profile names.
- Separate policies for charger connected, normal battery, and low battery.
- Low battery is based on **UPower's own warning state**, not a hard-coded percentage.
- A temporary manual choice in GNOME is respected until the next physical power-state change.
- A small root-owned systemd service; no network requests and no telemetry.
- Does not edit `/etc/tuned/ppd.conf`.
- Includes a read-only terminal dashboard for verifying GNOME, TuneD, service, and kernel CPU policy state together.
- GitHub Actions validates Bash syntax and ShellCheck warnings.


## Everyday commands

| Command | Purpose |
|---|---|
| `sudo gnome-power-profile-automation configure` | Open the guided policy menu |
| `sudo gnome-power-profile-automation configure --yes` | Reset policy to recommended defaults |
| `sudo gnome-power-profile-automation status` | Show power state, target profile, and visible GNOME mode |
| `sudo gnome-power-profile-automation apply` | Force the policy once now |
| `bash tools/watch-power-profile-backend.sh` | Open the live backend monitor |
| `journalctl -u gnome-power-profile-automation.service -f` | Follow state-transition logs |
| `sudo ./uninstall.sh` | Remove the service and keep the configuration |
| `sudo ./uninstall.sh --purge-config` | Remove the service and configuration |

## Manual override behavior

The monitor responds to **physical state transitions**, not to every battery-percentage update.

For example:

1. You unplug the charger, and the configured normal-battery mode is selected.
2. You manually choose **Performance** in GNOME for a compile.
3. The monitor leaves that choice alone while the laptop remains on normal battery.
4. It applies policy again only when you plug in, unplug, enter low battery, or leave low battery.

Restarting the service or running `apply` intentionally forces the configured policy again.

## Configuration file

The installed configuration is:

```text
/etc/gnome-power-profile-automation.conf
```

Example:

```bash
AC_PROFILE="performance"
BATTERY_PROFILE="balanced"
LOW_BATTERY_PROFILE="power-saver"
LOW_BATTERY_WARNING_LEVEL=3
```

Allowed profiles:

```text
performance
balanced
power-saver
```

UPower low-battery levels supported by the tool:

| Value | Meaning |
|---:|---|
| `3` | Low |
| `4` | Critical |
| `5` | Action / final battery state |

Use the guided command rather than editing the file directly. After a manual edit, restart the service:

```bash
sudo systemctl restart gnome-power-profile-automation.service
```

## Verify the backend is changing

The repository includes a standalone, read-only monitor with a terminal dashboard:

```bash
bash tools/watch-power-profile-backend.sh
```

It refreshes every second and shows:

- The visible GNOME Power Profiles API value.
- TuneD's active backend profile.
- `tuned.service`, `tuned-ppd.service`, and the automation-service state.
- The active kernel CPU governor and energy-performance preference for every exposed CPU policy.
- AC/battery state, battery percentage, and UPower warning level.

Use it while plugging and unplugging the charger. Stop it with `Ctrl+C`.

```bash
# Refresh every two seconds
bash tools/watch-power-profile-backend.sh --interval 2

# Print one clean snapshot for a bug report or issue
bash tools/watch-power-profile-backend.sh --once
```

It is intentionally **not** installed system-wide: it is a troubleshooting utility you can run directly from a clone of the repository, and it never changes a system setting.

The names differ by layer:

```text
GNOME Performance  -> TuneD throughput-performance
GNOME Balanced     -> TuneD balanced
GNOME Power Saver  -> TuneD powersave
```

A persistent mismatch between GNOME's visible mode and TuneD's active backend profile is worth investigating. For a stricter one-time check after a transition, run:

```bash
sudo tuned-adm verify
```

## Project layout

```text
.
|-- config/       Default configuration template
|-- src/          Installed command and UPower monitor runtime
|-- systemd/       Systemd unit file
|-- tests/         Syntax and ShellCheck validation
|-- tools/         Read-only development and troubleshooting utilities
|-- install.sh     Installer
|-- uninstall.sh   Uninstaller
`-- README.md
```

The files are intentionally separated. The installer copies tracked source files rather than generating a long program through nested heredocs, making changes easier to review, test, package, and upgrade.

## Development

Run local validation:

```bash
bash tests/test-syntax.sh
```

GitHub Actions runs the same syntax and ShellCheck validation for pushes to `main` and pull requests.

## Security and scope

The systemd service runs as root because it changes a system-wide Power Profiles D-Bus property. It only reads local UPower state and performs local D-Bus calls. It has no network logic, telemetry, or third-party daemon dependency.

The backend monitor under `tools/` is read-only and does not need `sudo` for ordinary status reads.

Review the scripts before installing them on a shared or production machine.

## License

Licensed under the repository's existing [GNU General Public License v3.0](LICENSE).
