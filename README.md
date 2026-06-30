> [!NOTE]
> I wanted my Fedora laptop to switch GNOME power modes automatically when moving between AC power, battery, and low-battery states, but I could not find a simple built-in configuration for that.
>
> This project is a small helper script that:
> 
> 1. Watches UPower for charger and battery-warning state changes.
> 2. Sets GNOME's visible Power Mode through the Power Profiles interface exposed by Fedora's `tuned-ppd`.
>
> It does not modify TuneD profiles or tune the CPU directly; it only automates the same visible GNOME power-mode choice you can make manually.

# GNOME Power Mode Automation for Fedora

A small Bash installer that keeps the **visible GNOME Power Mode** aligned with the laptop's real power state:

| Physical state | Default visible GNOME mode |
|---|---|
| Charger connected | **Performance** |
| Normal battery use | **Balanced** |
| System-reported low battery | **Power Saver** |

The installer uses a guided terminal menu, creates one small systemd service, and listens to **UPower** for power-source and battery-warning changes. It is intended for Fedora systems using **TuneD** with the `tuned-ppd` compatibility layer.

> **Design goal:** GNOME's Quick Settings remain truthful. When the script moves to a new physical power state, GNOME itself visibly changes between Performance, Balanced, and Power Saver.

> [!IMPORTANT]
> This repository has been tested for personal use on: Fedora 44 w. Gnome 50
> 
> Pull Request's and contribution are welcome ^_^
---

## What it does

- Presents a clean, numbered `1 / 2 / 3` setup menu instead of asking for internal profile names.
- Lets you select a GNOME power mode for:
  1. AC power connected
  2. Normal battery use
  3. Low battery
- Uses the **system-reported** UPower warning state instead of a hard-coded battery percentage.
- Updates the public GNOME Power Mode through the Power Profiles D-Bus interface exposed by `tuned-ppd`.
- Preserves a temporary manual GNOME choice while the laptop remains in the same physical state.
- Does **not** modify `/etc/tuned/ppd.conf`.
- Has no network behavior, no telemetry, and no third-party daemon dependency.

---

## Requirements

This project is intended for **Fedora Workstation with GNOME**, where the GNOME power menu is backed by `tuned-ppd`.

Required packages:

```bash
sudo dnf install tuned tuned-ppd upower
```

The script also uses standard tools provided by Fedora's base system: Bash, systemd, `busctl`, and `journalctl`.

