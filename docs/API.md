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
| GET | `/health` | none | `{"status":"ok"\|"degraded","homekit":"ready"\|"starting"\|"notAuthorized"\|"noHomes","eventLog":"ok"\|"failing"\|"off","service","version"}` |
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
