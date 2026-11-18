#!/usr/bin/env bash
# Installs Logcatnip from GitHub Releases without the Gatekeeper warning:
#
#   curl -fsSL https://raw.githubusercontent.com/GreenmistStudios/logcatnip/main/scripts/install.sh | bash
#
# A browser marks downloads with com.apple.quarantine, and Gatekeeper blocks a quarantined app that isn't
# notarized. curl doesn't set the attribute, so an app downloaded here opens normally. The zip is checked
# against the release's SHA-256, and the app's bundle identifier, version, architecture and code signature
# are checked before it replaces an existing copy.
#
#   LOGCATNIP_VERSION=0.1.0       install that release instead of the latest
#   LOGCATNIP_INSTALL_DIR=~/Apps  install there (default: /Applications, or ~/Applications if that isn't writable)
#   LOGCATNIP_NO_OPEN=1           don't open the app afterwards
#
# Everything runs inside main(), so a download cut off halfway through doesn't run part of the script.
set -euo pipefail

REPO="GreenmistStudios/logcatnip"
BUNDLE_ID="studio.greenmist.logcatnip"
APP_NAME="Logcatnip.app"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

latest_version() {
    # /releases/latest redirects to /releases/tag/vX.Y.Z; reading the redirect avoids the API's rate limit.
    local url
    url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" ||
        die "couldn't reach GitHub"
    case "$url" in
        */releases/tag/v*) printf '%s\n' "${url##*/releases/tag/v}" ;;
        *) die "no release found at https://github.com/$REPO/releases" ;;
    esac
}

main() {
    [ "$(uname -s)" = "Darwin" ] || die "Logcatnip runs on macOS only"
    local os_major
    os_major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$os_major" -ge 14 ] || die "Logcatnip needs macOS 14 or later (this Mac has $(sw_vers -productVersion))"

    local version="${LOGCATNIP_VERSION:-}"
    version="${version#v}"
    [ -n "$version" ] || version="$(latest_version)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a version: $version"

    local install_dir="${LOGCATNIP_INSTALL_DIR:-}"
    if [ -z "$install_dir" ]; then
        install_dir="/Applications"
        if [ ! -w "$install_dir" ]; then
            install_dir="$HOME/Applications"
            say "/Applications isn't writable; installing to $install_dir"
        fi
    fi
    mkdir -p "$install_dir" || die "couldn't create $install_dir"
    [ -w "$install_dir" ] || die "$install_dir isn't writable"

    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/logcatnip-install.XXXXXX")"
    # shellcheck disable=SC2064 # expand now: $work is local and gone by the time the trap runs.
    trap "rm -rf '$work'" EXIT

    local zip="Logcatnip-$version.zip"
    local base="https://github.com/$REPO/releases/download/v$version"
    say "Downloading Logcatnip $version"
    curl -fL --progress-bar -o "$work/$zip" "$base/$zip" || die "couldn't download $base/$zip"
    curl -fsSL -o "$work/$zip.sha256" "$base/$zip.sha256" || die "couldn't download $base/$zip.sha256"

    local expected actual
    expected="$(awk '{ print $1; exit }' "$work/$zip.sha256")"
    actual="$(shasum -a 256 "$work/$zip" | awk '{ print $1 }')"
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        die "checksum mismatch for $zip (expected ${expected:-nothing}, got $actual)"
    fi

    ditto -x -k "$work/$zip" "$work/unpacked" || die "couldn't unpack $zip"
    local app="$work/unpacked/$APP_NAME"
    [ -d "$app" ] || die "$zip has no $APP_NAME"

    local plist="$app/Contents/Info.plist" id short arch
    id="$(plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null || true)"
    [ "$id" = "$BUNDLE_ID" ] || die "unexpected bundle identifier: ${id:-missing}"
    short="$(plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || true)"
    [ "$short" = "$version" ] || die "the app says it's version ${short:-missing}, expected $version"
    arch="$(uname -m)"
    [[ " $(lipo -archs "$app/Contents/MacOS/Logcatnip") " == *" $arch "* ]] || die "this release doesn't run on $arch"
    codesign --verify --deep --strict "$app" 2>/dev/null || die "the app's code signature is invalid"
    xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

    local target="$install_dir/$APP_NAME" was_running=0
    if pgrep -qf "$target/Contents/MacOS/Logcatnip"; then
        was_running=1
        say "Quitting Logcatnip"
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        local i=0
        while pgrep -qf "$target/Contents/MacOS/Logcatnip"; do
            i=$((i + 1))
            [ "$i" -le 50 ] || die "Logcatnip is still running; quit it and run the installer again"
            sleep 0.2
        done
    fi

    # Keep the old app until the new one is in place, so a failed move leaves a working copy.
    local backup="$install_dir/.Logcatnip-previous-$$.app"
    if [ -e "$target" ]; then
        mv "$target" "$backup" || die "couldn't move the existing $target aside"
    fi
    if ! mv "$app" "$target"; then
        [ -e "$backup" ] && mv "$backup" "$target"
        die "couldn't move the app to $target"
    fi
    rm -rf "$backup"

    say "Installed Logcatnip $version to $target"
    if [ "${LOGCATNIP_NO_OPEN:-0}" != "1" ]; then
        open "$target"
    elif [ "$was_running" = 1 ]; then
        say "Logcatnip was running; open it again to use $version"
    fi
}

main "$@"
