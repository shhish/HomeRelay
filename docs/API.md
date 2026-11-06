# HomeRelay API (v1)

HomeRelay serves Apple Home on the local network from the Mac mini, so any device on the network can see and control what the Home app shows.

- **Base URL:** `http://<mac>.local:18796/api/v1`, or the Mac's LAN IP on port 18796. IPv4 and IPv6 both work.
- **Connections:** HTTP/1.1 keep-alive. A connection with no traffic for 2 minutes is closed; event streams stay open because of their keepalives.
- **Discovery:** Bonjour/mDNS service `_homerelay._tcp`, TXT `api=/api/v1`.
- **Auth:** `Authorization: Bearer <token>` on everything except `/health`. Create tokens with `scripts/homerelay-token add NAME`. Tokens are `control` (full access) or `--read-only` (`read`: GETs and events only).
- **Format:** JSON in and out. Errors are `{"error": {"code": "...", "message": "...", "candidates": [...]}}`.

## Referring to things

Wherever a path takes `{ref}`, use an id or a name:

- Ids are HomeKit UUIDs and never change. Prefer them in firmware.
- Names match case-insensitively. If two accessories share a name, use `Room/Name` (URL-encoded, so `Office%2FDesk%20Lamp`), or you get `409 ambiguous` listing each candidate as `Room/Name (id)`. Twins in the same room need their id.
- `?home=` (id or name) narrows to one home. Without it, every home is searched.

## Endpoints

| Method | Path | Scope | What it does |
|---|---|---|---|
| GET | `/health` | none | `{"status":"ok"\|"degraded","homekit":"ready"\|"starting"\|"notAuthorized"\|"noHomes","eventLog":"ok"\|"failing"\|"off","history":{…},"service","version"}` |
| GET | `/health/ready` | none | The same body; `503` unless HomeKit is ready (for monitors) |
| GET | `/homes` | read | Homes with room, accessory and scene counts |
| GET | `/snapshot?refresh=1&compact=1` | read | Everything: rooms, accessories (with services and characteristics) and scenes, per home |
| GET | `/rooms` | read | Rooms with the ids of their accessories |
| GET | `/accessories?room=&category=&refresh=1&compact=1` | read | Accessories, optionally filtered |
| GET | `/accessories/{ref}` | read | One accessory, with values freshly read from the device (`?refresh=0` to use cached values) |
| POST | `/accessories/{ref}` | control | Set values by name, e.g. `{"on": true, "brightness": 40}`; returns the accessory |
| POST | `/accessories/{ref}/toggle` | control | Flip `on`, `active` or the lock, whichever the accessory has |
| PUT | `/characteristics/{id}` | control | Low-level write: `{"value": ...}` to one characteristic by id |
| GET | `/scenes` | read | Scenes as the Home app shows them |
| POST | `/scenes/{ref}/run` | control | Run a scene |
| GET | `/events?accessory=ID,ID&since=SEQ` | read | Server-sent events stream of changes, resumable (see below) |
| GET | `/events/stats?hours=24` | read | Event log size, position and event counts by type and origin over the window |
| GET | `/states` | read | Virtual accessories ("States") and their values |
| GET | `/bridge` | control | HomeKit bridge status; while unpaired, its setup code and `X-HM://` payload |
| POST | `/states` | control | Create one: `{"name": "Guest mode", "kind": "switch", "resetAfter": 3600}` |
| PUT | `/states/{ref}` | control | `{"on": true}`; also `name` and `resetAfter` (seconds, or null) |
| DELETE | `/states/{ref}` | control | Remove a State |
| GET | `/history/series?accessory=ID&type=` | read | Recorded series: id, characteristic id, kind, unit, names, first and last seen |
| GET | `/history?series=ID,ID&from=&to=&step=auto` | read | Values over a time range (see History) |
| GET | `/history/summary?series=ID&window=1h` | read | One series summarised over a recent window, up to `14d` |
| GET | `/health/history` | none | History status; `503` when unhealthy (for monitors) |

`refresh=1` reads from the devices any value that HomeKit isn't already keeping current through change notifications; values under notification are already live. Battery-powered devices are only read for values never seen before, since each read wakes the sensor (seconds of delay, and battery drain). A value that doesn't answer within 6 s is skipped, and not retried for 5 minutes, so one dead device doesn't slow every request. Vendor-defined (`custom.*`) values are never read; their `value` is whatever HomeKit last cached. Without `refresh`, values come from HomeKit's cache. In the background, values without notifications are re-read every 30 s, and mains-powered devices are fully re-read every 10 minutes.

Right after a write, a bridged device (Hue, Homebridge) can briefly report its previous value if read directly. Trust the write's response, or wait for the change event.

## Accessories

