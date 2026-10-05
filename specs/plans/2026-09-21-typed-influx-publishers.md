# Typed Influx publishers (BROTLib#4)

**Status: proposed.** Nothing of this plan is implemented. The smaller fix for #4 is on `develop` (`ce47d3b`); this plan
is the full fix that issue asks for.

## Problem

`I_Comm.Publish(domain, location, parameter, value : STRING)` gets every value as text. `FB_Comm_MQTT_Influx`
decides the InfluxDB type from that text (`F_InfluxFieldValue`): no `.` and no exponent means integer (`15i`), a number
with `.` or exponent means float, `TRUE`/`FALSE` means boolean, anything else is a quoted string.

InfluxDB keeps the type of the first write to a field (per shard) and rejects a point whose type differs (documented
behaviour, **not tested against our server**). So a field written as `15i` at one moment and `15.5` at the next loses
data. The text of a value depends on its value, not on its meaning:

- `LREAL_TO_STRING(15.0)` prints `15` (from memory, not checked), so a whole-number `LREAL` becomes an integer field.
- Some fields are written both from a literal and from a computed number. In MONETN the roof position
  `AUXILIARY.DOME.REALPOS` gets `'1.0'` / `'0.0'` for opened / closed and `LREAL_TO_STRING(percent_open / 100.0)` in
  between; when the computed value is a whole number its text has no `.`. Step 1 finds the rest.
- The smaller fix removes the invalid lines (exponents, truncated lines, unescaped tags) but cannot make the type stable:
  the type is still guessed from the text.

The fix is to decide the type at the call site.

## Call sites (survey, approximate)

`grep` for `.Publish(` across the repos, classified by the form of the value argument (a regular expression, so the
numbers are indicative, not exact):

| Repo | `.Publish(` calls |
|---|---|
| MONETN | 217 |
| IAG50cm | 108 |
| MONETcommon | 104 |
| BROTLib | 41 |
| MONETS | 33 |
| HalfBROT | 32 |
| MONETRoof | 22 |
| **total** | **about 550** |

By value form: `LREAL_TO_STRING(...)` about 193, `BOOL_TO_STRING(...)` about 92, integer `*_TO_STRING(...)` about 20,
`REAL_TO_STRING(...)` a handful, and about 240 with a string literal or a string variable (`'0.0'`, `'1'`,
`'J2000.0'`, `telescopeConfig.name`, ...). `fbComm` is declared as `I_Comm` everywhere; the only implementer is the
abstract `FB_Comm_MQTT`, extended by `FB_Comm_MQTT_Influx`.

## Constraint: what InfluxDB already holds

Fields that already have data keep the type of their first write. A typed publisher that picks a different type for such
a field gets the same rejections as today, just for a different reason. **Before any call site is migrated we need the
current field types from the server** (`SHOW FIELD KEYS` per database and measurement). That is outside this repo. For
each field that has a conflict we decide: match the stored type, or write to a new field name and leave the old one.

## Design

New methods on `I_Comm`, abstract in `FB_Comm_MQTT`, implemented in `FB_Comm_MQTT_Influx`. Same first three arguments
as `Publish`.

| Method | Value | Written as |
|---|---|---|
| `PublishLREAL` | `LREAL` | float: `LREAL_TO_STRING(value)` with no `i`. A whole number is still a float, because no `i` is appended. NaN and Inf are not valid line protocol: the point is not published. |
| `PublishINT` | `LINT` | integer: `<n>i` |
| `PublishBOOL` | `BOOL` | `TRUE` / `FALSE`, retained like today |
| `PublishString` | `STRING` | quoted, `"` and `\` escaped (`F_EscapeInfluxString`) |

- `Publish(..., value : STRING)` stays for one release with today's behaviour (the smaller fix), marked deprecated, so
  the consumers keep compiling and migrate repo by repo. It is removed in a later release.
- `REAL` values: converting to `LREAL` changes the text (`0.1` becomes `0.10000000149...`). Either add `PublishREAL`
  (uses `REAL_TO_STRING`) or migrate those few sites to an `LREAL` source. Decide when the sites are listed.
- Tag and key escaping, the 255 character limit and the `dropped` counter from the smaller fix are shared by all
  methods.
- Adding methods to `I_Comm` breaks any implementer other than `FB_Comm_MQTT`; none was found in the repos.

## Steps

1. **Inventory.** A script (`testing/inventory_publish.py`) lists every `.Publish(` call site with domain, location,
   parameter and the form of the value, and flags parameters that are written in more than one form or from several
   places. This is the list of flip candidates and the input for the type decisions. *Output: table per repo.*
2. **Field types from the server.** The operator runs `SHOW FIELD KEYS` and shares the result (or just the list of
   conflicts). Decide per conflicting field: match, or new name.
3. **BROTLib: API and tests.** The four methods plus `I_Comm`, TcUnit tests for the exact line each writes (type, `i`
   suffix, NaN/Inf, escaping, boolean retain, buffer overflow). Internal call sites (41) migrated. Release BROTLib
   0.6.0 (new methods, `Publish` deprecated).
4. **Migrate the consumers, one repo per release**, largest risk first: IAG50cm, MONETcommon, HalfBROT, MONETRoof,
   MONETS, MONETN (217, largely a copy of the MONETcommon code). The rewrite is mechanical
   (`Publish(a, b, c, LREAL_TO_STRING(v))` becomes `PublishLREAL(a, b, c, v)`) and is done by script, then reviewed as a
   diff. Literals become the right typed call (`'0.5'` to `PublishLREAL(..., 0.5)`, status codes to `PublishINT`
   or `PublishLREAL` according to step 2). Build against the latest libraries each time.
5. **Roll-out check.** After each consumer is deployed, watch the InfluxDB / Telegraf side for field type conflicts
   for that consumer's measurements. Not verified on a telescope yet, and not tested against a server.
6. **Remove the string `Publish`** and `F_InfluxFieldValue`'s guessing (a later BROTLib release, when no consumer uses
   it).

## Tests

- TcUnit (BROTLibTests): one suite for the four methods' output lines, using the existing helpers
  (`F_EscapeInfluxTag`, `F_EscapeInfluxString`, `F_TruncateInfluxEscaped`). The MQTT client itself is not mocked, so the
  line is built by a function that the publisher and the test both call.
- Inventory script: run on every repo after migration and expect no `Publish(` with a string value left, and no
  parameter written in two forms.
- Not testable here: what the server does with a type change. Confirm with a scratch database first if one is available.

## Open questions

1. Which types do the existing fields hold? (step 2, needs the server.)
2. Does anything read these fields and depend on their type (Grafana panels, alerts)? A type change from integer to
   float can change a query result.
3. `PublishREAL` or migrate the REAL sites?
4. Should status codes (`'0'`, `'1'`, `'2'`) be integers or floats? Follow the stored type.

## Not in this plan

- A typed argument on the existing `Publish` (an overload): TwinCAT function block methods cannot be overloaded, so
  separate method names are used.
- MQTT authentication, TLS and command validation (#27) and delivery semantics (#5).
