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

   This brings in all 17 Swift files **and** `Resources/catalog.json`
   (it's inside the dragged folder, so it lands in the app bundle —
   the code finds it via `Bundle.main` in a plain Xcode project).

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
   First launch takes a moment while the catalogue ranks (~5,000 objects).

## Signing reality — read before investing time

- **Free Apple ID:** sideloading works, but the provisioning certificate
  **expires every 7 days**. The app stays installed but won't launch until
  you re-run it from Xcode (⌘R again). Fine for personal use at the scope.
- **Apple Developer Program ($99/yr):** enables TestFlight and installs
  that don't expire. Worth it only if you want the app on your phone
  permanently without the weekly re-run.

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
