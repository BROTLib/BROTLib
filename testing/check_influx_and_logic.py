"""Port of small pieces of BROTLib logic, to check what they actually do.

1. FB_Comm_MQTT_Influx.Publish field typing (F_IsNumericValue + 'i' suffix rule)
2. FB_Comm_MQTT_Influx.PublishLog / Publish line length vs STRING(255)
3. F_YREAL with an inverted output range and cut = TRUE
4. FB_InfoConnection.sDiag decoding (cascade of bit tests)
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
