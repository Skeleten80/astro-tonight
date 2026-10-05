#!/usr/bin/env python3
"""One-shot builder for AstroTonight's vendored bright-comet snapshot.

Downloads the Minor Planet Center's comet orbital elements
(``Soft03Cmt.txt`` — the xephem-format feed), parses the MPC records,
solves each orbit for the fetch date, ranks by estimated apparent total
magnitude, and writes the brightest few to
``Sources/AstroTonight/Resources/comets.json``.

This is a *build* tool, not a runtime dependency — rerun it only when
you want to refresh the vendored snapshot::

    python3 tools/build_minor_bodies.py [--input Soft03Cmt.txt] [--top 10]

Data source (recorded here per project convention):

* Minor Planet Center, "Orbital Elements: Comets" (xephem feed),
  fetched 2026-10-05 (Last-Modified: Mon, 05 Oct 2026 08:15:51 GMT)::

      https://www.minorplanetcenter.net/iau/Ephemerides/Comets/Soft03Cmt.txt

  MPC data is made available for personal use; the magnitude parameters
  are explicitly flagged uncertain by the MPC.

MPC record layout (verified against known orbits — 12P/Pons-Brooks and
1P/Halley — not just the docs page, because the docs page only says
"information on the MPC's format is here" and links the data file):

* elliptic ``name,e,Incl,Node,Peri,a,n,e,M,Epoch,Equinox,H,G``
  (inclination FIRST — the non-obvious field order; confirmed by
  matching 12P's node=255.8675 / peri=199.0349 against published values)
* hyperbolic ``name,h,Tp,Incl,Node,Peri,e,q,Equinox,H[,G]``
  (G is occasionally absent, e.g. older records — then it is null)

Selection rule (documented so the Swift refresh path can mirror it):
keep records whose element epoch is within 400 days of the fetch date,
estimate the current apparent total magnitude with the standard comet
law ``m = H + 5*log10(Delta) + 2.5*G*log10(r)``, keep the ``--top``
brightest with m <= 16. Records without both H and G get no magnitude
estimate and are skipped.

JSON schema (must decode with ``CometElements`` in
``Sources/AstroTonight/MinorBodies.swift``):

* ``source_url`` / ``fetched_utc``: provenance of this snapshot
* ``objects``: array of
  ``name, epochJD, e, q_au, tp_jd, node_deg, peri_deg, incl_deg, H, G``
  where ``epochJD`` is the element epoch, ``q_au`` the perihelion
  distance, ``tp_jd`` the perihelion-passage Julian date, and H/G the
  MPC total-magnitude parameters (null when absent).

The Kepler solver below is the reference implementation that
``tools/validate_kepler.py`` checks against JPL Horizons, and that
``MinorBodies.swift`` mirrors branch-for-branch.
"""

import argparse
import datetime
import json
import math
import os
import re
import sys
import urllib.request

MPC_URL = ("https://www.minorplanetcenter.net/iau/Ephemerides/Comets/"
           "Soft03Cmt.txt")
# Gaussian gravitational constant, rad/day (AU, day, solar-mass units).
K_GAUSS = 0.01720209895
# Near-parabolic window: |e - 1| below this uses Barker's equation.
PARABOLIC_EPS = 1e-6
# Freshness window for the snapshot, days.
FRESH_DAYS = 400.0
# Faintest estimated magnitude admitted to the bundle.
MAX_MAG = 16.0

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT_PATH = os.path.join(REPO, "Sources", "AstroTonight", "Resources",
                        "comets.json")


# --------------------------------------------------------------------------
# Time

def epoch_str_to_jd(s):
    """``10/04.0/2026`` -> Julian date (Meeus algorithm)."""
    m = re.match(r"\s*(\d+)/([\d.]+)/(\d+)\s*$", s)
    if not m:
        raise ValueError("bad epoch %r" % s)
    y, mo, d = int(m.group(3)), int(m.group(1)), float(m.group(2))
    if mo <= 2:
        y -= 1
        mo += 12
    a = y // 100
    b = 2 - a + a // 4
    return (int(365.25 * (y + 4716)) + int(30.6001 * (mo + 1))
            + d + b - 1524.5)


def now_jd():
    return (datetime.datetime.now(datetime.timezone.utc).timestamp()
            / 86400.0 + 2440587.5)


# --------------------------------------------------------------------------
# Kepler solver (reference implementation; mirrored in MinorBodies.swift)

def _newton_elliptic(mean_anom, e):
    """Solve E - e*sin(E) = M. M in radians, normalized to [-pi, pi]."""
    E = mean_anom + e * math.sin(mean_anom)
    for _ in range(50):
        step = (E - e * math.sin(E) - mean_anom) / (1.0 - e * math.cos(E))
        E -= step
        if abs(step) < 1e-13:
            break
    return E


def _newton_hyperbolic(mean_anom, e):
    """Solve e*sinh(F) - F = M for e > 1."""
    F = math.asinh(mean_anom / e)
    for _ in range(50):
        step = ((e * math.sinh(F) - F - mean_anom)
                / (e * math.cosh(F) - 1.0))
        F -= step
        if abs(step) < 1e-13:
            break
    return F


