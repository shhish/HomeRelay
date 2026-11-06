# HomeRelay bridge integration

Verified on 2026-11-06 with Swift 6.4.2 and the macOS 27.2 SDK. This work targets
Apple transport and virtual switches/sensors. Nothing was paired to a real Home,
iPhone, or Home hub. No commit was made.

## Gap assessment

| Gap | Status | Implementation and evidence |
| --- | --- | --- |
| Durable pairings and identity | **Fixed** | `FilePairingStore` persists controller keys and permissions; `FileAccessoryIdentityStore` persists device ID, Ed25519 private key, setup code and setup ID. Both have storage protocols. `AtomicFile` creates 0600 temporary files, syncs contents, renames atomically and syncs the directory. Load/corruption errors propagate. Tests cover reload, permissions, failed writes, corruption and concurrent initial pairing. aiohomekit reconnects both controllers after an abrupt demo process kill. |
| Controller permissions | **Fixed** | Pair-setup creates the initial admin. Verified controller identity authorizes add/remove/list; regular controllers cannot manage pairings. Existing identifiers cannot silently change public keys. Removing/demoting the last admin clears all pairings. Unit tests and aiohomekit exercise permission reporting, denials and last-admin cleanup; e2e also checks session revocation and rejection of a fresh verify. |
| Cross-controller events | **Fixed** | Successful controller writes notify subscribed peers, excluding the originating connection. App updates notify all subscribers when the value changes. Failed handlers do not publish a new value. Unit tests cover fan-out and suppression; aiohomekit receives contact/motion events and switch events on the second controller, including writes interleaved with reads. |
| Multiple frames and HTTP reassembly | **Fixed** | Responses are split into frames of at most 1024 plaintext bytes. `HAPConnection` separately buffers encrypted frames and HTTP requests, consumes exact request lengths, and serializes responses/events through one send queue. Unit tests cover fragmentation into seven-byte reads, pipelining, malformed lengths and 250 KB frame round-trips. aiohomekit reads 150 States plus the bridge (151,734 bytes after controller normalization) and sends an HTTP write spanning multiple encrypted frames. |
| c#, stable IIDs and AIDs | **Fixed for structural layouts** | `FileBridgeConfigurationStore` persists c#, the structural fingerprint and IID allocations/tombstones. Startup compares the completed database with the saved layout; unchanged restarts do not bump c#. Numbers wrap 65535 → 1. Allocation uses service identity and characteristic type, independent of array order. AIDs are explicitly assignable; the app must retain its State-to-AID mapping. Tests cover reorder, additions, wrapping and save failure; e2e checks live c# updates, restart stability and unchanged old AIDs/IIDs after additions. |
| Timed writes | **Fixed** | `HAPPermission.timedWrite` advertises `tw`. `/prepare` records a connection-scoped PID and monotonic deadline; subsequent writes enforce matching, expiry and one-shot consumption. Swift tests cover mandatory `tw`, wrong/missing PID, another connection, expiry and replay. aiohomekit exercises prepare/write/replay on the ordinary switch. |
| Catalyst | **Partly verified** | `e2e/check-catalyst.sh` successfully compiled `HAPApple` and its HAPCore/HAPCrypto/HAPTransport dependencies for `arm64-apple-ios18.0-macabi`. No unavailable-API diagnostic occurred. This is a compilation check, not a linked/signed HomeRelay app or Catalyst runtime test. `HAPAppleTests` separately exercises the real Network.framework TCP listener on macOS. |
| mDNS TXT | **Fixed; LAN behavior unverified** | `_hap._tcp` includes c#, s#=1, sf, ci, id, md, pv=1.1, ff=0 and setup hash. `md` uses the model. Pair-setup, unpairing and structural changes refresh advertisements. Unit tests check record construction; e2e reads the actual LocalOnly DNS-SD TXT record and verifies paired/unpaired sf and live c# changes. Production uses MDNSApple; the test's local-only advertiser keeps traffic off the LAN. |
| Fixed port | **Fixed / retained** | `AppleHAPService.start(port:)` and `AppleTCPServer.start(port:)` accept a fixed port. The demo uses 51827. e2e restarts on it; `HAPAppleTests` verifies immediate stop/start on the same port and duplicate-start rejection. Stop waits for listener cancellation before returning. |

## Public API for HomeRelay

Use `HAPCore`, `HAPCrypto`, `HAPTransport` and `HAPApple`. Keep the storage lock,
bridge, stores and service in a long-lived owner. Select an app-owned persistent
directory in the Catalyst container, outside caches or the application bundle.
Keep that directory across updates and restore it as a unit.

