# HomeRelay design

- **What it is:** a headless Mac Catalyst service that serves Apple Home over a token-protected LAN API (`docs/API.md`), for microcontrollers and other local clients.
- **In scope since November 2026:** a durable event log, and later long-term history and virtual accessories ("States"), because HomeRelay sees every value first and knows exactly when it wasn't running. See "Event log" below.
- **Not in scope:** MCP, a Homebridge fallback, public internet exposure, automations or rules. Rules run in a separate engine that consumes the event stream and calls this API.
- **Platform:** Mac Catalyst only. The iOS target exists because Catalyst requires it; nothing ships to iPhone or iPad. The service persists events, history and States, and has no UI beyond a 1x1 hidden window that HomeKit needs.
- **Exposure:** LAN on port 18796. GET `/api/v1/health` and its `/ready`, `/history` and `/bridge` subroutes are public; other API operations need a bearer token (OPTIONS preflight is public). Health routes reject other methods with 405 and `Allow: GET`. Don't put it behind a public hostname.

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
- `EventLog` is SQLite in WAL mode with FULL synchronization on the internal disk (`hot.sqlite` next to `tokens.json`). One serial queue does all SQLite work; events normally flush once per second. Disk failures can retain up to 100,000 queued events, so the normal one-second crash-loss window is not a guarantee during I/O failure. SIGTERM flushes first; a session is marked stopped only after a successful flush.
- `seq` never repeats: before allocating from a new block of 10,000 numbers, the log commits `meta.reserved_seq`. An unclean restart skips the unused reservation (and retains the old 10,000-number migration margin). A successful clean close releases unused numbers in the same transaction that marks the session stopped. `meta.last_seq` survives retention. A failed reservation drops the new event rather than issuing an unsafe number or streaming an unresumable event; health and drop counters expose the failure. `meta.store_id` identifies the install; a client that passes it back as `?store=` gets a `reset` gap instead of resuming another install's position.
- Retention: archived rows older than 14 days are deleted hourly. Unarchived rows stay until the 2 GB logical-data cap, past which oldest events are dropped even without a history copy; the count is kept in `meta.dropped`. This measures live SQLite pages, not total filesystem allocation including free pages and WAL.
- `sessions` records each run's start, last-alive time (every 30 s) and stop, so history can show gaps instead of drawing a flat line across them.
- Event stream connections are pull-based (`EventStreamSession`): replays never outrun the client, and a client that falls behind live events catches up from the log.

## History

- `History` (HomeRelayCore) copies the event log to `HOMERELAY_HISTORY_DIR` every minute: `history/raw/YYYY-MM.sqlite` (UTC months; samples and reachability) and `history/rollups.sqlite` (series catalog, names over time, sessions, `rollup_5m`, `rollup_1h`, `rollup_1d`).
- The directory is used only while `.homerelay-store` in it holds this install's store id. HomeRelay never creates that directory or marker; `scripts/history-setup` does, after checking the volume is mounted. Without the marker the disk counts as missing and events wait in the event log, so an unmounted disk can't get files written to the boot disk under its mount point.
- Order per batch: raw rows and the rollups they affect commit first, with `meta.archived_seq` in the rollup transaction, then the event log marks them archived. A crash in between re-copies the batch; inserts are idempotent and rollups are recomputed. Raw queries merge the hot tail by sequence rather than timestamp, preserving repeated events in one millisecond. Each source reads at most 10,001 rows per series for a 10,000-point response; legacy cold files without a cursor deduplicate overlap by sequence.
- Rollups use step-hold: a value holds until the next, but only within the HomeRelay run that recorded it (`sessions`). Buckets store only when they contain values; queries fill quiet buckets from the previous `last`. When a session is learned to have ended, the buckets it ended in are recomputed.
- Daily after 03:00 local: back up (VACUUM INTO) the rollups and current month to `HOMERELAY_BACKUP_DIR`, keeping 7 days, and each closed month once it can no longer change. Each backup is written to a temporary name, checked with `PRAGMA quick_check`, given an install-specific completion marker, verified and atomically renamed. Interrupted temporary files are cleaned on the next backup run. Legacy or invalid final files are rebuilt; they cannot authorize retention. Closed-month backups must also match the source sample and reachability counts. Only then delete 5-minute rollups past 5 years and raw months past 24, each raw month also requiring matching hourly sample counts. Failed maintenance is retried on the next cycle.
- Reachability changes are archived to the raw files only; past 24 months they survive only in the closed-month backups.
- The marker is re-checked every run, and the app also refuses a directory on the boot volume.
- `/history/summary` reads the event log, not the disk, so routines keep working while the disk is away.
- `/health/history` is `503` when the disk has been missing for an hour, archiving lags a day, or events were dropped in the last day; Switchboard's `homerelay_history` probe watches it.

## States and the HomeKit bridge

- `StateStore` (HomeRelayCore) saves proposed States to an owner-only temporary file and atomically renames it before changing memory, timers or observers. Changes publish `characteristic` events on accessory `state:<id>`, so they're logged, archived and streamed like devices. `states.json` also stores retired slug tombstones and absolute reset deadlines, with defaults for older files. Legacy deadlines derive from `updatedAt`; overdue States expire at startup. Updating an active reset starts the new interval now; null cancels it. Creation and startup record value samples. The existing periodic sampler lives in the app's HomeKit store, so periodic State sampling needs app integration. Archive origin codes append `bridge` and `reset` after the existing five codes.
- `StateBridge` (app) publishes States through a vendored, hardened copy of hap-swift (`Packages/HAPSwift`, Apache-2.0; NOTICE and HOMERELAY.md describe the changes and their verification). Identity, pairings and layout live in `~/Library/Application Support/HomeRelay/bridge/` (0700); a paired bridge never mints a new identity. Each State keeps its accessory id for life; the configuration number changes only when the layout does.
- Home-app writes to a switch State arrive through the bridge's write handler and set the State with origin `bridge` and `by: home-app`. Sensor States are read-only in HomeKit.
- Pair setup is refused after 100 failed attempts until HomeRelay restarts (HAP 5.6.1). The setup code is only returned by `/bridge`, to control tokens, while unpaired.
- Not covered by automated tests: pairing and automations with a real iPhone and Home hub. The loopback controller tests (aiohomekit) live in the fork's `e2e/`.
