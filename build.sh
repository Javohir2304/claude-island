#!/bin/bash
# Builds Orol.app into ./build and (with --install) copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Orol.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Orol "$APP/Contents/MacOS/Orol"
cp .build/release/orol-hook "$APP/Contents/MacOS/orol-hook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/Orol.icns ] && cp Resources/Orol.icns "$APP/Contents/Resources/Orol.icns"
cp Resources/orol_wake.py Resources/orol_tts.py "$APP/Contents/Resources/"

# Ad-hoc signature with a requirement that names the bundle, not this build's hash, so the
# permissions you gave (Accessibility, microphone) survive rebuilds.
codesign --force --sign - "$APP/Contents/MacOS/orol-hook"
codesign --force --sign - -r='designated => identifier "app.orol.island"' "$APP"

echo "Built $APP"
if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Orol.app"
    cp -R "$APP" "$HOME/Applications/Orol.app"
    echo "Installed to $HOME/Applications/Orol.app"
fi
