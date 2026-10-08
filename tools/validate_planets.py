#!/usr/bin/env python3
"""Validate the Schlyter planet-position implementation against JPL Horizons.

Implements Paul Schlyter's "How to compute planetary positions"
(http://stjarnhimlen.se/comp/ppcomp.html) exactly as ported to Swift in
Sources/AstroTonight/Planets.swift, then compares geocentric RA/Dec of all
8 planets at 3 widely-spaced timestamps against the JPL Horizons API
(apparent RA/Dec, observer table, geocentric center 500@399).

Pass criterion: angular separation < 2 arcminutes per body per timestamp.

Note: Schlyter computes a *geometric* position for the mean equinox of the
day and deliberately ignores light-time, aberration and nutation (all
sub-arcminute-to-arcminute effects), so a small residual against Horizons'
*apparent* coordinates is expected and honest.
"""

import math
import sys
import urllib.parse
import urllib.request

D2R = math.pi / 180.0
R2D = 180.0 / math.pi

# Orbital elements: (N0, Ndot, i0, idot, w0, wdot, a0, adot, e0, edot,
#                     M0, Mdot) with angles in degrees and d in days since
# 2000 Jan 0.0 (i.e. d = JD - 2451543.5). Values transcribed from
# Schlyter section 4.
ELEMENTS = {
    # Sun entry = Earth's orbital elements (Schlyter section 5).
    "sun":   (0.0, 0.0, 0.0, 0.0, 282.9404, 4.70935e-5, 1.000000, 0.0,
              0.016709, -1.151e-9, 356.0470, 0.9856002585),
    "mercury": (48.3313, 3.24587e-5, 7.0047, 5.00e-8, 29.1241, 1.01444e-5,
                0.387098, 0.0, 0.205635, 5.59e-10, 168.6562, 4.0923344368),
    "venus": (76.6799, 2.46590e-5, 3.3946, 2.75e-8, 54.8910, 1.38374e-5,
              0.723330, 0.0, 0.006773, -1.302e-9, 48.0052, 1.6021302244),
    "earth": (0.0, 0.0, 0.0, 0.0, 282.9404, 4.70935e-5, 1.000000, 0.0,
              0.016709, -1.151e-9, 356.0470, 0.9856002585),
    "mars":  (49.5574, 2.11081e-5, 1.8497, -1.78e-8, 286.5016, 2.92961e-5,
              1.523688, 0.0, 0.093405, 2.516e-9, 18.6021, 0.5240207766),
    "jupiter": (100.4542, 2.76854e-5, 1.3030, -1.557e-7, 273.8777,
                1.64505e-5, 5.20256, 0.0, 0.048498, 4.469e-9,
                19.8950, 0.0830853001),
    "saturn": (113.6634, 2.38980e-5, 2.4886, -1.081e-7, 339.3939,
               2.97661e-5, 9.55475, 0.0, 0.055546, -9.499e-9,
               316.9670, 0.0334442282),
    "uranus": (74.0005, 1.3978e-5, 0.7733, 1.9e-8, 96.6612, 3.0565e-5,
               19.18171, -1.55e-8, 0.047318, 7.45e-9, 142.5905, 0.011725806),
    "neptune": (131.7806, 3.0173e-5, 1.7700, -2.55e-7, 272.8461, -6.027e-6,
                30.05826, 3.313e-8, 0.008606, 2.15e-9, 260.2471,
                0.005995147),
}


def norm360(x):
    v = x % 360.0
    return v


def kepler_e(M_rad, e):
    """Eccentric anomaly from mean anomaly (radians), Schlyter sec. 6."""
    E = M_rad + e * math.sin(M_rad) * (1.0 + e * math.cos(M_rad))
    for _ in range(25):
        E1 = E - (E - e * math.sin(E) - M_rad) / (1.0 - e * math.cos(E))
        if abs(E1 - E) < 1e-11:
            E = E1
            break
        E = E1
    return E