The following illustrates provisioning. `directory` and `setupCode` are supplied
by HomeRelay; pass the same setup code on subsequent launches. Generate it once
with `AccessoryIdentity.generateSetupCode()` if needed, then retain it securely.
Do not generate a new identity or code on every launch.

```swift
import Foundation
import HAPCore
import HAPCrypto
import HAPTransport
import HAPApple

let storageLock = try StorageDirectoryLock(directory: directory) // retain
let pairings = try FilePairingStore(
    url: directory.appendingPathComponent("pairings.json"))
let alreadyPaired = await pairings.isPaired
let saved = try await FileAccessoryIdentityStore(
    url: directory.appendingPathComponent("identity.json"),
    allowsCreation: !alreadyPaired
).loadOrCreate(setupCode: setupCode)

func info(_ name: String, serial: String) -> AccessoryInfo {
    AccessoryInfo(name: name, manufacturer: "Virtual", model: "VirtualBridge",
                  serialNumber: serial, firmwareRevision: "1.0")
}
let bridge = try HAPBridge(
    info: info("Virtual Bridge", serial: "bridge"),
    configurationStore: FileBridgeConfigurationStore(
        url: directory.appendingPathComponent("layout.json")))

// Example permanent AIDs. Persist your own logical State -> AID mapping.
// AID 1 belongs to the bridge. Never derive these IDs from display/list order.
let definitions: [(UInt64, String, HAPService)] = [
    (2, "Switch",    .switch(startIID: 1)),
    (3, "Contact",   .contactSensor(startIID: 1)),
    (4, "Motion",    .motionSensor(startIID: 1)),
    (5, "Occupancy", .occupancySensor(startIID: 1)),
    (6, "Leak",      .leakSensor(startIID: 1)),
]
for (aid, name, service) in definitions {
    try await bridge.addAccessory(info: info(name, serial: "state-\(aid)"),
                                  services: [service], aid: aid)
}
try await bridge.endBatchUpdate() // finish the implicit startup batch

// Resolve assigned IIDs from the database, not the factories' startIID values.
func iid(_ aid: UInt64, _ type: HAPCharacteristicType) async throws -> UInt64 {
    let database = await bridge.accessoryDatabase()
    guard let char = database.first(where: { $0.aid == aid })?
        .services.flatMap(\.characteristics).first(where: { $0.type == type })
    else { throw HAPError.notFound }
    return char.iid
}
let switchIID = try await iid(2, .on)
// `states` is HomeRelay's Sendable/actor-backed State owner.
await bridge.registerWriteHandler(aid: 2, iid: switchIID) { value in
    guard case .bool(let enabled) = value else { throw HAPError.invalidValue }
    await states.setSwitch(enabled)
}

let service = AppleHAPService(
    bridge: bridge, setupCode: saved.setupCode, deviceID: saved.deviceID,
    setupID: saved.setupID, identity: try saved.identity, pairingStore: pairings)
try await service.start(port: 51827)
```

A controller write invokes the registered async throwing handler, then publishes
the accepted value and peer events. Do not echo the same write through
`updateCharacteristic` inside that handler. Throw on failure. Use app updates
for independent State changes:

```swift
let contactIID = try await iid(3, .contactSensorState)
await bridge.updateCharacteristic(aid: 3, iid: contactIID, value: .uint8(1))
```

| Service factory | Value characteristic | App update value |
| --- | --- | --- |
| `.switch(startIID:)` | `.on` | `.bool(false/true)` |
| `.contactSensor(startIID:)` | `.contactSensorState` | `.uint8(0)` closed; `.uint8(1)` open |
| `.motionSensor(startIID:)` | `.motionDetected` | `.bool(false/true)` |
| `.occupancySensor(startIID:)` | `.occupancyDetected` | `.uint8(0/1)` absent/present |
| `.leakSensor(startIID:)` | `.leakDetected` | `.uint8(0/1)` dry/leak |

These sensor factories are read/notify only. HomeRelay must persist its actual
State values separately and restore them before opening the listener. Pairing
and layout stores do not persist characteristic values.

For multiple services of the same type on one accessory, assign each a permanent
`HAPService.stableIdentifier`; duplicate anonymous services are rejected.
Keep service identities and the layout file stable. Do not reuse an old AID for
a different logical State. Runtime additions/removals use throwing
`addAccessory(..., aid:)` / `removeAccessory(aid:)`; optional
`beginBatchUpdate()` / `endBatchUpdate()` groups a layout change into one c# update.
`AppleHAPService.start` also finishes startup provisioning. External pairing-store
changes require `service.reAdvertise()`.