def _barker_bracket(jd, tp_jd, q):
    """Parabolic branch (Barker's equation): returns (true_anom, r)."""
    # tan(v/2) + tan^3(v/2)/3 = 2*k*(t-Tp) / (2q)^1.5
    B = 2.0 * K_GAUSS * (jd - tp_jd) / (2.0 * q) ** 1.5
    S = B  # S = tan(v/2); B itself is a fine Newton start
    for _ in range(50):
        step = (S + S ** 3 / 3.0 - B) / (1.0 + S * S)
        S -= step
        if abs(step) < 1e-13:
            break
    return 2.0 * math.atan(S), q * (1.0 + S * S)


def solve_orbit(e, q, tp_jd, jd):
    """True anomaly (rad) and heliocentric distance (AU) at ``jd``.

    Three explicit branches: elliptic (e < 1), near-parabolic
    (|e-1| <= 1e-6, Barker), hyperbolic (e > 1)."""
    if abs(e - 1.0) <= PARABOLIC_EPS:
        return _barker_bracket(jd, tp_jd, q)
    if e < 1.0:
        a = q / (1.0 - e)
        n = K_GAUSS / a ** 1.5
        M = (n * (jd - tp_jd) + math.pi) % (2.0 * math.pi) - math.pi
        E = _newton_elliptic(M, e)
        v = 2.0 * math.atan2(math.sqrt(1.0 + e) * math.sin(E / 2.0),
                             math.sqrt(1.0 - e) * math.cos(E / 2.0))
        return v, a * (1.0 - e * math.cos(E))
    a = q / (1.0 - e)  # negative for e > 1
    n = K_GAUSS / abs(a) ** 1.5
    M = n * (jd - tp_jd)
    F = _newton_hyperbolic(M, e)
    v = 2.0 * math.atan2(math.sqrt(e + 1.0) * math.sinh(F / 2.0),
                         math.sqrt(e - 1.0) * math.cosh(F / 2.0))
    return v, abs(a) * (e * math.cosh(F) - 1.0)


def _earth_heliocentric_xyz(jd):
    """Earth's heliocentric J2000-ecliptic position (AU).

    Low-precision solar theory with the same constants as
    AstroMath.sunEclipticLongitude — BUT: those constants yield the
    Sun's longitude in the mean-equinox-OF-DATE frame (the w rate
    includes general precession), while the comet elements are J2000.
    Mixing the frames costs 0.37 deg by 2026 (measured against JPL
    Horizons vectors — exactly the J2000->date precession). So the
    of-date longitude is corrected back to J2000 by subtracting the
    accumulated precession in longitude
    p_A = 5028.796195*T + 1.1054348*T^2 arcsec (T = centuries since
    J2000). Exact for this model because Earth's ecliptic latitude is
    identically 0 here."""
    d = jd - 2451543.5
    w = math.radians(282.9404 + 4.70935e-5 * d)      # of-date!
    ecc = 0.016709 - 1.151e-9 * d
    M = math.radians(356.0470 + 0.9856002585 * d)
    E = _newton_elliptic(M % (2.0 * math.pi), ecc)
    xv = math.cos(E) - ecc
    yv = math.sqrt(1.0 - ecc * ecc) * math.sin(E)
    v = math.atan2(yv, xv)
    r = math.hypot(xv, yv)
    lam_sun_date = v + w  # Sun's geocentric ecliptic longitude, of-date
    # Earth's heliocentric longitude, of-date, then precess to J2000.
    T = (jd - 2451545.0) / 36525.0
    p_A = math.radians((5028.796195 * T + 1.1054348 * T * T) / 3600.0)
    lam_earth_j2000 = lam_sun_date + math.pi - p_A
    return (r * math.cos(lam_earth_j2000),
            r * math.sin(lam_earth_j2000), 0.0)


def geocentric_radec(e, q, tp_jd, node_deg, peri_deg, incl_deg, jd):
    """Geocentric J2000 RA/Dec (deg), heliocentric r (AU), Delta (AU)."""
    v, r = solve_orbit(e, q, tp_jd, jd)
    Om, wp, ii = (math.radians(node_deg), math.radians(peri_deg),
                  math.radians(incl_deg))
    u = wp + v
    x = r * (math.cos(Om) * math.cos(u)
             - math.sin(Om) * math.sin(u) * math.cos(ii))
    y = r * (math.sin(Om) * math.cos(u)
             + math.cos(Om) * math.sin(u) * math.cos(ii))
    z = r * math.sin(u) * math.sin(ii)
    ex, ey, ez = _earth_heliocentric_xyz(jd)
    xg, yg, zg = x - ex, y - ey, z - ez
    # J2000 obliquity (the whole computation is J2000 now).
    eps = math.radians(23.4392911)
    xq = xg
    yq = yg * math.cos(eps) - zg * math.sin(eps)
    zq = yg * math.sin(eps) + zg * math.cos(eps)
    ra = math.degrees(math.atan2(yq, xq)) % 360.0
    dec = math.degrees(math.atan2(zq, math.hypot(xq, yq)))
    return ra, dec, r, math.sqrt(xg * xg + yg * yg + zg * zg)


