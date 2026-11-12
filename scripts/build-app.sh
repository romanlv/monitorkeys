#!/bin/bash
# Builds build/Lumen.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
app=build/Lumen.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Lumen "$app/Contents/MacOS/Lumen"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.ourapp.lumen</string>
    <key>CFBundleName</key><string>Lumen</string>
    <key>CFBundleExecutable</key><string>Lumen</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocationUsageDescription</key><string>Lumen uses your approximate location to work out sunrise and sunset for the day schedule.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>Lumen uses your approximate location to work out sunrise and sunset for the day schedule.</string>
</dict>
</plist>
PLIST

# Sign with the local certificate in signing/ when present (scripts/make-signing-cert.sh), so macOS
# keeps permissions such as Accessibility across rebuilds. Falls back to ad-hoc signing.
keychain="$PWD/signing/lumen.keychain-db"
identity="Lumen Local Signing"
if [[ -f "$keychain" ]]; then
    security unlock-keychain -p lumen "$keychain"
    # codesign only finds identities in the search list. Add ours for the duration of the signing,
    # then put the user's list back exactly as it was.
    original=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}" # trim leading spaces
        line="${line%\"}"
        original+=("${line#\"}")
    done < <(security list-keychains -d user)
    trap 'security list-keychains -d user -s ${original[@]+"${original[@]}"}' EXIT
    security list-keychains -d user -s ${original[@]+"${original[@]}"} "$keychain"
    codesign --force --sign "$identity" "$app"
else
    codesign --force --sign - "$app"
fi
echo "built $app"
