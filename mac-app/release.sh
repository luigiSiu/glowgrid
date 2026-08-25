#!/usr/bin/env bash
#
# release.sh - produce a Glowgrid.app that other people's Macs will open
#
#   ./release.sh                  build, sign, notarise, staple, zip
#   ./release.sh --skip-notarize  build and sign only (fast; for checking signing)
#
# Why this is separate from build.sh: signing for release needs the network,
# takes minutes rather than seconds, and burns a notarisation submission every
# run. build.sh stays ad-hoc signed and instant, which is what you want fifty
# times a day. This script is for the handful of times you cut a release.
#
# Gatekeeper needs three things and refusing any one of them produces the same
# "Apple could not verify this app is free of malware" dialog:
#
#   1. a Developer ID Application signature   (not Apple Development, not
#      Apple Distribution - those are for your own machines and the App Store)
#   2. the hardened runtime, plus a secure timestamp
#   3. a notarisation ticket, stapled into the bundle
#
# One-time setup before this works:
#
#   Certificate: Xcode > Settings > Accounts > your team > Manage
#   Certificates > + > Developer ID Application.
#
#   Notary credentials: create an app-specific password at appleid.apple.com
#   (Sign-In and Security > App-Specific Passwords), then store it once:
#
#     xcrun notarytool store-credentials glowgrid-notary \
#       --apple-id you@example.com \
#       --team-id M7SS3X57KG
#
#   That puts the password in your keychain, so it never appears in this file,
#   in your shell history, or in CI logs.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/build/Glowgrid.app"
ENTITLEMENTS="$HERE/Glowgrid.entitlements"
DIST="$HERE/build/dist"

# Overridable so a second machine, or a CI runner with a different identity,
# does not need this file edited.
NOTARY_PROFILE="${NOTARY_PROFILE:-glowgrid-notary}"

SKIP_NOTARIZE=0
case "${1:-}" in
  --skip-notarize) SKIP_NOTARIZE=1 ;;
  "") ;;
  *) echo "usage: $(basename "$0") [--skip-notarize]" >&2; exit 64 ;;
esac

# ---------------------------------------------------------------- identity

# Matched by prefix rather than hardcoded: the certificate's common name
# contains your name and team ID, and it changes when the certificate is
# renewed. SIGN_IDENTITY can pin it explicitly if you ever hold two.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning \
      | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
      | head -n 1
  )"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  cat >&2 <<'EOF'
error: no "Developer ID Application" certificate in your keychain.

An "Apple Development" or "Apple Distribution" certificate is not a
substitute: the first only works on machines registered to your account, the
second is for the Mac App Store. Neither will get an app past Gatekeeper on
someone else's Mac.

Create one in Xcode > Settings > Accounts > your team > Manage Certificates,
then the + button > Developer ID Application.
EOF
  exit 1
fi

echo "identity: $SIGN_IDENTITY"

# ---------------------------------------------------------------- build

# Reuse build.sh rather than duplicating the compile: it already handles the
# universal binary, the generated icon and the bundle layout. Its ad-hoc
# signature is simply replaced below.
"$HERE/build.sh"

# ---------------------------------------------------------------- sign

# --options runtime is the hardened runtime; --timestamp gets a signed
# timestamp from Apple, which is why the app keeps launching after the
# certificate expires - the signature is provably from when it was valid.
# Both are refused by the notary service if absent, and --timestamp is the one
# that needs the network, so a failure here is usually just connectivity.
echo "signing"
codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP"

# --strict catches the things the notary service would reject anyway, but
# locally and in a second rather than after a round trip.
codesign --verify --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
ZIP="$DIST/Glowgrid-$VERSION.zip"

mkdir -p "$DIST"
rm -f "$ZIP"

if [[ "$SKIP_NOTARIZE" == 1 ]]; then
  # ditto rather than zip: zip(1) mangles symlinks and resource forks inside
  # app bundles, which invalidates the signature you just applied.
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo
  echo "signed but NOT notarised: $ZIP"
  echo "Gatekeeper will still warn. Fine for testing signing, not for release."
  exit 0
fi

# ---------------------------------------------------------------- notarise

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
error: no notary credentials stored under the profile "$NOTARY_PROFILE".

Create an app-specific password at appleid.apple.com, then:

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
    --apple-id you@example.com \\
    --team-id M7SS3X57KG

EOF
  exit 1
fi

# The notary service takes an archive, never a bare .app. This zip is only a
# transport: the real distributable is rebuilt after stapling, because the
# ticket has to be inside the bundle that people download.
UPLOAD="$DIST/upload.zip"
rm -f "$UPLOAD"
ditto -c -k --keepParent "$APP" "$UPLOAD"

echo "submitting to Apple (usually 1-5 minutes)"

# --wait blocks until Apple decides, but a *rejection* is still a successful
# round trip as far as the exit code is concerned. So read the verdict rather
# than trusting $?, and on a rejection fetch the log immediately: it names the
# offending binary and the reason, and without it you are guessing.
SUBMISSION="$(
  xcrun notarytool submit "$UPLOAD" \
    --keychain-profile "$NOTARY_PROFILE" \
    --output-format json \
    --wait
)"

rm -f "$UPLOAD"

SUBMISSION_ID="$(echo "$SUBMISSION" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
STATUS="$(echo "$SUBMISSION" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)"

if [[ "$STATUS" != "Accepted" ]]; then
  echo "notarisation failed: ${STATUS:-unknown status}" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    echo "--- Apple's log ---" >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  exit 1
fi

# ---------------------------------------------------------------- staple

# Stapling writes the ticket into the bundle. Without it macOS has to ask
# Apple's servers on first launch, so an offline user - or an Apple outage -
# sees the malware warning on a perfectly good app.
echo "stapling"
xcrun stapler staple "$APP"

# The real check: this is what Gatekeeper itself will conclude. "source=Notarized
# Developer ID" is the line you want; anything else means a user gets a warning.
echo "verifying"
spctl --assess --type exec --verbose=4 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "done: $ZIP"
echo "Attach that to a GitHub release. It will open with a double click."
