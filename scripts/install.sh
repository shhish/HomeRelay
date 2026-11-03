#!/bin/bash
# Builds HomeRelay, installs it to ~/Applications and (re)starts the LaunchAgent.
#   scripts/install.sh            build + install + restart
#   scripts/install.sh --no-build install the existing build/Release app
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DEST="$HOME/Applications/HomeRelay.app"
PORT="${HOMERELAY_PORT:-18796}"

cd "$REPO_ROOT"
[[ "${1:-}" == "--no-build" ]] || scripts/build.sh

# The LaunchAgent label follows the app's bundle ID (set in Config/Local.xcconfig).
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/Release/HomeRelay.app/Contents/Info.plist)"
LABEL="${HOMERELAY_LABEL:-$BUNDLE_ID.backend}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x HomeRelay 2>/dev/null || true
mkdir -p "$HOME/Applications" logs
rm -rf "$APP_DEST"
ditto build/Release/HomeRelay.app "$APP_DEST"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$REPO_ROOT/scripts/run.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOMERELAY_PORT</key>
    <string>$PORT</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$REPO_ROOT</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$REPO_ROOT/logs/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$REPO_ROOT/logs/launchd.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
# RunAtLoad does not always fire for a freshly bootstrapped agent.
launchctl kickstart "gui/$(id -u)/$LABEL"
echo "Installed $APP_DEST and started $LABEL"

for _ in $(seq 1 30); do
    if body=$(curl -fsS -m 2 "http://127.0.0.1:$PORT/api/v1/health" 2>/dev/null); then
        echo "Health: $body"
        exit 0
    fi
    sleep 1
done
echo "No health response on port $PORT yet; check logs/homerelay.log" >&2
exit 1
