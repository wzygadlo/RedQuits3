#!/bin/sh
# Build RedQuits3.app into dist/ (ad-hoc signed, arm64).
# shortcut: ad-hoc signature changes on every rebuild, so Accessibility must be
# re-granted after each rebuild; upgrade to a stable signing identity if that gets old.
set -eu
cd "$(dirname "$0")"

APP=dist/RedQuits3.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos13.0 Sources/App.swift Sources/main.swift -o "$APP/Contents/MacOS/RedQuits3" \
    -framework AppKit -framework ApplicationServices

cp Assets/RedQuits3.icns Assets/StatusIcon.png Assets/StatusIcon@2x.png "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>RedQuits3</string>
    <key>CFBundleIdentifier</key><string>com.wzygadlo.RedQuits3</string>
    <key>CFBundleName</key><string>RedQuits3</string>
    <key>CFBundleDisplayName</key><string>RedQuits3</string>
    <key>CFBundleIconFile</key><string>RedQuits3</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Wojtek Zygadlo. MIT License.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --options runtime --timestamp=none --sign - "$APP"
codesign --verify --strict "$APP"
echo "Done: $APP"
