#!/bin/zsh
# Usage: ./build.sh [--install|--pkg]
set -euo pipefail
cd "$(dirname "$0")"

# The app's file name, jaredsmacutils, names the executable and the installer too. The Swift package keeps the app's
# old name, Yafie.
NAME="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' Resources/Info.plist)"
ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)"
APP="build/$NAME.app"
MODE="${1:-}"

# Release also covers Intel
ARCHS=()
[[ "$MODE" == "--pkg" ]] && ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Yafie"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuIcon.tiff Resources/MenuIconOutline.tiff "$APP/Contents/Resources/"
# The name Finder shows, Jared's Cool Mac Utilities App
cp -R Resources/en.lproj "$APP/Contents/Resources/"

# A Developer ID Application certificate signs it, with the hardened runtime notarization needs. macOS ties the app's
# permissions to the team, so they last across updates. YAFIE_SIGNING_IDENTITY picks one by name or SHA-1. See
# docs/buildfromsource.md.
IDENTITY="${YAFIE_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ { print $2; exit }')"
fi
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --entitlements Resources/jaredsmacutils.entitlements \
        --strip-disallowed-xattrs --sign "$IDENTITY" "$APP"
    TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    SIGNED_BY="Developer ID, team $TEAM"
elif [[ "$MODE" == "--pkg" ]]; then
    echo "No Developer ID Application identity. Run scripts/setup-signing.sh first." >&2
    exit 1
else
    codesign --force --strip-disallowed-xattrs --sign - "$APP"  # ad hoc is enough for a build from source
    SIGNED_BY="ad hoc"
fi
echo "Built $APP (signed by $SIGNED_BY)"

if [[ "$MODE" == "--install" ]]; then
    # SIGTERM lets it restore sleep. Before 1.1.4, it ran as Yafie.
    for running in "$NAME" Yafie; do
        if pkill -x "$running"; then
            for _ in {1..25}; do
                pgrep -x "$running" >/dev/null || break
                sleep 0.2
            done
        fi
    done
    rm -rf "/Applications/$NAME.app"
    # The copy from before the rename, but never another app with that name
    old_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' /Applications/Yafie.app/Contents/Info.plist \
        2>/dev/null || true)"
    if [[ "$old_id" == "$ID" ]]; then rm -rf /Applications/Yafie.app; fi
    ditto "$APP" "/Applications/$NAME.app"
    open "/Applications/$NAME.app"
    echo "Installed /Applications/$NAME.app"
fi

if [[ "$MODE" == "--pkg" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
    MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Resources/Info.plist)"
    TITLE="$(plutil -extract CFBundleDisplayName raw -o - Resources/en.lproj/InfoPlist.strings)"
    # Fixed name keeps the README download link stable
    PKG="downloads/$NAME.pkg"
    WORK="build/pkg"
    rm -rf "$WORK"
    mkdir -p "$WORK/root" downloads
    ditto "$APP" "$WORK/root/$NAME.app"

    # Always /Applications, never "relocated" onto another copy macOS knows about
    pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
    /usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$WORK/component.plist"
    pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --scripts Resources/pkg/scripts \
        --identifier "$ID" --version "$VERSION" --install-location /Applications "$WORK/$NAME-app.pkg" >/dev/null

    # Installer's title, checks, and closing page
    cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>$TITLE</title>
    <conclusion file="conclusion.txt" mime-type="text/plain"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="$MIN_OS"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="$ID"/>
    </choices-outline>
    <choice id="$ID" visible="false">
        <pkg-ref id="$ID"/>
    </choice>
    <pkg-ref id="$ID" version="$VERSION" onConclusion="none">$NAME-app.pkg</pkg-ref>
</installer-gui-script>
EOF
    # The installer has its own certificate, Developer ID Installer, from the same team
    INSTALLER="${YAFIE_INSTALLER_IDENTITY:-}"
    if [[ -z "$INSTALLER" ]]; then
        INSTALLER="$(security find-identity -v | awk '/"Developer ID Installer/ { print $2; exit }')"
    fi
    if [[ -z "$INSTALLER" ]]; then
        echo "No Developer ID Installer identity. Run scripts/setup-signing.sh first." >&2
        exit 1
    fi
    rm -f "$PKG"
    productbuild --distribution "$WORK/distribution.xml" --resources Resources/pkg/resources \
        --package-path "$WORK" --sign "$INSTALLER" --timestamp "$PKG" >/dev/null
    rm -rf "$WORK"

    # Notarizes the installer, and the app in it, with an app-specific password, so Gatekeeper opens it without a
    # warning. Apple usually takes minutes, but a new kind of submission can take hours. Then NOTARY_REQUIRED (releases)
    # stops here, and anything else carries on unnotarized.
    if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
        notary() { xcrun notarytool "$@" --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$TEAM" }
        # The result goes to stdout, or to stderr when the wait runs out
        notary submit "$PKG" --wait --timeout "${NOTARY_TIMEOUT:-60m}" --output-format json \
            > build/notary.out 2>&1 || true
        cat build/notary.out
        STATUS="$(sed -nE 's/.*"status" *: *"([^"]+)".*/\1/p' build/notary.out | head -1)"
        SUBMISSION="$(sed -nE 's/.*"id" *: *"([0-9a-fA-F-]{36})".*/\1/p' build/notary.out | head -1)"
        if [[ "$STATUS" == "Accepted" ]]; then
            xcrun stapler staple "$PKG"
            echo "Notarized and stapled"
        elif [[ -n "$SUBMISSION" && ( -z "$STATUS" || "$STATUS" == "In Progress" ) ]]; then
            echo "Apple is still notarizing submission $SUBMISSION. Its recent submissions:"
            notary history 2>&1 | head -12 || true
            if [[ -n "${NOTARY_REQUIRED:-}" ]]; then
                echo "Stopping rather than publishing it unnotarized. Run this again once Apple finishes." >&2
                exit 1
            fi
            echo "::warning::Apple hasn't finished notarizing submission $SUBMISSION, so this build isn't notarized."
        else
            [[ -n "$SUBMISSION" ]] && notary log "$SUBMISSION" || true
            echo "Notarization failed${STATUS:+ ($STATUS)}" >&2
            exit 1
        fi
    elif [[ -n "${NOTARY_REQUIRED:-}" ]]; then
        echo "Set NOTARY_APPLE_ID and NOTARY_PASSWORD to notarize." >&2
        exit 1
    else
        echo "Not notarized: set NOTARY_APPLE_ID and NOTARY_PASSWORD to notarize."
    fi

    # What Check for Updates reads, hashed after stapling. The hash lets it reject a stale or broken download.
    cat > downloads/update.json <<EOF
{
  "version": "$VERSION",
  "url": "https://github.com/jfreema/Jareds-Cool-Mac-Utils-App/raw/main/downloads/$NAME.pkg",
  "sha256": "$(shasum -a 256 "$PKG" | cut -d' ' -f1)"
}
EOF
    # Not downloads/latest.json and Yafie.pkg: they stay at 1.1.3, the last Yafie, for copies before it, which only
    # take Yafie.app. 1.1.3's Check for Updates then takes them on to the new name.
    # README shows the version next to the download link
    sed -i '' -E "s/Version [0-9.]+ ·/Version $VERSION ·/" README.md
    echo "Built $PKG ($VERSION) and downloads/update.json"
fi
