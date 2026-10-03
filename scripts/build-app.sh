#!/bin/bash
# Build AstroTonight.app — a real macOS app bundle.
#
# Why not just press Run in Xcode? Xcode runs a SwiftPM executable target as
# a bare binary with no app bundle and no Info.plist, and macOS Location
# Services requires NSLocationWhenInUseUsageDescription in an Info.plist
# before it will even show the permission prompt. So for the "Use my
# location" button to work, the app must be bundled: this script builds the
# release binary, wraps it in AstroTonight.app with the Info.plist (which
# carries the usage description), ad-hoc signs it, and opens it.
#
# Run on a Mac:  ./scripts/build-app.sh   (from the repo root)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/AstroTonight.app"
echo "→ swift build -c release"
swift build -c release --disable-sandbox 2>/dev/null || swift build -c release

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AstroTonight "$APP/Contents/MacOS/AstroTonight"
# SwiftPM resource bundle (carries catalog.json); name is <target>_<target>.bundle
shopt -s nullglob
for b in .build/release/*.bundle; do
    cp -R "$b" "$APP/Contents/Resources/"
done
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "→ opening $APP"
open "$APP"
