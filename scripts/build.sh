#!/bin/bash
# Builds a signed Release HomeRelay.app for Mac Catalyst into build/Release.
# Signing uses the workspace App Store Connect key so Xcode can create or
# refresh the development profile (HomeKit capability) without the GUI.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${APPLE_APPS_ENV:-$REPO_ROOT/../../.private/apple-apps.env}"  # optional App Store Connect key env file
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

auth=()
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
    if [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]]; then
        auth=(-authenticationKeyPath "$APP_STORE_CONNECT_API_KEY_PATH"
              -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID"
              -authenticationKeyIssuerID "$APP_STORE_CONNECT_API_ISSUER_ID")
    fi
fi

cd "$REPO_ROOT"
mkdir -p build
xcodegen generate --quiet
APP="build/DerivedData/Build/Products/Release-maccatalyst/HomeRelay.app"
rm -rf "$APP"  # so a failed build can't pass off an old app as new
# ${auth[@]+...} keeps macOS's bash 3.2 happy when the array is empty under set -u.
set +e
xcodebuild \
    -project HomeRelay.xcodeproj \
    -scheme HomeRelay \
    -configuration Release \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath build/DerivedData \
    -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
    build > build/xcodebuild.log 2>&1
status=$?
set -e
grep -E "error:|warning: .*HomeRelay|BUILD (SUCCEEDED|FAILED)" build/xcodebuild.log || true
if (( status != 0 )) || [[ ! -d "$APP" ]]; then
    if grep -q "Program License Agreement" build/xcodebuild.log; then
        echo "Apple wants the latest Program License Agreement accepted: sign in at developer.apple.com/account and accept it." >&2
    fi
    echo "Build failed (xcodebuild exit $status); see build/xcodebuild.log" >&2
    exit 1
fi
rm -rf build/Release && mkdir -p build/Release && ditto "$APP" build/Release/HomeRelay.app
codesign --verify --strict build/Release/HomeRelay.app
echo "Built $(pwd)/build/Release/HomeRelay.app"