Fedora adopted `tuned` plus `tuned-ppd` as the desktop-facing power-profile backend; `tuned-ppd` acts as the compatibility bridge for desktops that expect the Power Profiles API. UPower exposes the composite display battery and its warning level through its system D-Bus API.  
Sources: [Fedora Change proposal](https://fedoraproject.org/wiki/Changes/TunedAsTheDefaultPowerProfileManagementDaemon), [UPower API reference](https://upower.freedesktop.org/docs/UPower.html), [UPower device properties](https://upower.freedesktop.org/docs/Device.html).

---

## Install

Clone or download the repository, then run the script with `sudo`:

```bash
chmod +x gnome_tuned_ppd_mode_hook.sh
sudo ./gnome_tuned_ppd_mode_hook.sh
```

The guided setup presents readable choices such as:

```text
1 of 3: Charger connected

  1) Performance
     Highest responsiveness and the most eager CPU boosting.

  2) Balanced
     Recommended everyday mode.

  3) Power Saver
     Prioritizes battery runtime, lower heat, and quieter operation.

Choose 1, 2, or 3 [default: 1]:
```

### Non-interactive installation

To use the recommended defaults without prompts:

```bash
sudo ./gnome_tuned_ppd_mode_hook.sh --yes
```

Default policy:

```text
Charger connected  -> Performance
Normal battery     -> Balanced
Low battery        -> Power Saver
Low-battery trigger -> UPower "Low" warning
```

If a configuration already exists, `--yes` preserves it. To reset to the defaults intentionally:

```bash
sudo ./gnome_tuned_ppd_mode_hook.sh --yes --reconfigure
```

---

## How manual overrides work

The automation reacts to a change in **physical state**, not every battery percentage update.

For example:

1. You unplug your laptop: GNOME changes from **Performance** to **Balanced**.
2. While still on battery, you manually choose **Performance** for a compile or another demanding task.
3. The script leaves that manual setting alone.
4. It applies the configured policy again only when the physical state changes, such as plugging in, unplugging, entering low battery, or leaving low battery.

The service applies the configured policy once when it starts. Restarting the service or using `--apply` therefore intentionally overrides a temporary manual selection.

---

## Configuration

The generated configuration file is:

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

Allowed profile values are:

```text
performance
balanced
power-saver
```

UPower warning levels used by this project:

| Value | Meaning |
|---:|---|
| `3` | Low |
| `4` | Critical |
| `5` | Action / final low-battery state |

Use the guided configurator instead of editing the file manually:

```bash
sudo ./gnome_tuned_ppd_mode_hook.sh --reconfigure
```

After a manual file edit, restart the service:

```bash
sudo systemctl restart gnome-power-profile-automation.service
```

---

## Commands

| Command | Purpose |
|---|---|
| `sudo ./gnome_tuned_ppd_mode_hook.sh` | Interactive install or service repair |
| `sudo ./gnome_tuned_ppd_mode_hook.sh --yes` | Install with defaults, without prompts |
| `sudo ./gnome_tuned_ppd_mode_hook.sh --reconfigure` | Open the guided setup again |
| `sudo ./gnome_tuned_ppd_mode_hook.sh --status` | Show state, target profile, and current GNOME mode |
| `sudo ./gnome_tuned_ppd_mode_hook.sh --apply` | Force the configured policy once now |
| `sudo ./gnome_tuned_ppd_mode_hook.sh --uninstall` | Remove the service and runtime script |
| `sudo ./gnome_tuned_ppd_mode_hook.sh --help` | Show command-line help |

### View logs

```bash
journalctl -u gnome-power-profile-automation.service -f
```

### Check the service

```bash
systemctl status gnome-power-profile-automation.service
```

---

## Installed files

The installer creates these local files:

| Path | Purpose |
|---|---|
| `/usr/local/libexec/gnome-power-profile-automation` | Runtime monitor used by systemd |
| `/etc/gnome-power-profile-automation.conf` | Your policy settings |
| `/etc/systemd/system/gnome-power-profile-automation.service` | The systemd unit |
| `/run/gnome-power-profile-automation/last-state` | Temporary state memory; recreated at boot |

`--uninstall` removes the service and runtime program, but deliberately keeps the configuration file so a future installation can reuse your settings.

---

## Troubleshooting

### The GNOME Power Mode menu is missing

Confirm that Fedora's compatibility service is installed and running:

```bash
sudo dnf install tuned tuned-ppd upower
systemctl status tuned.service tuned-ppd.service
```

Then confirm the Power Profiles D-Bus service responds:

```bash
busctl --system get-property \
  net.hadess.PowerProfiles \
  /net/hadess/PowerProfiles \
  net.hadess.PowerProfiles \
  ActiveProfile
```

### The automation service does not start

Read the service log:

```bash
journalctl -u gnome-power-profile-automation.service -b --no-pager
```

Then check the backend services:

```bash
systemctl status upower.service tuned.service tuned-ppd.service
```

### It does not switch at the expected percentage

That is expected: the script does not use a percentage threshold. It follows the `WarningLevel` reported by UPower, which depends on system policy, battery hardware, and desktop configuration. Run:

```bash
sudo ./gnome_tuned_ppd_mode_hook.sh --status
```

to see the current warning level.

---

## Security and scope

The installed service runs as root because it writes the system-wide Power Profiles D-Bus property. It only reads local UPower state and sends local D-Bus calls; it does not make network connections or collect data.

Review the script before installing it, particularly before using it on a shared or production machine.

---

## License

No license file is included yet. Add an appropriate `LICENSE` file before redistributing the project publicly.
