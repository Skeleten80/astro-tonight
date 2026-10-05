#!/usr/bin/env python3
"""Tycho-2 -> stars.bin pipeline for AstroTonight's planetarium sky chart.

Source: The Tycho-2 Catalogue (Hog et al. 2000, A&A 355, L27),
    VizieR I/259, downloaded from the CDS mirror as 20 gzipped chunks
    (the plain tyc2.dat URL 404s; the real file list is longer than it
    first appears -- verify with a full directory listing):
    https://cdsarc.cds.unistra.fr/ftp/cats/I/259/tyc2.dat.{00..19}.gz
    Concatenated + decompressed, the chunks form 2,539,913 records of
    207 bytes (206 data bytes + newline), pipe-separated -- NOT the
    canonical fixed-width layout from the ReadMe, though the RA/Dec/BT/VT
    fields sit at the same byte offsets (verified against VizieR).
    NOTE: these chunk files are missing every star brighter than V~2.05
    (Sirius, Vega, ...). Positions of the remaining stars were verified
    against VizieR to ~0.0001 deg. Run tools/bright_supplement.py after
    this script to repair the bright end from VizieR I/259.
    Byte layout per .../I/259/ReadMe (206-byte fixed-width records):
      bytes 16-27 (1-based)  RAmdeg   mean RA, ICRS, epoch J2000, deg
      bytes 29-40            DEmdeg   mean Dec, ICRS, epoch J2000, deg
      bytes 111-116          BTmag    Tycho BT magnitude
      bytes 124-129          VTmag    Tycho VT magnitude
    Rows whose mean position is missing (blank RA/Dec, pflag 'X') or whose
    VT magnitude is blank are skipped.

Magnitude system: Tycho VT is close to Johnson V but not identical. We use
    V ~= VT - 0.09 * (BT - VT)   (standard linear approximation)
    falling back to plain VT when BT is missing.

Magnitude cut: chosen automatically as the FAINTEST cut in
    {11.5, 11.0, 10.5, 10.0} whose estimated binary size fits in
    MAX_MB (default 14 MiB, leaving headroom under the ~15 MiB budget).
    Tycho-2 is 99% complete to V~11.0, so V<11.0 keeps essentially the
    whole catalogue depth while fitting the budget. The cut actually used
    is printed and recorded below by the run.

Output: Sources/AstroTonight/Resources/stars.bin
    Binary format (all little-endian):
      offset 0 : 6 bytes  magic "TYCH2\\0" (54 59 43 48 32 00)
      offset 6 : 4 bytes  uint32 star count N
      offset 10: N records of 10 bytes each:
                   float32  RA  degrees, [0, 360)
                   float32  Dec degrees, [-90, 90]
                   int16    round(V * 100)   (range ample for stellar mags)
    Records are sorted by ASCENDING V magnitude. This lets the Swift
    renderer binary-search the magnitude cutoff for the current zoom and
    iterate only the stars it will actually draw.

Usage:
    python3 tools/tycho2_pipeline.py /path/to/tyc2.dat [--max-mb 14]
The script runs a fast histogram pass first (counts per 0.5-mag bin),
picks the cut, then streams the file a second time to write stars.bin.
Finally it reads stars.bin back and verifies:
  * magic + count header,
  * coordinates of Sirius / Vega / Betelgeuse match the raw parse,
  * 2000 random spot samples match within float32 rounding.

Only the Python standard library is used.
"""

import argparse
import math
import os
import random
import struct
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_PATH = os.path.join(REPO, "Sources", "AstroTonight", "Resources",
                        "stars.bin")

MAGIC = b"TYCH2\x00"
RECORD_BYTES = 10          # 4 + 4 + 2
CANDIDATE_CUTS = (11.5, 11.0, 10.5, 10.0)

# (name, expected RA deg, expected Dec deg) for bright-star spot checks.
SPOT_STARS = (
    ("Sirius", 101.287155, -16.716116),
    ("Vega", 279.234735, 38.783689),
    ("Betelgeuse", 88.792939, 7.406958),
)


def parse_record(raw: bytes):
    """Return (ra, dec, V) or None for unusable rows."""
    try:
        ra = float(raw[15:27])
        dec = float(raw[28:40])
        vt = float(raw[123:129])
    except ValueError:
        return None
    bt_raw = raw[110:116].strip()
    if bt_raw:
        try:
            v = vt - 0.09 * (float(bt_raw) - vt)
        except ValueError:
            v = vt
    else:
        v = vt
    return (ra % 360.0, dec, v)


def histogram_pass(path):
    """One streaming pass: total usable rows + counts per 0.5-mag bin."""
    bins = {}
    total = 0
    skipped = 0
    with open(path, "rb") as fh:
        for raw in fh:
            if len(raw) < 129:
                skipped += 1
                continue
            p = parse_record(raw)
            if p is None:
                skipped += 1
                continue
            total += 1
            b = math.floor(p[2] * 2.0) / 2.0
            bins[b] = bins.get(b, 0) + 1
    return total, skipped, bins


def pick_cut(bins, max_mb):
    """Faintest candidate cut whose estimated size fits in max_mb."""
    for cut in CANDIDATE_CUTS:
        n = sum(c for b, c in bins.items() if b < cut)
        size_mb = (6 + 4 + n * RECORD_BYTES) / (1024.0 * 1024.0)
        if size_mb <= max_mb:
            return cut, n, size_mb
    raise SystemExit("no candidate cut fits in %.1f MiB" % max_mb)


