# iOS App Design Document for Environmental Flight Logger

## Overview

An iOS app that logs cabin environmental conditions during flights by combining passive RuuviTag Bluetooth sensor data with in-flight WiFi API data. Data is stored locally and presented as both a real-time dashboard and historical graphs.

---

## Platform

- **iOS 17+**
- **SwiftUI** throughout
- **SwiftData** for local persistence
- **Apple Charts framework** for all graphs — no third-party chart libraries

---

## Features

### 1. Flight Recording Mode

The user must explicitly enable **Flight Recording Mode** to begin a session. The app does not log passively in the background without this being active.

**Session start:**
- User taps "Start Recording"
- If an airline WiFi API is reachable, the app auto-populates flight metadata (flight number, origin, destination, departure time) from the API response
- If no API is reachable, the user is prompted to enter a flight label manually (e.g. `AA 123 / 2026-04-04`)
- This behavior is **configurable**: the user can set a preference to always prompt manually, always attempt auto-detect, or auto-detect with a manual fallback (default)

**Session end:**
- The app monitors the active airline API for an "on ground" / "wheels on ground" indicator and automatically ends the session when detected
- The user can also stop recording manually at any time

---

### 2. Data Collection

#### RuuviTag (Bluetooth LE)
- **Model:** RuuviTag standard (RAv2 broadcast format)
- **Method:** Passive listen — the app scans for and reads RuuviTag BLE advertisement packets; no connection or pairing required
- **Fields collected:** temperature, humidity, pressure
- **Rate:** Driven by the RuuviTag's own broadcast interval (passive receive)

#### Airline WiFi API
- **Method:** HTTP polling every 30 seconds while recording is active
- **Fields collected:** altitude (ft and m), ground speed, air temperature, flight status, on-ground indicator, and all available flight metadata (origin, destination, flight number, times, aircraft model)
- **Airline support is modular** — see Airline Plugin System below

---

### 3. Airline Plugin System

Airline integrations are defined as **JSON field mapping configs**, not hardcoded logic. Each config specifies:

```json
{
  "airline": "United",
  "url": "https://www.unitedwifi.com/portal/r/getAllSessionData",
  "fields": {
    "flightNumber":   "flifo.flightNumber",
    "origin":         "flifo.originAirportCode",
    "destination":    "flifo.destinationAirportCode",
    "altitudeFt":     "flifo.altitudeFt",
    "groundSpeedMPH": "flifo.groundSpeedMPH",
    "airTempF":       "flifo.airTemperatureF",
    "onGround":       "flifo.onGround"
  }
}
```

The app ships with a United Airlines config. Additional airline configs can be added in future iterations without code changes — only a new JSON config file is required.

**Generic (no API) sessions** use a manual label. If the user provides a flight number, the app can optionally correlate altitude data from external sources after the fact.

---

### 4. Data Logging

All data is timestamped and associated with a **Flight Session**. SwiftData models:

- **FlightSession** — flight number, airline, origin, destination, departure/arrival times, aircraft model, start/end timestamps, recording mode (api-auto | manual)
- **SensorReading** — timestamp, temperature (°C), humidity (%), pressure (hPa), session reference
- **FlightDataPoint** — timestamp, altitude (ft), ground speed (MPH), outside air temp (°F), flight status string, session reference

Data persists locally on-device after the app is closed. iCloud backup is supported via standard iOS app backup (no explicit iCloud sync required for v1).

---

### 5. Real-time Dashboard

Displayed while Flight Recording Mode is active:

- Live numeric readouts: cabin temp, humidity, pressure, altitude, ground speed
- A scrolling real-time line chart showing the last N minutes of: **cabin pressure**, **humidity**, and **API-reported altitude** on a shared timeline
- Flight metadata banner: flight number, origin → destination, time remaining

---

### 6. Historical Data Browser

- List of past flight sessions, sortable by date or flight number
- Tap a session to view its detail view

