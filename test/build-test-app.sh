#!/bin/bash
# Builds the self-test app bundle on the host (it is never launched on the host).
# Usage: build-test-app.sh OUTPUT_DIR  -> OUTPUT_DIR/MacvmTest.app
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: build-test-app.sh OUTPUT_DIR}
app="$out/MacvmTest.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O "$here/TestApp.swift" -o "$app/Contents/MacOS/MacvmTest"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.macvm.test</string>
  <key>CFBundleName</key><string>MacvmTest</string>
  <key>CFBundleExecutable</key><string>MacvmTest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1
echo "$app"
