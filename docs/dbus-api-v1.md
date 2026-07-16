# D-Bus API version 1

Status: proposed public contract. The current 1.2 release does not implement
this interface.

This interface is the only runtime boundary intended for the command-line
client and future GNOME extension. Architecture and privilege decisions are in
[`architecture.md`](architecture.md).

## Identifiers

| Item | Value |
|---|---|
| Bus | System bus |
| Well-known name | `io.github.Uripeer3.GnomePowerProfileAutomation1` |
| Object path | `/io/github/Uripeer3/GnomePowerProfileAutomation1` |
| Interface | `io.github.Uripeer3.GnomePowerProfileAutomation1` |
| API version | `1` |

The backend also implements the standard
`org.freedesktop.DBus.Introspectable`, `org.freedesktop.DBus.Peer`, and
`org.freedesktop.DBus.Properties` interfaces.

Only the installed system backend may own the well-known name. Clients address
the well-known name but authorization decisions use the caller's unique D-Bus
name.

## Introspection contract

The implementation must ship introspection XML equivalent to:

```xml
<node>
  <interface name="io.github.Uripeer3.GnomePowerProfileAutomation1">
    <property name="ApiVersion" type="u" access="read"/>
    <property name="BackendState" type="s" access="read"/>
    <property name="PowerSource" type="s" access="read"/>
    <property name="PolicyState" type="s" access="read"/>
    <property name="ActiveProfile" type="s" access="read"/>
    <property name="DesiredProfile" type="s" access="read"/>
    <property name="LastError" type="s" access="read"/>

    <method name="GetStatus">
      <arg name="status" type="a{sv}" direction="out"/>
    </method>
    <method name="GetConfiguration">
      <arg name="configuration" type="a{sv}" direction="out"/>
    </method>
    <method name="SetConfiguration">
      <arg name="configuration" type="a{sv}" direction="in"/>
      <arg name="effective_configuration" type="a{sv}" direction="out"/>
    </method>
    <method name="ApplyPolicy">
      <arg name="status" type="a{sv}" direction="out"/>
    </method>

    <signal name="StatusChanged">
      <arg name="status" type="a{sv}"/>
    </signal>
    <signal name="ConfigurationChanged">
      <arg name="configuration" type="a{sv}"/>
    </signal>
  </interface>
</node>
```

Implementations emit standard `PropertiesChanged` signals when a published
property changes. Custom signals carry complete snapshots so clients can replace
their cached model atomically.

## Common value types

### Profiles

Profile strings are exactly:

- `performance`
- `balanced`
- `power-saver`

An empty profile string is allowed only in runtime status when the provider is
unavailable. It is never valid in configuration.

### Power source

`power-source` and `PowerSource` use:

- `ac`
- `battery`
- `unknown`

### Policy state

`policy-state` and `PolicyState` use:

- `ac`
- `battery`
- `low-battery`
- `unknown`

### Backend state

`backend-state` and `BackendState` use:

- `ready`
- `degraded`

Clients synthesize `unavailable` only when no compatible service owns the bus
name. The backend never publishes `unavailable` about itself.

### Lid actions

Lid-action strings are exactly:

- `suspend`
- `hibernate`
- `lock`
- `ignore`

### UPower warning levels

Warning levels use an unsigned integer and preserve UPower's values:

| Value | Meaning |
|---:|---|
| `0` | Unknown |
| `1` | None |
| `2` | Discharging |
| `3` | Low |
| `4` | Critical |
| `5` | Action |

Configuration accepts `3`, `4`, or `5` as the low-battery threshold.

## Properties

All properties are read-only. Mutations use explicit methods so the backend can
authorize and validate them.

| Property | Type | Meaning |
|---|---|---|
| `ApiVersion` | `u` | Always `1` for this interface |
| `BackendState` | `s` | `ready` or `degraded` |
| `PowerSource` | `s` | Current physical source or `unknown` |
| `PolicyState` | `s` | Current policy state or `unknown` |
| `ActiveProfile` | `s` | Visible Power Profiles value, or empty when unavailable |
| `DesiredProfile` | `s` | Configured target for the current policy state, or empty when unknown |
| `LastError` | `s` | Latest concise diagnostic, or empty when healthy |

Properties and `GetStatus` describe the backend's latest coherent snapshot. A
client that needs all fields together should use `GetStatus` and then subscribe
to `StatusChanged`.

## Status document

`GetStatus`, `ApplyPolicy`, and `StatusChanged` return a complete `a{sv}` with
these required keys:

| Key | Variant type | Meaning |
|---|---|---|
| `api-version` | `u` | D-Bus API version; always `1` |
| `backend-state` | `s` | `ready` or `degraded` |
| `power-source` | `s` | `ac`, `battery`, or `unknown` |
| `policy-state` | `s` | `ac`, `battery`, `low-battery`, or `unknown` |
| `active-profile` | `s` | Current visible profile, or empty |
| `desired-profile` | `s` | Current configured target, or empty |
| `battery-percentage` | `d` | `0.0` through `100.0`, or `-1.0` when unavailable |
| `battery-warning-level` | `u` | UPower warning level `0` through `5` |
| `last-error` | `s` | Concise diagnostic, or empty |

API version 1 clients must ignore unknown status keys. New informational keys
may be added without changing the interface version.

## Configuration document

`GetConfiguration`, `SetConfiguration`, and `ConfigurationChanged` use a
complete `a{sv}` with exactly these required keys:

