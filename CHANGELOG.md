# Changelog

## 2026-09-07 — History Sync Verified End-to-End on Device

History sync now demonstrably works on hardware: log frames downloaded from the
tag's flash, parsed, deduped and persisted. Database rows match the captured
wire bytes exactly (raw 2256/5547/100554 → 22.56°C / 55.47% / 1005.54 hPa at the
tag's own timestamp).

### Fixed: app failed to launch (migration crash)
- Adding two `String` properties to `DiagnosticSample` broke launch against any
  existing store: SwiftData lightweight migration cannot backfill a mandatory
  attribute with no **property-level** default. A default in `init` does not
  count
- `ModelStore` no longer bricks the app on a load failure. It moves the
  unreadable store aside (never deletes — it may hold recoverable flight data)
  and starts fresh, so the app still opens away from a laptop

### Fixed: periodic sync starved foreground scanning
- `syncHistory` calls `stopScan()` for its whole duration, so with a 90s
  timeout on a 2-minute retry cycle the app scanned only ~30s in every 120s.
  It presented as "stuck scanning for RuuviTag"
- Root cause was the policy, not the timeout: foreground live scanning is ~5s
  resolution versus the tag's ~5 min log, so syncing there trades better data
  for worse. **Periodic sync now runs only while backgrounded**, where live BLE
  is dead. Session-end and manual syncs are unconditional
- Timeout 90s → 45s
- Scanning now always resumes after a sync while a session is active; it was
  gated on `wasScanningBeforeSync` and could silently leave the app not scanning

### Diagnosed: "the tag never answers" was wrong
- Two frame types arrive on NUS TX. 18-byte heartbeats beginning `05` (a Data
  Format 5 payload with the tag's current reading, streamed while connected),
  and 11-byte log frames. Heartbeats were arriving the whole time and being
  correctly discarded, so `historySamples` stayed empty and the sync looked dead
- Added GATT stage tracing (`retrieved@ connected@ services@ chars@ notifying@
  written@`) and a capped raw-frame hex dump, which is what made this visible
- Added `didWriteValueFor`: a rejected log request was previously
  indistinguishable from the tag not answering

### Fixed: flaky UI tests
- An active session keeps the app running after a test ends — the location
  keep-alive working as designed — so `launch()` failed with "current state:
  Running Background". Both UI test classes now terminate in setUp/tearDown
- Replaced the template `testExample()`, which asserted nothing, with
  `testLaunchesToForeground()`

### Backlog
- New #19: NUS heartbeat frames as a background live-data source. They arrive
  over the connection, so unlike advertisements they should work backgrounded —
  potentially much better resolution than 15-minute log sync

---

## 2026-09-07 — Periodic History Sync, Session Cap, Sync UX

Backlog items #9, #16 and #17. (#11 turned out to already be complete.)

### Periodic history sync (#17)
- The tag's log is now pulled every 15 minutes during a session, not only at
  session end. Since live BLE is dead once backgrounded, this is the only route
  to cabin data across a locked screen
- **Key fix:** sync previously located the tag by *scanning*, which delivers
  nothing in the background — so periodic sync could never have worked there.
  It now remembers the tag's identifier and uses
  `retrievePeripherals(withIdentifiers:)` to connect directly with no scan,
  which is permitted in the background
- The tag identifier persists across launches in `UserDefaults`
- The data watermark advances only on success, so a failed sync re-requests the
  same window rather than losing it
- Attempt timing is tracked separately from the watermark, so repeated failures
  can't turn into a retry on every 15s liveness tick

### Connection-slot contention UX (#16)
- New dashboard "Tag History" card: sync state, last result, and on failure a
  reason naming Ruuvi Station as the likely cause
- Manual "Sync Now" button
- Automatic retry backoff: 2 min after a failure, 15 min after success
- **Bug fixed:** `historyState` stayed `.failed` after an error, and
  `syncHistory` guards on `historyState == .idle` — so a single failure would
  have blocked every subsequent sync permanently. Now always returns to `.idle`,
  with the failure preserved in `lastSyncResult`
- History connect timeout reduced 60s → 30s

### Session duration cap (#9)
- Sessions auto-end after 21h (longest scheduled flight ~19h, plus headroom)
- Matters most for manual sessions, which have no `onGround` indicator and
  otherwise run until the battery dies

### Units (#11) — already done
- Entry was inaccurate. `UnitPreference` covers formatting, chart-value
  conversion and labels; `SettingsView` has the picker; both views consume it;
  `.system` reads `Locale.current.measurementSystem`

---

## 2026-09-07 — Hardware Verification on Device

Everything previously marked unverified was tested against a real RuuviTag and
an iPhone 17. Two prior conclusions turned out to be wrong and are corrected
here.

### Scan filter was broken — the app could never see the tag
- Measured A/B over 12s scans: `withServices: [NUS]` discovered the tag **0
  times**; `withServices: nil` discovered it immediately
- The tag advertises **no service UUIDs at all** — not in the advertisement,
  not in the scan response. RAWv2 data is entirely manufacturer-specific
- This filter dated from the original commit, so live sensor logging had never
  worked, in foreground or background. Now scans unfiltered
- Confirmed fixed on device: `Reading #1 saved: 22.6°C 55% 1005hPa`

### The tag accepts only one connection at a time
- With Ruuvi Station connected from a phone, the tag advertises
  non-connectable and `connect` hangs silently until timeout
- With the phone's Bluetooth off, the same tag advertised `connectable=true`
  and connected immediately
- **flight-logger contends with Ruuvi Station for that slot**; history sync
  fails whenever another app holds it
- `beginHistoryConnection` now checks the flag and fails fast with an
  actionable message instead of hanging

### History protocol verified against real traffic
- Full log read succeeded: 34 frames, clean end-of-data
- Request bytes byte-identical to what the tag accepted, big-endian framing
  confirmed, all three scalings confirmed; decoded values matched the live
  advertisement to within sensor drift
- Captured frames pinned as regression tests (`RuuviHardwareCaptureTests`)
- Added spec constants missed earlier: response type `0x10`, and the error
  frame `[0x30, 0x30, 0xF0]`, which had been misread as normal end-of-data
- Observed log cadence ~301s (5 min) — the real resolution of history downloads

### Background behaviour measured on device
App launched from the Home screen (no debugger), screen locked, 37 samples over
9.3 minutes, every one in `background` state:
- Cadence 15.0–16.0s against a 15s target — **no throttling, no suspension**
- HTTPS **37/37 succeeded** (9–110 ms) — background API polling will work in
  flight
- Store readable **37/37**
- BLE readings **0** — background scanning confirmed dead with no debugger
- **When In Use** location authorization is sufficient; Always is not needed

### Correction: file protection was not a data-loss bug
- The P0 fix was premised on SwiftData defaulting to `NSFileProtectionComplete`.
  That premise was wrong — iOS defaults app files to
  `completeUntilFirstUserAuthentication`, which is already lock-safe
- Setting it explicitly is kept (it removes reliance on an undocumented
  default) but should not be described as fixing data loss

### Bugs found by the instrumentation
- `readingCount`/`lastReading`/discovery counters were not reset between
  sessions, so a new session inherited the previous session's totals — observed
  live when a reading landed 8s before the new session was created
- Network probe reported `"HTTP 200"` in its error field on success

### Diagnostics
- New `DiagnosticSample` model records timestamp, app state, sample gap, store
  readability, BLE/location status, and network result/latency
- New info-level BLE logging: first reading, every 10th, and discovery counts
  distinguishing "CoreBluetooth delivering nothing" from "tag not seen"

---

## 2026-09-07 — P1 Background Execution

Made recording actually survive backgrounding and screen lock. Platform
constraints are now written up in `DESIGN.md` → Background Execution
Constraints so they aren't rediscovered later.

### Location keep-alive
- New `LocationKeepAlive` holds the process open for the duration of a session.
  `beginBackgroundTask` grants ~30 seconds; an active `CLLocationManager` with
  `allowsBackgroundLocationUpdates` grants hours
- Location data is discarded — only the runtime is used. Coarsest accuracy,
  1km distance filter, and active only while recording
- `pausesLocationUpdatesAutomatically = false`, which matters: iOS otherwise
  pauses updates when it decides the device is stationary, silently killing the
  keep-alive mid-flight
- Does not depend on getting a fix, which is unreliable in a cabin
- Location callbacks double as a background heartbeat for the API poll loop
- Dashboard badge states plainly whether logging will survive screen lock, and
  prompts for access when it won't

### RuuviTag onboard history sync
- New `RuuviHistoryProtocol` implements the Nordic UART Service log format:
  11-byte frames, big-endian timestamps and values, `0xFF` end-of-data sentinel,
  plus assembly of per-measurement frames into complete entries
- Transport lives in `RuuviTagScanner` as an explicitly triggered mode, so there
  is one `CBCentralManager` and the scan/connect transition is coordinated.
  Live scanning is suspended for the download and resumed afterwards
- Runs at session end; merges into the session deduped against
  advertisement-derived readings on whole-second timestamps
- 60-second timeout, and a mid-download disconnect keeps whatever arrived
- **⚠️ The wire protocol is unvalidated against physical hardware.** Constants
  come from documentation, not observed traffic. Framing and scaling are
  unit-tested and isolated so they can be corrected in one place
- Periodic mid-flight sync is deliberately not wired up until the protocol is
  confirmed, since syncing suspends live scanning

### API polling resilience
- Poll loop restructured so detection retries with backoff (60s → 5m) instead of
  giving up permanently. Previously, starting a recording before joining the
  airline WiFi meant `.noAPI` for the rest of the flight
- `resumeIfNeeded` restarts a dead loop; new `heartbeat()` also forces a poll
  when the last one is more than 90s overdue
- Service now holds its own session/context references rather than depending on
  the caller to re-supply them

### Background modes
- Removed `processing` (no `BGTaskScheduler` registration existed) and
  `external-accessory` (irrelevant) — both were dead and are review flags
- Added `location` with a usage description

### Tests
- Replaced the template stub with real coverage: 12 tests across RAWv2 parsing
  and the history protocol
- RAWv2 is verified against the official Data Format 5 test vector, which
  confirms the existing parser was correct
- History protocol covers request framing, big-endian round-tripping, negative
  temperatures, Pa→hPa scaling, end-of-data, malformed frames, and entry
  assembly including dropping incomplete groups

---

## 2026-09-07 — P0 Data Loss Fixes

Diagnosed why logging stopped when the app backgrounded or the screen locked.
Three distinct bugs, all of which also cost data in the foreground. Added
`TODO.md` with the full prioritized backlog (absorbs `FEATURE_REQUESTS.md`).

### Removed the BLE connect path — it was killing the data stream
- `RuuviTagScanner` connected to every discovered RuuviTag. iOS stops
  delivering `didDiscover` for connected peripherals, and RuuviTag firmware
  stops advertising once a central connects — so connecting permanently
  terminated the advertisement stream that all sensor readings come from
- The NUS subscription meant to replace it could never fire: it subscribed to
  the TX characteristic without ever writing a history request to RX
- Deleted `connectToPeripheral`, the entire `CBPeripheralDelegate` extension,
  the connect/disconnect delegate callbacks, `connectedPeripheral` state, and
  the `.connected` scan status
- `didDiscover` now early-returns on non-Ruuvi manufacturer data instead of
  falling through to a connection attempt
- Documented in-code why advertisement-only is deliberate, and why the NUS
  scan filter is foreground-only

### Fixed SwiftData store being unwritable while the screen is locked
- The store defaulted to `NSFileProtectionComplete`, making it inaccessible on
  a passcode-locked device — a large part of the "stops logging when the screen
  locks" symptom
- New `ModelStore` builds the container with an explicit store URL (matching
  SwiftData's own default, so existing data is preserved) and applies
  `completeUntilFirstUserAuthentication` to the Application Support directory
  and to the store, `-wal`, and `-shm` files
- Directory-level protection means SQLite's sidecar files inherit the class
- **Not yet verified on device** — the simulator does not reproduce this

### Stopped swallowing save errors
- `try? context.save()` in `RuuviTagScanner` and `AirlineAPIService` hid the
  above failure entirely; both now use `do/catch` and log via `os.Logger`
- In `AirlineAPIService` the save is in its own `do/catch` so a persistence
  failure isn't misreported as an API error
- Both services expose `persistenceError`, surfaced by a new dashboard badge
  ("Not saving data") so silent data loss is visible

---

## 2026-04-04 — Flight List Sorting, Time Remaining & Background Handling

### Flight List Sorting
- Segmented picker in the toolbar to sort by Date (default) or Flight Number
- Deletion works correctly in both sort orders

### Time Remaining in Dashboard
- Dashboard flight banner now shows "Xh Xm remaining" when the airline API reports time to destination
- `AirlineAPIService` exposes `timeRemainingMinutes` observable property, updated each poll cycle

### Background Handling
- API polling and BLE scanning stop immediately when the app enters the background (`scenePhase`)
- Both services resume automatically when the app returns to the foreground with an active session

---

## 2026-04-04 — Configurable Session Start Flow & Settings

### StartRecordingSheet
- Multi-phase sheet: auto-detect airline WiFi → show detected flight info → confirm, or fall back to manual entry
- Probes bundled airline configs and shows flight number, route preview when detected
- Manual entry view with text field for flight label (e.g. "AA 123 / 2026-04-04")
- "Enter details manually instead" escape hatch from auto-detect results

### RecordingStartMode Preference
- Three modes persisted via `@AppStorage`: auto-detect with fallback (default), auto-detect only, always manual
- Each mode controls the StartRecordingSheet flow

### Settings Tab
- New Settings tab in the main TabView
- Inline picker for session start mode with descriptions for each option

---

## 2026-04-04 — Real-time & Historical Charts

### Dashboard Live Chart
- Stacked mini line charts showing the last 10 minutes of cabin pressure (hPa), humidity (%), and altitude (ft)
- Auto-updates as new sensor readings and flight data points arrive
- Compact layout with hidden X-axes and leading Y-axis value labels
- "Waiting for data..." placeholder when no readings exist yet

### FlightDetailView Chart Improvements
- Series toggle buttons (Altitude, Pressure, Humidity) to show/hide individual chart series
- Horizontally scrollable time axis via `chartScrollableAxes(.horizontal)` for panning through long flights
- Each series in its own chart panel with proper Y-axis labels and time-formatted X-axis
- Animated toggle transitions

### Bug Fix
- Fixed crash on "Start Recording" caused by `CBCentralManager` creation without Bluetooth entitlement/usage description — scanner now checks `NSBluetoothAlwaysUsageDescription` and `CBCentralManager.authorization` before creating the manager
- Fixed double-start of services (button handler + `onChange` both triggered)

---

## 2026-04-04 — Airline API Polling & RuuviTag BLE Scanner

### AirlineAPIService
- `@Observable` service that detects airline WiFi by probing bundled configs, then polls every 30 seconds
- Dot-notation JSON path resolver (e.g. `flifo.altitudeFt`) with string/number/bool coercion
- Auto-populates session metadata (flight number, origin, destination, aircraft) on first successful poll
- Auto-stops recording when the API's `onGround` indicator becomes true
- Dashboard shows live connection status: detecting, connected, no API, or error

### RuuviTagScanner
- `@Observable` CoreBluetooth service that passively listens for RuuviTag BLE advertisement packets
- Parses RAWv2 (Data Format 5) manufacturer data: temperature (°C), humidity (%), pressure (hPa)
- Creates `SensorReading` records linked to the active flight session
- Dashboard shows BLE scan status: scanning, found tag name, Bluetooth off, or unauthorized
- Requires `NSBluetoothAlwaysUsageDescription` in Info.plist

---

## 2026-04-04 — Initial App Structure

Built out the foundational structure from DESIGN.md.

### SwiftData Models
- **FlightSession** — flight number, airline, origin/destination, scheduled times, aircraft model, recording start/end timestamps, recording mode (`api-auto` | `manual`), with cascade-delete relationships to child readings
- **SensorReading** — timestamp, cabin temperature (°C), humidity (%), pressure (hPa), linked to a session
- **FlightDataPoint** — timestamp, altitude (ft), ground speed (MPH), outside air temp (°F), flight status string, linked to a session

### Airline Plugin System
- **AirlineConfig** — Codable model for JSON-driven API field mappings, with `AirlineConfigLoader` utility to load bundled configs
- **united.json** — bundled United Airlines WiFi API config (`unitedwifi.com/portal/r/getAllSessionData`)

### Views
- **ContentView** — TabView with Dashboard and Flights tabs
- **DashboardView** — idle state with "Start Recording" button; active recording state with flight banner, live sensor readout cards (temp, humidity, pressure), flight data cards (altitude, speed, air temp), and stop button
- **FlightListView** — chronological list of past flight sessions with swipe-to-delete, navigation to detail view, empty state placeholder
- **FlightDetailView** — flight metadata summary (route, airline, aircraft, duration, mode, reading counts) and Charts-based altitude/pressure plots

### Housekeeping
- Removed template `Item.swift` model
- Updated `flight_loggerApp` to register all three SwiftData models in the shared container
