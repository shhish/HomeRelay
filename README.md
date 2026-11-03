# HomeRelay

Apple Home as a local API. HomeRelay runs on an always-on Mac, reads and controls everything in the Home app through Apple's HomeKit framework, and serves it to other devices on your network: microcontrollers like the ESP32, scripts, a Raspberry Pi, dashboards.

```
ESP32 / scripts / Pi ──HTTP + SSE──▶ HomeRelay (Mac :18796) ──HomeKit──▶ Apple Home
```

Only Apple devices can control an Apple Home, and a HomeKit accessory can't be shared with a non-Apple controller. So a Mac that's always on and signed in to the Home acts on other devices' behalf. That covers every accessory and scene in the Home app, whether it came from Homebridge, Matter, Thread or Wi-Fi.

- REST for accessories, rooms, scenes and values, plus a Server-Sent Events stream of changes.
- Bearer tokens (`control` or `read-only`), stored only as SHA-256 hashes.
- Bonjour discovery (`_homerelay._tcp`). LAN only: don't expose it to the internet.

API reference: [docs/API.md](docs/API.md).

## Requirements

- A Mac on macOS 26 or later, signed in to the iCloud account that owns the Home, and left on.
- Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and an Apple Developer account. HomeKit needs the HomeKit capability on your App ID, so free provisioning isn't enough.

## Setup

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your bundle prefix and team ID
scripts/install.sh                      # build, install to ~/Applications, start the LaunchAgent
scripts/homerelay-token add orb         # prints a control token once
scripts/homerelay-token add dash --read-only
scripts/smoke.py                        # read-path checks with a temporary token
scripts/smoke.py --write "Floor Lamp"   # also toggles it twice and checks the event
```

On first launch macOS asks whether HomeRelay may access Home data. Until that's allowed, `/api/v1/health` reports `"homekit": "starting"` (or `notAuthorized` if it was denied; fix it in System Settings → Privacy & Security → Home).

## Layout

| Path | What |
|---|---|
| `Packages/HomeRelayCore` | HTTP server (SwiftNIO), router, auth, value handling, event hub. No HomeKit, so it's tested with `swift test` against a fake home. |
| `Sources/HomeRelay` | The Mac Catalyst app: HomeKit store, naming, config, Bonjour. |
| `scripts/` | build, install, LaunchAgent wrapper, token tool, smoke test. |
| `logs/` | `homerelay.log` (service) and `launchd.log`; ignored by git. |

## Running

- LaunchAgent `<bundle id>.backend` (for example `com.example.homerelay.backend`) runs `scripts/run.sh`, which launches the app through LaunchServices (HomeKit needs a real app launch with a UIKit scene) and relaunches it within about 5 s if it exits. The wrapper does the restarting because launchd defers KeepAlive respawns when the Mac is busy.
- Settings (LaunchAgent environment): `HOMERELAY_PORT` (18796), `HOMERELAY_HOST` (`::`, IPv6 and IPv4), `HOMERELAY_POLL_SECONDS` (30: re-read values without change notifications, with a full mains-device sweep every 20th run; 0 turns it off), `HOMERELAY_LOG_READS` (1 logs successful GETs too), `HOMERELAY_TOKENS_FILE`.
- Tokens are stored as SHA-256 hashes in `~/Library/Application Support/HomeRelay/tokens.json` and reloaded on change.
- Stop: `launchctl bootout gui/$(id -u)/<bundle id>.backend`. Start again: `scripts/install.sh --no-build`.

## Tests

```bash
cd Packages/HomeRelayCore && swift test
```

## License

MIT. See [LICENSE](LICENSE).
