#!/bin/bash
# Builds build/MonitorKeys.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
app=build/MonitorKeys.app

# Quit any copy running from this bundle before replacing it. Once its files change, macOS can
# no longer verify it, and WindowServer drops every key and click its event tap passes on.
# Matched on the resolved paths of the files each process maps as code ("txt" in lsof), so it
# doesn't matter how the copy was started (open, relative path, symlinked folder).
exe="$(cd "$(dirname "$app")" 2>/dev/null && pwd -P || echo "$(pwd -P)/$(dirname "$app")")/$(basename "$app")/Contents/MacOS/MonitorKeys"
running_here() {
    local pid
    for pid in $(pgrep -x MonitorKeys || true); do
        lsof -a -p "$pid" -d txt -Fn 2>/dev/null | grep -qxF "n$exe" && echo "$pid"
    done
    return 0
}
pids=$(running_here)
if [[ -n "$pids" ]]; then
    kill -TERM $pids 2>/dev/null || true
    for _ in {1..50}; do
        [[ -z "$(running_here)" ]] && break
        sleep 0.1
    done
    pids=$(running_here)
    [[ -n "$pids" ]] && kill -KILL $pids 2>/dev/null || true
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/MonitorKeys "$app/Contents/MacOS/MonitorKeys"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.ourapp.monitorkeys</string>
    <key>CFBundleName</key><string>MonitorKeys</string>
    <key>CFBundleExecutable</key><string>MonitorKeys</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.3</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocationUsageDescription</key><string>MonitorKeys uses your approximate location to work out sunrise and sunset for the day schedule.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>MonitorKeys uses your approximate location to work out sunrise and sunset for the day schedule.</string>
</dict>
</plist>
PLIST

# Sign with the local certificate in signing/ when present (scripts/make-signing-cert.sh), so macOS
# keeps permissions such as Accessibility across rebuilds. Falls back to ad-hoc signing.
keychain="$PWD/signing/monitorkeys.keychain-db"
identity="MonitorKeys Local Signing"
if [[ -f "$keychain" ]]; then
    security unlock-keychain -p monitorkeys "$keychain"
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