```json
{
  "id": "6D3A…",
  "name": "Floor Lamp",
  "home": "Home",
  "room": "Bedroom",
  "category": "lightbulb",
  "reachable": true,
  "bridged": true,
  "manufacturer": "Govee",
  "model": "H6076",
  "state": {"on": true, "brightness": 60, "hue": 30, "saturation": 80},
  "services": [
    {"id": "…", "type": "lightbulb", "name": "Floor Lamp", "primary": true,
     "characteristics": [
       {"id": "…", "type": "brightness", "label": "Brightness", "value": 60,
        "format": "int", "unit": "percentage", "min": 0, "max": 100, "step": 1,
        "readable": true, "writable": true, "notifies": true}
     ]}
  ]
}
```

`state` is the short version most clients need: characteristic type to value, primary service first, with device-information and vendor-specific values left out. `services` has everything, including ids and limits for building controls. Add `?compact=1` to `/accessories`, `/accessories/{ref}` or `/snapshot` to drop `services` and keep responses small (useful on the ESP32).

Vendor-defined services and characteristics (Hue, Ecobee, Eve and so on) have the type `custom.<first 8 hex digits of their UUID>`. `category` is what Apple reports, except that bridged accessories Apple calls `other` get a category from their main service.

Common `state` keys: `on`, `active` (fans, purifiers, TVs: 0/1), `brightness`, `hue`, `saturation`, `colorTemperature`, `currentTemperature`, `targetTemperature`, `currentHeatingCooling`, `targetHeatingCooling` (0 off, 1 heat, 2 cool, 3 auto), `humidity`, `lockState` / `lockTarget` (0 unsecured, 1 secured), `rotationSpeed`, `position` / `targetPosition`, `motion`, `occupancy`, `contact` (0 closed, 1 open), `batteryLevel`, `lowBattery`, `inUse`, `doorState` / `doorTarget`. Anything else gets a camelCased version of Apple's label.

Categories include `lightbulb`, `outlet`, `switch`, `fan`, `thermostat`, `doorLock`, `door`, `window`, `windowCovering`, `garageDoor`, `sensor`, `securitySystem`, `bridge`, `camera`, `doorbell`, `button`, `airPurifier`, `heater`, `airConditioner`, `humidifier`, `dehumidifier`, `television`, `speaker` and `other`.

## Setting values

`POST /accessories/{ref}` takes any writable characteristic type as a key. Values are made to fit: `"on"`, `1` and `true` all work for switches; numbers are clamped to the device's range and rounded to its step, so `150` brightness becomes `100`. Turning on is applied before other keys, so `{"brightness": 30, "on": true}` turns the light on first. Turning off is applied last, because many lights switch back on when their brightness changes. Two shortcuts:

- `on` works for accessories that use `active` instead of a power switch (most fans and purifiers).
- `locked: true|false` sets a lock's target state.

An unknown key returns `422` listing what the accessory can write.

## Events

`GET /events` keeps the connection open and sends [server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html):

```
id: 4182
event: characteristic
data: {"accessory":"Floor Lamp","accessoryId":"6D3A…","characteristic":"on","characteristicId":"…","home":"Home","origin":"notification","room":"Bedroom","seq":4182,"serviceId":"…","ts":"2026-10-26T22:31:04.512-0400","type":"characteristic","value":false}

id: 4183
event: characteristic
data: {…,"by":"orb","cause":"routine:hall-1","origin":"write","seq":4183,"value":true}

id: 4184
event: reachability
data: {"accessory":"Tower Fan","accessoryId":"…","reachable":false,"seq":4184,"type":"reachability",…}

id: 4185
event: homes
data: {"type":"homes","seq":4185,…}
```

