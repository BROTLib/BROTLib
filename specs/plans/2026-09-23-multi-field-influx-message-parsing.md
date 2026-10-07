# Multi-field Influx message parsing (BROTLib#39)

**Status: proposed, revised 2026-10-07.** Parser change not implemented; pinning tests for today's behaviour are written (`FB_InfluxMessage_Tests`, not yet run). Split out of #6 (coordinates and commands arrive as
separate messages with persistent buffers) — this plan covers the parser-side prerequisite only.

## Problem

`FB_InfluxMessage` parses an incoming MQTT command payload in Influx line-protocol format
(`measurement[,tags] field_set[ timestamp]`). The field set can itself hold multiple comma-separated
`parameter=value` pairs (`field1=val1,field2=val2`) — that's valid Influx line protocol, not a
BROTLib invention. But the parser only ever returns the *first* pair:

```st
comma_position := FIND(parameter_value, commaSeparator);
IF comma_position = 0 THEN
	// we have only one parameter value pair
	bResultSplit := FindAndSplit(..., pLeftString := ADR(parameter), pRightString := ADR(value), ...);
ELSE
	// we have more than one parameter value pair
	parameter_value := LEFT(parameter_value, comma_position-1);
	bResultSplit := FindAndSplit(..., pLeftString := ADR(parameter), pRightString := ADR(value), ...);
	// TODO: return the rest an re-parse
END_IF
```

