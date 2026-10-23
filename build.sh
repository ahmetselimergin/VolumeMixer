#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP="build/Volume Mixer.app"

# App icon is generated once from tools/make_icon.swift.
if [[ ! -f Resources/AppIcon.icns ]]; then
    mkdir -p Resources build/AppIcon.iconset
    swift tools/make_icon.swift build/icon_1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.2" Sources/*.swift -o "$APP/Contents/MacOS/VolumeMixer"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
