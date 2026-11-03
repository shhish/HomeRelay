# HomeRelay design

- **What it is:** a headless Mac Catalyst service that serves Apple Home over a token-protected LAN API (`docs/API.md`), for microcontrollers and other local clients.
- **Not in scope:** MCP, history or SQLite logging, a Homebridge fallback, public internet exposure, automations or rules. Use the Home app or a separate tool for those.
- **Platform:** Mac Catalyst only. The iOS target exists because Catalyst requires it; nothing ships to iPhone or iPad. The app has no user data and no UI beyond a 1x1 hidden window that HomeKit needs.
- **Exposure:** LAN on port 18796. Every route except `/api/v1/health` needs a bearer token. Don't put it behind a public hostname.

## Runtime

- LaunchAgent `<bundle id>.backend` → `scripts/run.sh` → `open -n -W` on `~/Applications/HomeRelay.app`. HomeKit needs a LaunchServices launch with an active UIKit scene; exec'ing the binary directly loses Home access.
- Health: `GET /api/v1/health` (`homekit` is `starting`, `ready`, `notAuthorized` or `noHomes`).
- Home access is granted once per bundle ID in System Settings → Privacy & Security → Home. A new bundle ID or signing team means asking again.
- Logs: `logs/homerelay.log` (writes and errors; set `HOMERELAY_LOG_READS=1` for reads), rotated at 10 MB on restart.
- Tokens: `scripts/homerelay-token`. Hashes only, in `~/Library/Application Support/HomeRelay/tokens.json`.

## Signing

`scripts/build.sh` uses automatic Apple Development signing with `-allowProvisioningUpdates`. If `APPLE_APPS_ENV` points to a file defining `APP_STORE_CONNECT_API_KEY_PATH`, `APP_STORE_CONNECT_API_KEY_ID` and `APP_STORE_CONNECT_API_ISSUER_ID`, the build uses that App Store Connect key to refresh profiles without the Xcode UI. Enable the HomeKit capability on your App ID once in the developer portal; automatic signing alone can't add it.