**Session Detail View:**
- Flight metadata summary
- Scrollable multi-series line chart: **cabin pressure**, **humidity**, and **altitude** on a shared time axis
- Toggle individual series on/off
- Pinch-to-zoom and pan on the time axis

---

## Technical Notes

- BLE scanning uses `CoreBluetooth`; the app requests `bluetooth-always` usage only while recording is active to minimize battery impact
- API polling uses `URLSession` on a 30-second loop; it runs for the whole session, including while backgrounded (see below)
- The airline plugin JSON configs are bundled in the app target and loaded at startup
- All numeric sensor values are stored in SI units (°C, hPa, meters); display conversion to imperial units is a UI-layer concern

---

## Background Execution Constraints

These are iOS platform limits, established by investigation. They are recorded
here so the constraints aren't rediscovered the hard way.

### Never connect to the tag during live logging

Sensor data comes from the RuuviTag's BLE **advertisement** packet. Connecting
to the tag destroys that stream twice over:

- iOS does not deliver `didDiscover` for a peripheral currently connected to
  the device.
- RuuviTag firmware stops advertising once a central connects.

Connection is therefore reserved for history sync, which explicitly suspends
live scanning for its duration and resumes it afterwards.

### Scan with no service filter — verified 2026-09-07

A RuuviTag in RAWv2 broadcast mode advertises **no service UUIDs at all**,
in neither the advertisement nor the scan response. Measured directly against
hardware over 12-second scans:

| Scan | Ruuvi advertisements discovered |
|---|---|
| `scanForPeripherals(withServices: [NUS])` | **0** |
| `scanForPeripherals(withServices: nil)` | 1 |

RAWv2 sensor data lives entirely in manufacturer-specific data (company
`0x0499`). Filtering must therefore be done in `didDiscover`, never by
CoreBluetooth. Do not reintroduce a service filter.

### Background advertisement capture is not achievable

This follows directly from the above, and there is no workaround:

- Background scans **must** filter by service UUID, and unfiltered scans return
  nothing. Since the tag advertises no service UUIDs, **no filter exists that
  can match it in the background.** CoreBluetooth cannot filter on manufacturer
  data at all.
- `CBCentralManagerScanOptionAllowDuplicatesKey` is **ignored in the
  background** — one callback per peripheral, then silence.
- Background scan intervals are throttled aggressively regardless.

Note this restriction is tied to *app state*, not process liveness: the
location keep-alive stops the app being suspended, but it is still
"backgrounded" as far as CoreBluetooth is concerned. **Location keep-alive
rescues API polling; it cannot rescue BLE scanning.**

Live advertisement scanning is therefore a **foreground-only** path, and the
tag's onboard log is the only route to sensor data covering a locked screen.

### Gap-free data comes from the tag's onboard log

The RuuviTag records to its own flash continuously (~10 days at the default
interval) whether or not a phone is listening. Downloading that log over the
Nordic UART Service is what produces complete flight data. Live advertisements
provide the real-time dashboard; the log provides the record.

**The tag accepts only one connection at a time — verified 2026-09-07.**

This is the single most important operational constraint. With another central
already connected (Ruuvi Station on a phone), the tag advertises
`kCBAdvDataIsConnectable = 0` and `connect` hangs silently until timeout — it
does not fail fast, and nothing in the advertisement explains why.

Measured, same tag, minutes apart:

| Phone Bluetooth | `connectable` | `connect()` |
|---|---|---|
| On (Ruuvi Station holding the slot) | `false` | hangs, times out |
| Off | `true` | succeeds immediately |

Consequences:

- **flight-logger and Ruuvi Station contend for the same slot.** History sync
  will fail whenever another app holds the connection. The user must not have
  Ruuvi Station connected during a sync.
- `beginHistoryConnection` checks the connectable flag and fails fast with an
  actionable message rather than hanging for 60 seconds.
- This is *not* a firmware limitation or a button-press requirement, which were
  both plausible-looking wrong theories along the way.

