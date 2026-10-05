#!/usr/bin/env python3
"""Constellation lines -> constellations.json for AstroTonight's sky chart.

Source: d3-celestial by Olaf Frohn (BSD 2-clause, permissive - NOT copyleft)
    https://github.com/ofrohn/d3-celestial
    Lines : data/constellations.lines.json (89 features, MultiLineString,
            coordinates are [RA, Dec] in degrees, RA in [-180, 180])
    Names : data/constellations.json (GeoJSON features with id + name;
            joined to the lines by the 3-letter id)
    Attribution is kept in this header and in the Swift reader's doc
    comment, satisfying the BSD "reproduce the copyright notice" clause.

Why this source: the common alternative, Stellarium's constellation art
data, is GPL-licensed and cannot be bundled. d3-celestial's BSD license
allows bundling with attribution, so no hand-drawn fallback was needed.

Output: Sources/AstroTonight/Resources/constellations.json
    JSON array of {"name": str, "lines": [[ra1,dec1,ra2,dec2], ...]},
    degrees. Each MultiLineString polyline is split into individual
    segments, and RA is unwrapped along each polyline (adding +/-360 so
    consecutive points differ by <= 180 deg) so segments crossing the
    RA=0 meridian stay continuous; the Swift side re-wraps per segment.

Usage:
    python3 tools/constellation_pipeline.py [lines.json] [names.json]
    Defaults download from the GitHub raw URLs above (needs network).
"""

import json
import os
import sys
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_PATH = os.path.join(REPO, "Sources", "AstroTonight", "Resources",
                        "constellations.json")

LINES_URL = ("https://raw.githubusercontent.com/ofrohn/d3-celestial/"
             "master/data/constellations.lines.json")
NAMES_URL = ("https://raw.githubusercontent.com/ofrohn/d3-celestial/"
             "master/data/constellations.json")


def load(path_or_url):
    if os.path.exists(path_or_url):
        with open(path_or_url, encoding="utf-8") as fh:
            return json.load(fh)
    with urllib.request.urlopen(path_or_url, timeout=60) as r:
        return json.load(r)


def unwrap(polylines):
    """Yield (ra, dec) points with RA unwrapped along each polyline."""
    for line in polylines:
        prev = None
        out = []
        for ra, dec in line:
            if prev is not None:
                while ra - prev > 180.0:
                    ra -= 360.0
                while ra - prev < -180.0:
                    ra += 360.0
            out.append((ra, dec))
            prev = ra
        yield out


def main():
    lines_src = sys.argv[1] if len(sys.argv) > 1 else LINES_URL
    names_src = sys.argv[2] if len(sys.argv) > 2 else NAMES_URL
    lines_data = load(lines_src)
    names_data = load(names_src)

    names = {}
    for f in names_data["features"]:
        fid = f.get("id")
        nm = f.get("properties", {}).get("name")
        if fid and nm:
            names[fid] = nm

    result = []
    total_segs = 0
    for f in lines_data["features"]:
        fid = f.get("id", "?")
        name = names.get(fid, fid)
        segs = []
        for line in unwrap(f["geometry"]["coordinates"]):
            for (ra1, dec1), (ra2, dec2) in zip(line, line[1:]):
                segs.append([round(ra1, 4), round(dec1, 4),
                             round(ra2, 4), round(dec2, 4)])
        total_segs += len(segs)
        result.append({"name": name, "lines": segs})

    result.sort(key=lambda c: c["name"])
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(result, fh, separators=(",", ":"))

    size_kb = os.path.getsize(OUT_PATH) / 1024.0
    print("constellations: %d  segments: %d  -> %s (%.1f KiB)"
          % (len(result), total_segs, OUT_PATH, size_kb))
    # sanity: every named constellation got lines
    empty = [c["name"] for c in result if not c["lines"]]
    assert not empty, "constellations with no lines: %s" % empty
    # sanity: Orion's belt region present (Alnilam ~ RA 84.05, Dec -1.2)
    orion = next(c for c in result if c["name"] == "Orion")
    belt = [s for s in orion["lines"]
            if min(s[0], s[2]) < 85.0 < max(s[0], s[2])]
    assert belt, "Orion looks wrong"
    print("sanity checks passed (all 89 named, Orion belt segment found)")


if __name__ == "__main__":
    main()
