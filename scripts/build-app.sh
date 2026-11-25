#!/bin/zsh
# Builds CalFeed.app (ad-hoc signed) into the given directory. Used by install.sh, CI and the Homebrew formula.
#   scripts/build-app.sh <out-dir>   →   <out-dir>/CalFeed.app
set -euo pipefail

ROOT="${0:A:h:h}"
OUT="${1:?usage: build-app.sh <out-dir>}"
APP="$OUT/CalFeed.app"
VERSION="$(<"$ROOT/VERSION")"

command -v swiftc >/dev/null || { echo "Needs Swift. Run: xcode-select --install" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
swiftc -O "$ROOT/main.swift" -o "$APP/Contents/MacOS/CalFeed"
# macOS only grants calendar access to a signed app bundle with a usage description (Info.plist).
codesign --force --sign - "$APP"
echo "$APP"
