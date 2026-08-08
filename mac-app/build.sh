#!/usr/bin/env bash
#
# build.sh - compile the menu bar app into Glowgrid.app
#
#   ./build.sh          build
#   ./build.sh -r       build, then relaunch the app
#
# No Xcode project on purpose. An .xcodeproj is a large generated blob that is
# painful to diff and review, and buys nothing for an app this size. Everything
# here is plain source plus swiftc, the same toolchain already used for
# mac-cli/media-sensor.
#
# The .app bundle is NOT optional, even though swiftc can produce a bare
# executable. macOS only reads Info.plist from a bundle, and we need it for two
# things: LSUIElement (menu bar only, no Dock icon) and
# NSBluetoothAlwaysUsageDescription. Without the latter, CoreBluetooth access
# is killed with SIGABRT and no usable error - exactly the failure the Python
# CLI hit early on.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/build/Glowgrid.app"
MACOS_DIR="$APP/Contents/MacOS"

echo "building Glowgrid.app"

rm -rf "$APP"
mkdir -p "$MACOS_DIR"

swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework CoreBluetooth \
  -framework CoreAudio \
  -framework CoreMediaIO \
  -o "$MACOS_DIR/Glowgrid" \
  "$HERE"/Sources/*.swift

cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature. Unsigned bundles get their Bluetooth permission forgotten
# between builds, so macOS re-prompts every single launch. Signing (even with
# no identity) gives the bundle a stable identity and the grant sticks.
codesign --force --sign - "$APP" >/dev/null 2>&1 || {
  echo "warning: ad-hoc codesign failed; you may be re-prompted for Bluetooth each launch" >&2
}

echo "built: $APP"

if [[ "${1:-}" == "-r" || "${1:-}" == "--run" ]]; then
  echo "relaunching"
  pkill -x Glowgrid 2>/dev/null || true
  sleep 1
  open "$APP"
fi
