# HomeRelay design

- **What it is:** a headless Mac Catalyst service that serves Apple Home over a token-protected LAN API (`docs/API.md`), for microcontrollers and other local clients.
- **In scope since November 2026:** a durable event log, and later long-term history and virtual accessories ("States"), because HomeRelay sees every value first and knows exactly when it wasn't running. See "Event log" below.
- **Not in scope:** MCP, a Homebridge fallback, public internet exposure, automations or rules. Rules run in a separate engine that consumes the event stream and calls this API.
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

## Event log

- `HomeKitStore` hands every event to `EventHub.publish`, which appends it to `EventLog` (numbering it with `seq`) and only then fans it out, so a slow or disconnected stream client can always recover from the log. Periodic `sample` records go to the log only.
- `EventLog` is SQLite in WAL mode on the internal disk (`hot.sqlite` next to `tokens.json`). One serial queue does all SQLite work; events are written in one transaction per second, so a crash loses at most about a second. SIGTERM flushes first.
- `seq` never repeats: `meta.last_seq` survives retention, and after an unclean stop numbering skips ahead 10,000 past numbers the crashed run may have streamed but not written. `meta.store_id` identifies the install; a client that passes it back as `?store=` gets a `reset` gap instead of resuming another install's position.
- Retention: archived rows older than 14 days are deleted hourly. Until the history archiver exists, nothing is archived, so rows stay until the 2 GB cap, past which the oldest tenth goes and the count is kept in `meta.dropped`.
- `sessions` records each run's start, last-alive time (every 30 s) and stop, so history can show gaps instead of drawing a flat line across them.
- Event stream connections are pull-based (`EventStreamSession`): replays never outrun the client, and a client that falls behind live events catches up from the log.
