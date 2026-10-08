"""Port of small pieces of BROTLib logic, to check what they actually do.

1. FB_Comm_MQTT_Influx.Publish field typing (F_IsNumericValue + 'i' suffix rule)
2. FB_Comm_MQTT_Influx.PublishLog / Publish line length vs STRING(255)
3. F_YREAL with an inverted output range and cut = TRUE
4. FB_InfoConnection.sDiag decoding (cascade of bit tests)
5. FB_EventLog._LevelToString: bit-test vs a combined Level value
6. FB_InfluxMessage: quoted value, trailing timestamp (#24)
7. FB_InfluxMessage multi-field walk (`remaining`) and the two-pass handler (BROTLib#39)
Run: python3 check_influx_and_logic.py
"""


def is_numeric(s):                      # F_IsNumericValue, line by line
    if len(s) == 0:
        return False
    seen_digit = seen_dot = seen_exp = seen_exp_digit = prev_exp = False
    for i, c in enumerate(s, start=1):
        if c in "-+" and (i == 1 or prev_exp):
            pass
        elif c == "." and not seen_dot and not seen_exp:
            seen_dot = True
        elif c in "eE" and not seen_exp and seen_digit:
            seen_exp = True
        elif "0" <= c <= "9":
            if seen_exp:
                seen_exp_digit = True
            else:
                seen_digit = True
        else:
            return False
        prev_exp = c in "eE"
    return seen_digit and (not seen_exp or seen_exp_digit)


def field_value(value):                 # the classification block in Publish
    is_bool = value in ("TRUE", "FALSE", "true", "false")
    numeric = is_numeric(value)
    if numeric and "." not in value:
        return value + "i"
    if is_bool or numeric:
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def logic_yreal(x, xmin, xmax, ymin, ymax, cut=True):
    if xmax - xmin == 0:
        return 0.0
    y = (ymax - ymin) / (xmax - xmin) * x + (ymin - (ymax - ymin) / (xmax - xmin) * xmin)
    if cut:
        lo, hi = min(ymin, ymax), max(ymin, ymax)   # LIMIT(MN, IN, MX) needs MN <= MX
        y = min(max(y, lo), hi)
    return y


ADSLOG_MSGTYPE_HINT, ADSLOG_MSGTYPE_WARN, ADSLOG_MSGTYPE_ERROR, ADSLOG_MSGTYPE_LOG = 1, 2, 4, 0x10


def level_to_string_old(level):          # the old `=` comparison (#18)
    if level == ADSLOG_MSGTYPE_HINT:
        return "INFO"
    elif level == ADSLOG_MSGTYPE_WARN:
        return "WARNING"
    return "ERROR"


def level_to_string_new(level):          # FB_EventLog._LevelToString, fixed
    if level & ADSLOG_MSGTYPE_ERROR:
        return "ERROR"
    elif level & ADSLOG_MSGTYPE_WARN:
        return "WARNING"
    return "INFO"


def parse_influx_message(payload, strip_timestamp_and_quotes=True):
    # FB_InfluxMessage: measurement[,tags] parameter=value[ timestamp], single field only
    measurement_tags, _, parameter_value = payload.partition(" ")
    measurement = measurement_tags.partition(",")[0]
    first_pair = parameter_value.split(",", 1)[0]
    parameter, _, value = first_pair.partition("=")
    if strip_timestamp_and_quotes:
        value = value.split(" ", 1)[0]                    # drop a trailing timestamp (#24 fix)
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            value = value[1:-1]                            # strip quotes (#24 fix)
    return measurement, parameter, value


def parse_one(payload):
    """FB_InfluxMessage after #39: the first pair plus `remaining`, a complete payload for the next pair."""
    measurement = parameter = value = remaining = ""
    if " " not in payload:
        return measurement, parameter, value, remaining
    measurement_tags, _, parameter_value = payload.partition(" ")
    measurement = measurement_tags.partition(",")[0]
    if "," in parameter_value:
        first, _, rest = parameter_value.partition(",")
        remaining = measurement_tags + " " + rest
        parameter_value = first
    parameter, _, value = parameter_value.partition("=")
    value = value.split(" ", 1)[0]
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        value = value[1:-1]
    return measurement, parameter, value, remaining


