# `domain`/`location` tagging in `FB_Comm_MQTT_Influx.Publish()`

Status: informational/reference, written 2026-09-09. Covers what `domain`/`location` actually do today, across every repo, and what's confirmed to consume (or not consume) them. See also `telescope-telemetry-publish-chain.md` and `mqtt-telemetry-patterns.md`.

## Wire format

`Publish(domain, location, parameter, value)` builds one line of Influx line protocol per call:

```
fbFormat(sFormat := '%s,location=%s,host=%s %s=%s', arg1 := domain, arg2 := location, arg3 := HostName, arg4 := parameter, arg5 := sFieldVal, ...);
```

i.e. `<domain>,location=<location>,host=<HostName> <parameter>=<value>`. In Influx line protocol terms: `domain` is the **measurement** name, `location` and `host` are **tags**.

## Every `(domain, location)` pair actually used, across every repo

Checked every `fbComm.Publish(...)` call site in `MONETS`, `MONETN`, `BROTLib`, `HalfBROT`, `IAG50cm` (2026-09-09, before the `power` split below). Only four combinations existed, each a hardcoded literal at every call site — never a variable:

| domain | location | Used for |
|---|---|---|
| `electronics` | `base` | `MainReady`, `MasterError`, cabinet temperature |
| `hydraulics` | `base` | oil/brake/pump state |
| `telescope` | `dome` | pointing, position, covers, focus, sensors, telescope info — the large majority of all calls |
| `telescope` | `power` | frequency/voltage guards, power quality (`FB_MonetPowerMonitoring`/`FB_PowerMonitoring`) — **superseded, see the update below: this is now `domain := 'power'`** |
| `diagnostics` | `base` | **added later same day** — `bInterrupted`, per-axis `bError`/`nErrorID`/`bEnable`, safety state, readiness state (MONETS only) |

`location` never varies within `electronics` or `hydraulics` (always `'base'`); it only distinguishes anything within `telescope` (`'dome'` vs `'power'`). Note also that `Publish()`'s own `VAR_INPUT` declares `location : STRING(255) := 'roof'` as its default — a value no call site anywhere actually uses, suggesting it was designed to vary more than it does in practice.

## Is `location` — or `domain`, or `host` — actually consumed by anything downstream?

**`pybrotlib` (the Python MQTT client, `BROTLib/pyBROT`): no, provably.** Its parser (`src/pybrotlib/transport/mqtttransport.py`, `_process_message`) does:

```python
key, value = msg.payload.decode("utf-8").split(" ")[1].split("=")
```

It splits the payload on spaces and keeps only index `[1]` — the `parameter=value` half. Index `[0]` (`telescope,location=dome,host=<controller>`) is computed by `.split(" ")` but never read. `domain`/`location`/`host` are discarded outright, not merely unused by convention. Its `Telemetry` dataclass model (`src/pybrotlib/telemetry.py`) has no field for any of them either — it's a pure mirror of the `OBJECT.*`/`POSITION.*`/`TELESCOPE.*`/`POINTING.*`/`AUXILIARY.*` namespace and nothing else. Notably, this dataclass also has **no representation at all** for `electronics`, `hydraulics`, or `power` domain data — `pybrotlib` only models the `telescope`-domain TCS-contract fields; the other three domains exist for Influx/Telegraf's benefit only, not `pybrotlib`'s.

**InfluxDB: technically yes, functionally unknown.** `location` and `host` are real Influx tags — indexed, stored, queryable in principle (Telegraf's `mqtt_consumer` + `data_format = "influx"` passes the line straight through with no tag-dropping). So it's not deleted from the data. But no query, dashboard, or Telegraf processor stage has been found (as of this writing) that actually filters, groups, or reports on `location`. It reaches storage but nothing downstream demonstrably reads it back.

## Recommendation

Keep `location` as-is — it originates from the original developer's design and has an established convention (`'base'`/`'dome'`/`'power'`), and removing it would touch every `Publish()` call site across five repos for a purely cosmetic cleanup. **Document, don't remove.** The useful fact to carry forward: `location` (and `domain`, and `host`) are currently *write-only* from every known consumer's perspective — nobody should assume changing `location` values will affect any client behavior (`pybrotlib` ignores it unconditionally), and nobody should assume an existing Influx query depends on a particular `location` value without checking first.

Separately, if `power`-measurement fields (`FrequencyGuardError`, `L1OverVoltage`, `PowerQuality`, etc.) are ever pulled out of `telescope`/`location=power` into their own `domain := 'power'` (proposed only, not committed to — see the domain-configuration discussion 2026-09-09), that's unaffected by any of the above: `pybrotlib` doesn't model `power` data today regardless of which domain it lives under, so moving it is a pure Influx/Telegraf-side reorganization with no client-side impact to worry about.

## Update: `location`/`host` dropped at the Telegraf layer (2026-09-09, same day)

Tim removed `location` and `host` from the Telegraf config — i.e. these tags are now excluded (e.g. via `tagexclude`) before Telegraf writes into InfluxDB, rather than touching the PLC-side `Publish()` API. This is consistent with the finding above: since no known consumer reads `location`/`host` back, dropping them at ingestion has no effect on `pybrotlib` or anything else, while reducing Influx tag cardinality. The PLC still publishes them on the wire (unchanged, per "keep as-is per the original developer's design" above) — only the Telegraf→Influx hop now discards them.

**Consequence worth flagging**: with `location` no longer landing in Influx, the `telescope`/`dome` vs. `telescope`/`power` distinction (the one place `location` was ever meaningfully doing separating work — see above) **no longer exists in Influx at all**. Pointing/status fields and power-quality fields now land in the same `telescope` measurement with no tag distinguishing their origin. This isn't a data-integrity problem (field names don't collide — `OBJECT.EQUATORIAL.RA` vs `L1OverVoltage`), but it does mean a query can no longer cheaply say "give me everything from the power subsystem" via a tag filter; it would need to enumerate specific field names instead. If that granularity is ever wanted back, the `power`-domain split proposed above becomes the only way to get it (a distinct measurement, not a tag) — dropping the tag makes that split more relevant, not less.

**Also worth flagging**: with `host` also dropped, if a broker/topic is ever shared by more than one physical controller in the future, their data would become indistinguishable in Influx. Not a live concern today — only one physical controller currently publishes to MONETS's telemetry topic (identifier kept in IAG's private specs).

## Update: `power` domain split implemented (2026-09-09, same day)

The split proposed above shipped: `FB_MonetPowerMonitoring` now publishes under `domain := 'power'` instead of `'telescope'`/`location := 'power'` (MONETcommon `v0.3.0`, commit `8148cb0`). `location` itself was left unchanged (still `'power'`) per the "keep as-is" decision — only `domain` moved. This restores, via a real measurement rather than a tag, exactly the granularity that dropping the `location` tag at Telegraf (above) had removed: `power`-subsystem fields are now their own Influx measurement again, cleanly separated from `telescope`'s TCS-contract fields, independent of whatever Telegraf does with tags.