def helio(body, d):
    """Heliocentric ecliptic position (AU): returns
    (xh, yh, zh, r, lonecl_deg, latecl_deg, M_deg)."""
    N0, Nd, i0, id_, w0, wd, a0, ad, e0, ed, M0, Md = ELEMENTS[body]
    N = norm360(N0 + Nd * d)
    i = norm360(i0 + id_ * d)
    w = norm360(w0 + wd * d)
    a = a0 + ad * d
    e = e0 + ed * d
    M = norm360(M0 + Md * d)
    E = kepler_e(M * D2R, e)
    xv = a * (math.cos(E) - e)
    yv = a * (math.sqrt(1.0 - e * e) * math.sin(E))
    v = math.atan2(yv, xv)
    r = math.hypot(xv, yv)
    Nr, ir, wr = N * D2R, i * D2R, w * D2R
    vw = v + wr
    xh = r * (math.cos(Nr) * math.cos(vw)
              - math.sin(Nr) * math.sin(vw) * math.cos(ir))
    yh = r * (math.sin(Nr) * math.cos(vw)
              + math.cos(Nr) * math.sin(vw) * math.cos(ir))
    zh = r * math.sin(vw) * math.sin(ir)
    lonecl = norm360(math.atan2(yh, xh) * R2D)
    latecl = math.atan2(zh, math.hypot(xh, yh)) * R2D
    return xh, yh, zh, r, lonecl, latecl, M


def apply_perturbations(body, lonecl, latecl, Mj, Ms, Mu):
    """Schlyter section 10: longitude/latitude perturbation terms for
    Jupiter, Saturn, Uranus (degrees)."""
    lon = lonecl
    lat = latecl
    s = math.sin
    c = math.cos
    if body == "jupiter":
        lon += (-0.332 * s(D2R * (2 * Mj - 5 * Ms - 67.6))
                - 0.056 * s(D2R * (2 * Mj - 2 * Ms + 21.0))
                + 0.042 * s(D2R * (3 * Mj - 5 * Ms + 21.0))
                - 0.036 * s(D2R * (Mj - 2 * Ms))
                + 0.022 * c(D2R * (Mj - Ms))
                + 0.023 * s(D2R * (2 * Mj - 3 * Ms + 52.0))
                - 0.016 * s(D2R * (Mj - 5 * Ms - 69.0)))
    elif body == "saturn":
        lon += (+0.812 * s(D2R * (2 * Mj - 5 * Ms - 67.6))
                - 0.229 * c(D2R * (2 * Mj - 4 * Ms - 2.0))
                + 0.119 * s(D2R * (Mj - 2 * Ms - 3.0))
                + 0.046 * s(D2R * (2 * Mj - 6 * Ms - 69.0))
                + 0.014 * s(D2R * (Mj - 3 * Ms + 32.0)))
        lat += (-0.020 * c(D2R * (2 * Mj - 4 * Ms - 2.0))
                + 0.018 * s(D2R * (2 * Mj - 6 * Ms - 49.0)))
    elif body == "uranus":
        lon += (+0.040 * s(D2R * (Ms - 2 * Mu + 6.0))
                + 0.035 * s(D2R * (Ms - 3 * Mu + 33.0))
                - 0.015 * s(D2R * (Mj - Mu + 20.0)))
    return lon, lat


def position(body, jd):
    """Geocentric RA/Dec in degrees, matching Swift PlanetMath.position."""
    d = jd - 2451543.5
    ecl = 23.4393 - 3.563e-7 * d
    # Sun's geocentric ecliptic position: for the Sun's orbital elements
    # (N=0, i=0) the heliocentric ecliptic longitude equals lonsun and
    # the latitude is zero, so lonecl/rs come straight from helio().
    _, _, _, rs, lonsun, _, _ = helio("sun", d)
    xs = rs * math.cos(lonsun * D2R)
    ys = rs * math.sin(lonsun * D2R)
    if body == "earth":
        xg, yg, zg = xs, ys, 0.0
    else:
        xh, yh, zh, r, lonecl, latecl, M = helio(body, d)
        _, _, _, _, _, _, Mj = helio("jupiter", d)
        _, _, _, _, _, _, Ms = helio("saturn", d)
        _, _, _, _, _, _, Mu = helio("uranus", d)
        lonecl, latecl = apply_perturbations(body, lonecl, latecl,
                                             Mj, Ms, Mu)
        xh = r * math.cos(lonecl * D2R) * math.cos(latecl * D2R)
        yh = r * math.sin(lonecl * D2R) * math.cos(latecl * D2R)
        zh = r * math.sin(latecl * D2R)
        xg = xh + xs
        yg = yh + ys
        zg = zh
    er = ecl * D2R
    xe = xg
    ye = yg * math.cos(er) - zg * math.sin(er)
    ze = yg * math.sin(er) + zg * math.cos(er)
    ra = norm360(math.atan2(ye, xe) * R2D)
    dec = math.atan2(ze, math.hypot(xe, ye)) * R2D
    return ra, dec