MAX_FIELDS = 8


def walk(payload, verb_pass):
    """FB_Comm_MQTT_Influx._DispatchPass: yields the (parameter, value) pairs that belong to this pass."""
    nxt, n = payload, 0
    while nxt != "" and n < MAX_FIELDS:
        n += 1
        measurement, parameter, value, nxt = parse_one(nxt)
        if measurement != "command":
            return
        if (parameter in ("track", "slew")) == verb_pass:
            yield parameter, value


class Handler:
    """The buffer-and-consume part of FB_Comm_MQTT_Influx, with a stub telescope that records Track() calls."""
    def __init__(self):
        self.ra = self.dec = None
        self.tracks = []

    def apply(self, parameter, value):
        if parameter == "rightascension":
            self.ra = float(value)
        elif parameter == "declination":
            self.dec = float(value)
        elif parameter == "track":
            if self.ra is not None and self.dec is not None:
                self.tracks.append((self.ra, self.dec))
            self.ra = self.dec = None

    def handle(self, payload):
        for verb_pass in (False, True):
            for parameter, value in walk(payload, verb_pass):
                self.apply(parameter, value)


def diag_connection(v):                 # FB_InfoConnection.sDiag cascade, in source order
    b = lambda n: bool(v >> n & 1)
    if v == 0: return "No error"
    if b(0): return "Invalid Command"
    if b(1): return "Unknown Command"
    if b(1) and b(0): return "Invalid Connection ID"
    if b(2): return "Invalid CRC"
    if b(0) and b(2): return "Watchdog expired"
    if b(1) and b(2): return "Invalid FSoE address"
    if b(0) and b(1) and b(2): return "Invalid data"
    if b(3): return "Invalid Com.-Parameter length"
    if b(0) and b(3): return "Invalid Com.-Parameter"
    if b(1) and b(3): return "Invalid User.-Parameter length"
    if b(0) and b(1) and b(3): return "Invalid User.-Parameter"
    if b(2) and b(3): return "FSoE Master Reset"
    if b(4): return "Error by FSoE Slave detected"
    if b(5): return "FSoE Slave reports Failsafe value active"
    if b(6): return "StartUp"
    if b(7): return "FSoE Master reports Failsafe value active"
    return "Error"