`PairingStore`, `AccessoryIdentityStore` and `BridgeConfigurationStore` permit
app-selected storage implementations. The convenience service initializers still
have volatile defaults: pass the durable objects explicitly. Layout mutation
methods now throw, and custom pairing stores must implement permission and atomic
initial-pairing operations. `CharacteristicProtocol` is now an actor.

## Reproduction and results

From the checkout, the final unit-test run exited 0: **201 tests passed**
(HAPTransport 78, HAPCrypto 79, HAPCore 43, HAPApple 1).

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --disable-sandbox --cache-path .build/cache \
  --config-path .build/config --security-path .build/security

e2e/run.sh
e2e/check-catalyst.sh
```

The cache flags keep build artifacts local; `--disable-sandbox` accommodates
nested SwiftPM manifest execution in the restricted agent environment.

`e2e/run.sh` passed every check with aiohomekit 4.0.1 in `.venv-e2e/`. It generates
setup codes/controller keys, starts only its own loopback demo, queries only its
exact LocalOnly TXT record, and removes successful-run credentials. Failure logs
and credentials remain under ignored `.e2e-state/` with restrictive permissions.
It never browses the owner's Home. The script exercises pairing, accessory reads,
switch writes, sensor/peer events, admin/regular permissions, concurrent traffic,
prepare/PID replay, abrupt restart, layout addition, large frames and unpairing.

The standalone executable is `hap-bridge-demo`:

```sh
swift run hap-bridge-demo --storage ./demo-state --setup-code "$SETUP_CODE" --port 51827
```

Its default is loopback TCP and local-only Bonjour. Stdin accepts `switch 0/1`,
`contact 0/1`, `motion 0/1`, `status`, `add-switch`, and `quit`. `--count 150`
selects the stress layout. `--lan` deliberately exposes the demo on the LAN; it
was not used here. Keep `demo-state` private and out of source control.

The Catalyst check succeeded using native SwiftPM with the explicit macabi
triple. This toolchain supports that compilation path, although the native build
backend is deprecated. No unavailable APIs were found in the compiled dependency
closure; a signed Catalyst app build/runtime remains unverified.

## Remaining risks and recommendation

- aiohomekit cannot prove Home-app pairing UX, Siri, Home hub/iCloud propagation,
  automation triggers, controller caching of layout changes, LAN discovery across
  interfaces, or recovery after sleep/network changes. No real-device or long
  soak test was performed, and a process kill is not a power-loss/reboot test.
- The 150-State run is a framing stress test, not evidence that an iPhone accepts
  that many bridged accessories. HAP-NodeJS limits a bridge to **149 bridged
  accessories**; plan multiple bridges if necessary ([implementation](https://github.com/homebridge/HAP-NodeJS/blob/latest/src/lib/Accessory.ts)).
- Files use private permissions, not Keychain encryption. Hold the directory
  lock, use one store instance per file, preserve all storage together, and stop
  on storage errors rather than resetting state. Multi-file backup consistency,
  disk failure/power-loss behavior, and future schema migrations need app policy.
- The fingerprint covers AIDs, IIDs, types, formats and permissions. Values and
  display/firmware strings do not bump c#. Metadata-only constraint changes
  (ranges, units, valid values) are not currently fingerprinted.
- This is not complete HAP conformance/certification. Optional characteristic
  query/response features and unpaired request throttling need a broader audit.
  A stalled subscriber is disconnected once its event queue reaches 256 entries;
  clients must reconnect, resubscribe and read current state.
- HAPLinux was only adjusted for throwing bridge APIs. Its transport has not
  adopted the Apple connection/session/event changes and is outside these claims.

The [mikeburgh fork](https://github.com/mikeburgh/hap-swift) exists. Its `main`
matched pinned revision `6e62417d61522823552417714b62af89b2e211b3` when checked.
It lowers macOS deployment to 14 and pins its mdns-swift fork, but the inspected
pairing store, permission handling, bridge, session and TCP code retain these
reliability gaps. Its LICENSE.md contains Apache-2.0; borrowing with the required
notices is permitted. No implementation was copied from that fork.

**Recommendation:** fall back to Homebridge for an immediate production promise
of years of unattended operation. This fork now has a working, repeatable Apple
transport proof and is suitable for a controlled HomeRelay trial. Rely on it in
production only after signed Catalyst integration and an isolated real-iPhone/
Home-hub soak demonstrate pairing retention, automations and network recovery.
