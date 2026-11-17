#!/bin/sh
# Build the disposable test fixture into dist/WindowFixture.app. RedQuits3 ignores apps without a
# bundle identifier, so a bare swiftc binary would never be quit. Run after build.sh, which clears dist/.
set -eu
cd "$(dirname "$0")/.."

APP=dist/WindowFixture.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -target arm64-apple-macos13.0 Tests/WindowFixture.swift -o "$APP/Contents/MacOS/WindowFixture"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>WindowFixture</string>
    <key>CFBundleIdentifier</key><string>com.wzygadlo.RedQuits3.WindowFixture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
EOF
echo "Done: $APP"
