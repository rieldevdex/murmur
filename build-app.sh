#!/bin/bash
# Builds Murmur.app next to this script.
# Run from Terminal:  ./build-app.sh   then   open Murmur.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Murmur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"
cp Info.plist "$APP/Contents/Info.plist"

# App icon: turn Icon.png (1024 x 1024) into the .icns file macOS expects.
# To use your own icon, replace Icon.png with any square PNG and rebuild.
if [ -f Icon.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size Icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double Icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

# Signing. macOS remembers permissions (Screen Recording, Accessibility, Automation) by the
# app's signature. An ad-hoc signature changes with every build, so permissions reset each time.
# A signing certificate of your own keeps the signature the same, so they're kept. To make one
# (once): Keychain Access › Certificate Assistant › Create a Certificate…, name it
# "Murmur Signing", Identity Type "Self Signed Root", Certificate Type "Code Signing".
IDENTITY="Murmur Signing"
# A certificate made under the app's old name works too
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    IDENTITY="Visualiser Signing"
fi
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\" (permissions will be kept between builds)"
else
    codesign --force --sign - "$APP"
    echo "Signed ad hoc: no \"$IDENTITY\" certificate found, so macOS may ask for permissions again"
fi

# Nudge Finder and the Dock to pick up a changed icon
touch "$APP"

echo "Built $APP"
