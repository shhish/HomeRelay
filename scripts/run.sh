#!/bin/bash
# LaunchAgent entry point. HomeKit only works when the app is launched through
# LaunchServices (so it gets a UIKit scene and its own privacy permissions),
# so this waits on `open -W` instead of exec'ing the binary.
#
# It also restarts the app itself: under load launchd defers KeepAlive
# respawns ("pended nondemand spawn"), which left the API down for minutes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${HOMERELAY_APP:-$HOME/Applications/HomeRelay.app}"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/homerelay.log"
mkdir -p "$LOG_DIR"

[[ -d "$APP" ]] || { echo "HomeRelay.app not found at $APP; run scripts/install.sh" >&2; exit 78; }


# open(1) does not forward the caller's environment, so pass settings explicitly.
env_args=()
while IFS='=' read -r key value; do
    env_args+=(--env "$key=$value")
done < <(env | grep '^HOMERELAY_' | grep -v '^HOMERELAY_APP=' || true)

# Stopping the LaunchAgent (bootout sends SIGTERM) also quits the app.
trap 'pkill -x HomeRelay; exit 0' TERM INT

delay=5
while true; do
    # Keep one previous log once it passes 10 MB.
    if [[ -f "$LOG" ]] && (( $(stat -f%z "$LOG") > 10485760 )); then
        mv "$LOG" "$LOG.1"
    fi
    started=$SECONDS
    open -n -W --stdout "$LOG" --stderr "$LOG" ${env_args[@]+"${env_args[@]}"} "$APP" &
    wait $! || true
    # A run under 30 s is a crash loop (port taken, bad build): back off to 60 s.
    if (( SECONDS - started < 30 )); then
        delay=$(( delay * 2 > 60 ? 60 : delay * 2 ))
    else
        delay=5
    fi
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') HomeRelay exited; restarting in ${delay}s" >&2
    sleep "$delay" &
    wait $!
done
