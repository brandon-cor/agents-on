#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-0.4.1}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use a version such as 0.4.1' >&2; exit 2; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
package="$work/Agents-On"
app="$package/Agents On.app"
mkdir -p "$app/Contents/MacOS" dist
for arch in arm64 x86_64; do
  /usr/bin/swiftc -target "$arch-apple-macos14.0" Sources/main.swift -o "$work/AgentsOn-$arch" -framework Cocoa
done
/usr/bin/lipo -create "$work/AgentsOn-arm64" "$work/AgentsOn-x86_64" -output "$app/Contents/MacOS/AgentsOn"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.brandon-cor.agents-on</string>
<key>CFBundleName</key><string>Agents On</string>
<key>CFBundleExecutable</key><string>AgentsOn</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app"
cp scripts/agents scripts/shell.sh scripts/uninstall.sh scripts/start.sh scripts/doctor.sh "$package/"
cp README.md LICENSE "$package/"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package" dist/Agents-On-macOS.zip
(cd dist && /usr/bin/shasum -a 256 Agents-On-macOS.zip > SHA256SUMS)
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/lipo -archs "$app/Contents/MacOS/AgentsOn"
"$app/Contents/MacOS/AgentsOn" --status