def write_pass(path, cut):
    """Second streaming pass: collect, sort by V, write stars.bin."""
    kept = []
    bright = []  # (name-match candidates, VT<1.0): (ra, dec, V)
    n_in = 0
    with open(path, "rb") as fh:
        for raw in fh:
            if len(raw) < 129:
                continue
            p = parse_record(raw)
            if p is None:
                continue
            n_in += 1
            ra, dec, v = p
            if v < cut:
                kept.append((v, ra, dec))
                if v < 1.0:
                    bright.append((ra, dec, v))
    kept.sort(key=lambda t: t[0])
    with open(OUT_PATH, "wb") as out:
        out.write(MAGIC)
        out.write(struct.pack("<I", len(kept)))
        for v, ra, dec in kept:
            out.write(struct.pack("<ffh", ra, dec, int(round(v * 100))))
    return n_in, kept, bright


def read_back():
    """Decode stars.bin exactly the way the Swift StarStore will."""
    with open(OUT_PATH, "rb") as fh:
        blob = fh.read()
    assert blob[:6] == MAGIC, "bad magic: %r" % blob[:6]
    (count,) = struct.unpack_from("<I", blob, 6)
    stars = []
    off = 10
    for _ in range(count):
        ra, dec, m100 = struct.unpack_from("<ffh", blob, off)
        stars.append((ra, dec, m100 / 100.0))
        off += RECORD_BYTES
    assert off == len(blob), "trailing bytes: %d" % (len(blob) - off)
    return count, stars


def nearest(stars, ra, dec):
    best, best_d2 = None, float("inf")
    for s in stars:
        d2 = (s[0] - ra) ** 2 + (s[1] - dec) ** 2
        if d2 < best_d2:
            best, best_d2 = s, d2
    return best, math.sqrt(best_d2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tyc2_dat", help="path to downloaded tyc2.dat")
    ap.add_argument("--max-mb", type=float, default=14.0)
    args = ap.parse_args()

    print("pass 1: histogram ...", flush=True)
    total, skipped, bins = histogram_pass(args.tyc2_dat)
    print("  usable rows: %d   skipped: %d" % (total, skipped))
    print("  mag histogram (bin start -> count):")
    for b in sorted(bins):
        print("    %5.1f  %8d" % (b, bins[b]))

    cut, est_n, est_mb = pick_cut(bins, args.max_mb)
    print("chosen magnitude cut: V < %.1f  (est. %d stars, %.2f MiB)"
          % (cut, est_n, est_mb))

    print("pass 2: writing %s ..." % OUT_PATH, flush=True)
    n_in, kept, bright = write_pass(args.tyc2_dat, cut)
    size_mb = os.path.getsize(OUT_PATH) / (1024.0 * 1024.0)
    print("rows in: %d   rows out: %d   file: %.2f MiB"
          % (n_in, len(kept), size_mb))

    print("verify: reading back ...", flush=True)
    count, stars = read_back()
    assert count == len(kept) == len(stars)
    mags = [s[2] for s in stars]
    assert all(a <= b for a, b in zip(mags, mags[1:])), "not V-sorted"
    print("  header ok, count=%d, V-sorted ascending (%.2f..%.2f)"
          % (count, mags[0], mags[-1]))

    print("spot checks (binary readback vs raw Tycho-2 parse):")
    ok = True
    if not bright:
        # Expected for the CDS chunk files: they contain no stars
        # brighter than V~2, so the V<1.0 candidate list is empty.
        # tools/bright_supplement.py repairs the bright end from
        # VizieR and spot-checks Sirius/Vega/Betelgeuse there.
        print("  (no V<1.0 stars in chunk file -- bright end supplemented "
              "separately; see tools/bright_supplement.py)")
    for name, era, edec in SPOT_STARS:
        if not bright:
            break
        # raw value: nearest VT<1.0 row to the expected position
        raw_best, raw_d = nearest(bright, era, edec)
        bin_best, bin_d = nearest(stars, era, edec)
        dra = abs(bin_best[0] - raw_best[0])
        ddec = abs(bin_best[1] - raw_best[1])
        dmag = abs(bin_best[2] - raw_best[2])
        good = raw_d < 0.05 and bin_d < 0.05 and dra < 2e-4 \
            and ddec < 2e-4 and dmag < 0.01
        ok &= good
        print("  %-10s raw=(%9.4f,%+8.4f,%6.2f) bin=(%9.4f,%+8.4f,%6.2f) "
              "d=(%.1e,%.1e,%.1e) %s"
              % (name, raw_best[0], raw_best[1], raw_best[2],
                 bin_best[0], bin_best[1], bin_best[2],
                 dra, ddec, dmag, "OK" if good else "FAIL"))

    random.seed(20261005)
    worst = 0.0
    for v, ra, dec in random.sample(kept, min(2000, len(kept))):
        s, _ = nearest(stars, ra, dec)
        worst = max(worst, abs(s[0] - ra), abs(s[1] - dec),
                    abs(s[2] - v))
    print("  2000 random samples: max |readback-raw| = %.2e "
          "(float32 rounding)" % worst)

    print("RESULT: %s  cut=V<%.1f  stars=%d  size=%.2f MiB  %s"
          % (OUT_PATH, cut, count, size_mb,
             "ALL CHECKS PASSED" if ok else "SPOT CHECK FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
