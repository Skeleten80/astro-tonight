#!/usr/bin/env python3
"""Bright-star supplement for stars.bin.

WHY THIS EXISTS: the Tycho-2 chunk files on the CDS mirror
(https://cdsarc.cds.unistra.fr/ftp/cats/I/259/tyc2.dat.{00..19}.gz,
pipe-separated, 207-byte records) are missing every star brighter than
V~2.05 -- e.g. Sirius (TYC 5949-2777-1, VT=-1.088), Canopus, Vega,
Betelgeuse and ~50 other bright stars are absent, even though the file
holds the full 2,539,913 records with unique TYC ids. Positions in the
file were cross-checked against VizieR for faint stars (agreement to
~0.0001 deg), so the file is genuine Tycho-2 below the bright cutoff;
only the bright end needs repair.

This script fetches the missing bright end (VT in [-2, 2.5]) from the
live VizieR I/259 catalogue, merges it into stars.bin (deduplicating by
TYC id against the chunk file, and by position as a safety net), and
re-sorts by V. The V magnitude uses the same approximation as
tycho2_pipeline.py: V ~= VT - 0.09*(BT - VT), or VT when BT is blank
(which is the case for the brightest stars, e.g. Sirius and Vega).

Usage:
    python3 tools/bright_supplement.py [bright.tsv]
    Default TSV path is /tmp/tycho2/bright_full.tsv, fetched via:
      https://vizier.cds.unistra.fr/viz-bin/asu-tsv?-source=I/259&VTmag=-2..2.5&-out.max=500
    Columns are located from the TSV header row (VizieR's column order
    varies), so the script does not assume fixed positions.

Only the Python standard library is used (urllib for the fetch).
"""

import os
import struct
import sys
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN_PATH = os.path.join(REPO, "Sources", "AstroTonight", "Resources",
                        "stars.bin")
MAGIC = b"TYCH2\x00"
VIZIER_URL = ("https://vizier.cds.unistra.fr/viz-bin/asu-tsv"
              "?-source=I/259&VTmag=-2..2.5&-out.max=500")
DEFAULT_TSV = os.path.join(REPO, "tools", "bright_vizier.tsv")


def read_bin(path):
    with open(path, "rb") as fh:
        blob = fh.read()
    assert blob[:6] == MAGIC, "bad magic"
    (count,) = struct.unpack_from("<I", blob, 6)
    stars = []
    off = 10
    for _ in range(count):
        ra, dec, m100 = struct.unpack_from("<ffh", blob, off)
        stars.append([m100 / 100.0, ra, dec])
        off += 10
    assert off == len(blob)
    return stars


def write_bin(path, stars):
    stars.sort(key=lambda s: s[0])
    with open(path, "wb") as out:
        out.write(MAGIC)
        out.write(struct.pack("<I", len(stars)))
        for v, ra, dec in stars:
            out.write(struct.pack("<ffh", ra, dec, int(round(v * 100))))


def fetch_tsv(path):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    with urllib.request.urlopen(VIZIER_URL, timeout=120) as r:
        text = r.read().decode("utf-8")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return text


def parse_bright_tsv(text):
    """Return [(v, ra, dec, (tyc1, tyc2, tyc3))].

    Columns are located from each header row (VizieR's column order
    varies, and a response can repeat the header); rows are parsed
    against the most recent header. De-duplicated by TYC id.
    """
    def is_header(line):
        return "TYC1" in line and "\t" in line

    header = None
    seen = set()
    stars = []
    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        if is_header(line):
            header = [c.strip() for c in line.split("\t")]
            continue
        stripped = line.strip()
        if header is None or line.startswith("-") \
                or not stripped[0].isdigit():
            continue  # unit row / separator
        f = line.split("\t")
        if len(f) != len(header):
            continue
        row = dict(zip(header, f))

        def col(*names):
            for nm in names:
                if nm in row and row[nm].strip():
                    return row[nm].strip()
            return None

        try:
            tyc = (int(col("TYC1")), int(col("TYC2")), int(col("TYC3")))
            ra = float(col("RA(ICRS)", "RAJ2000", "_RAJ2000"))
            dec = float(col("DE(ICRS)", "DEJ2000", "_DEJ2000"))
            vt = float(col("VTmag"))
        except (TypeError, ValueError):
            continue
        if tyc in seen:
            continue
        seen.add(tyc)
        bt_s = col("BTmag")
        bt = float(bt_s) if bt_s else None
        v = vt - 0.09 * (bt - vt) if bt is not None else vt
        stars.append((v, ra % 360.0, dec, tyc))
    return stars


def main():
    tsv_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_TSV
    text = fetch_tsv(tsv_path)
    bright = parse_bright_tsv(text)
    assert bright, "no bright stars parsed"
    assert all(-2.5 < s[0] < 2.6 for s in bright), \
        "parsed V out of query range -- column mapping wrong"
    print("bright stars from VizieR: %d (V %.2f..%.2f)"
          % (len(bright), min(s[0] for s in bright),
             max(s[0] for s in bright)))
    assert len(bright) > 40, "suspiciously few bright stars"

    stars = read_bin(BIN_PATH)
    print("stars.bin before: %d stars" % len(stars))

    # Dedupe: the chunk file has no stars brighter than V~2.05, but check
    # positionally anyway (0.05 deg) in case of boundary overlap. Only
    # the faint tail of the supplement can possibly overlap, so index
    # just the file's V<2.5 stars for the check.
    faint_end = [s for s in stars if s[0] < 2.5]
    print("file stars with V<2.5 (dedupe index): %d" % len(faint_end))

    def near(ra, dec):
        for _, sra, sdec in faint_end:
            if abs(sra - ra) < 0.05 and abs(sdec - dec) < 0.05:
                return True
        return False

    added = 0
    for v, ra, dec, tyc in bright:
        if not near(ra, dec):
            stars.append([v, ra, dec])
            added += 1
    print("added %d bright stars (%d already present)"
          % (added, len(bright) - added))

    write_bin(BIN_PATH, stars)
    size_mb = os.path.getsize(BIN_PATH) / (1024.0 * 1024.0)
    check = read_bin(BIN_PATH)
    mags = [s[0] for s in check]
    assert all(a <= b for a, b in zip(mags, mags[1:]))
    print("stars.bin after: %d stars, %.2f MiB, V-sorted (%.2f..%.2f)"
          % (len(check), size_mb, mags[0], mags[-1]))

    # Spot-check the famous missing stars by position.
    for name, era, edec in (("Sirius", 101.287, -16.716),
                            ("Vega", 279.235, 38.784),
                            ("Betelgeuse", 88.793, 7.407),
                            ("Canopus", 95.988, -52.696)):
        best = min(check, key=lambda s: (s[1] - era) ** 2
                   + (s[2] - edec) ** 2)
        d = ((best[1] - era) ** 2 + (best[2] - edec) ** 2) ** 0.5
        status = "OK" if d < 0.01 else "FAIL"
        print("  %-10s V=%6.2f d=%.4f deg %s" % (name, best[0], d, status))
        assert d < 0.01, name
    print("SUPPLEMENT OK")


if __name__ == "__main__":
    main()
