#!/usr/bin/env python3
"""Validate the Kepler solver in tools/build_minor_bodies.py.

Two independent checks:

1. SOLVER MATH vs JPL Horizons (no network needed — reference data is
   baked in below, fetched 2026-10-05): JPL's own full-precision
   osculating elements (Horizons EPHEM_TYPE=ELEMENTS, epoch 2026-10-04
   TDB) are fed through THIS solver and compared with Horizons'
   geocentric RA/Dec (EPHEM_TYPE=OBSERVER, CENTER=500@399) at
   2026-10-05 / 10-15 / 10-25. Same elements on both sides, so any
   residual is solver error alone. Target: < 60 arcsec.

2. REAL-WORLD STALENESS (needs --mpc and --horizons files): the MPC
   Soft03Cmt.txt snapshot elements through this solver vs Horizons.
   Residuals here are dominated by the ELEMENTS (MPC osculating
   snapshot vs JPL's fitted orbit), not the solver — this is the honest
   number behind the app's STALE warning.

3. SELF-CONSISTENCY (no network): circular e=0 hand-check (quarter
   period -> true anomaly exactly 90 deg, r == a), branch continuity
   across e=1 (elliptic/Barker/hyperbolic agree to < 1 arcsec), Newton
   residuals < 1e-10.

Usage::

    python3 tools/validate_kepler.py [--mpc Soft03Cmt.txt \\
        --horizons 12P=h12p.txt 161P=h161p.txt 3I=h3i.txt]
"""

import argparse
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_minor_bodies import (parse_mpc, solve_orbit, geocentric_radec,
                                _newton_elliptic, _newton_hyperbolic)

AU_KM = 149597870.700

# JPL Horizons full-precision osculating elements, epoch 2026-10-04 TDB,
# fetched 2026-10-05 via EPHEM_TYPE=ELEMENTS, CENTER=500@10.
# (name, e, q_au, tp_jd, node_deg, peri_deg, incl_deg)
JPL_ELEMENTS = {
    "12P": ("12P/Pons-Brooks", 0.9547889682117366,
            1.169771298447315e8 / AU_KM, 2460421.703232776839,
            255.8673822784870, 199.0383736525972, 74.14823924830149),
    "3I": ("3I/ATLAS", 6.123796914303071,
           2.022615820574696e8 / AU_KM, 2460977.945146910381,
           323.0241769651266, 128.7968533044968, 175.2401071482720),
}

# Horizons OBSERVER RA/Dec (deg, geocentric, CENTER=500@399),
# fetched 2026-10-05 for the JDs below.
JDS = [2461318.5, 2461328.5, 2461338.5]
JPL_REF = {
    "12P": [(243.73303, -31.25993), (244.63741, -31.12516),
            (245.64692, -31.03007)],
    "3I": [(108.31425, 19.26631), (107.94771, 19.25076),
           (107.44649, 19.25210)],
}


def angular_sep_arcsec(ra1, dec1, ra2, dec2):
    r1, d1, r2, d2 = map(math.radians, (ra1, dec1, ra2, dec2))
    c = (math.sin(d1) * math.sin(d2)
         + math.cos(d1) * math.cos(d2) * math.cos(r1 - r2))
    return math.degrees(math.acos(min(1.0, max(-1.0, c)))) * 3600.0


def check_solver_vs_horizons():
    """Same JPL elements both sides: residual == solver error."""
    print("== solver math vs JPL Horizons (JPL elements both sides) ==")
    worst = 0.0
    for key, (name, e, q, tp, node, peri, incl) in JPL_ELEMENTS.items():
        for jd, (ra_ref, dec_ref) in zip(JDS, JPL_REF[key]):
            ra, dec, _, _ = geocentric_radec(e, q, tp, node, peri, incl, jd)
            err = angular_sep_arcsec(ra, dec, ra_ref, dec_ref)
            worst = max(worst, err)
            print("  %-16s jd=%.1f  err=%6.2f arcsec" % (name, jd, err))
    print("max solver error: %.2f arcsec" % worst)
    return worst