if __name__ == "__main__":
    print("1. Influx field value written for a few strings (what LREAL_TO_STRING might return)")
    for v in ("15", "15.5", "0", "1e5", "1E-05", "-3", "1.0E-5", "NaN", "TRUE", "50cm", "5."):
        print(f"   {v!r:10} -> {field_value(v)}")
    print("   Same field, two cycles: 15.0 prints as '15' -> 15i ; 15.5 -> 15.5 (float). "
          "InfluxDB rejects a point whose type differs from the first one written.")

    print("\n2. Line length vs STRING(255)")
    for name, fmt_fixed in (("PublishLog", len('log,host=,level= message=""')),
                            ("Publish", len(',location=,host= =') )):
        print(f"   {name}: fixed overhead {fmt_fixed} chars + variable fields must stay <= 255")
    host, level = "CX-4E6032", "WARNING"
    room = 255 - (len('log,host=') + len(host) + len(',level=') + len(level) + len(' message="') + 1)
    print(f"   PublishLog with host {host!r}, level {level!r}: message must be <= {room} chars after escaping")

    print("\n3. F_YREAL(x=0.25, Xmin=0, Xmax=1, Ymin=1, Ymax=0, cut=TRUE) =",
          logic_yreal(0.25, 0, 1, 1, 0), "(inverted mapping should give 0.75)")
    print("   same with cut=FALSE =", logic_yreal(0.25, 0, 1, 1, 0, cut=False))

    print("\n4. FB_InfoConnection.sDiag: value -> text (FSoE codes are numeric values 0..15)")
    expected = {1: "Invalid Command", 2: "Unknown Command", 3: "Invalid Connection ID", 4: "Invalid CRC",
                5: "Watchdog expired", 6: "Invalid FSoE address", 7: "Invalid data",
                8: "Invalid Com.-Parameter length", 9: "Invalid Com.-Parameter",
                10: "Invalid User.-Parameter length", 11: "Invalid User.-Parameter"}
    bad = 0
    for v, want in expected.items():
        got = diag_connection(v)
        flag = "" if got == want else "   <-- differs"
        bad += got != want
        print(f"   {v:2d}: intended {want:32s} decoded {got}{flag}")
    print(f"   {bad} of {len(expected)} codes decode to the wrong text")

    print("\n5. FB_EventLog._LevelToString: a Level combined with ADSLOG_MSGTYPE_LOG (0x10),")
    print("   the same bit this FB itself ORs in before calling ADSLOGSTR")
    for name, base in (("HINT", ADSLOG_MSGTYPE_HINT), ("WARN", ADSLOG_MSGTYPE_WARN), ("ERROR", ADSLOG_MSGTYPE_ERROR)):
        combined = base | ADSLOG_MSGTYPE_LOG
        old, new = level_to_string_old(combined), level_to_string_new(combined)
        flag = "" if old == new else "   <-- old reads as ERROR regardless of the real level"
        print(f"   {name:5s} | LOG: old={old:8s} new={new:8s}{flag}")

    print("\n6. FB_InfluxMessage: quoted value and trailing timestamp")
    cases = [
        'command mode="auto"',
        'command mode="auto" 1234567890',
        'command temperature=20.5 1234567890',
        'command nasmyth=1',
    ]
    for payload in cases:
        old = parse_influx_message(payload, strip_timestamp_and_quotes=False)
        new = parse_influx_message(payload, strip_timestamp_and_quotes=True)
        flag = "" if old == new else "   <-- old kept the quotes/timestamp in value"
        print(f"   {payload!r}")
        print(f"     old value={old[2]!r}  new value={new[2]!r}{flag}")

    print("\n7. multi-field walk and two-pass handler (expected values of the TcUnit cases)")
    ok = True

    def check(label, got, want):
        global ok
        good = got == want
        ok &= good
        print(f"   {'ok ' if good else 'BAD'} {label}: {got!r}" + ("" if good else f"   want {want!r}"))

    check("walk a=1,b=2,c=3", [parse_one(p)[:4] for p in ("command a=1,b=2,c=3", "command b=2,c=3", "command c=3")],
          [("command", "a", "1", "command b=2,c=3"), ("command", "b", "2", "command c=3"), ("command", "c", "3", "")])
    check("tags and timestamp kept", parse_one("command,site=x a=1,b=2 1700000000000000000"),
          ("command", "a", "1", "command,site=x b=2 1700000000000000000"))
    check("last pair loses the timestamp", parse_one("command,site=x b=2 1700000000000000000"), ("command", "b", "2", ""))
    check("no space", parse_one("command"), ("", "", "", ""))
    for label, messages, want in (
        ("single-field messages", ["command rightascension=10.5", "command declination=20.5", "command track=1"], [(10.5, 20.5)]),
        ("data before verb", ["command rightascension=10.5,declination=20.5,track=1"], [(10.5, 20.5)]),
        ("verb first", ["command track=1,rightascension=10.5,declination=20.5"], [(10.5, 20.5)]),
        ("stale buffer loses", ["command rightascension=1.5", "command declination=2.5",
                                "command rightascension=10.5,declination=20.5,track=1"], [(10.5, 20.5)]),
        ("incomplete pair", ["command rightascension=10.5,track=1"], []),
        ("second track is dropped", ["command rightascension=10.5,declination=20.5,track=1", "command track=1"], [(10.5, 20.5)]),
        ("timestamp after the last field", ["command rightascension=10.5,declination=20.5,track=1 1700000000000000000"], [(10.5, 20.5)]),
        ("other measurement", ["status rightascension=10.5,declination=20.5,track=1"], []),
        ("track is the ninth field", ["command rightascension=10.5,declination=20.5,x1=0,x2=0,x3=0,x4=0,x5=0,x6=0,track=1"], []),
    ):
        h = Handler()
        for m in messages:
            h.handle(m)
        check(label, h.tracks, want)
    print("   all consistent with the TcUnit expectations" if ok else "   MISMATCH")
