# AstroTonight on iPhone / iPad — iMac setup

One iOS target covers **both iPhone and iPad** (a universal app). The whole
codebase is shared with the Mac version: same ranking, same features
(imaging windows, moon verdicts, cloud + seeing, thumbnails, session log,
exports). Only the platform seams differ (clipboard, hover, location
settings) — those live in `Sources/AstroTonight/Platform.swift`.

There is deliberately **no `.xcodeproj` in this repo** — a hand-written
project file can't be verified without Xcode, and a broken one is worse
than none. Creating the project on the iMac takes about five minutes.

## The 5-minute path (on the iMac, in Xcode)

1. **Clone the repo** (Terminal):
   ```bash
   git clone https://github.com/Skeleten80/astro-tonight.git
   cd astro-tonight
   ```

2. **Xcode → File → New → Project → iOS → App**, then:
   - Product Name: `AstroTonight`
   - Interface: **SwiftUI**, Language: **Swift**
   - Uncheck "Include Tests"
   - Save it anywhere (e.g. `~/Projects/`)

3. **Delete the template's files.** The template creates its own
   `AstroTonightApp.swift` (or `YourNameApp.swift`) and `ContentView.swift`
   — ours have the same names and the same `@main` entry point, so leaving
   the template's copies in causes duplicate-symbol build errors. In the
   Project navigator, select those two files → Delete → **Move to Trash**.

4. **Drag in our sources.** In Finder, open the cloned repo's
   `Sources/AstroTonight` folder and drag it into Xcode's Project
   navigator (drop it on the `AstroTonight` group). In the dialog:
   - ✅ "Copy items if needed" **unchecked** is fine either way; leaving
     it unchecked keeps one copy of the code
   - ✅ **"Add to targets: AstroTonight" must be checked**
   - "Create groups" (not folder references)

   This brings in all 33 Swift files **and** `Resources/` (the catalogue
   `catalog.json`, the star-chart `stars.bin` + `constellations.json`, the
   satellite `tle.txt`, and the comet `comets.json` — it's inside the
   dragged folder, so everything lands in the app bundle; the code finds
   it via `Bundle.main` in a plain Xcode project).

5. **Deployment target:** select the project (top of the navigator) →
   the `AstroTonight` target → General → **Minimum Deployments: iOS 17.0**.

6. **Location permission text:** select the target → Info tab → add a row:
   - Key: `Privacy - Location When In Use Usage Description`
     (`NSLocationWhenInUseUsageDescription`)
   - Value: `AstroTonight uses your location to rank tonight's targets for your sky.`

   Without this key, iOS will not show the location prompt and the
   "Use my location" button silently does nothing.

7. **Signing:** select the target → Signing & Capabilities → Team →
   choose your Apple ID (add it in Xcode → Settings → Accounts if needed).

8. **Run it:** plug in the iPhone/iPad (or use the same Wi-Fi network),
   pick it in the run-destination menu next to the ▶ button, press **⌘R**.
   First launch takes a moment while the catalogue ranks (~13,000 objects)
   and the star chart loads (~1.46 M stars).

### Privacy manifest

The repo root contains `PrivacyInfo.xcprivacy`, declaring the app's use
of the UserDefaults API (required-reason `CA92.1` — all settings, the
session log, the observing list, and the thumbnail cache manifest live
there). Drag it into the Xcode project navigator and make sure **Add to
targets: AstroTonight** is checked, same as the sources. App Store
Connect flags uploads that touch a required-reason API without one, so
don't skip this before TestFlight.

## Signing reality — read before investing time

- **Free Apple ID:** sideloading works, but the provisioning certificate
  **expires every 7 days**. The app stays installed but won't launch until
  you re-run it from Xcode (⌘R again). Fine for personal use at the scope.
- **Apple Developer Program ($99/yr):** enables TestFlight and installs
  that don't expire. Worth it only if you want the app on your phone
  permanently without the weekly re-run.

## TestFlight (paid developer account)

With the paid account, the flow is: archive once in Xcode, upload to
App Store Connect, install via the TestFlight app. Builds stay valid for
**90 days** — re-upload a fresh build every ~3 months to keep it alive
(just bump the build number and repeat steps 4–5).

1. **Bundle ID.** In the target's General tab, set something stable and
   reverse-DNS, e.g. `com.skeleten80.AstroTonight`. You'll reuse this
   exact string in App Store Connect — it must match.

2. **Create the App Store Connect record** (browser, once):
   [App Store Connect](https://appstoreconnect.apple.com) → My Apps →
   **+** → New App → platform **iOS**, name `AstroTonight`, bundle ID
   from step 1, SKU anything (e.g. `astrotonight-ios-1`).

3. **Version/build numbers** (Xcode, target → General): set **Version**
   `1.0` and **Build** `1`. Every upload needs a *higher build number*
   than the last — that's the only thing you must bump for re-uploads.

4. **Archive:** in Xcode's run-destination menu choose **Any iOS Device
   (arm64)** (not a simulator), then **Product → Archive**. The first
   archive is the slowest; it also catches anything the debug build let
   slide.

5. **Upload:** when the Organizer window opens, select the archive →
   **Distribute App → App Store Connect → Upload** → Next through the
   defaults (include symbols: yes). Wait for the "upload successful"
   confirmation.

6. **Wait for processing:** in App Store Connect → your app →
   **TestFlight** tab, the build appears once Apple finishes processing
   (usually 10–30 minutes). You'll get an email.

7. **Add yourself as a tester:** TestFlight tab → **Internal Testing**
   → add yourself (your Apple ID must be added under Users and Access
   first if it isn't). Internal testers skip beta app review — the build
   is available immediately after processing.

8. **Install:** on the iPhone/iPad, install Apple's **TestFlight** app
   from the App Store, accept the invite, and install AstroTonight.
   It now launches like any app and won't expire for 90 days.

Two gotchas worth knowing: the first upload asks an **export compliance**
question — answer "no" to non-exempt encryption for this app (it only
uses standard HTTPS), or add the `ITSAppUsesNonExemptEncryption = NO`
key to Info.plist to stop it asking. And if an upload is rejected for a
missing icon, the template's `Assets.xcassets` AppIcon slot needs *some*
image — any 1024×1024 PNG works for TestFlight.

## What differs from the Mac version

- **Clipboard:** copy buttons use `UIPasteboard` — same buttons, same text.
- **Hover affordances:** the row lift-on-hover and the chart's
  hover-scrubber are macOS-only; on iOS the star toggles are always
  visible (tap), and the chart scrubs with a finger drag.
- **Location settings link:** opens the app's page in the Settings app
  (the iOS convention) instead of the System Settings pane.
- **Layout:** `NavigationSplitView` collapses to a navigation stack on
  iPhone automatically; the detail view scrolls. No fixed window sizes.
- **Night-vision red mode, thumbnails, cloud, seeing, session log,
  exports:** all work identically.

## The Mac path is unchanged

Open the repo folder in Xcode on the Mac and ⌘R (or `swift run`), and
`scripts/build-app.sh` still builds the real `.app` bundle for the
location button. The iOS port changes nothing about the Mac build —
`Platform.swift` keeps the macOS branches exactly as they were.