**Protocol verified against hardware.** With the slot free, a full log read
succeeded: 34 frames, correct end-of-data. Request bytes, big-endian framing,
all three scalings, and terminator detection all confirmed; decoded values
matched the tag's live advertisement to within sensor drift. The captured
frames are pinned as regression tests in `RuuviHardwareCaptureTests`.

**Log cadence was ~301s (5 minutes)** on this tag — the effective resolution of
any history download, and much coarser than the live advertisement stream.
Adjustable in Ruuvi Station if finer flight data is wanted.

### Measured background behaviour — 2026-09-07, iPhone 17

App launched from the Home screen (no debugger), screen locked, 37 samples over
9.3 minutes. Every sample recorded `applicationState = background`:

| Measure | Result |
|---|---|
| Sample cadence | 15.0–16.0 s against a 15 s target — **no throttling** |
| Suspension gaps | **none** — 37 consecutive samples |
| HTTPS requests | **37 / 37 succeeded**, 9–110 ms |
| Store readable | **37 / 37** |
| BLE readings | **0** across the whole locked period |

Conclusions: the location keep-alive holds the process at full cadence with
only **When In Use** authorization; background networking is completely
unaffected, so airline API polling will work in flight; and BLE really is dead
in the background, independently confirmed with no debugger attached.

### Staying alive requires location

`beginBackgroundTask` grants roughly 30 seconds — not a flight. An active
`CLLocationManager` with `allowsBackgroundLocationUpdates` is the supported way
to keep the process running for hours, and it is what allows the API poll loop
and foreground-quality BLE scanning to continue with the screen off.

The location *data* is discarded; only the runtime matters. `CLLocationManager`
runs at the coarsest accuracy, only while a session is recording, and with
`pausesLocationUpdatesAutomatically = false` — iOS otherwise pauses updates when
it decides the device is stationary, silently killing the keep-alive mid-flight.

Note this does not depend on obtaining an actual fix; GPS in a cabin is
unreliable, but requesting updates keeps the app alive whether fixes arrive or
not.

### The store must survive screen lock

The container is built with `completeUntilFirstUserAuthentication` applied to
the Application Support directory (so SQLite's `-wal`/`-shm` sidecars inherit
it) and to the store files themselves.

**Correction:** this was originally introduced on the theory that SwiftData
defaults to `NSFileProtectionComplete` and was therefore silently dropping
writes while locked. That premise appears to be wrong — iOS defaults
app-created files to `NSFileProtectionCompleteUntilFirstUserAuthentication`,
which is already lock-safe, and Core Data sets the same class by default.

Measured over 37 samples across 9.3 minutes with the device locked and no
debugger attached: **0 store failures**. That is consistent both with the fix
working and with the store never having been at risk. Setting the class
explicitly is still worth keeping — it removes the dependency on an undocumented
default — but it should not be described as having fixed a data-loss bug.

### Live Activities do not grant runtime

A Live Activity is a display mechanism, not an execution one. It renders in a
separate widget process and gives the host app no background time. Updates
require either the app to already be running (`activity.update()`) or an
ActivityKit push — and APNs needs real internet, which in-flight captive portals
generally block. The airline API itself is local to the portal, which is why
polling works without internet.

---

## Example United Airlines API Response

```
GET https://www.unitedwifi.com/portal/r/getAllSessionData
```

```json
{
  "flifo": {
    "originAirportCode": "EWR",
    "destinationAirportCode": "SFO",
    "flightNumber": "1885",
    "flightStatus": "In Flight - Estimated to Arrive 4 Minutes Early",
    "airSpeedMPH": "62",
    "groundSpeedMPH": "433",
    "airTemperatureF": "-2",
    "altitudeFt": "21404",
    "altitudeMeters": "6523",
    "aircraftModel": "Boeing 777-200",
    "scheduledDepartureTimeLocal": "04 May 2019 4:00 PM",
    "scheduledArrivalTimeLocal": "04 May 2019 7:04 PM",
    "timeRemainingToDestination": 319,
    "flightDurationMinutes": 364
  }
}
```