- `characteristic` events come from HomeKit's change notifications, from HomeRelay's own writes and scene runs, and from the 30-second re-read for devices that don't send notifications. Vendor-defined (`custom.*`) values are not streamed.
- `origin` says where a value came from: `notification` (the device reported it), `poll` (a re-read found a change), `write` or `scene` (HomeRelay set it, so `value` is what was requested; the device's own report follows as a `notification` if it sends one). Writes and scene runs also carry `by` (the token name) and, for scenes, `scene`. A notification repeating the previous value within 10 seconds is dropped as a duplicate, except button presses.
- Send `X-HomeRelay-Cause: <id>` (up to 128 printable characters, no spaces) with a write or scene run, and the events it causes carry `cause: "<id>"`. A routine engine uses this to recognise its own actions.
- `homes` means accessories, rooms or scenes changed; fetch `/snapshot` again.
- A `: keepalive` comment line arrives every 15 s. If 45 s pass with nothing, reconnect.
- `?accessory=ID1,ID2` limits the stream to those accessories (ids only).
- The connection closes after the stream ends; open a new one for other requests.

### Resuming

Every event has a `seq` (also sent as the SSE `id:`) that keeps increasing across restarts. HomeRelay keeps the last 14 days of events on disk.

- Reconnect with `?since=<last seq you handled>`, or send it as `Last-Event-ID` (browsers' `EventSource` does this for you). Events after it are replayed, then the stream goes live with no duplicates.
- Each install's log has an id, sent as the `X-HomeRelay-Store` response header and in `/events/stats`. Pass it back as `?store=<id>` and a position from a different install is treated as a `reset` rather than resumed.
- A client that reads too slowly to keep up isn't sent a partial stream: it catches up from the log.
- If events you asked for are no longer available, a `gap` frame comes first:

```
id: 2000
event: gap
data: {"type":"gap","missingFrom":1001,"missingTo":2000,"reason":"expired","store":"…","ts":"…"}
```

  `reason` is `expired` (older than the log keeps), `lost` (never written: a disk failure, or the last second before a crash) or `reset` (`since` is ahead of the log or `store` doesn't match, so it came from a different install; `missingTo` is absent). The range is in raw `seq` numbers and may include events your filter wouldn't have shown. After a gap, fetch `/snapshot` for current state.
- Without `since`, the stream starts live, as before.

## States

States are on/off values HomeRelay keeps itself, for things the house should remember: "Guest mode", "Movie time", "Garage open too long". Routines and clients set them; the HomeKit bridge (when enabled) shows them in the Home app, where a `switch` can be flipped by hand or with Siri and a sensor (`contact`, `motion`, `occupancy`, `leak`) can trigger Apple Home automations.

- `{ref}` is the State's `id` (a slug of its first name, such as `guest-mode`), `state:<id>`, or its name.
- A change is a `characteristic` event on accessory `state:<id>` (room `States`, characteristic `on`, characteristic id `state:<id>:on`), so the event log, history and routines treat States like any device. `origin` is `write`, `bridge` (the Home app) or `reset`.
- `resetAfter` turns a State off that many seconds after it was turned on, even across restarts.
- At most 149 States (one HomeKit bridge holds 150 accessories, one being the bridge). Each keeps its bridge accessory id (`aid`) for life, so the Home app keeps its room and automations.
- **The HomeKit bridge** (`HOMERELAY_BRIDGE=1`) publishes every State as an accessory of a bridge called "HomeRelay States" on port 51827. Pair it once: Home app → Add Accessory → More options → HomeRelay States, then type the `setupCode` from `GET /bridge` (or scan `setupURI` rendered as a QR code). The pairing survives restarts and updates. A `contact` State reads open when on.

## History

With a history directory set up (`scripts/history-setup`), HomeRelay keeps every recorded value long-term. Without one, `/history/summary` still works from the 14-day event log.

- **Series:** one per characteristic. `GET /history/series` lists them with a numeric `id`; anywhere a series is asked for, its `id` or the characteristic id works. `kind` is `numeric` (temperature, brightness), `binary` (motion, contact, on), `enum` (lock state, door state, modes) or `text`.
- **`GET /history?series=ID,ID&from=&to=&step=`**: `from`/`to` are epoch milliseconds or ISO 8601 (defaults: the last 24 hours). `step` is `raw`, `5m`, `1h`, `1d` or `auto` (the finest that stays under about 2,000 points; raw up to 6 hours). Up to 20 series.
  - `raw` returns `points`: `{"t": ms, "value": 21.5, "origin": "notification"}` (`text` instead of `value` for text series). Values from the last minute, not yet archived, are included.
  - Other steps return one entry in `buckets` per bucket from `from` to `to`: `n` (values recorded in it), `coverage` (seconds the value was known), `mean` (time-weighted), `min`, `max`, `last`, `lastMs`, `transitions`, plus `on` (seconds on) for binary and `states` (`{"0": 3600, "1": 120}`, seconds per state) for enum series. A value holds until the next one, so a quiet bucket still has a `mean`, with `n: 0`.
  - 5-minute and hourly buckets align to UTC; daily buckets start at local midnight.
  - `gaps` lists `[start, end]` ms ranges when HomeRelay wasn't running. Values don't carry across a gap.
- **`GET /history/summary?series=ID&window=1h`**: the same summary fields over the last `window` (`90s`, `15m`, `1h`, `7d`; at most `14d`), plus `current` and `since`. For conditions such as "the garage has been open for 10 minutes" (`summary.on` ≥ 600) or "the average temperature over the last hour".
- **Kept:** raw values 24 months, 5-minute buckets 5 years, hourly and daily buckets forever. A raw month is removed only after its hourly buckets account for every value in it and a backup copy exists.
- `503 history_unavailable` means the history disk isn't there right now; nothing is lost, values wait in the event log.

## Examples

```bash
TOKEN=hr_…
curl -H "Authorization: Bearer $TOKEN" http://my-mac.local:18796/api/v1/accessories
curl -X POST -H "Authorization: Bearer $TOKEN" -d '{"on":true,"brightness":40}' \
  "http://my-mac.local:18796/api/v1/accessories/Floor%20Lamp"
curl -X POST -H "Authorization: Bearer $TOKEN" "http://my-mac.local:18796/api/v1/scenes/Good%20Night/run"
curl -N -H "Authorization: Bearer $TOKEN" http://my-mac.local:18796/api/v1/events
```

ESP32 (ESP-IDF `esp_http_client`): set the `Authorization` header, use `HTTP_METHOD_POST` with a JSON body for writes, and for events open `/events` with a long timeout and parse lines starting with `data: `. Store the token in NVS, not in source.