Everything after the first comma is silently dropped. `FB_Comm_MQTT_Influx._handleMQTTMessage`
(the only consumer, see `#4`/`#22`/`#24`'s prior work in this file) only ever sees one
`parameter`/`value` per call.

## Why this matters (relation to #6)

`rightascension`/`declination`/`elevation`/`azimuth` currently arrive as four separate MQTT
messages, filling a shared buffer (`RaDec`/`AltAz` fields on `FB_Comm_MQTT_Influx`) that a later
`track`/`slew` message consumes and resets. With QoS 0 and no acknowledgement:

- a lost message plus a stale buffer value from an earlier, aborted sequence can combine
  coordinates from two different targets into one `Track()` call, silently;
- an incomplete pair (e.g. `declination` never arrives) is dropped with no error, no log, no
  reply — the caller has no way to know the command didn't happen.

If a producer could send `command track=1,rightascension=123.4,declination=56.7` as **one** atomic
message instead of three, the whole buffer-staleness/mixing class of bug goes away by
construction — there's no multi-message sequence left to get out of sync. This plan is the
parser-side change that makes that possible; it does not itself change what BROTLib does with the
fields once parsed (see "Not in this plan").

## Correction (2026-10-07): the message format

Earlier versions of this plan and #39 wrote the example as `command track,rightascension=123.4,...`. That
is not valid line protocol: after the measurement comes a field set of `key=value` pairs, and `track` alone
has no `=`. Today's verbs are sent as `command track=1` (the handler ignores the value), so the multi-field
form is `command track=1,rightascension=123.4,declination=56.7`.

## Ordering contract (new): data fields before the verb

Dispatching the pairs in message order is not enough to make `track`/`slew` atomic. With
`track=1,rightascension=...,declination=...` the loop would run `track` first, while `RaDec` still holds
the old buffer, which is exactly the stale-coordinate bug this change is meant to remove. Pick one:

1. **Contract:** producers send the data fields first (`rightascension=..,declination=..,track=1`). Simple,
   but nothing stops a producer from getting it wrong.
2. **Two passes in the handler (recommended):** first apply every non-verb field (`rightascension`,
   `declination`, `elevation`, `azimuth`, `temperature`, ...), then run the verbs (`track`, `slew`, `park`,
   ...). Same-message data then always wins over the buffer, in any field order.

Either way the buffer stays for single-field producers until they are migrated.

## Design

**Approach: return the remainder, let the caller loop.** This matches the TODO already left in
the source (`// TODO: return the rest an re-parse`) rather than introducing a new shape (e.g. a
fixed-size output array with a count, which would need an arbitrary cap and waste memory on every
call that only ever has one field).

Add one new `VAR_OUTPUT` to `FB_InfluxMessage`:

```st
VAR_OUTPUT
	measurement:	STRING(255) := '';
	parameter:		STRING(255) := '';
	value:			STRING(255) := '';
	remaining:		STRING(255) := '';	// unparsed field=value pairs, '' if none left
END_VAR
```

When a comma is found in `parameter_value`, instead of just taking `LEFT(parameter_value,
comma_position-1)` and discarding the rest, also set `remaining := MID(parameter_value,
LEN(parameter_value)-comma_position, comma_position+1)` (everything after the comma). When no
comma is found, `remaining := ''` (nothing left).

**Caller side** (`FB_Comm_MQTT_Influx._handleMQTTMessage`): wrap the existing
`measurement`/`parameter`/`value` dispatch (the big `IF measurement = 'command' THEN ELSIF
parameter = ... END_IF` chain) in a loop that re-invokes `FB_InfluxMessage` on `remaining` until
it comes back empty:

```st
sFieldSet := sPayloadRcv;	-- or wherever the caller currently gets the full payload
firstPass := TRUE;
WHILE firstPass OR sFieldSet <> '' DO
	firstPass := FALSE;
	influxMessage(sPayload := ..., measurement =>, parameter =>, value =>, remaining => sFieldSet);
	-- existing dispatch on measurement/parameter/value goes here, per pair
END_WHILE
```

The exact plumbing (does `FB_InfluxMessage` re-parse the whole original payload each loop, or
just the remaining field-set fragment?) needs care: `FB_InfluxMessage.sPayload` currently expects
`measurement[,tags] field_set`, not a bare field set — the measurement/tags prefix only needs
parsing once. Two options:

1. Reconstruct a synthetic payload each loop (`measurement || ' ' || remaining`) and re-run the
   full parse (simplest variant: let `FB_InfluxMessage` output the next full payload itself, `remaining` =
   measurement + ' ' + rest, so the caller just feeds `remaining` back as `sPayload`) — simplest, re-does needless work (measurement/tag split) every iteration but that's
   cheap.
2. Add a second, lighter method/mode that parses just a field-set fragment (skip the
   measurement/comma-tag step) for iterations after the first — more code, avoids redundant work.

Recommend option 1 first: correctness over a micro-optimization that doesn't matter for a
handful of fields per message.

## Bounds and safety

- **Loop bound**: cap the `WHILE` at a fixed maximum iteration count (e.g. 8) regardless of
  `remaining`, so a malformed or adversarial payload with many commas can't spin the PLC scan
  cycle. `FB_InfluxMessage`'s own `sPayload : STRING(255)` limit already bounds how many fields
  can even fit in one message in practice.
- **No behavior change for single-field messages**: every existing command (`park`, `track` with
  its current buffer-fill pattern, etc.) is still a single-field message today and must keep
  working identically — `remaining := ''` for those, loop runs exactly once. This plan changes
  parsing capability, not what any current producer actually sends.

## Tests

**Pinning tests, written first (`BROTLibTests/.../FB_InfluxMessage_Tests.TcPOU`, 8 cases).** There was no
coverage of `FB_InfluxMessage` before. They pin today's behaviour with a fresh instance per case: a single
pair, numbers with sign and exponent, tags dropped, a trailing timestamp dropped, quotes of a string value
stripped, **only the first of several pairs returned** (characterisation of #39, to be extended when it is
fixed), the timestamp after the last of several pairs, and no space giving empty outputs. The expected values
were derived by reading the code, so the first run on the user-mode runtime confirms them; a failure there
means my reading was wrong, not that the parser regressed.

**Not pinned, because the behaviour is uncertain without a run:** a payload with no `=` in the field set
(what `FindAndSplit` leaves in the outputs when the separator is missing), a double space after the
measurement, a value that itself contains `=`, outputs kept from a previous call on the same instance
(the early `RETURN` does not reset them; harmless in `_handleMQTTMessage`, where the instance is a method
local).

**After the fix:** 2 fields, the maximum the 255-character buffer allows, the 8-iteration cap, a trailing
timestamp after the *last* field of several, and the two-pass handler ordering (data fields in any order
before the verb).

- `testing/` Python mirror (matching the existing `check_influx_and_logic.py` convention): a reference
  implementation of the remainder-loop logic, checked against hand-built multi-field Influx lines.

## Open questions

1. **Still open, not checkable from this repo:** does anything currently on the wire send a multi-field message today, relying on BROTLib
   dropping everything past the first comma as (accidental) truncation? Not found in this repo's
   own call sites, but pybrotlib/pyobs-brot or another external producer is worth checking before
   this ships, in case something depends on today's drop-the-rest behavior.
2. Loop iteration cap: is 8 enough for the realistic case (e.g. `track` with 2 fields, or a future
   combined offset command with more)? Revisit once #6's producer-side change (a real proposal for
   which commands actually become multi-field) exists.

## Not in this plan

- Changing what `FB_Comm_MQTT_Influx._handleMQTTMessage` actually *does* with multiple fields
  (e.g. consuming `track,rightascension=...,declination=...` as one atomic command instead of the
  current fill-a-buffer-then-track pattern) — that's #6's producer-side follow-up, blocked on this
  parser change existing first, plus a decision on which commands should become multi-field and
  updating whatever publishes commands today.
- The buffer-staleness bug's safe, non-breaking mitigations (deduping `derotator`/
  `derotatoroffset`, logging on a silently-dropped incomplete pair or unrecognized `power` value)
  — those don't need this parser change and are handled directly under #6.
