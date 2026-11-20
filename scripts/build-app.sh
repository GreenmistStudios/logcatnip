#!/usr/bin/env bash
# Builds Logcatnip.app from the Swift package.
#
#   scripts/build-app.sh            # release build into build/Logcatnip.app
#   CONFIG=debug scripts/build-app.sh
#   VERSION=1.2.3 scripts/build-app.sh   # the release workflow passes the version it is about to tag
#   UNIVERSAL=1 scripts/build-app.sh     # arm64 + x86_64, as releases ship (the default builds the Mac's own arch)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh   # as releases sign (default: ad hoc)
#
# Without VERSION the app takes the newest vX.Y.Z tag, so local builds compare with releases correctly.
# scripts/package-release.sh turns a Developer ID build into the notarized zip and DMG that releases publish.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
LAST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)"
VERSION="${VERSION:-${LAST_TAG#v}}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/Logcatnip.app"

ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
# `${a[@]+"${a[@]}"}`: macOS's bash 3.2 calls an empty array unbound under `set -u`.
swift build -c "$CONFIG" --product Logcatnip ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/Logcatnip"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Logcatnip"

# App icon: design/AppIcon.png (1024px, from design/render-icons.swift) scaled to every iconset size.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" design/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) design/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Logcatnip</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>studio.greenmist.logcatnip</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Logcatnip</string>
    <key>CFBundleDisplayName</key>
    <string>Logcatnip</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>studio.greenmist.logcatnip.logcat</string>
            <key>UTTypeDescription</key>
            <string>Android Logcat File</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.json</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>logcat</string>
                </array>
            </dict>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Logcatnip uses adb to find, pair and connect Android devices on your network for wireless debugging.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if [ -n "${SIGN_IDENTITY:-}" ]; then
    # Developer ID: notarization needs the hardened runtime and a secure timestamp. The app needs no
    # entitlements; it isn't sandboxed and only launches adb, simctl and sh.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP" >/dev/null
fi
echo "Built $APP"
