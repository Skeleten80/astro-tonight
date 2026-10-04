# AstroTonight — "what's worth imaging tonight" (macOS + iOS/iPadOS)

A native companion for AstroCapture across Apple platforms: it loads the
same vendored 5,045-object night-sky catalogue (`catalog.json`, OpenNGC /
CC-BY-SA-4.0) and ranks what's best placed tonight for your site — no
Python, no terminal, just a list you can browse with coffee. One
universal iOS target covers iPhone and iPad.

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

## iOS / iPadOS

The same codebase builds as a universal iOS app (iPhone + iPad, iOS 17+)
— all logic and features are shared, including the imaging windows,
cloud + seeing forecasts, DSS thumbnails, session log, and exports.
The platform seams (clipboard, hover, location-settings links) are
centralised in `Sources/AstroTonight/Platform.swift`.

No `.xcodeproj` is checked in (a hand-written one can't be verified
without Xcode). The 5-minute iMac path: **File → New → Project → iOS
App**, delete the template's `ContentView.swift`/`*App.swift` (name
collision with ours), drag in `Sources/AstroTonight` (with
`Resources/catalog.json` — the code falls back to `Bundle.main` outside
SwiftPM), set the iOS 17 deployment target, add
`NSLocationWhenInUseUsageDescription` to the target's Info tab, sign
with your Apple ID, and ⌘R onto the device. Full beginner-proof steps
— including the signing reality (free Apple ID = 7-day certificates,
re-run weekly; $99/yr Developer Program = TestFlight and permanent
installs) — are in [`docs/iOS-setup.md`](docs/iOS-setup.md).

What differs on iOS: copy buttons use `UIPasteboard`; the hover
lift/scrubber are macOS-only (star toggles are always visible, the
chart scrubs by finger drag); the location-settings link opens the
app's page in the Settings app; `NavigationSplitView` collapses to a
navigation stack on iPhone automatically.

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
- **Fits-my-rig framing** — each target is checked against your selected
  rig preset (default T7i + stock 6SE at 1500 mm f/10: 0.85° × 0.57°
  field, 0.51″/px; f/6.3-reducer preset and customs available in Site
  settings): a badge (fits with room / fills the frame / tight / mosaic
  target) plus a to-scale diagram of the sensor rectangle vs the target.
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
  app's ranking carries over as `priority`. With the observing-list
  filter on, **Export night plan** copies the whole starred list as one
  multi-target `targets:` block for a full night's run.
- **Imaging window** — each detail view shows the best contiguous
  stretch where the target is both above your minimum altitude *and*
  the sky is astronomically dark ("21:42 → 03:15 (5.5 h)"), with a live
  status: "opens in 2h 14m" / "open now · closes in 3h 05m" / "closed
  for tonight".
- **Night-vision mode** — toolbar toggle lays a non-interactive red
  multiply layer over the whole app so it doesn't ruin your dark
  adaptation at the scope. Persisted between launches. (v1 is an
  overlay, not a full theme swap.)
- **Session log** — "Mark as imaged" in the detail view, with optional
  notes; imaged targets get a green "✓ Oct 3" badge in the list, and a
  "Hide imaged" toggle filters them out. Saved between launches.
- **Cloud cover** — the sidebar shows an Open-Meteo forecast strip
  (current hour + next 6, colour-coded) next to the dark-hours line.
  Free, no API key — but it needs internet, and it's a forecast, not a
  measurement.
- **Seeing forecast** — next to the cloud strip, the sidebar shows the
  7Timer astro seeing (1–8, lower is better) and transparency (1–8,
  higher is better) for the current hour, colour-coded. Free, no API
  key; cached ~6 h since the model updates twice daily. Coarse 0.5°
  model — a forecast, not a measurement. Seeing also feeds the top-pick
  score as a small penalty and appears in the observing plan.
- **DSS preview** — the detail view shows a Digitized Sky Survey
  (DSS2 Red) cutout of the target from NASA SkyView, fetched on demand
  and cached on disk (~200 MB cap, oldest evicted first). Needs
  internet; a failed fetch shows a quiet placeholder, never an error.
- **Dark shading on the altitude chart** — the astronomically dark
  interval is shaded behind the altitude curve, so you can see at a
  glance when the target is both up and the sky is dark.
- **"Image this now" top pick** — a hero card at the top of the list
  fusing rank, open imaging window, cloud cover, and the moon verdict
  into one recommendation (tapping it jumps to the target). When nothing
  is imageable right now it names the next upcoming window instead. The
  score is a documented heuristic, not a measurement.
- **Horizon profile** — survey your real horizon in Site settings
  (azimuth/altitude points with steppers, interpolated around the
  compass) and the ranking, imaging windows, and "up now" badges all
  respect your trees and roofline instead of a flat minimum. The altitude
  chart's threshold line traces the surveyed profile too. Empty profile =
  the old flat behaviour, byte-identical to `astrocapture tonight`.
- **Rig presets** — the framing check is no longer hardcoded: pick
  "6SE + T7i (f/10)" (the default), "6SE + T7i + f/6.3 reducer"
  (945 mm → 1.35° × 0.90°, 0.81″/px, derived not hardcoded), or add your
  own custom rigs (name + focal length/ratio + sensor size + pixel size)
  in Site settings. Built-ins can't be deleted; customs can.
- **Sort options** — Rank (the default, exactly the ranker's order),
  Peak time, Window opens, or A–Z, next to the type filter.
- **Moon strip on the 7-day view** — each night in the best-night strip
  already shows its moon illumination % (green = dim or well away).
- **Field-ready observing plan** — "Copy observing plan" copies a
  Markdown plan for tonight: site, dark window, moon, horizon, rig,
  cloud summary, then per target the imaging window, peak, moon
  separation + verdict, framing vs the selected rig, and imaged ✓
  status. Uses the observing list when it's non-empty, otherwise the top
  20 ranked — stated in the output.
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
- The ranking is geometric only: with no horizon surveyed it doesn't
  know about your horizon obstructions (survey them in Site settings) or
  the neighbour's porch light. The cloud strip is an Open-Meteo
  **forecast**, not a measurement — look up before you haul the scope
  out.
- The seeing forecast is 7Timer's **coarse astro model** (0.5° grid,
  updated twice daily) — useful for "is tonight a high-res night",
  not a measurement of your sky.
- DSS previews need internet and are **cached per target** (~200 MB
  cap); SkyView is a best-effort public service, so a missing preview
  is normal, not a bug.
- The "image this now" top pick is a **heuristic score** (rank position +
  window-open bonus + cloud penalty + moon penalty + small seeing
  penalty), documented in `Planning.topPick`. It points at the detail
  view; the detail view has the real numbers.
- The horizon editor is **numeric** (azimuth/altitude steppers), not a
  drawn skyline — stand where the scope sits and dial each point in.
- Night-vision mode is a **v1 overlay** (red multiply layer), not a
  full red theme — bright white text still shows through dimmed and
  reddened, so keep the screen brightness low at the scope.
- Written against the macOS 14 / iOS 17 SDKs. Like the other Xcode
  targets in this workspace, it **has not been compile-checked on Linux**
  (there is no Swift toolchain on the build VM, and SwiftUI is
  Apple-only) — the iOS port in particular is hand-ported without a
  compiler, so Xcode on the iMac is the real test **for both platforms**
  now. If it reports a build error, that's a real bug; report it and it
  gets fixed.