def ang_sep(ra1, dec1, ra2, dec2):
    r1, d1, r2, d2 = (x * D2R for x in (ra1, dec1, ra2, dec2))
    c = (math.sin(d1) * math.sin(d2)
         + math.cos(d1) * math.cos(d2) * math.cos(r1 - r2))
    c = min(1.0, max(-1.0, c))
    return math.acos(c) * R2D


HORIZONS = "https://ssd.jpl.nasa.gov/api/horizons.api"
# Horizons command IDs; Earth is validated via the Sun's geocentric
# position (command '10'), matching PlanetMath's .earth behavior.
COMMAND = {
    "mercury": "199", "venus": "299", "earth": "10", "mars": "499",
    "jupiter": "599", "saturn": "699", "uranus": "799", "neptune": "899",
}


def add_minute(iso):
    import datetime
    dt = datetime.datetime.strptime(iso, "%Y-%m-%d %H:%M")
    dt += datetime.timedelta(minutes=1)
    return dt.strftime("%Y-%m-%d %H:%M")


def horizons_radec(body, start_utc):
    params = {
        "format": "text",
        "COMMAND": COMMAND[body],
        "OBJ_DATA": "NO",
        "MAKE_EPHEM": "YES",
        "EPHEM_TYPE": "OBSERVER",
        "CENTER": "500@399",
        "START_TIME": start_utc,
        "STOP_TIME": add_minute(start_utc),
        "STEP_SIZE": "1m",
        "QUANTITIES": "2",  # Apparent RA & DEC (true equinox of date)
        "CAL_FORMAT": "CAL",
        "ANG_FORMAT": "DEG",
        "CSV_FORMAT": "YES",
    }
    url = HORIZONS + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "AstroTonight/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        text = resp.read().decode("utf-8", errors="replace")
    if "$$SOE" not in text or "$$EOE" not in text:
        raise RuntimeError(f"Horizons returned no ephemeris for {body}:\n"
                           + text[:2000])
    head, rest = text.split("$$SOE", 1)
    data = rest.split("$$EOE", 1)[0].strip().splitlines()
    header = [ln for ln in head.strip().splitlines()
              if ln.strip().startswith("Datetime") or
              ln.strip().startswith("Date")][-1]
    cols = [c.strip() for c in header.split(",")]
    try:
        ra_i = next(i for i, c in enumerate(cols) if "R.A" in c)
        dec_i = next(i for i, c in enumerate(cols) if "DEC" in c)
    except StopIteration:
        raise RuntimeError(f"could not find RA/DEC columns in: {header}")
    if "app" not in cols[ra_i].lower():
        raise RuntimeError(f"quantity is not apparent: {header}")
    row = [c.strip() for c in data[0].split(",")]
    return float(row[ra_i]), float(row[dec_i])


def jd_from_utc(iso):
    # iso like "2026-01-15 00:00"
    import calendar
    import datetime
    dt = datetime.datetime.strptime(iso, "%Y-%m-%d %H:%M")
    dt = dt.replace(tzinfo=datetime.timezone.utc)
    return calendar.timegm(dt.timetuple()) / 86400.0 + 2440587.5


def main():
    stamps = ["2026-01-15 00:00", "2026-06-01 00:00", "2026-10-08 00:00"]
    bodies = ["mercury", "venus", "earth", "mars",
              "jupiter", "saturn", "uranus", "neptune"]
    max_err = {b: 0.0 for b in bodies}
    print(f"{'body':<9}{'2026-01-15':>12}{'2026-06-01':>12}"
          f"{'2026-10-08':>12}{'max':>10}")
    for body in bodies:
        errs = []
        for ts in stamps:
            ra_s, dec_s = position(body, jd_from_utc(ts))
            ra_h, dec_h = horizons_radec(body, ts)
            err_arcmin = ang_sep(ra_s, dec_s, ra_h, dec_h) * 60.0
            errs.append(err_arcmin)
        max_err[body] = max(errs)
        print(f"{body:<9}" + "".join(f"{e:>11.2f}'" for e in errs)
              + f"{max_err[body]:>9.2f}'")
    print()
    worst = max(max_err.values())
    limit = 2.0
    if worst < limit:
        print(f"PASS: worst error {worst:.2f}' < {limit}' for all bodies.")
        return 0
    bad = [b for b in bodies if max_err[b] >= limit]
    print(f"FAIL: {bad} exceed {limit}'.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
