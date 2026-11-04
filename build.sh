#!/bin/zsh
# Builds Claude Limits.app into ./build. Pass "install" to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Limits"
APP="build/Claude Limits.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Limits"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

if [[ "${1:-}" == "install" ]]; then
  pkill -x Limits 2>/dev/null || true
  # Opening the app while the old copy is still quitting fails with error -600.
  sleep 1
  rm -rf "/Applications/Claude Limits.app"
  cp -R "$APP" /Applications/
  open "/Applications/Claude Limits.app"
  echo "Installed /Applications/Claude Limits.app"
else
  echo "Built $APP"
fi
