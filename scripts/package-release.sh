#!/usr/bin/env bash
# Packages a Developer ID build of build/Logcatnip.app (scripts/build-app.sh with SIGN_IDENTITY) for a release:
#
#   build/Logcatnip-X.Y.Z.dmg          the installer: drag the app onto Applications
#   build/Logcatnip-X.Y.Z.zip          what the in-app updater downloads
#   and a .sha256 next to each
#
# Both are notarized, with the ticket stapled, so Gatekeeper opens them without a warning, even offline.
#
#   VERSION=1.2.3 SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package-release.sh
#
# Notarization credentials, either:
#   NOTARY_PROFILE=name                                     a `xcrun notarytool store-credentials` keychain profile
#   NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=… NOTARY_ISSUER=…   an App Store Connect API key, as the release workflow uses
# SKIP_NOTARIZE=1 packages without notarizing, to try the DMG locally; don't publish that.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Logcatnip.app"
: "${VERSION:?set VERSION, e.g. VERSION=1.2.3}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to the Developer ID Application identity the app was built with}"
DMG="build/Logcatnip-$VERSION.dmg"
ZIP="build/Logcatnip-$VERSION.zip"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -d "$APP" ] || die "no $APP; run scripts/build-app.sh first"
built="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[ "$built" = "$VERSION" ] || die "built $built, expected $VERSION"
archs="$(lipo -archs "$APP/Contents/MacOS/Logcatnip")"
for arch in arm64 x86_64; do
    [[ " $archs " == *" $arch "* ]] || die "missing $arch (has: $archs); build with UNIVERSAL=1"
done
codesign --verify --deep --strict "$APP"
# Notarization rejects ad-hoc signatures and apps without the hardened runtime; say so before uploading.
details="$(codesign -dvv "$APP" 2>&1)"
[[ "$details" == *"Authority=Developer ID Application"* ]] || die "$APP isn't signed with a Developer ID; build with SIGN_IDENTITY"
[[ "$details" == *"(runtime)"* ]] || die "$APP isn't signed with the hardened runtime"

notary_auth=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
    notary_auth=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ]; then
    notary_auth=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER:?set NOTARY_ISSUER}")
elif [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    die "set NOTARY_PROFILE, or NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER (or SKIP_NOTARIZE=1 to try it locally)"
fi

# The DMG holds the app and a link to /Applications, the usual drag-to-install window.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/Logcatnip.app"
ln -s /Applications "$stage/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Logcatnip" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "warning: SKIP_NOTARIZE=1, so Gatekeeper will still warn about these" >&2
else
    # Notarizing the DMG notarizes the app inside it too, so one upload covers both.
    echo "Notarizing $DMG (usually a few minutes)"
    result="$(xcrun notarytool submit "$DMG" "${notary_auth[@]}" --wait --timeout 30m --output-format plist)" ||
        true
    status="$(plutil -extract status raw - <<<"$result" 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        id="$(plutil -extract id raw - <<<"$result" 2>/dev/null || true)"
        [ -n "$id" ] && xcrun notarytool log "$id" "${notary_auth[@]}" >&2 || true
        die "notarization finished with status '${status:-unknown}': $result"
    fi
    xcrun stapler staple -q "$DMG"
    xcrun stapler staple -q "$APP"
    spctl --assess --type execute "$APP"
    spctl --assess --type open --context context:primary-signature "$DMG"
fi

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
for file in "$ZIP" "$DMG"; do
    (cd "$(dirname "$file")" && shasum -a 256 "$(basename "$file")" > "$(basename "$file").sha256")
    cat "$file.sha256"
done