| Key | Variant type | Allowed values |
|---|---|---|
| `schema-version` | `u` | `1` |
| `ac-profile` | `s` | Supported profile string |
| `battery-profile` | `s` | Supported profile string |
| `low-battery-profile` | `s` | Supported profile string |
| `low-battery-warning-level` | `u` | `3`, `4`, or `5` |
| `lid-close-on-battery` | `s` | Supported lid action |
| `lid-close-on-ac` | `s` | Supported lid action |

Configuration documents are strict:

- Every key is required.
- Unknown keys are rejected in API version 1.
- Values are validated by type and allowlist.
- The backend does not coerce strings to integers or accept aliases.
- `SetConfiguration` replaces the complete document; it is not a patch method.
- Returned configuration uses canonical values and key types.

The mapping to configuration schema 1 is:

| D-Bus key | INI key |
|---|---|
| `schema-version` | `Version` |
| `ac-profile` | `ACProfile` |
| `battery-profile` | `BatteryProfile` |
| `low-battery-profile` | `LowBatteryProfile` |
| `low-battery-warning-level` | `LowBatteryWarningLevel` |
| `lid-close-on-battery` | `LidCloseOnBattery` |
| `lid-close-on-ac` | `LidCloseOnAC` |

Clients must not depend on that file mapping. It exists to define migration and
implementation tests; D-Bus remains the supported runtime boundary.

## Methods

### `GetStatus() -> a{sv}`

Returns one complete status snapshot.

- Authorization: none.
- Side effects: none.
- Does not force provider refresh or policy application.

### `GetConfiguration() -> a{sv}`

Returns the complete canonical configuration currently accepted by the
backend.

- Authorization: none.
- Side effects: none.
- A malformed on-disk document produces `InvalidConfiguration`; raw malformed
  contents are never returned.

### `SetConfiguration(a{sv}) -> a{sv}`

Validates and atomically replaces the complete system policy.

- Polkit action:
  `io.github.Uripeer3.gnome-power-profile-automation.configure`.
- Authorization is checked before validation details are returned, preventing
  unauthorized callers from using mutation errors as a probing interface.
- The file commit is atomic and preserves root ownership and safe permissions.
- Accepted mutation commits are serialized; the last successful complete
  document wins.
- On success, the method returns the canonical effective configuration and
  emits `ConfigurationChanged` after the durable commit.
- The backend schedules power-profile and lid-policy reconciliation after the
  commit. Reconciliation failure does not roll back valid desired state; it
  changes `BackendState` to `degraded` and emits `StatusChanged`.

### `ApplyPolicy() -> a{sv}`

Forces reconciliation of the configured power profile for the current physical
state and retries managed lid policy if needed.

- Polkit action:
  `io.github.Uripeer3.gnome-power-profile-automation.apply`.
- This is the explicit override to the normal transition-only behavior.
- On success, returns the resulting complete status snapshot.
- Provider failure returns a typed error and also publishes degraded state.

There is no public `Reload`, `Restart`, `SyncLidPolicy`, arbitrary profile-set,
file-write, or command-execution method in API version 1.

## Signals

### `StatusChanged(a{sv} status)`

Emitted after the coherent status snapshot changes. The argument is the same
complete document returned by `GetStatus`; it is not a partial patch.

Backends should coalesce equivalent events. Battery percentage changes alone
may update status, but must not cause profile application unless the policy
state changes.

### `ConfigurationChanged(a{sv} configuration)`

Emitted after a new configuration has been durably committed or an
administrator maintenance operation replaces the accepted configuration.

The argument is the complete canonical document. It is never emitted for a
rejected mutation.

## Errors

Typed error names use the interface prefix:

| Error suffix | Meaning |
|---|---|
| `Error.NotAuthorized` | Polkit denied or dismissed authorization |
| `Error.InvalidConfiguration` | Missing, unknown, mistyped, or invalid field |
| `Error.UnsupportedConfigurationVersion` | `schema-version` is not supported |
| `Error.ConfigurationUnavailable` | No valid configuration can be loaded |
| `Error.PersistenceFailed` | Atomic configuration commit failed |
| `Error.ProviderUnavailable` | Required UPower or Power Profiles provider is unavailable |
| `Error.ApplyFailed` | A provider or logind rejected reconciliation |

For example:

```text
io.github.Uripeer3.GnomePowerProfileAutomation1.Error.InvalidConfiguration
```

Human-readable error messages are diagnostics only. Clients branch on error
names and may display the message to the user.

## Authorization behavior

- Read calls never trigger Polkit.
- Each mutating method authorizes the actual D-Bus sender.
- Authorization is not transferred between callers.
- The backend must handle client disconnect while authorization is pending.
- A denied or dismissed prompt leaves configuration and system state unchanged.
- Backend-internal automatic transitions do not require Polkit; they enforce
  previously authorized system configuration.

## Compatibility policy

The trailing `1` versions the bus name, object path, and interface together.

Compatible API version 1 changes may:

- Add optional informational keys to status documents.
- Add read-only properties, methods, or signals that old clients can ignore.
- Add new typed error names.

Version 1 must not:

- Change an existing D-Bus signature.
- Change the meaning or type of a required key.
- Remove or rename a method, property, signal, or required key.
- Broaden a mutating method's authorization without review.

A breaking change introduces a new versioned bus name, object path, and
interface. The backend may temporarily expose multiple interface versions to
support upgrades, but clients never guess compatibility from the package
version.

## Client requirements

Clients must:

- Verify `ApiVersion` before enabling mutations.
- Treat no owner, timeout, or incompatible version as backend unavailable.
- Ignore unknown status keys.
- Reject unknown required configuration semantics rather than silently dropping
  them during a save.
- Subscribe to signals instead of polling continuously.
- Remove signal subscriptions and D-Bus proxies during shutdown or extension
  disable.
- Never fall back to direct privileged file or service operations.
