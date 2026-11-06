#!/bin/sh
# ./build.sh          builds Tadak.app and installs it to /Applications. Signs with your Apple Development cert, if you
#                     have one, so the Accessibility permission survives rebuilds (ad-hoc signing resets it).
# ./build.sh release  builds Tadak.zip to publish instead: Apple silicon + Intel, ad-hoc signed (a personal cert's name
#                     would be readable in the download), not installed.
set -e
cd "$(dirname "$0")"
APP=Tadak.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
compile() { swiftc -O -target "$1-apple-macos14.0" main.swift -o "$2"; }  # SwiftUI panel features need macOS 14
if [ "$1" = release ]; then
    TMP=$(mktemp -d)
    compile arm64 "$TMP/arm64"; compile x86_64 "$TMP/x86_64"
    lipo -create "$TMP/arm64" "$TMP/x86_64" -output $APP/Contents/MacOS/Tadak
    rm -rf "$TMP"
else
    compile "$(uname -m)" $APP/Contents/MacOS/Tadak
fi
cp -R sounds/ $APP/Contents/Resources/  # recorded clips (tools/session.sh + tools/slice, tools/clicks)
cp AppIcon.icns $APP/Contents/Resources/  # drawn by tools/icon.swift
cp -R icons $APP/Contents/Resources/icons  # Phosphor Icons, MIT
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.tadak</string>
  <key>CFBundleName</key><string>Tadak</string>
  <key>CFBundleExecutable</key><string>Tadak</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
if [ "$1" = release ]; then
    codesign --force -s - $APP
    rm -f Tadak.zip && ditto -c -k --norsrc --noextattr --keepParent $APP Tadak.zip
    echo "built Tadak.zip"
    exit
fi
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force -s "${IDENTITY:--}" $APP
pkill -x Tadak || true
rm -rf /Applications/$APP && ditto $APP /Applications/$APP
echo "installed /Applications/$APP"