def comet_mag(H, G, r, Delta):
    """Standard comet total-magnitude law. Approximate by construction."""
    return H + 5.0 * math.log10(Delta) + 2.5 * G * math.log10(r)


# --------------------------------------------------------------------------
# MPC parsing

def parse_mpc(text):
    """Parse Soft03Cmt.txt -> list of element dicts. Skips malformed."""
    out = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        f = [x.strip() for x in line.split(",")]
        try:
            name, typ = f[0], f[1]
            if typ == "e" and len(f) >= 13:
                incl, node, peri = float(f[2]), float(f[3]), float(f[4])
                a, n, ecc, M = (float(f[5]), float(f[6]),
                                float(f[7]), float(f[8]))
                epoch_jd = epoch_str_to_jd(f[9])
                h_raw = f[11].strip()
                if h_raw.startswith("g "):  # MPC magnitude-system prefix
                    h_raw = h_raw[2:].strip()
                H = float(h_raw)
                G = float(f[12]) if f[12].strip() else None
                q = a * (1.0 - ecc)
                if n:
                    tp_jd = epoch_jd - M / n
                else:
                    # Ultra-long-period records (a > ~1e5 AU) print n as
                    # 0.0000000; they always carry M = 0 at epoch, i.e.
                    # the epoch IS the perihelion passage.
                    tp_jd = epoch_jd if M == 0.0 else None
            elif typ == "h" and len(f) >= 10:
                tp_jd = epoch_jd = epoch_str_to_jd(f[2])
                incl, node, peri = float(f[3]), float(f[4]), float(f[5])
                ecc, q = float(f[6]), float(f[7])
                H = float(f[9])
                G = float(f[10]) if len(f) >= 11 and f[10].strip() else None
            else:
                print("skip L%d: unrecognized %r" % (lineno, line[:60]),
                      file=sys.stderr)
                continue
            if tp_jd is None:
                continue
            out.append(dict(name=name, epochJD=epoch_jd, e=ecc, q_au=q,
                            tp_jd=tp_jd, node_deg=node, peri_deg=peri,
                            incl_deg=incl, H=H, G=G))
        except (ValueError, IndexError) as ex:
            print("skip L%d: %s (%r)" % (lineno, ex, line[:60]),
                  file=sys.stderr)
    return out


def fetch_mpc(timeout=30):
    req = urllib.request.Request(MPC_URL, headers={"User-Agent":
                                                   "AstroTonight/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        last_mod = resp.headers.get("Last-Modified", "")
        return resp.read().decode("utf-8", "replace"), last_mod


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default=None,
                    help="local Soft03Cmt.txt instead of downloading")
    ap.add_argument("--top", type=int, default=10)
    ap.add_argument("--out", default=OUT_PATH)
    args = ap.parse_args()

    fetched_utc = (datetime.datetime.now(datetime.timezone.utc)
                   .strftime("%Y-%m-%dT%H:%M:%SZ"))
    if args.input:
        text = open(args.input, encoding="utf-8").read()
        source_note = "local file " + args.input
    else:
        text, last_mod = fetch_mpc()
        source_note = ("downloaded " + fetched_utc
                       + ("; Last-Modified: " + last_mod if last_mod else ""))

    jd_now = now_jd()
    elems = parse_mpc(text)
    print("parsed %d records (%s)" % (len(elems), MPC_URL))

    ranked = []
    for el in elems:
        age = jd_now - el["epochJD"]
        if abs(age) > FRESH_DAYS or el["H"] is None or el["G"] is None:
            continue
        _, _, r, Delta = geocentric_radec(el["e"], el["q_au"], el["tp_jd"],
                                          el["node_deg"], el["peri_deg"],
                                          el["incl_deg"], jd_now)
        m = comet_mag(el["H"], el["G"], r, Delta)
        if m <= MAX_MAG:
            ranked.append((m, el))
    ranked.sort(key=lambda t: t[0])
    kept = [el for _, el in ranked[:args.top]]
    print("kept %d comets (brightest at fetch date):" % len(kept))
    for m, el in ranked[:args.top]:
        print("  m=%5.1f  %-28s e=%.5f q=%.3f" % (m, el["name"], el["e"],
                                                  el["q_au"]))

    doc = {
        "source_url": MPC_URL,
        "fetched_utc": fetched_utc,
        "fetch_note": source_note,
        "selection": ("element epoch within %.0f d of fetch; "
                      "top %d by estimated current total magnitude "
                      "(m = H + 5*log10(Delta) + 2.5*G*log10(r)), "
                      "m <= %.1f" % (FRESH_DAYS, args.top, MAX_MAG)),
        "objects": [
            {k: el[k] for k in ("name", "epochJD", "e", "q_au", "tp_jd",
                                "node_deg", "peri_deg", "incl_deg",
                                "H", "G")}
            for el in kept
        ],
    }
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