def parse_horizons_file(path):
    rows = []
    in_data = False
    for line in open(path):
        if "$$SOE" in line:
            in_data = True
            continue
        if "$$EOE" in line:
            break
        if in_data:
            m = re.match(r"\s*(\d{4})-(\w{3})-(\d{2}) \d{2}:\d{2}"
                         r"\s+([\d.]+)\s+([-\d.]+)", line)
            if not m:
                continue
            mon = {"Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5,
                   "Jun": 6, "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10,
                   "Nov": 11, "Dec": 12}[m.group(2)]
            a, b = int(m.group(1)), mon
            if b <= 2:
                a -= 1
                b += 12
            c = a // 100
            jd = (int(365.25 * (a + 4716)) + int(30.6001 * (b + 1))
                  + float(m.group(3)) + 2 - c + c // 4 - 1524.5)
            rows.append((jd, float(m.group(4)), float(m.group(5))))
    return rows


def check_snapshot_staleness(mpc_path, horizons_map):
    """MPC snapshot elements vs Horizons: residual == element error."""
    elems = {e["name"]: e for e in parse_mpc(open(mpc_path).read())}
    name_for = {"12P": "12P/Pons-Brooks", "161P": "161P/Hartley-IRAS",
                "3I": "3I/ATLAS"}
    print("== MPC snapshot elements vs Horizons (element staleness) ==")
    worst = 0.0
    for key, path in horizons_map.items():
        el = elems[name_for[key]]
        age = (JDS[0] - el["epochJD"])
        for jd, ra_ref, dec_ref in parse_horizons_file(path):
            ra, dec, _, _ = geocentric_radec(
                el["e"], el["q_au"], el["tp_jd"], el["node_deg"],
                el["peri_deg"], el["incl_deg"], jd)
            err = angular_sep_arcsec(ra, dec, ra_ref, dec_ref)
            worst = max(worst, err)
            print("  %-16s epoch age %5.0f d  err=%8.1f arcsec"
                  % (key, age, err))
    print("max snapshot error: %.1f arcsec" % worst)
    return worst


def check_self_consistency():
    print("== self-consistency ==")
    a, jd0 = 2.0, 2460000.0
    period = 2.0 * math.pi / (0.01720209895 / a ** 1.5)
    v, r = solve_orbit(0.0, a, jd0, jd0 + period / 4.0)
    print("  circular e=0: v=%.6f deg (want 90), r=%.9f (want %s)"
          % (math.degrees(v), r, a))
    assert abs(math.degrees(v) - 90.0) < 1e-9 and abs(r - a) < 1e-9

    vs = []
    for e in (1.0 - 1e-7, 1.0, 1.0 + 1e-7):
        v, r = solve_orbit(e, 1.0, jd0, jd0 + 10.0)
        vs.append((math.degrees(v), r))
    spread_v = max(v[0] for v in vs) - min(v[0] for v in vs)
    print("  e=1 continuity: dv=%.2e deg" % spread_v)
    assert spread_v * 3600.0 < 1.0

    worst = 0.0
    for e in (0.0, 0.2, 0.6, 0.9, 0.99):
        for k in range(24):
            M = -math.pi + k * (2.0 * math.pi / 24)
            E = _newton_elliptic(M, e)
            worst = max(worst, abs(E - e * math.sin(E) - M))
    for e in (1.1, 2.0, 6.14):
        for M in (-3.0, -0.5, 0.0, 0.5, 3.0):
            F = _newton_hyperbolic(M, e)
            worst = max(worst, abs(e * math.sinh(F) - F - M))
    print("  Newton residual: %.2e (want < 1e-10)" % worst)
    assert worst < 1e-10
    print("  all self-consistency checks passed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mpc", default=None)
    ap.add_argument("--horizons", nargs="+", default=[],
                    help="KEY=path pairs, e.g. 12P=/tmp/horizons_12p.txt")
    args = ap.parse_args()

    worst = check_solver_vs_horizons()
    ok = worst < 60
    print("SOLVER: max %.2f arcsec (%s)" % (worst, "PASS < 60" if ok
                                            else "FAIL >= 60"))
    if args.mpc and args.horizons:
        hmap = dict(a.split("=", 1) for a in args.horizons)
        check_snapshot_staleness(args.mpc, hmap)
    check_self_consistency()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
