#!/usr/bin/env bash
# Builds Kertas.app into ./build, signs it, and installs it in /Applications.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

echo "→ compiling"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Kertas"

APP="$ROOT/build/Kertas.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kertas"
cp "$ROOT/tools/helper.py" "$APP/Contents/Resources/helper.py"
[[ -f "$ROOT/assets/Kertas.icns" ]] && cp "$ROOT/assets/Kertas.icns" "$APP/Contents/Resources/"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# Point the app at the editable copy of the helper, so changing it needs no rebuild.
/usr/libexec/PlistBuddy -c "Delete :KertasHelperPlaceholder" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :KertasHelper string $ROOT/tools/helper.py" "$APP/Contents/Info.plist"

# The shared local certificate keeps the app's identity fixed across rebuilds,
# so macOS asks about folder access once, not after every build.
"$HOME/Desktop/project/3d/bengkel/common/sign.sh" "$APP"

rm -rf /Applications/Kertas.app
cp -R "$APP" /Applications/Kertas.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Kertas.app
echo "→ installed /Applications/Kertas.app"
