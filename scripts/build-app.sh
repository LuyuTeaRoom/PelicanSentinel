#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift scripts/make-icon.swift artifacts/AppIcon.iconset
iconutil -c icns artifacts/AppIcon.iconset -o Resources/AppIcon.icns
swift build -c release
app="$PWD/dist/Pelican Sentinel.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
binary_dir="$(swift build -c release --show-bin-path)"
cp "$binary_dir/PelicanSentinel" "$app/Contents/MacOS/PelicanSentinel"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/PelicanLogo.svg Resources/MenuBarLogo.svg "$app/Contents/Resources/"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
print "$app"
