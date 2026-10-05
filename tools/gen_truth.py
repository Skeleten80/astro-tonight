import json, datetime
from sgp4.api import Satrec, jday

def load_tles(path):
    lines = open(path).read().splitlines()
    sats = {}
    for i in range(0, len(lines), 3):
        name, l1, l2 = lines[i].strip(), lines[i+1], lines[i+2]
        sats[name] = (l1, l2)
    return sats

stations = load_tles('stations.tle')
visual = load_tles('visual.tle')

picks = {
    "ISS (ZARYA)": stations["ISS (ZARYA)"],
    "HST": visual["HST"],
    "CSS (TIANHE)": stations["CSS (TIANHE)"],
}

# 5 fixed UTC timestamps
stamps = [
    "2026-10-05T12:00:00Z",
    "2026-10-05T18:30:00Z",
    "2026-10-06T00:00:00Z",
    "2026-10-06T06:00:00Z",
    "2026-10-06T12:00:00Z",
]

truth = {"timestamps": stamps, "satellites": []}
for name, (l1, l2) in picks.items():
    sat = Satrec.twoline2rv(l1, l2)
    entry = {"name": name, "line1": l1, "line2": l2,
             "epoch_jd": sat.jdsatepoch + sat.jdsatepochF, "points": []}
    for ts in stamps:
        dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        jd, fr = jday(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second + dt.microsecond/1e6)
        e, r, v = sat.sgp4(jd, fr)
        entry["points"].append({
            "iso": ts, "jd": jd + fr,
            "r": list(r), "v": list(v),
            "minutes_since_epoch": (jd + fr - entry["epoch_jd"]) * 1440.0,
        })
    truth["satellites"].append(entry)

json.dump(truth, open('sgp4_truth.json', 'w'), indent=1)
print("wrote sgp4_truth.json")
for s in truth["satellites"]:
    p = s["points"][0]
    print(s["name"], "epoch_jd=%.6f" % s["epoch_jd"], "r0=", [f"{x:.3f}" for x in p["r"]])
