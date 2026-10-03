# AstroTonight — "what's worth imaging tonight" (Xcode, macOS)

A native macOS companion for AstroCapture: it loads the same vendored
5,045-object night-sky catalogue (`catalog.json`, OpenNGC / CC-BY-SA-4.0)
and ranks what's best placed tonight for your site — no Python, no
terminal, just a list you can browse with coffee.

## Open it

On a Mac with Xcode 15 or later:

1. **File → Open → the `astro-tonight` folder** (or `xed .`
   from the repo root in Terminal).
2. Select the **AstroTonight** scheme (My Mac destination).
3. Press **⌘R**.

First launch takes a moment: the catalogue is parsed and ranked once
(~5,000 objects × 145 time steps, well under a second on Apple Silicon).

### Device location

The site panel has a **Use my location** button (Core Location). One
wrinkle: Xcode runs a SwiftPM executable as a bare binary with no app
bundle and no `Info.plist`, and macOS will not even show the location
permission prompt without the `NSLocationWhenInUseUsageDescription` key.
So for the location button to work, build the real app bundle instead:

```bash
cd astro-tonight
./scripts/build-app.sh
```

That compiles the release binary, wraps it in `dist/AstroTonight.app`
with the `Info.plist` (which carries the usage description), ad-hoc
signs it, and opens it. The first tap of **Use my location** then shows
the normal macOS prompt. If you deny it, the button degrades gracefully
to the manual latitude/longitude steppers — nothing breaks.

Quick ⌘R testing in Xcode works fine for everything *except* the
location button.

## What you get

- **Ranked target list** — peak altitude first, then hours above your
  minimum altitude. Identical ordering to `astrocapture tonight`
  (same algorithm, same catalogue).
- **Live "up now" badges** — each row shows the target's current altitude
  and whether it's above your minimum, low, or below the horizon.
  Refreshes every minute.
- **Search + type filter** — by name or catalogue ID (M51, NGC 7000…),
  grouped into Galaxies / Nebulae / Clusters / Other.
- **Detail view** — rise/set/peak times, hours above minimum, current
  alt/az, a 24-hour altitude chart with your minimum-altitude line and a
  now-marker, and one-click copy of J2000 coordinates (or a
  hand-controller-friendly `13h 29m 53s  +47° 11' 43"` string for the
  NexStar).
- **Moon awareness** — illumination % and waxing/waning in the toolbar,
  per-target moon separation, and a "Moon OK / glare risk" verdict.
- **Fits-my-rig framing** — each target is checked against your actual
  rig (T7i + stock 6SE at 1500 mm f/10: 0.85° × 0.57° field, 0.51″/px):
  a badge (fits with room / fills the frame / tight / mosaic target)
  plus a to-scale diagram of the sensor rectangle vs the target.
- **Dark hours** — astronomical dusk → dawn (Sun below −18°) for your
  site in the sidebar, per-target "dark time above minimum", and the
  24 h altitude chart keeps its minimum-altitude line.
- **Observing list** — star picks from the list or the detail view;
  filter to the list with the toggle. Saved between launches.
- **Best night this week** — each target gets a 7-night scan (peak
  altitude + moon at peak); the best night is highlighted, moon-clear
  first, then highest peak.
- **Field-rotation hint** — alt-az reality check at the target's peak:
  rotation rate in °/hr and estimated star trailing at the frame
  corners in a 30 s sub (frame centre is unaffected).
- **AstroCapture export** — "Copy scheduler YAML" (toolbar: the whole
  listed set; detail: the single target) produces a `targets:` block
  for your plan YAML — names resolve through the catalogue and the
  app's ranking carries over as `priority`.
- **Site settings** — latitude/longitude steppers (default Stratford,
  ON), or **Use my location** to set the site from the Mac's location
  services (needs the bundled `.app`, see above); minimum-altitude slider
  (default 30°, like the CLI), and how many targets to list. Saved
  between launches.

## Ranking semantics

24-hour window centred on *now*, 10-minute steps, minimum altitude 30°
by default. For each object: peak altitude and hours above the minimum
are computed; objects peaking below the minimum are dropped; the rest
sort by peak altitude, then hours above. Times are shown in your Mac's
local timezone.

## Look & feel

The app is a night-sky app, so it commits: forced dark mode, an animated
starfield behind everything (two drifting star layers with twinkle, a
faint nebula wash, and a shooting star every ~12 s), and frosted-glass
cards for every detail section. The glass is built on materials
(`.ultraThinMaterial`) rather than the macOS-26-only `glassEffect` API,
so it renders on the deployment target (macOS 14) instead of only on
the newest SDK. Small interactive details: the altitude chart draws
itself in on appear and has a hover/drag scrubber (time + altitude
readout), list rows lift on hover, the observing-list star bounces, and
the detail view crossfades between targets.

## Honest caveats

- Coordinates are used as **J2000 mean place** (the catalogue's frame);
  precession/nutation to tonight's apparent place are skipped. The
  residual is ~±0.5° — it cannot change a ranking, and plate solving
  removes it at the scope.
- The Moon model is **low precision (~±1°)** — plenty for a
  separation verdict, not for ephemeris work.
- The ranking is geometric only: it doesn't know about clouds, your
  horizon obstructions, or the neighbour's porch light.
- Written against the macOS 14 SDK. Like the other Xcode targets in this
  workspace, it **has not been compile-checked on Linux** (there is no
  Swift toolchain on the build VM, and SwiftUI is macOS-only) — Xcode on
  the iMac is the real test. If it reports a build error, that's a real
  bug; report it and it gets fixed.
