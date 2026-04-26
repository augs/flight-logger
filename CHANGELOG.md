# Changelog

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
