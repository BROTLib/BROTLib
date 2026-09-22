"""Reference values for the BROTLibTests TcUnit suites (pure stdlib, no numpy/erfa needed).

Two jobs:
1. Validate the tracking formulas against an independent oracle: numerical derivatives of the
   HA/Dec -> Az/El transform (same equations as erfa.hd2ae / erfa.hd2pa), under sidereal motion.
2. Print the LREAL constants that BROTLibTests/.../FB_Tracking_Tests.TcPOU asserts against, at 17
   significant digits, so they can be regenerated after a formula change.

Run: python3 golden_vectors.py
"""
import math

OMEGA = 4.178074605556e-3  # deg/s, as in the ST (F_*velocity)
d2r = math.pi / 180.0
r2d = 180.0 / math.pi


# ---- the ST formulas, transcribed -------------------------------------------------------------
def az_vel(el, az, lat):
    if abs(math.cos(el * d2r)) > 1.0e-3:
        return (math.sin(lat * d2r) - math.cos(lat * d2r) * math.cos(az * d2r) * math.tan(el * d2r)) * OMEGA
    return 0.0


def el_vel(az, lat):
    return math.sin(az * d2r) * math.cos(lat * d2r) * OMEGA


def derot_vel(az, el, lat, sign=1.0):
    if abs(math.cos(el * d2r)) > 1.0e-3:
        base = (-OMEGA * math.cos(az * d2r) * math.cos(lat * d2r) / math.cos(el * d2r)
                - OMEGA * math.cos(lat * d2r) * math.sin(az * d2r))
        return base + (1.0 - sign) * el_vel(az, lat)
    return 0.0


def modabs(x, y):
    """TwinCAT MODABS: result in [0, y)."""
    return x - y * math.floor(x / y)


def derot_pos(az, el, lat, sign=1.0):
    a = modabs(az, 360.0) * d2r
    e = min(max(el, 0.0), 90.0) * d2r
    la = min(max(lat, -90.0), 90.0) * d2r
    q = -r2d * math.atan2(math.sin(a), math.tan(la) * math.cos(e) - math.sin(e) * math.cos(a))
    return modabs(q - sign * el, 360.0)


# ---- independent oracle -----------------------------------------------------------------------
def hd2ae(ha_deg, dec_deg, lat_deg):
    """HA/Dec -> Az (north through east) / El, degrees. Same equations as erfa.hd2ae."""
    ha, dec, phi = ha_deg * d2r, dec_deg * d2r, lat_deg * d2r
    x = -math.cos(ha) * math.cos(dec) * math.sin(phi) + math.sin(dec) * math.cos(phi)
    y = -math.sin(ha) * math.cos(dec)
    z = math.cos(ha) * math.cos(dec) * math.cos(phi) + math.sin(dec) * math.sin(phi)
    r = math.hypot(x, y)
    az = math.atan2(y, x) if r else 0.0
    if az < 0:
        az += 2 * math.pi
    return az * r2d, math.atan2(z, r) * r2d


def hd2pa(ha_deg, dec_deg, lat_deg):
    ha, dec, phi = ha_deg * d2r, dec_deg * d2r, lat_deg * d2r
    return math.atan2(math.cos(phi) * math.sin(ha),
                      math.sin(phi) * math.cos(dec) - math.cos(phi) * math.sin(dec) * math.cos(ha)) * r2d


def wrap180(x):
    return (x + 180.0) % 360.0 - 180.0


def validate():
    """Random sidereal-tracking states away from the zenith; central differences over +-1 s."""
    import random
    rng = random.Random(1)
    lat = 51.56
    worst = dict(az=0.0, el=0.0, derot_plus=0.0, derot_minus=0.0, pa=0.0)
    n = 0
    for _ in range(4000):
        ha, dec = rng.uniform(-180, 180), rng.uniform(-30, 89)
        az, el = hd2ae(ha, dec, lat)
        if not 10 < el < 80:
            continue
        n += 1
        az0, el0 = hd2ae(ha - OMEGA, dec, lat)
        az1, el1 = hd2ae(ha + OMEGA, dec, lat)
        worst["az"] = max(worst["az"], abs(wrap180(az1 - az0) / 2 - az_vel(el, az, lat)))
        worst["el"] = max(worst["el"], abs((el1 - el0) / 2 - el_vel(az, lat)))
        for s, key in ((1.0, "derot_plus"), (-1.0, "derot_minus")):
            num = wrap180(derot_pos(az1, el1, lat, s) - derot_pos(az0, el0, lat, s)) / 2
            worst[key] = max(worst[key], abs(num - derot_vel(az, el, lat, s)))
        q_st = -math.degrees(math.atan2(math.sin(az * d2r), math.tan(lat * d2r) * math.cos(el * d2r)
                                        - math.sin(el * d2r) * math.cos(az * d2r)))
        worst["pa"] = max(worst["pa"], abs(wrap180(q_st - hd2pa(ha, dec, lat))))
    print(f"oracle check over {n} random states, max |numerical - formula| (deg/s; pa in deg):")
    for k, v in worst.items():
        print(f"  {k:12s} {v:.2e}")


