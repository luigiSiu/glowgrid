#!/usr/bin/env bash
#
# build.sh - compile the menu bar app into Glowgrid.app
#
#   ./build.sh          build
#   ./build.sh -r       build, then relaunch from build/
#   ./build.sh -i       build, install into /Applications, launch from there
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
RES_DIR="$APP/Contents/Resources"
ICNS="$HERE/build/AppIcon.icns"
ICON_SRC="$HERE/icon/make-icon.swift"

echo "building Glowgrid.app"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# The icon is drawn by code rather than committed as a binary, so it has to be
# rendered before it can be bundled. Rendering takes a couple of seconds, so
# the result is cached in build/ and only redone when the generator changes.
if [[ ! -f "$ICNS" || "$ICON_SRC" -nt "$ICNS" ]]; then
  echo "drawing icon"
  ICONSET="$HERE/build/Glowgrid.iconset"
  rm -rf "$ICONSET"
  swift "$ICON_SRC" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONSET"
fi

cp "$ICNS" "$RES_DIR/AppIcon.icns"

# Built for both architectures and stitched together with lipo. swiftc emits
# one architecture per invocation, so a universal binary means compiling twice;
# the alternative is an arm64-only app that simply will not launch on an Intel
# Mac, which is a poor first impression for a project meant to be shared.
ARCHS=(arm64 x86_64)
SLICES=()

for arch in "${ARCHS[@]}"; do
  echo "compiling $arch"
  slice="$HERE/build/Glowgrid-$arch"
  swiftc \
    -O \
    -target "$arch-apple-macos13.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework CoreBluetooth \
    -framework CoreAudio \
    -framework CoreMediaIO \
    -framework EventKit \
    -framework ServiceManagement \
    -o "$slice" \
    "$HERE"/Sources/*.swift
  SLICES+=("$slice")
done

lipo -create -output "$MACOS_DIR/Glowgrid" "${SLICES[@]}"
rm -f "${SLICES[@]}"

cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature. Unsigned bundles get their Bluetooth permission forgotten
# between builds, so macOS re-prompts every single launch. Signing (even with
# no identity) gives the bundle a stable identity and the grant sticks.
codesign --force --sign - "$APP" >/dev/null 2>&1 || {
  echo "warning: ad-hoc codesign failed; you may be re-prompted for Bluetooth each launch" >&2
}

echo "built: $APP"

case "${1:-}" in
  -r|--run)
    echo "relaunching"
    pkill -x Glowgrid 2>/dev/null || true
    sleep 1
    open "$APP"
    ;;

  -i|--install)
    # Install before enabling "Launch at login". SMAppService records the app's
    # location as well as its identifier, so a login item registered from
    # build/ breaks as soon as that directory is rebuilt or removed.
    # /Applications is the one path that stays put.
    echo "installing to /Applications"
    pkill -x Glowgrid 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/Glowgrid.app"
    cp -R "$APP" "/Applications/Glowgrid.app"
    open "/Applications/Glowgrid.app"
    echo "installed: /Applications/Glowgrid.app"
    ;;
esac
