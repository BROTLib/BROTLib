"""FB_PointingModelForward / FB_PointingModelInversion: does the 11-step fixed-point
inversion converge? Line-by-line port of the ST. Needs numpy only.

Coefficients: MONETN calibration from TRACKING.md (degrees), AOFF = EOFF = 0.
Run: python3 check_pointing_inversion.py
"""
import numpy as np

d2r = np.pi / 180.0
C = dict(AOFF=0.0, BNP=0.417996, AN_A=-0.000540, AE_A=0.001094, NPAE=0.354092,
         EOFF=0.0, AN_E=-0.001539, AE_E=0.002838, TF=0.075394)


def forward(az, el, c=C):
    if el < 89.9:
        tan_el, cos_el = np.tan(el * d2r), np.cos(el * d2r)
    else:  # clamp as in the ST
        tan_el, cos_el = 572.9572133543033, 0.0017453283658982613
    saz, caz = np.sin(az * d2r), np.cos(az * d2r)
    d_az = (c["AOFF"] - c["BNP"] / cos_el + c["AN_A"] * saz * tan_el
            - c["AE_A"] * caz * tan_el + c["NPAE"] * tan_el)
    d_el = c["EOFF"] + c["AN_E"] * caz + c["AE_E"] * saz + c["TF"] * np.cos(el * d2r)
    return d_az, d_el


def inversion(az, el, n=11, c=C):
    d_az = d_el = 0.0
    for _ in range(n + 0):          # FOR i := 0 TO 10  -> 11 passes
        d_az, d_el = forward(az - d_az, el - d_el, c)
    return d_az, d_el


def residual_arcsec(az, el, c=C):
    """Fixed-point residual of the returned offsets, as sky separation (az * cos el)."""
    d_az, d_el = inversion(az, el, c=c)
    f_az, f_el = forward(az - d_az, el - d_el, c)
    return 3600.0 * np.hypot((d_az - f_az) * np.cos(el * d2r), d_el - f_el)


if __name__ == "__main__":
    azs = np.arange(0, 360, 5.0)
    print("MONETN coefficients, residual of the 11-step inversion (arcsec on sky, worst over azimuth)")
    print(" el[deg]   worst residual   forward az-offset at that el (deg, worst az)")
    for el in (10, 30, 50, 60, 70, 75, 80, 83, 85, 87, 89, 89.5):
        r = max(residual_arcsec(a, el) for a in azs)
        fo = max(abs(forward(a, el)[0]) for a in azs)
        print(f" {el:6.1f}   {r:12.3f}\"   {fo:8.3f}")
    print("\nSame with all coefficients scaled by 0.1 (a well-aligned mount)")
    c = {k: v * 0.1 for k, v in C.items()}
    for el in (60, 80, 85, 87, 89):
        r = max(residual_arcsec(a, el, c) for a in azs)
        print(f" {el:6.1f}   {r:12.3f}\"")
    print("\nIterations needed for < 0.1\" (MONETN coefficients, worst azimuth)")
    for el in (30, 60, 75, 80, 85):
        worst = 0
        for a in azs:
            for n in range(1, 200):
                d = inversion(a, el, n=n)
                f = forward(a - d[0], el - d[1])
                if 3600 * np.hypot((d[0] - f[0]) * np.cos(el * d2r), d[1] - f[1]) < 0.1:
                    break
            worst = max(worst, n)
        print(f" el={el:3d}: {worst} iterations" + ("  (never converged)" if worst == 199 else ""))

    print("\nNear zenith (clamp at 89.9 deg in the forward model), worst azimuth")
    for el in (89.5, 89.8, 89.9, 89.99):
        r = max(residual_arcsec(a, el) for a in np.arange(0, 360, 1.0))
        fo = max(abs(forward(a, el)[0]) for a in np.arange(0, 360, 1.0))
        print(f" el={el:6.2f}: residual {r:.3f}\", forward az-offset {fo:.1f} deg")
