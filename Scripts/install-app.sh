#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$HOME/Applications/One Space.app"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/OneSpace"
osascript -e 'quit app "One Space"' >/dev/null 2>&1 || true
sleep 1; pkill -x OneSpace >/dev/null 2>&1 || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OneSpace"
# Keep an existing Info.plist. Otherwise install the source plist and pin the bundle keys.
PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  cp "Sources/OneSpace/Resources/Info.plist" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable OneSpace" "$PLIST" \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string OneSpace" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.tara.onespace" "$PLIST" \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.tara.onespace" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$PLIST" \
    || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
fi
codesign --force --deep -s - "$APP"
open "$APP"
echo "Installed and launched: $APP"
