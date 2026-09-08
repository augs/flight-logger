# Airline WiFi APIs — field reference

Every field known to exist in each in-flight portal API, whether or not the app
currently maps it. Kept because these APIs are only reachable in the air: a
field not recorded during a flight is gone, and rediscovering the shape means
waiting for another one.

**Provenance matters here.** Nothing below was captured by us. Each section says
where it came from, and anything marked ⚠️ is inferred rather than observed.
When a real capture is made, save it to `flight-loggerTests/Fixtures/` and
update the section from the capture, not from this file.

Legend: **bold** = mapped by our config today · *italic* = time-series (changes
during flight) · plain = static metadata, captured once.

---

## United Airlines / Gogo

- **Endpoint:** `https://www.unitedwifi.com/portal/r/getAllSessionData`
- **Gogo (same shape):** `http://airborne.gogoinflight.com/portal/r/getAllSessionData`
- **Envelope:** `{ "flifo": {...}, "host": "..." }`
- **Source:** `bogo/1K` (`FlightDetails`, a Swift `Codable` struct decoded from a
  real captured sample — so this list is complete for that sample),
  `ejcx/uwc`, `KDE/kpublictransport`.

**Every numeric arrives as a `String`**, except `flightDurationMinutes` and
`timeRemainingToDestination` which are `Int`, and `isFake` which is `Bool`.

### Time-series

| Field | Notes |
|---|---|
| ***altitudeFt*** | mapped |
| *altitudeMeters* | metric sibling |
| ***groundSpeedMPH*** | mapped |
| *groundSpeedKPH* | metric sibling |
| *airSpeedMPH* / *airSpeedKPH* | **airspeed ≠ ground speed** — not currently recorded |
| ***airTemperatureF*** | mapped |
| *airTemperatureC* | metric sibling |
| *windDirection* | not recorded |
| ***flightStatus*** | free text, e.g. `"In Flight - Estimated to Arrive 4 Minutes Early"` |
| ***timeRemainingToDestination*** | Int, minutes |

### Static metadata

| Field | Notes |
|---|---|
| **flightNumber** | |
| **originAirportCode** / **destinationAirportCode** | IATA |
| originCity / originState | |
| destinationCity / destinationState | |
| **aircraftModel** | e.g. `"Boeing 777-200"` |
| equipmentCode | fleet type code |
| tailNumber (`String?`) / noseNumber | registration |
| departureGate / departureTerminal / departureConcourse | |
| arrivalGate / arrivalTerminal / arrivalConcourse | |
| **scheduledDepartureTimeLocal** / **scheduledArrivalTimeLocal** | e.g. `"04 May 2019 4:00 PM"` |
| scheduledDepartureTime / scheduledArrivalTime | |
| actualDepartureTime / actualDepartureTimeLocal | |
| estimatedArrivalTime / estimatedArrivalTimeLocal | |
| estimatedDepartureTimeLocal | |
| flightDurationMinutes | Int |
| flightMapPath | relative to the `host` field |
| isFake | `Bool` — presumably demo data; unhandled |

### No on-ground flag

United has **no** on-ground boolean. Verified: the 40-field struct above
contains none. Auto-stop uses `onGroundStatusValues` against `flightStatus`.

⚠️ `"In Flight"` is confirmed from the documented sample. `"arrived"`,
`"landed"`, `"at gate"`, `"on ground"` are plausible but **unobserved**.

⚠️ `ejcx/uwc` handles `isPortalInitialized: false`, where the portal answers 200
with no `flifo` key before the flight begins. Our detection accepts any 200 and
would latch onto it.

---

## Panasonic Avionics

- **Endpoint:** `https://services.inflightpanasonic.aero/inflight/services/flightdata/v2/flightdata`
- **Envelope:** flat object
- **Source:** `zisra/inflight-metrics` (`FlightInfoV2` TypeScript type),
  `KDE/kpublictransport` (`panasonic-inflight.js`), `microg/GmsCore`,
  `southgate/inflight-wifi`.

Real JSON types here, not strings. Speed in **knots**, temperature in
**Celsius** — both converted on the way in.

### Time-series

