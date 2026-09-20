"""F_Azimuthvelocity / F_Elevationvelocity / F_Derotatorvelocity / F_DerotatorPosition2
against numerical derivatives of erfa's HA/Dec -> Az/El transform (pyerfa).

Sidereal tracking: HA advances at OMEGA deg/s, Dec is fixed. Az/El from erfa.hd2ae
(Az from north through east, as in the ST). Run: python3 check_tracking_functions.py
"""
import numpy as np
import erfa

d2r = np.pi / 180.0
OMEGA = 4.178074605556e-3  # deg/s, as in the ST
LAT = 51.56                # Goettingen; result does not depend on it qualitatively


def az_vel(el, az, lat):
    if abs(np.cos(el * d2r)) > 1e-3:
        return (np.sin(lat * d2r) - np.cos(lat * d2r) * np.cos(az * d2r) * np.tan(el * d2r)) * OMEGA
    return 0.0


def el_vel(az, lat):
    return np.sin(az * d2r) * np.cos(lat * d2r) * OMEGA


def derot_vel(el, az, lat):
    if abs(np.cos(el * d2r)) > 1e-3:
        return (-OMEGA * np.cos(az * d2r) * np.cos(lat * d2r) / np.cos(el * d2r)
                - OMEGA * np.cos(lat * d2r) * np.sin(az * d2r))
    return 0.0


def derot_pos(az, el, lat, sign=1.0):
    """F_DerotatorPosition2 without the unused declination input."""
    a = (az % 360.0) * d2r
    e = np.clip(el, 0, 90) * d2r
    la = np.clip(lat, -90, 90) * d2r
    q = -np.degrees(np.arctan2(np.sin(a), np.tan(la) * np.cos(e) - np.sin(e) * np.cos(a)))
    return (q - sign * el) % 360.0


def azel(ha_deg, dec_deg, lat_deg):
    az, el = erfa.hd2ae(ha_deg * d2r, dec_deg * d2r, lat_deg * d2r)
    return np.degrees(az), np.degrees(el)


def wrap180(x):
    return (x + 180.0) % 360.0 - 180.0


if __name__ == "__main__":
    rng = np.random.default_rng(1)
    dt = 1.0  # s, central difference
    err = {"az": [], "el": [], "der+": [], "der-": []}
    worst_pos = 0.0
    for _ in range(4000):
        ha = rng.uniform(-180, 180)
        dec = rng.uniform(-30, 89)
        az0, el0 = azel(ha - OMEGA * dt, dec, LAT)
        az1, el1 = azel(ha + OMEGA * dt, dec, LAT)
        az, el = azel(ha, dec, LAT)
        if not (10 < el < 80):
            continue
        err["az"].append(wrap180(az1 - az0) / (2 * dt) - az_vel(el, az, LAT))
        err["el"].append((el1 - el0) / (2 * dt) - el_vel(az, LAT))
        for s, key in ((1.0, "der+"), (-1.0, "der-")):
            num = wrap180(derot_pos(az1, el1, LAT, s) - derot_pos(az0, el0, LAT, s)) / (2 * dt)
            err[key].append(num - derot_vel(el, az, LAT))
        # parallactic angle: ST formula vs erfa.hd2pa
        q_erfa = np.degrees(erfa.hd2pa(ha * d2r, dec * d2r, LAT * d2r))
        q_st = -np.degrees(np.arctan2(np.sin(az * d2r), np.tan(LAT * d2r) * np.cos(el * d2r)
                                      - np.sin(el * d2r) * np.cos(az * d2r)))
        worst_pos = max(worst_pos, abs(wrap180(q_st - q_erfa)))
    print("max |numerical derivative - ST formula|, deg/s (10 < el < 80, sidereal rate is 0.00418)")
    for k, v in err.items():
        print(f"  {k:5s} {np.max(np.abs(v)):.2e}")
    print(f"ST parallactic angle (with its leading minus) vs erfa.hd2pa: max |q_ST - q_erfa| = {worst_pos:.2e} deg")

    print("\nBehaviour at the cos(el) > 1e-3 guard (Az velocity in deg/s, lat %.2f, az=45):" % LAT)
    for el in (89.0, 89.9, 89.94, 89.95, 89.99):
        print(f"  el={el:6.2f}  cos={np.cos(el*d2r):.2e}  az_vel={az_vel(el, 45.0, LAT):+.3f}  "
              f"derot_vel={derot_vel(el, 45.0, LAT):+.3f}")
