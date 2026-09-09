# Data sharing — design notes

Design for contributing flight data to a public dataset, so that cabin humidity
performance can be compared across aircraft types.

**Status: design only. Nothing here is built.** The app today stores everything
on device and uploads nothing. Recorded now so the reasoning survives; revisit
before implementing.

---

## Research question

> How well do different aircraft types maintain cabin humidity, and how much do
> time-at-pressure and real altitude explain the difference?

---

## Relative humidity is the wrong metric

RH is a ratio to saturation, and saturation depends on temperature. Two cabins
both reading 12% RH at 19 °C and 24 °C hold **different amounts of water**.
Comparing aircraft on RH alone would partly be comparing how warm each cabin
runs.

The app already records temperature, RH and pressure — enough to compute the
physically meaningful quantities:

```
es = 6.112 · exp(17.67·T / (T + 243.5))     saturation vapour pressure, hPa
e  = (RH/100) · es                           actual vapour pressure, hPa
w  = 622 · e / (p − e)                       mixing ratio, g/kg dry air
AH = 216.7 · e / (T + 273.15)                absolute humidity, g/m³
```

**Mixing ratio is the one to compare on.** It is conserved when air is
compressed or heated, so it isolates how much water the aircraft puts into the
cabin from how the cabin is conditioned.

Cabin altitude follows from cabin pressure by the standard atmosphere:

```
h = 44330 · (1 − (p/1013.25)^(1/5.255))      metres
```

## Per-flight derived metrics

Two numbers per flight answer the question better than a raw series, and are far
less identifying:

- **Equilibrium mixing ratio `w∞`** and **time constant `τ`**, from fitting
  `w(t) = w∞ + (w₀ − w∞)·e^(−t/τ)` over the cruise segment. "How dry does this
  aircraft settle, and how fast does it get there."
- **Cabin-altitude-hours** — ∫(cabin altitude)dt, the time-at-pressure integral.

**Fit over cruise only.** Climb and descent contaminate the fit badly. Segment
using `flight_phase` (Panasonic), `flightStatus` (United), or altitude stability
where neither exists.

## Real altitude is the missing covariate

Only the airline API reports aircraft altitude, and most flights have no
reachable portal. GPS is not a substitute — verified 2026-09-08, an underground
journey produced invalid speed in 35/35 samples and coarse cell-derived
altitude, and an aircraft cabin is closer to that than to open sky.

**Outside air temperature may be the better covariate anyway.** United and
Panasonic both report it, and outside absolute humidity is essentially a
function of it — at −55 °C the air is dry regardless of altitude. Since cabin
dryness is driven by exchanging cabin air for dry outside air, OAT is closer to
the causal variable than altitude, and it is measured rather than inferred.

---

## Enriching from public ADS-B

With flight number, date and origin, a public ADS-B source supplies the altitude
track independently of the airline API — and, via `icao24` → typecode, the
**aircraft type**. That closes both gaps at once: the type is otherwise missing
for Panasonic (which backs the most carriers) and UGO.

