"""FB_BLINK and FB_Horn: simulate the TOF chains exactly as written (10 ms PLC cycle).

TOF model: Q = IN while IN is TRUE; after the falling edge Q stays TRUE for PT.
Call order matters: the second block's IN expression sees the first block's *updated* Q.
Run: python3 check_blink_horn.py
"""
CYCLE = 10  # ms


class TOF:
    def __init__(self):
        self.Q = False
        self.prev = False
        self.t = 0
        self.timing = False

    def __call__(self, IN, PT):
        if IN:
            self.Q, self.timing = True, False
        else:
            if self.prev:            # falling edge: start timing, Q stays TRUE
                self.t, self.timing = 0, True
            elif self.timing:
                self.t += CYCLE
            if self.timing and self.t >= PT:
                self.Q, self.timing = False, False
        self.prev = IN
        return self.Q


def runs(samples):
    """list of (level, duration_ms) for a boolean sample stream"""
    out, cur, n = [], samples[0], 0
    for s in samples:
        if s == cur:
            n += 1
        else:
            out.append((cur, n * CYCLE)); cur, n = s, 1
    out.append((cur, n * CYCLE))
    return out


def blink(on_ms, off_ms, cycles=1000):
    imp, pause, q = TOF(), TOF(), []
    for _ in range(cycles):
        imp(not pause.Q and not imp.Q, on_ms)
        pause(not pause.Q and not imp.Q, off_ms)   # sees updated imp.Q, as in the ST
        q.append(imp.Q)
    return q


def horn(on_ms, off_ms, cycles=1000):
    imp, pause, q = TOF(), TOF(), []
    for _ in range(cycles):
        imp(not pause.Q and not imp.Q, on_ms)
        pause(not pause.Q and not imp.Q, off_ms)   # sees updated imp.Q, as in the ST
        q.append(imp.Q)
    return q


if __name__ == "__main__":
    print("FB_BLINK: expected ON/OFF (ms) -> simulated steady-state runs [(level, ms), ...]")
    for name, on, off in (("slow", 500, 500), ("fast", 250, 250), ("short", 100, 900), ("long", 900, 100)):
        r = runs(blink(on, off, 600))[2:6]
        print(f"  {name:5s} {on:4d}/{off:<4d} -> {[(int(l), d) for l, d in r]}")
    print("\nFB_Horn: symmetric ON/OFF per mode (beep 500 ms, short 3 s, long 5 s)")
    for name, on in (("beep", 500), ("short", 3000), ("long", 5000)):
        r = runs(horn(on, on, 1500))[:5]
        print(f"  {name:5s} -> {[(int(l), d) for l, d in r]}")
