# MQTT telemetry patterns: retain, on-change vs. interval, and LWT

Status: informational/reference, written 2026-09-09, updated 2026-10-08 for the retained-line timestamp (#38) and the LWT that #5 added. Written out of a discussion about whether MONET/S's telemetry is sufficient for debugging (see IAG's own specs, `plans/2026-09-09-static-review-and-live-ads-findings.md`, kept private since it covers a live incident). Not a proposal for a specific change by itself — see IAG's own `plans/` for the concrete follow-up.

## Does the MQTT broker store the last value for late subscribers?

Only if the publisher sets the **retain** flag on that message. A retained message is held by the broker per-topic and delivered immediately to any subscriber that subscribes afterward (including one that just reconnected), even if nothing has been published since. Without retain, a subscriber that wasn't connected at publish time never sees that value until the next publish.

**This is already implemented, selectively**, in `FB_Comm_MQTT_Influx.Publish()`:

```
// retain message if value is boolean
retain_message := bIsBool;
...
published := fbMqttClient.Publish(..., bRetain := retain_message, ...);
```

Boolean-valued fields (`MainReady`, `MasterError`, hydraulics state flags, etc.) are retained; numeric/string fields (positions, RA/Dec, telescope info strings) are not. The reason is that booleans are meant to be published on change only, which can mean hours between two messages, while floats like RA/Dec change all the time and go out on a timer anyway. Retaining a boolean means a dashboard opening mid-session, or Telegraf reconnecting, sees current state immediately rather than waiting for the next change. HalfBROT's `FB_HydraulicsControl` relies on this: it publishes its flags only when its status word changes.

### Retained lines carry a timestamp (#38)

The broker replays a retained message unchanged. Without a timestamp in the line, Telegraf stores the replay at the time it receives it, so a flag that last changed at 02:13 (or a PLC that has been dead for hours) shows up as fresh data at the moment Telegraf reconnects. Since #38, `Publish()` appends the optional Influx line-protocol timestamp to every retained line, in unix nanoseconds from `F_GetSystemTime()` via `F_InfluxTimestamp`:

```
hydraulics,location=base,host=CX-1234 BrakeOpen=true 1791462896000000000
```

Non-retained lines carry no timestamp; Telegraf stamps them on receipt, which is within milliseconds of the publish. If the PLC clock reads before 1970 the timestamp is left off. Every consumer that parses the raw MQTT payload must accept the trailing timestamp: Telegraf (`data_format = "influx"`, nanosecond precision by default) does; pyBROT's `MQTTTransport` does from pyBROT#40 on. Do not deploy a BROTLib with this change before the pyBROT that BROTgui and pyobs-brot use has it, or every retained `true` is read as `False`.

## Interval-based vs. publish-on-change

Two different kinds of telemetry warrant two different publish strategies:

- **Continuously-varying values** (position, RA/Dec, sidereal time): a rate-limited timer is the right call. "Publish on change" for a float that drifts every scan anyway degenerates into publishing every scan, so the existing telemetry timer (500ms while moving, 1-5s while idle, in `FB_MonetTelescopeControl`/`FB_BaseTelescopeControl`) is appropriate as-is.
- **Discrete state/fault values** (`bInterrupted`, per-axis `bError`, safety state): edge-triggered publish-on-change (`R_TRIG`/`F_TRIG` on the boolean) is strictly better than interval polling for this class — you get the exact transition moment instead of up to one timer-period of latency, and paired with `bRetain := TRUE`, a late-joining subscriber still sees the current state immediately without needing to wait for the next transition.

For debugging classes like a `bInterrupted` deadlock, on-change + retain is the combination that matters: it means the state was actually observable in Influx/MQTT at the moment it happened, not just inferable after the fact via a live ADS read.

## Last Will and Testament (LWT)

MQTT clients can register a **Last Will and Testament** message with the broker at connect time — a message the *broker* publishes automatically if that client disconnects ungracefully (crash, network drop, power loss), without any code in the client needing to run at the moment of failure. This is a broker-side mechanism, so it fires even on a hard crash where the client never gets a chance to publish anything itself.

Since #5, `FB_Comm_MQTT` registers a last will on `{sTopicPublish}/status` (`'offline'`, retained) and publishes a retained `'online'` there once it is connected and subscribed. That is the connection-level half of the stale-retained-values problem: the timestamp above tells Influx *when* a replayed value was true, the status topic tells a dashboard that the PLC behind the retained values is gone. No consumer reads the status topic yet (pyBROT#36).

## Practical implication for adding new telemetry fields

When adding new debug-telemetry fields (e.g. `bInterrupted`, per-axis `bError`/`nErrorID`/`bEnable`, `SafetyHandling.error`/`.estop`/`.state`):
- Publish under a new `domain` (e.g. `'diagnostics'`) rather than mixing into `'telescope'` — `Publish()`'s `domain` parameter becomes the Influx measurement name directly, so this is free separation with no new MQTT topic or Telegraf config needed.
- Use edge-triggered publish (`R_TRIG`/`F_TRIG`) for these boolean fields, with `bRetain` behavior already covering them for free via the existing `bIsBool` check in `Publish()`.
- A periodic heartbeat/full-snapshot publish is still worth adding on a slow timer (e.g. 30s) *in addition to* edge-triggering — not for late-subscriber correctness (retain handles that) but so a human scanning Influx history can confirm the system was actively reporting during a given window, not silently stalled. (Whether the telemetry system itself is still alive is a distinct question from whether a given field's *value* changed — that's what LWT above is really for, at the connection level rather than the field level.)
