# Telescope telemetry publish chain (`FB_BaseTelescopeControl._PublishTelemetry`)

Status: implemented, traced 2026-09-09 while investigating what feeds the `telescope` measurement in MONET/S's InfluxDB (connection details are private — see IAG's own specs, `monets-influx-access.md`).

## What it does

`FB_BaseTelescopeControl` (`BROTLib/BROTLib/Telescope/FB_BaseTelescopeControl.TcPOU`) publishes a TCS-style telemetry snapshot over MQTT via `fbComm.Publish('telescope', 'dome', '<DOTTED.FIELD.NAME>', value)` — e.g. `OBJECT.EQUATORIAL.RA`, `POSITION.LOCAL.SIDEREAL_TIME`, `TELESCOPE.INFO.NAME`, `TELESCOPE.STATUS.GLOBAL`. This is independent of and separate from whatever a concrete `MAIN.TcPOU` publishes directly on its own timer (e.g. MONETS's `MainReady`/`MasterError`).

## Call chain (concrete example: MONETS)

1. `FB_MonetTelescopeControl` (MONETcommon) runs its own telemetry timer in its main cyclic body (~line 417-427): 500ms while `bSlewing`/`bTrack`/`bTracking`, 1000ms otherwise. On timeout, calls `_SendTelemetry()`.
2. `_SendTelemetry()` (~line 842) calls `SUPER^._PublishTelemetry()`.
3. This resolves to `FB_AltAzTelescopeControl._PublishTelemetry()` (BROTLib), which adds alt/az-specific fields and calls its own `SUPER^._PublishTelemetry()`.
4. Which resolves to `FB_BaseTelescopeControl._PublishTelemetry()` (BROTLib, line 114) — the base set of fields (object coordinates, local/sidereal time, telescope info/config/status).

Each subclass in an inheritance chain that wants telemetry published must have its own timer calling into this chain somewhere (`FB_MonetTelescopeControl` does; a hypothetical telescope FB that never calls `_PublishTelemetry`/`_SendTelemetry` at any level would simply never publish this telemetry, silently).

## Why this was non-obvious

Reading only `MAIN.TcPOU`'s own `fbComm.Publish(...)` calls badly undersells what actually gets published — most of a telescope's MQTT telemetry comes from inherited base-class behavior with its own independent timer, not from anything visible in the top-level POU. When tracing "what publishes field X", check the full `EXTENDS` chain's own cyclic bodies, not just the concrete FB actually instantiated in `MAIN`.

## Downstream

A **Telegraf** setup subscribes to the relevant MQTT topics and writes into InfluxDB (confirmed for MONET/S — connection details are private, see IAG's own specs) — Telegraf is the MQTT→Influx bridge, not a re-publisher; it just relays whatever line-protocol-formatted messages the PLC already sends.
