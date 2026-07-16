> [!NOTE]
> I wanted my **Fedora laptop** to switch GNOME power modes automatically when moving between AC power, battery, and low-battery states, but I could not find a simple built-in configuration for that.
>
> This project is a small helper that:
>
> 1. Hooks into UPower charger and battery-warning state changes.
> 2. Sets GNOME's visible Power Mode through the Power Profiles interface exposed by Fedora's `tuned-ppd`.
> 3. Configures systemd-logind's native lid-close action separately for battery and AC power.
>
> It does not modify TuneD profiles or tune the CPU directly; it only automates the same visible GNOME power-mode choice you can make manually.

> [!WARNING]
> **Do not run TLP alongside this project, `tuned-ppd`, or another active desktop power-profile backend.** See [This project compared with TLP](#this-project-compared-with-tlp) before changing power-management stacks.

# GNOME Power Mode Automation for Fedora

A small Fedora utility that automatically selects the **visible GNOME Power Mode** when a laptop moves between AC power, normal battery use, and the system-reported low-battery state. It can also configure a simple, separate lid-close action for battery and AC power.

It is designed for Fedora Workstation systems that use **TuneD** plus `tuned-ppd` for GNOME's Power Profiles compatibility layer.

The default behavior is:

| Physical state | Default visible GNOME mode |
|---|---|
| Charger connected | **Performance** |
| Normal battery | **Balanced** |
| UPower low battery | **Power Saver** |

| Lid-close condition | Default action |
|---|---|
| Battery | **Suspend** |
| AC power | **Suspend** |

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

Fedora uses TuneD with `tuned-ppd` to provide the Power Profiles API used by GNOME. UPower provides the display-battery state and warning level used by this utility. Lid-close behavior uses the `systemd-logind` service already present on a normal Fedora system. See Fedora's [TuneD change proposal](https://fedoraproject.org/wiki/Changes/TunedAsTheDefaultPowerProfileManagementDaemon), the [UPower Device API](https://upower.freedesktop.org/docs/Device.html), and systemd's [logind configuration reference](https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html).

## Installation

Clone the repository, review it, and run the installer locally:

```bash
git clone https://github.com/Uripeer3/Fedora-Gnome-Power-Profile-Automation.git
cd Fedora-Gnome-Power-Profile-Automation
sudo ./install.sh
```

The service runs as root because it writes a system-wide D-Bus power-profile property and a small root-owned logind drop-in. Avoid blind `curl | sudo bash` installations; this project is meant to be inspected before installation.

### Guided setup

The installer can open the configuration menu immediately:

```bash
sudo ./install.sh --reconfigure
```

The menu explains each GNOME mode:

```text
1) Performance
   Maximum responsiveness for compiling, containers, and heavy work.

2) Balanced
   Recommended general-purpose mode with moderate power use.

3) Power Saver
   Prioritizes battery runtime, lower heat, and quieter operation.
```

It then asks for a lid-close action on battery and on AC power:

```text
1) Suspend (recommended)
   Sleep until the lid opens or another wake event occurs.

2) Hibernate
   Save memory to disk, then power down. Requires working hibernation.

3) Lock screen
   Keep the system running and ask the desktop session to lock.

4) Do nothing
   Leave the system running after the lid closes.
```

### Non-interactive installation

Install with the recommended defaults:

```bash
sudo ./install.sh --yes --reconfigure
```

Default policy:

```text
Charger connected       -> Performance
Normal battery          -> Balanced
Low battery             -> Power Saver
Low trigger             -> UPower "Low" warning
Lid close on battery    -> Suspend
Lid close on AC         -> Suspend
```

## Features

- Clear numbered terminal configuration menus; users choose simple numbered actions rather than internal profile names.
- Separate GNOME power-mode policies for charger connected, normal battery, and low battery.
- Low battery is based on **UPower's own warning state**, not a hard-coded percentage.
- Separate lid-close actions for battery and external power through a native `systemd-logind` configuration drop-in.
- A temporary manual choice in GNOME is respected until the next physical power-state change.
- A small root-owned systemd service; no network requests and no telemetry.
- No additional lid-monitor process or polling loop.
- Does not edit `/etc/tuned/ppd.conf`.
- Includes a read-only terminal dashboard for verifying GNOME, TuneD, service, and kernel CPU policy state together.
- GitHub Actions validates Bash syntax and ShellCheck warnings.

## Everyday commands

| Command | Purpose |
|---|---|
| `sudo gnome-power-profile-automation configure` | Open the guided power-mode and lid-close policy menu |
| `sudo gnome-power-profile-automation configure --yes` | Reset all policies to recommended defaults |
| `sudo gnome-power-profile-automation status` | Show power state, target profile, visible GNOME mode, and configured lid actions |
| `sudo gnome-power-profile-automation apply` | Force the power-profile policy once now |
| `sudo gnome-power-profile-automation sync-lid-policy` | Rebuild and apply the logind lid-close drop-in from the saved configuration |
| `bash tools/watch-power-profile-backend.sh` | Open the live backend monitor |
| `journalctl -u gnome-power-profile-automation.service -f` | Follow state-transition logs |
| `sudo ./uninstall.sh` | Remove the service and the managed lid policy, while keeping the configuration |
| `sudo ./uninstall.sh --purge-config` | Remove the service, managed lid policy, configuration, and migration backup |

## Manual override behavior

The monitor responds to **physical state transitions**, not to every battery-percentage update.

For example:

1. You unplug the charger, and the configured normal-battery mode is selected.
2. You manually choose **Performance** in GNOME for a compile.
3. The monitor leaves that choice alone while the laptop remains on normal battery.
4. It applies policy again only when you plug in, unplug, enter low battery, or leave low battery.

Restarting the service or running `apply` intentionally forces the configured power-profile policy again.

## Configuration file

The installed configuration is:

```text
/etc/gnome-power-profile-automation.conf
```

Example:

```ini
[Policy]
Version=1
ACProfile=performance
BatteryProfile=balanced
LowBatteryProfile=power-saver
LowBatteryWarningLevel=3
LidCloseOnBattery=suspend
LidCloseOnAC=suspend
```

The file is parsed as versioned data and is never executed as shell code. During an upgrade, the installer safely converts the previous shell-style format and preserves the original as `/etc/gnome-power-profile-automation.conf.legacy.bak`.

Allowed GNOME profiles:

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

Allowed lid-close actions:

| Value | Result |
|---|---|
| `suspend` | Sleep until a wake event occurs |
| `hibernate` | Save memory to disk and power down; requires hibernation to be configured correctly |
| `lock` | Ask the desktop session to lock without sleeping the system |
| `ignore` | Keep the system running |

Use the guided command rather than editing the file directly. After a manual edit, apply both the power profile and lid policy as needed:

```bash
sudo gnome-power-profile-automation sync-lid-policy
sudo systemctl restart gnome-power-profile-automation.service
```

## Lid-close behavior

The lid-close feature deliberately does **not** add another event listener. It writes this managed native systemd drop-in:

```text
/etc/systemd/logind.conf.d/90-gnome-power-profile-automation-lid.conf
```

The drop-in configures `HandleLidSwitch` for battery and `HandleLidSwitchExternalPower` for AC power, then reloads `systemd-logind`. That keeps the implementation small: the existing system service receives the lid-switch event and performs the configured action.

> [!IMPORTANT]
> The policy is system-wide. GNOME or another desktop component can hold a normal logind inhibitor while a session is active, and logind may defer the action accordingly. This is expected system behavior, not another background component from this project.
>
> This project intentionally does not change logind's separate docked-laptop behavior. When an external monitor makes the system appear docked, your existing `HandleLidSwitchDocked` policy can still determine the result.

Use this project as the single owner of the two logind values it creates. Avoid manually editing the generated drop-in; use `configure` or edit the project configuration then run `sync-lid-policy`.

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

## This project compared with TLP

[TLP](https://linrunner.de/tlp/) is a respected and substantially broader Linux power-management framework. It is not a direct substitute for this project; the two tools make different trade-offs.

| Aspect | This project | TLP |
|---|---|---|
| Primary role | A narrow **policy orchestrator** for GNOME's visible Power Mode and native lid-close choices | A broad **system power-management framework** |
| Fedora integration | Uses the existing Fedora `tuned` + `tuned-ppd` stack and systemd-logind | Applies and manages its own configurable power policy |
| AC / battery switching | Configurable AC, normal-battery, and UPower low-battery modes | `tlp-pd` can automatically select Performance on AC and Balanced on battery |
| Low-battery policy | Yes: configurable UPower warning-level trigger | No equivalent low-battery transition is part of the default `tlp-pd` switching model described by TLP |
| Lid-close policy | Simple AC/battery split through native logind values; no additional monitor | TLP has broader platform settings, but lid-close policy is not this project's reason for choosing TLP |
| GNOME / desktop menu | Changes the same visible profile GNOME already exposes through `tuned-ppd` | `tlp-pd` can implement the same desktop Power Profiles D-Bus API |
| Direct hardware tuning | No. TuneD remains responsible for the actual profile contents | Yes. TLP exposes settings across processor, platform, battery care, storage, graphics, networking, PCIe, USB, radios, and more |
| Background resource model | One small event-driven UPower service; lid-close handling is delegated to existing logind | A broader system service and policy stack responsible for a much larger set of tunables |
| Best fit | You want a simple, visible, Fedora-native GNOME policy with a low-battery rule and simple lid actions | You want to own and tune a much wider laptop power-management policy |

TLP documents that `tlp-pd` can replace a desktop Power Profiles implementation and provides automatic AC/battery switching, while its larger settings surface covers many power-management domains beyond desktop CPU profiles. See TLP's [Power Profiles documentation](https://linrunner.de/tlp/faq/ppd.html) and [settings catalogue](https://linrunner.de/tlp/settings/index.html).

### Resource occupation

Do not choose between the two solely by process count or a single memory number. Both are intended to be lightweight compared with normal desktop workloads, but they have different responsibilities.

- This project adds one root-owned, event-driven UPower monitor. It blocks while waiting for UPower events, then performs a small local D-Bus update only when the physical power state changes.
- Lid-close behavior adds **no process**. The project configures the existing `systemd-logind` service rather than polling for lid events itself.
- The existing Fedora `tuned` and `tuned-ppd` services remain the actual backend. This project does not replace them or add a second low-level tuning engine.
- TLP has a wider operational scope because it can manage many more classes of kernel and device settings. Its practical benefit and resource impact depend on the laptop, drivers, configured options, and workload.

For a meaningful decision, measure your own machine under your own workload: battery power draw, thermals, responsiveness, suspend/resume behavior, and device stability are more useful than comparing daemon RSS alone.

### Do not run both control stacks together

> [!WARNING]
> **Do not run TLP alongside this project, `tuned-ppd`, or another active desktop power-profile backend unless you intentionally replace the existing stack and understand the consequences.** Choose one owner for CPU/platform power policy.
>
> TLP explicitly warns that using it together with `power-profiles-daemon` can cause unpredictable results because both tools change overlapping kernel tunables. Fedora's `tuned-ppd` is a different compatibility provider, but this project actively directs TuneD through the same desktop Power Profiles interface. Treating the combination as unsupported is therefore the conservative and recommended configuration.

TLP's conflict guidance is worth reading before changing your power-management stack: [TLP conflicts](https://linrunner.de/tlp/faq/conflicts.html) and [TLP vs. desktop Power Profiles](https://linrunner.de/tlp/faq/ppd.html).

### Acknowledgements

This project is intentionally narrower than TLP, not a claim that it is universally better. TLP's documentation is especially useful for understanding the trade-off between desktop power profiles, deeper device tuning, conflict avoidance, and workload-specific measurement. Thanks to the TLP project and its maintainers for the clear technical documentation.

## Project layout

```text
.
|-- config/       Default configuration template
|-- dbus/         Public interface XML and system-bus ownership policy
|-- docs/         Target architecture and versioned D-Bus contract
|-- src/          CLI runtime plus read-only backend and focused libraries
|-- systemd/       Legacy monitor and read-only backend units
|-- tests/         Shell, policy, configuration, and backend validation
|-- tools/         Read-only development and troubleshooting utilities
|-- install.sh     Installer
|-- uninstall.sh   Uninstaller
`-- README.md
```

The files are intentionally separated. The installer copies tracked source files rather than generating a long program through nested heredocs, making changes easier to review, test, package, and upgrade.

The installed command only initializes shared context, loads the libraries, and
dispatches commands. Configuration persistence, platform access, lid policy,
monitoring, terminal UI, and pure policy decisions live in separate files under
`src/lib/` so later backend work can replace one boundary at a time.

## Extension architecture rollout

The root-owned Bash monitor remains the only component that applies policy. A
second, read-only backend now publishes coherent status and configuration over
the versioned system D-Bus interface. It observes the same providers but cannot
write configuration, change a profile, or manage logind.

This is an intentional migration stage. Authorized mutations, the unprivileged
CLI client, and final monitor ownership move to the backend in later pull
requests. The GNOME extension will then be an unprivileged client and will never
edit `/etc`, invoke `systemctl`, or set system-wide D-Bus properties directly.

Installation and maintenance still use `sudo`. Read-only D-Bus calls do not.

After installation, inspect the transitional API without `sudo`:

```bash
busctl --system introspect \
  io.github.Uripeer3.GnomePowerProfileAutomation1 \
  /io/github/Uripeer3/GnomePowerProfileAutomation1

busctl --system call \
  io.github.Uripeer3.GnomePowerProfileAutomation1 \
  /io/github/Uripeer3/GnomePowerProfileAutomation1 \
  io.github.Uripeer3.GnomePowerProfileAutomation1 \
  GetStatus
```

- [Target architecture and privilege model](docs/architecture.md)
- [D-Bus API version 1](docs/dbus-api-v1.md)

The documents define both the implemented read-only subset and the remaining
target contract.

## Development

Run local validation:

```bash
bash tests/test-syntax.sh
```

GitHub Actions runs the same syntax and ShellCheck validation for pushes to `main` and pull requests.

## Security and scope

The systemd services run as root. The legacy monitor changes the system-wide
Power Profiles property, while the transitional backend only publishes
read-only local state. Neither has network logic, telemetry, or a third-party
daemon dependency.

The backend monitor under `tools/` is read-only and does not need `sudo` for ordinary status reads.

Review the scripts before installing them on a shared or production machine.

## License

Licensed under the repository's existing [GNU General Public License v3.0](LICENSE).