| Field | Notes |
|---|---|
| ***altitude_feet*** | mapped |
| ***ground_speed_knots*** | mapped, → MPH |
| ***outside_air_temp_celsius*** | mapped, → °F; declared nullable |
| ***weight_on_wheels*** | `Bool` — real on-ground flag, drives auto-stop |
| ***flight_phase*** | mapped as status |
| ***time_to_destination_minutes*** | mapped |
| *distance_to_destination_nautical_miles* | not recorded |
| *distance_from_departure_nautical_miles* | not recorded |
| *distance_traveled_nautical_miles* | optional |
| *flight_speed_mach* | optional, not recorded |
| *wind_speed_knots* / *wind_direction_degree* | optional, not recorded |
| *head_wind_speed_knots* | nullable |
| *true_heading_degree* | not recorded |
| *current_coordinates* | `{latitude, longitude}` — **the only provider giving position** |
| *current_utc_date* / *current_utc_time* | |
| *decompression_state* | `Bool` — cabin decompression |
| *all_doors_closed* | number |

### Static metadata

| Field | Notes |
|---|---|
| **flight_number** | |
| **departure_iata** / **destination_iata** | |
| departure_icao / destination_icao | |
| **tail_number** | mapped as aircraftModel — imperfect, it is a registration |
| departure_utc_offset_minutes / destination_utc_offset_minutes | |
| time_at_origin / time_at_destination | |
| takeoff_time_utc | |
| estimated_arrival_time_utc | ⚠️ KDE notes this is *local* time despite the name |
| route_id | optional |
| media_date | |

### Carriers using Panasonic

Per microG's SSID map: Telekom FlyNet, Cathay Pacific, Singapore (KrisWorld),
SWISS Connect, Edelweiss, TAP Air Portugal, Shenzhen Airlines.

### v1 (older fleets)

Same data under `td_id_fltdata_*` names, e.g. `td_id_fltdata_flight_number`,
`td_id_weight_on_wheels`, `td_id_flight_phase`. Latitude/longitude use a
sign-encoding quirk: values over 80,000,000 have 80,000,000 subtracted and are
negated, then divided by 1000. Not currently configured.

---

## Lufthansa Group FlyNet

Two different APIs exist in the fleet.

### `/fapi/flightData` (camelCase)

- **Bases:** `www.lufthansa-flynet.com`, `lufthansa-flynet.com`,
  `wlan.onboard.lufthansa.com`, `flynet.lufthansa.com`, `www.swissconnect.com`
- **Alternate paths:** `/fapi/flightdata`, `/flightdata`
- **Source:** `southgate/inflight-wifi`

| Field | Notes |
|---|---|
| ***altitude*** / ***groundSpeed*** | mapped; speed in knots |
| ***weightOnWheels*** | real on-ground flag |
| ***flightPhase*** | |
| **flightNumber** | |
| **orig** / **dest** | objects; `.code` mapped |
| aircraftType / aircraftRegistration | |
| timeDest / elapsedFlightTime | `hh:mm` strings |
| eta / utc | |
| internetAvailable / IFCinstalled | connectivity, not flight data |

Carriers by flight-number prefix: LH Lufthansa, LX SWISS, OS Austrian,
EW Eurowings, WK Edelweiss, EN Air Dolomiti.

### `/map/api/flightData` (BoardConnect map)

- **Source:** `microg/GmsCore`
- Fields: `lat`, `lon`, `utc`, *`groundSpeed`*, *`altitude`*, *`heading`*
- Position only — no flight number or on-ground flag.

---

## UGO

- **Endpoint:** `https://api.ife.ugo.aero/navigation/positions`
- **Envelope:** a JSON **array**; element `0` is current
- **Source:** `microg/GmsCore`. SSID `AegeanWiFi`.
- Fields: `latitude`, `longitude`, *`altitude_meters`*,
  *`speed_kilometers_per_hour`*, `bearing_in_degree`, `created_at`
- Metric throughout; converted on the way in. Position only.

---

## Not yet investigated

Delta (`deltawifi.com`), American (`aainflight.com`), Alaska
(`alaskawifi.com`), Southwest, JetBlue, Emirates, Thales-equipped fleets.
Domain blocklists confirm the hostnames exist, but no API shape was found in
public code. See TODO.md #27.