def g(x):
    return f"{x:.17g}"


def vectors():
    lat = 51.56
    print("\n// F_Azimuthvelocity(elevation, azimuth, latitude)")
    for el, az, la in ((0.0, 0.0, lat), (30.0, 200.0, lat), (60.0, 300.0, -30.0), (89.9, 45.0, lat)):
        print(f"//   ({el}, {az}, {la}) = {g(az_vel(el, az, la))}")
    print("// F_Elevationvelocity(azimuth, latitude)")
    for az, la in ((123.4, lat), (300.0, -30.0)):
        print(f"//   ({az}, {la}) = {g(el_vel(az, la))}")
    print("// F_Derotatorvelocity(azimuth, elevation, latitude, sign)")
    for az, el, la, s in ((200.0, 30.0, lat, 1.0), (300.0, 60.0, -30.0, 1.0),
                          (200.0, 30.0, lat, -1.0), (300.0, 60.0, -30.0, -1.0)):
        print(f"//   ({az}, {el}, {la}, {s}) = {g(derot_vel(az, el, la, s))}")
    print("// F_DerotatorPosition2(azimuth, elevation, latitude, sign)")
    for az, el, la, s in ((123.4, 56.7, lat, 1.0), (123.4, 56.7, lat, -1.0), (300.0, 20.0, -30.0, 1.0),
                          (-30.0, 45.0, lat, 1.0), (10.0, 95.0, lat, 1.0)):
        print(f"//   ({az}, {el}, {la}, {s}) = {g(derot_pos(az, el, la, s))}")
    print("// analytic anchors")
    print(f"//   OMEGA*sqrt(2)           = {g(OMEGA * math.sqrt(2))}")
    print(f"//   derot_pos(90,0,45)      = {g(derot_pos(90, 0, 45))}   (315)")
    print(f"//   derot_pos(270,0,45)     = {g(derot_pos(270, 0, 45))}  (45)")
    print(f"//   derot_pos(90,45,0)      = {g(derot_pos(90, 45, 0))}  (225)")


def pointing(az, el, aoff=0.0, bnp=0.0, an_a=0.0, ae_a=0.0, npae=0.0, eoff=0.0, an_e=0.0, ae_e=0.0, tf=0.0):
    """FB_PointingModelForward, transcribed (azimuth/elevation offsets in degrees)."""
    if el < 89.9:
        tan_el, cos_el = math.tan(el * d2r), math.cos(el * d2r)
    else:                                   # clamp used by the ST near the zenith
        tan_el, cos_el = 572.9572133543033, 0.0017453283658982613
    d_az = (aoff - bnp / cos_el + an_a * math.sin(az * d2r) * tan_el
            - ae_a * math.cos(az * d2r) * tan_el + npae * tan_el)
    d_el = eoff + an_e * math.cos(az * d2r) + ae_e * math.sin(az * d2r) + tf * math.cos(el * d2r)
    return d_az, d_el


def pointing_vectors():
    print("\n// FB_PointingModelForward, all nine terms non-zero at (az 123.4, el 56.7)")
    combined = dict(aoff=0.1, bnp=0.02, an_a=0.03, ae_a=-0.04, npae=0.05, eoff=-0.06, an_e=0.07, ae_e=-0.08, tf=0.09)
    d_az, d_el = pointing(123.4, 56.7, **combined)
    print(f"//   {combined}")
    print(f"//   fAzimuthOffset = {g(d_az)}   fElevationOffset = {g(d_el)}")
    print("// zenith clamp (el >= 89.9 uses tan = 572.957..., cos = 0.001745...)")
    print(f"//   NPAE 0.001 @ el 89.95 -> {g(pointing(10.0, 89.95, npae=0.001)[0])}")
    print(f"//   BNP  0.001 @ el 89.95 -> {g(pointing(10.0, 89.95, bnp=0.001)[0])}")
    print(f"//   BNP  0.001 @ el 90    -> {g(pointing(10.0, 90.0, bnp=0.001)[0])}")


if __name__ == "__main__":
    validate()
    vectors()
    pointing_vectors()