[OpenSky Network](https://opensky-network.org/data), verified 2026-09-08:

- Historical archive is free; institutional researchers can request unlimited
  access.
- Aircraft database maps `icao24` to typecode, manufacturer, model, registration.
- Rate limits: 100/day anonymous, 4,000/day authenticated, 8,000 for receiver
  contributors.
- **OAuth2 client credentials since 18 March 2026**; basic auth is gone.
- Bulk historical access is via Trino, not REST.

### Enrich at ingest, not on the device

The app should upload the sensor data plus the identifying triple and stop.
Enrichment belongs to whatever assembles the dataset.

- No OAuth, rate limiting or network dependency in the app. 4,000 calls/day is a
  shared budget — unmanageable across many phones, trivial centrally.
- Enrichment becomes **re-runnable**: better matching, a second source or a
  corrected type table applies retroactively to every past contribution. Built
  into the app, it freezes at whatever v1 got right.
- No third-party call from the user's phone, so no flight number reaching
  OpenSky from their device.
- ADS-B data is sometimes late; a track queried at landing may be incomplete.

The app already captures `flightNumber`, `origin` and `recordingStartedAt`, so
this needs no new collection — only consent.

### Two caveats on ADS-B altitude

**Oceanic coverage is weakest exactly where it matters.** OpenSky is a *ground
receiver* network; mid-Atlantic and mid-Pacific have no receivers, and satellite
ADS-B is commercial and not in the free feed. Long-haul cruise — the segment of
most interest — will have gaps. Partly mitigated: cruise altitude is near
constant, so sparse coverage still pins the step changes, and the airline API
fills in where present. The analysis must expect partial tracks.

**Altitude references differ.** ADS-B reports barometric altitude against
standard 1013.25 hPa; an airline API may report geometric or locally corrected
altitude. These disagree by hundreds of feet near the ground. Record which
source each value came from rather than merging them — the same reasoning
already applied to GPS-vs-API altitude in the charts.

---

## Consent

This would be the first time anything leaves the device. `DESIGN.md` currently
promises *"All data stays on device. There is no account, no sync, and no
analytics."* That promise changes, and the change should be explicit rather than
absorbed into an existing toggle.

Two tiers, not a spectrum — a slider of options invites over-sharing by default.

| | **Tier A — anonymous** | **Tier B — identified** |
|---|---|---|
| Shares | aircraft type (when the API gives it), duration, distance bucket, month, sensor series, coverage stats | Tier A **plus** flight number, date, origin airport |
| Real altitude | airline API only, often absent | full ADS-B track |
| Aircraft type | often unknown | resolved via `icao24` |
| Identifiability | low | **publicly linkable to a flight you were on** |

Tier B needs its own consent, worded plainly. Anyone holding a passenger
manifest can identify the contributor; that is a real disclosure, not a
technicality.

### Never uploaded, either tier

`rawFirstResponse` (contains everything), all `DiagnosticSample` rows (battery
level and app state are device fingerprinting with no research value), gate and
terminal, tail number, coordinates, and exact timestamps in Tier A.

### Anonymisation and utility point the same way

Pleasingly, the privacy-preserving choices are also the scientifically better
ones: **minutes-from-takeoff** beats wall-clock because it is how flights are
aligned for comparison, and **distance bucket** beats a city pair because route
identity is not the variable of interest.

---

## Transport

Recommendation: **start with no backend.** The app produces a contribution file,
the user reviews it, and submits it via the share sheet to a public repository.

Not laziness — it makes consent auditable (the user can read exactly what is
sent), proves the schema before anyone builds a pipeline, and means no liability
for holding other people's travel data. Automate later if contributions actually
materialise.

---

## Sensor comparability

RuuviTag humidity accuracy is roughly ±3% RH, and a fixed 0.83 hPa offset was
measured between two pressure sensors in one cabin. Across contributors with
different tags, *absolute* comparisons will be noisy; *within-flight change* and
*curve shape* will be far more robust.

Design the analysis around trends rather than absolute levels, and carry
`ReadingSource` and coverage statistics with every contribution so 5-minute
backfilled data can be excluded from anything resolution-sensitive.

---

## Open questions

1. **Where does the dataset live, and under what licence?** Contributors cannot
   meaningfully consent without knowing. A licence permitting redistribution is
   probably necessary for the data to be useful.
2. **Does Tier A keep the city pair?** Useful (oceanic vs continental) but
   identifying in combination. Current lean: drop it, use distance bucket.
3. **Is manual submission acceptable long term**, or is a backend eventually
   wanted? A backend implies an operator holding identifiable travel data.
4. **How is the decay fit validated?** A poor fit on a noisy or short flight
   should be rejected rather than contributed as a confident number.
5. **What is the minimum viable contribution?** A flight with no aircraft type
   and no altitude may still be worth having, or may just add noise.
6. **Does anything need to be deletable after upload?** A public repository
   makes retraction hard; say so up front if so.

---

## Suggested order

1. **Derived metrics** — mixing ratio, absolute humidity, cabin altitude, cruise
   segmentation, decay fit. Pure functions, testable without hardware, and
   immediately useful in the app: a mixing-ratio chart is more honest than an RH
   chart regardless of whether sharing is ever built.
2. **Personal export** (TODO #13) — full fidelity, local. Wanted anyway, and it
   forces the serialisation questions.
3. **Tier A/B consent and contribution file.**
4. **Offline enrichment tool** — need not exist until there are contributions.
