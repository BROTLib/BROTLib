# MQTT command with space-separated fields: warn instead of dropping silently (BROTLib#79)

**Status: proposed, 2026-10-20.** Plan only, no PLC code changed. Base commit: `aea68ed` (`origin/develop`,
"Merge pull request #80", BROTLib 0.8.0). Nobody else works on #79 (checked 2026-10-20: no branch, no PR
mentions it). Follows the multi-field parsing of #39 (`2026-09-23-multi-field-influx-message-parsing.md`).

Marking used below: **[verified]** = read in the code at `aea68ed` or checked in another repo on 2026-10-20;
**[unverified]** = my reading of how TwinCAT behaves, to be confirmed by the first TcUnit run on the user-mode
runtime or on a PLC.

## Problem

T8 remote on MONET/S, 2026-10-19, BROTLib 0.8.0 (see IAG `2026-10-12-monet-telescope-test-plan.md`, line 172):

```
mosquitto_pub -t MONETS/Telescope/SET -m "command azimuth=150 elevation=50 slew=1"
```

Only `azimuth=150` is applied. `elevation=50` and `slew=1` are dropped, nothing is logged, the telescope does not
move and the sender gets no hint. The comma form `command azimuth=150,elevation=50,slew=1` works (#39). Cost about
40 minutes in the test session.

## Root cause [verified]

Influx line protocol is `measurement[,tags] field_set[ timestamp]`; a space ends the field set. The parser
treats everything after the first field's value and a space as the timestamp and throws it away.

`BROTLib/BROTLib/POUs/FB_InfluxMessage.TcPOU`:

- lines 55-58: `FindAndSplit` at the **first** space: `measurement_tags = 'command'`,
  `parameter_value = 'azimuth=150 elevation=50 slew=1'`.
- lines 70-76: no comma in `parameter_value`, so it is one pair: `parameter = 'azimuth'`,
  `value = '150 elevation=50 slew=1'`, `remaining = ''`.
- lines 90-97: the block meant for a trailing timestamp cuts `value` at its first space:
  `value := LEFT(value, space_position-1)` gives `'150'`; `'elevation=50 slew=1'` is discarded without a trace.

`BROTLib/BROTLib/POUs/Comm/FB_Comm_MQTT_Influx.TcPOU`:

- lines 45-46: `_handleMQTTMessage` runs `_DispatchPass` twice (data pass `bVerbPass := FALSE`, then the
  `track`/`slew` pass).
- lines 271-283: `_DispatchPass` walks the pairs through `remaining` (max `MAX_FIELDS = 8`, line 267). With
  `remaining = ''` it stops after `azimuth`; the data pass buffers `AltAz.Azimuth := 150` (line 124), the verb
  pass finds no `slew`.
- lines 284-286: the only existing "something was ignored" warning is for more than 8 fields, logged in the data
  pass only. Nothing looks at the discarded text.

Side effect worth knowing: `AltAz.Azimuth = 150` stays in the buffer, so a later `command elevation=..` plus
`command slew=1` from a single-field sender slews to azimuth 150. That is the existing buffer design (#6), not new.

## Worse variant: a space before the first comma [verified by reading, not run]

`command azimuth=150 elevation=50,slew=1`: line 70 finds the comma, so `remaining = 'command slew=1'` (lines
81-82), `parameter_value = 'azimuth=150 elevation=50'`, `value = '150'` after lines 94-97. Result: `azimuth=150`
is applied, `elevation=50` is dropped silently and **`slew=1` runs** with whatever elevation is in the buffer. With
an empty buffer the slew is dropped as incomplete (line 94, logged); with an elevation buffered by an earlier
single-field message the mount slews to a mixed target. This is the reason for open decision 1.

## Design (recommended, as proposed in the issue): warn, do not reject

Parsing stays exactly as it is; every message that is accepted today is still accepted and does the same thing.
What changes: the text cut off at lines 94-97 is kept in a new output, and the dispatcher logs one warning per
message when that text is not empty and not an integer timestamp.

One refinement over the issue text: the "is this a timestamp" check sits in `FB_InfluxMessage` (a second output
`trailingIgnored`), not in `_DispatchPass`. Reason: `FB_InfluxMessage` can be unit-tested output by output, the
ADS log in `_DispatchPass` cannot (see Tests). `_DispatchPass` then only decides when to log.

### `FB_InfluxMessage` (sketch)

New outputs, after `remaining` (line 18):

```st
	// text after the first space in this pair's value, '' if none. A trailing Influx timestamp lands here;
	// anything else means the sender separated fields with spaces instead of commas (BROTLib#79). Not parsed.
	trailing:			STRING(255) := '';
	// TRUE when 'trailing' is neither empty nor an integer timestamp: part of the message was ignored
	trailingIgnored:	BOOL;
```

Reset with the other outputs (lines 49-52):

```st
trailing := '';
trailingIgnored := FALSE;
```

Lines 94-97 become:

```st
// a trailing Influx timestamp (measurement[,tags] field_set timestamp) ends up appended to value, since only the
// first space in the whole payload is split off above. It is cut off here and handed out as 'trailing'. Anything
// that is not an integer timestamp means fields were separated by spaces (or a quoted string value holds a space,
// not supported); the caller logs that (BROTLib#79). Parsing is unchanged: value keeps only the text up to the space.
space_position := FIND(value, spaceSeparator);
IF space_position > 0 THEN
	trailing := MID(value, LEN(value) - space_position, space_position + 1);
	value := LEFT(value, space_position-1);
	trailingIgnored := trailing <> '' AND NOT _IsTimestamp(trailing);
END_IF
```

`MID(value, LEN(value) - space_position, space_position + 1)` is the same "everything after position p" pattern
as `sRest` on line 81. For `'park=1 '` (space at the end) it is `MID(.., 0, ..)`, which I expect to return `''`
**[unverified]**; the test `Trailing_Space_Only` pins it.

New private method:

```st
// TRUE when sText is an Influx line-protocol timestamp: an integer, optionally negative, at most 19 digits
// (nanoseconds since 1970 fit in 19 digits; seconds/ms/us precision are shorter). Empty text is not a timestamp.
METHOD PRIVATE _IsTimestamp : BOOL
VAR_INPUT
	sText	: STRING(255);
END_VAR
VAR
	nLen	: INT;
	nStart	: INT;
	i		: INT;
	c		: STRING(1);
END_VAR
```
```st
nLen := LEN(sText);
nStart := 1;
IF nLen > 0 AND LEFT(sText, 1) = '-' THEN
	nStart := 2;
END_IF
IF nLen < nStart OR nLen - nStart + 1 > 19 THEN
	RETURN;		// empty, a lone '-', or too many digits
END_IF
FOR i := nStart TO nLen DO
	c := MID(sText, 1, i);
	IF c < '0' OR c > '9' THEN
		RETURN;
	END_IF
END_FOR
_IsTimestamp := TRUE;
```

(The character loop is the same idiom as `F_IsNumericValue`; `F_IsNumericValue` itself is not usable because it
accepts `.`, `e` and a leading `+`.)

Module comment (lines 37-46): add one line, "A space inside the field set ends it; what follows is handed out in
'trailing' (a timestamp, or fields that should have been comma-separated, BROTLib#79)."

### `FB_Comm_MQTT_Influx._DispatchPass` (sketch)

New local `bTrailingLogged : BOOL;` (method locals start FALSE on every call). In the loop, after the
measurement check (after line 277):

```st
	// fields separated by spaces instead of commas: everything after the space was dropped by the parser.
	// Logged once per message, in the data pass only (both passes see the same pairs), BROTLib#79.
	IF influxMessage.trailingIgnored AND NOT bVerbPass AND NOT bTrailingLogged THEN
		bTrailingLogged := TRUE;
		ADSLOGSTR( ADSLOG_MSGTYPE_WARN OR ADSLOG_MSGTYPE_LOG,
			'MQTT command: fields must be separated by commas, ignored: %s', influxMessage.trailing);
	END_IF
```

This catches the space in any pair, not only the first (`command azimuth=150,elevation=50 slew=1`: the second
pair has `trailing = 'slew=1'`). Messages with a measurement other than `command` return before it, as today.
The format string plus a 255-character argument is longer than 255; `ADSLOGSTR` truncates the text
**[unverified, harmless]**.

Same style as the other command warnings (`'MQTT not understood %s'`, `'MQTT %s rejected: ...'`): ADS log only.
The sender does not see the ADS log; see open decision 2.

### Alternative (open decision 1): also skip `track`/`slew` of that message

Narrower than rejecting the whole message, and it closes the mixed-target case above: when the data pass saw an
ignored trailing text, the verb pass does not run.

```st
// _handleMQTTMessage
bIgnored := _DispatchPass(sPayloadRcv := sPayloadRcv, bVerbPass := FALSE);	// returns TRUE if trailing was logged
IF bIgnored THEN
	ADSLOGSTR( ADSLOG_MSGTYPE_WARN OR ADSLOG_MSGTYPE_LOG, 'MQTT command: track/slew of this message not run %s', sPayloadRcv);
ELSE
	_DispatchPass(sPayloadRcv := sPayloadRcv, bVerbPass := TRUE);
END_IF
```

(`_DispatchPass` becomes `METHOD PRIVATE _DispatchPass : BOOL` and returns `bTrailingLogged`.) Data fields are
still applied, so buffers behave as today. No known sender is affected: pyBROT and BROTgui never put a space in a
field set and send no timestamp (see "Other repositories"). A sender that sends a valid timestamp is not affected
either, because a timestamp does not set `trailingIgnored`.

Rejected for now: dropping the whole message (data fields too). That also changes what is buffered for messages
that today half-work, for little extra safety once the verb is skipped.

## Edge cases

| Payload | value | trailing | trailingIgnored | Notes |
|---|---|---|---|---|
| `command azimuth=150 elevation=50 slew=1` | `150` | `elevation=50 slew=1` | TRUE | the #79 case |
| `command park=1 1700000000000000000` | `1` | `1700000000000000000` | FALSE | ns timestamp, as today |
| `command park=1 1700000000` | `1` | `1700000000` | FALSE | s precision |
| `command park=1 -1700000000` | `1` | `-1700000000` | FALSE | negative timestamps are valid line protocol |
| `command park=1 12345678901234567890` | `1` | (20 digits) | TRUE | longer than any int64 ns timestamp |
| `command azimuth=150,elevation=50,slew=1` | `150` / `50` / `1` | `''` each | FALSE | comma form |
| `command,site=x a=1,b=2 1700000000000000000` | `1`, then `2` | `''`, then the timestamp | FALSE | tags + timestamp |
| `command azimuth=150,elevation=50 slew=1` | `150`, then `50` | `''`, then `slew=1` | FALSE, then TRUE | space in a later pair |
| `command azimuth=150 elevation=50,slew=1` | `150` | `elevation=50` | TRUE | slew still runs (decision 1) |
| `command park=1 ` | `1` | `''` | FALSE | trailing space only [unverified `MID` with length 0] |
| `command park=1  1700000000` | `1` | ` 1700000000` | TRUE | double space: a false warning; harmless, not worth trimming |
| `command mode="a b"` | `"a` | `b"` | TRUE | quoted string with a space: already unsupported, the warning is correct |
| `command park=1 1700000000\r\n` | `1` | `1700000000` + CR/LF | TRUE | only if a tool appends a line end (`mosquitto_pub -l`/`-f`); `-m` does not. Not handled, note only |
| `status a=1 b=2` | | | TRUE | measurement is not `command`: `_DispatchPass` returns before the log |
| 9 or more pairs | | | | the 8-field cap and its warning are unchanged; a space in pairs 9+ is not seen |

## Tests

### `BROTLibTests/BROTLibTests/BROTLibTests/POUs/FB_InfluxMessage_Tests.TcPOU`

`Check` asserts four outputs; rather than change its 16 call sites, add `CheckTrailing(sPayload, sValue,
sTrailing, bIgnored)` (fresh instance, asserts `value`, `trailing`, `trailingIgnored`). New cases:

1. `Spaced_Fields_Are_Reported`: `'command azimuth=150 elevation=50 slew=1'` gives `value '150'`, `remaining ''`,
   `trailing 'elevation=50 slew=1'`, `trailingIgnored TRUE`.
2. `Timestamp_Is_Not_Reported`: the ns, s and negative timestamps from the table: `trailingIgnored FALSE`,
   `trailing` = the timestamp; the 20-digit one: TRUE.
3. `Comma_Form_Has_No_Trailing`: `'command azimuth=150,elevation=50,slew=1'` and its two `remaining` payloads:
   `trailing ''`, FALSE.
4. `Tags_And_Timestamp_Are_Not_Reported`: `'command,site=x a=1,b=2 1700000000000000000'` (`trailing ''`) and
   `'command,site=x b=2 1700000000000000000'` (`trailing` = timestamp, FALSE).
5. `Space_In_A_Later_Pair_Is_Reported`: `'command elevation=50 slew=1'` (the `remaining` of
   `'command azimuth=150,elevation=50 slew=1'`): `value '50'`, `trailing 'slew=1'`, TRUE.
6. `Space_Before_The_First_Comma`: `'command azimuth=150 elevation=50,slew=1'`: `value '150'`,
   `trailing 'elevation=50'`, TRUE, `remaining 'command slew=1'` (pins the mixed-target case).
7. `Trailing_Space_Only`: `'command park=1 '`: `trailing ''`, FALSE.
8. Extend `Outputs_Are_Reset_Between_Calls`: the spaced payload, then `'command park=1'` on the same instance:
   `trailing ''`, FALSE.

Update the header comment and `BROTLibTests/README.md` (line 19, the `FB_InfluxMessage_Tests` row).

### `FB_Comm_MQTT_Influx_Tests.TcPOU` (behaviour only)

The `ADSLOGSTR` call itself cannot be observed from TcUnit (no hook on the ADS logger; the existing 8-field
warning is not tested either). What can be tested is what the stub telescope sees:

- `Spaced_Fields_Do_Not_Slew`: after `ResetHandler()`, `'command azimuth=150 elevation=50 slew=1'`:
  `stub.nSlew = 0` (pins today's behaviour; the warning is the only change).
- `Space_Before_Comma_Uses_The_Buffer`: `'command elevation=30'`, then `'command azimuth=150 elevation=50,slew=1'`.
  With the recommended design: `nSlew = 1`, `fSlewAlt = 30.0`, `fSlewAz = 150.0` (documents the hazard). With
  decision 1 taken: `nSlew = 0`. Whichever way the decision goes, this test states it.
- The existing `Trailing_Timestamp_Does_Not_Break_The_Last_Field` keeps covering "a timestamp still tracks".

The log line is checked by hand: on the user-mode runtime (XAE Error List, filter "MQTT command") and on MONET/S
(below). If a test of the log is wanted: a read-only diagnostic counter on `FB_Comm_MQTT_Influx` (e.g.
`nIgnoredTrailing : UDINT`, incremented where the warning is logged) would make it testable; not proposed unless
asked, it adds interface for a test.

### `testing/check_influx_and_logic.py`

Extend `parse_one` to return `trailing` and `trailing_ignored` (`re.fullmatch(r"-?\d{1,19}", t)`), add section 8
with the table above, and (if decision 1 is taken) a `Handler` case for the skipped verb. As with #39 this encodes
my reading of the ST code, so it is a consistency check, not an independent proof.

## README

`README.md` lines 207-210 (the `FB_InfluxMessage` bullet) become:

```markdown
- **`FB_InfluxMessage`** — parses Influx line-protocol messages (`measurement,tags parameter=value[,parameter=value ...] [timestamp]`)
  received on the command topic, one pair at a time (`remaining` holds the payload for the next pair).
  `FB_Comm_MQTT_Influx` walks up to 8 pairs per message and applies `track`/`slew` last, so they see the
  coordinates of the same message. Several fields go in **one comma-separated field set without spaces**:
  `command elevation=50,azimuth=150,slew=1`. A space ends the field set (what follows is the optional timestamp),
  so `command elevation=50 azimuth=150 slew=1` applies only `elevation=50`; the ignored rest is logged as a
  warning (`MQTT command: fields must be separated by commas, ignored: ...`, BROTLib#79).
```

If decision 1 is taken, add: "and `track`/`slew` of such a message are not run".

## Version

Additive (two new outputs, one private method, one log line), no interface removed: patch bump 0.8.0 to 0.8.1 in
`BROTLib/BROTLib/BROTLib.plcproj` (`ProjectVersion`, line 22), as a separate "Bump version to 0.8.1" commit like the
previous releases. Consumers (MONETcommon, HalfBROT, MONETS, MONETN, IAG50cm; dummyBROT presumably, not checked) need no code change; they
get the warning when rebuilt against 0.8.1.

## Hardware / manual re-test on MONET/S

Over `MONETS/Telescope/SET` with `C:\Program Files\mosquitto\mosquitto_pub.exe` (as in the 2026-10-19 session),
telescope powered and ready, someone watching the telescope or the webcam, XAE attached to watch the Error List
(the warning goes to the ADS log, not to `MONETS/Log`):

1. `-m "command azimuth=150 elevation=50 slew=1"`: no motion; one warning
   `MQTT command: fields must be separated by commas, ignored: elevation=50 slew=1`.
2. `-m "command azimuth=150,elevation=50,slew=1"`: slews to az 150 / el 50, no warning.
3. `-m "command park=1 1700000000000000000"` (or `gohome=1` with a timestamp): runs, no warning.
4. `-m "command elevation=45,azimuth=140 slew=1"`: no slew, one warning `... ignored: slew=1`.
5. Only on a parked or safe telescope, and only with decision 1 taken: `-m "command elevation=40"`, then
   `-m "command azimuth=160 elevation=50,slew=1"`: expected no slew plus both warnings. (With the recommended
   design this slews to el 40 / az 160; do not run it without someone watching.)
6. Send a non-command line to the same topic (`-m "status a=1 b=2"`): no warning.

The same steps on the user-mode runtime with `FB_TelescopeStub` are covered by the TcUnit cases above; the
hardware run only confirms the log text and that nothing else changed.

## Other repositories [verified 2026-10-20 unless marked]

- **No vendored copy of `FB_InfluxMessage`**: searched every repository under `Documents/brotlib` (MONETS, MONETN,
  MONETcommon and its `-fix`/`-wrap` checkouts, HalfBROT, AstroBROT, MONETRoof, IAG50cm and its `-fix` checkouts,
  IAG): the only `FB_InfluxMessage` POU is BROTLib's. Everyone gets the change through the library.
- **pyBROT** (`src/pybrotlib/components/telescope.py`, lines 101-116 and 125-223): sends single fields
  (`command rightascension=..`) or, with `multi_field_commands`, the comma form
  (`command rightascension=..,declination=..,track=1`); no spaces, no timestamps. Not affected, no warning.
- **BROTgui** (`BROTgui/qtelescopecontrol.py`, lines 232-416): only logs the commands it sends through pyBROT,
  single-field form. Not affected.
- **IAG specs** (private): `specs/plans/2026-10-12-iag50cm-test-runbook.md` line 31 documents
  `-m "command <fields>"` and uses single fields; `2026-10-12-monet-telescope-test-plan.md` line 172 already notes
  the comma syntax. Could link #79 there after the fix; no change needed.
- **MONETcommon#83** got a correction comment about the spaced syntax on 2026-10-19 (per the test plan); nothing to
  change in code.
- **`testing/check_influx_and_logic.py`**: extend, see Tests.
- **Not checked:** BROTweb (TwinCAT HMI, probably ADS rather than MQTT), Node-RED flows or scripts on other
  machines, pyobs configurations that publish raw MQTT.

## Open decisions (for Tim)

1. **Warn only (as in the issue, recommended default) or also skip `track`/`slew` of a message with ignored
   text?** Skipping closes the mixed-target slew (`command azimuth=150 elevation=50,slew=1` with a buffered
   elevation) at the cost of one more `IF` and log line; no known sender is affected. My recommendation: take it,
   it is a mount.
2. **Publish the warning on `<telescope>/Log` too (`PublishLog('WARN', ...)`), so a pyobs or `mosquitto_sub`
   user sees it?** The issue complains that "the sender gets no hint", and the ADS log alone does not reach the
   sender. None of the other command warnings (`not understood`, `rejected`, `incomplete`) does this today, and
   calling `PublishLog` from inside the receive handler has not been checked (client busy state). Suggest a
   separate issue that does it for all command warnings at once.
3. A diagnostic counter for testing the log line (see Tests): no by default.

## Not in this plan

- Supporting spaces as a separator (not line protocol; would make a real timestamp ambiguous).
- Quoted string values containing a space or a comma (still unsupported, now at least logged for the space).
- The buffer staleness of single-field senders (#6).
