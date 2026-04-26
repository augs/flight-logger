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
- API polling uses `URLSession` with a 30-second `Timer`; polling stops immediately when recording ends or the app is backgrounded
- The airline plugin JSON configs are bundled in the app target and loaded at startup
- All numeric sensor values are stored in SI units (°C, hPa, meters); display conversion to imperial units is a UI-layer concern

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
