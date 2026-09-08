# TODO

Prioritized work list. P0 items are active data-loss bugs; P1 is the core
"log data during an actual flight" capability; P2+ are features.

Absorbs the items previously tracked in `FEATURE_REQUESTS.md`.

---

## P0 — Data loss bugs — ✅ DONE 2026-09-07

These broke logging even in the foreground. All three are fixed; details kept
below for context.

**Verified on device 2026-09-07.** Also: #2's premise was wrong — see below.
The real data-loss bug was the BLE scan filter (P1 #5), which meant the app had
never recorded a reading in its life.

### 1. ✅ Remove the BLE connect path — it kills the advertisement stream

**Files:** `RuuviTagScanner.swift`

All sensor data is parsed from the advertisement packet in `didDiscover`
(`:235-244` → `recordReading`). But `didDiscover` also calls
`connectToPeripheral(peripheral)` at `:247`, and:

- iOS stops delivering `didDiscover` for a peripheral that is currently
  **connected** to the device.
- RuuviTag firmware (Nordic SoftDevice) **stops advertising** once a central
  connects.

So we see a few advertisements, connect, and readings stop permanently. The
connection destroys the data source.

The NUS subscription that was meant to replace it can't work either: `:313`
subscribes to the NUS **TX** characteristic but never writes a command to
**RX**. RuuviTag's GATT interface only streams after a history request is
issued, so `didUpdateValueFor` (`:325`) never fires — zero wakeups, zero data.

**Action:**
- Delete `connectToPeripheral` (`:124-133`) and its call site (`:247`).
- Delete the `CBPeripheralDelegate` extension (`:288-333`).
- Delete `didConnect` / `didFailToConnect` / `didDisconnectPeripheral`
  (`:250-283`) and the `connectedPeripheral` state.
- Keep `willRestoreState` but drop the peripheral-restoration branch.
- Drop `.connected` from `ScanStatus`.

Advertisement scanning only. Reconnect logic returns later as part of the
history sync (P1 #6), which is a deliberate, scheduled connection — not one
that races the advertisement stream.

### 2. ✅ SwiftData store is unreadable when the screen locks

**Files:** `flight_loggerApp.swift:16-29`

⚠️ **Premise was wrong.** This assumed SwiftData defaults to
`NSFileProtectionComplete`. iOS actually defaults app files to
`completeUntilFirstUserAuthentication`, which is already lock-safe — measured
37/37 successful store reads across 9.3 minutes locked. Setting the class
explicitly is kept because it removes reliance on an undocumented default, but
it fixed no data loss.

**Action:** set protection to `completeUntilFirstUserAuthentication`. Two ways,
verify which works cleanly with SwiftData:

- Preferred: `com.apple.developer.default-data-protection` entitlement set to
  `NSFileProtectionCompleteUntilFirstUserAuthentication` (applies app-wide).
- Or: construct `ModelConfiguration(url:)` at a known path and apply
  `FileManager.setAttributes([.protectionKey: ...])` — must cover the `-wal`
  and `-shm` sidecar files too, not just the main store.

SwiftData does not expose a file-protection option on `ModelConfiguration`
directly, so this needs testing on a real locked device, not the simulator.

### 3. ✅ Save errors are silently swallowed

**Files:** `RuuviTagScanner.swift:174`, `AirlineAPIService.swift:184`

Both use `try? context.save()`. Combined with #2 this means writes can fail for
an entire flight with no signal anywhere.

**Action:** replace with `do/catch` and log via the existing `os.Logger`. Add a
surfaced error state so the dashboard can show that persistence is failing.

---

## P1 — Background execution — ✅ DONE 2026-09-07

Constraints are now documented in `DESIGN.md` → Background Execution
Constraints. Details kept below for context.

**All verified on hardware 2026-09-07** (RuuviTag "Ruuvi ED2A" + iPhone 17) —
see `DESIGN.md` for measurements and `CHANGELOG.md` for the full write-up.

- History protocol confirmed against real traffic; captured frames pinned as
  regression tests.
- Location keep-alive confirmed: 9.3 min backgrounded, no suspension, no
  throttling, **When In Use** authorization sufficient.
- Background networking confirmed: 37/37 HTTPS requests at full cadence.
- Background BLE confirmed dead.

**Newly discovered constraint:** the tag accepts only one connection at a time,
so flight-logger contends with Ruuvi Station. See P2 #16.

### 4. ✅ Add location background mode as the keep-alive

**Files:** `Info.plist`, new `LocationKeepAlive.swift`, `DataCollectionManager.swift`

Nothing currently keeps the process alive. `beginBackgroundTask`
(`DataCollectionManager.swift:97`) buys ~30 seconds, then the app suspends and
`Task.sleep(for: .seconds(30))` (`AirlineAPIService.swift:76`) never resumes.
`resumeIfNeeded` only runs from `handleBecameActive` — i.e. when the user
reopens the app. API polling is therefore strictly foreground-only today.

**Action:**
- Add `location` to `UIBackgroundModes`.
- Add `NSLocationWhenInUseUsageDescription` /
  `NSLocationAlwaysAndWhenInUseUsageDescription` justifying flight logging.
- `CLLocationManager` with `allowsBackgroundLocationUpdates = true`, started on
  session start and stopped on session end — never outside a recording session.
- Use the coarsest accuracy that still keeps us alive, to limit battery cost.
- GPS works in airplane mode, so this is viable in-flight.

This is what makes everything else in P1 actually run.

### 5. ✅ Background advertisement scanning cannot work — stop relying on it

**Files:** `RuuviTagScanner.swift:108-120`

Three stacked iOS constraints:

- Background scans must filter by service UUID. The filter at `:115` uses the
  NUS UUID, but RAWv2 sensor data is manufacturer-specific data (company
  `0x0499`) in the **ADV** packet, while the NUS UUID is in the **SCAN_RSP**
  packet. Background scanning doesn't do active scanning, so the response is
  never seen and the filter matches nothing. CoreBluetooth cannot filter on
  manufacturer data at all.
- `CBCentralManagerScanOptionAllowDuplicatesKey` (`:116`) is **ignored in the
  background** — one callback per peripheral, then silence.
- Background scan intervals are throttled hard regardless.

**Action:** keep advertisement scanning as the *foreground* fast path (it works
well there), but treat it as best-effort. Gap-free data comes from #6. Document
this in `DESIGN.md` so the constraint isn't rediscovered later.

### 6. ✅ RuuviTag onboard history sync — the real fix

**Files:** new `RuuviHistoryProtocol.swift`, `RuuviTagScanner.swift`

Implemented as a gated mode inside `RuuviTagScanner` rather than a separate
class, so there is only ever one `CBCentralManager` and the scan/connect
transition is coordinated in one place.

The tag logs to its own flash continuously (~10 days at a configurable
interval) whether or not the phone is listening. Syncing that log sidesteps the
background problem entirely and yields complete, gap-free flight data instead of
a best-effort advertisement stream.

**Action:**
- Implement the Ruuvi GATT history protocol: connect, write the history request
  to NUS RX, read the reply stream from TX.
- Trigger on: app foreground with an active session, session end, and
  periodically on background wakeups.
- Deduplicate against advertisement-derived `SensorReading` rows by timestamp —
  needs a merge strategy, since both sources will overlap.
- Resolution is capped at the tag's own log interval; document that.

This is how Ruuvi Station works, and it's the architecturally correct answer.

### 7. ✅ API polling must survive suspend/resume

**Files:** `AirlineAPIService.swift:44-123`

Even with #4, the poll loop should not depend on a single long-lived `Task`.

**Action:**
- Make `resumeIfNeeded` (`:97`) run on background wakeups, not only
  `handleBecameActive`.
- Consider a background `URLSession` chaining each poll's completion into the
  next as a fallback when location keep-alive is unavailable. Legit, wakes a
  suspended app, but the OS controls timing so 30s is not guaranteed.
- The `pollOnce` throttle (`:118`) assumes BLE wakeups exist; revisit once #1
  and #6 land.

### 8. ✅ Remove dead background modes

**Files:** `Info.plist:5-10`

`processing` is declared with no `BGTaskScheduler` registration anywhere, and
`external-accessory` is irrelevant to this app. Both do nothing and are App
Store review flags.

**Action:** remove both. Keep `bluetooth-central`, add `location` per #4.

---

## P2 — Session integrity

### 21. ✅ Persistent-link restructure verified on hardware

68-minute locked-screen run, off charger, app backgrounded for all 65 samples,
tag carried in and out of range several times (2026-09-08).

| Measure | Result |
|---|---|
| Suspension gaps | **none** — max 64.0s against a 60s cadence, 0 over 90s |
| Link up | 43/65 samples; the rest fell back to `scanning`, never `idle` |
| Link drops | 3, all recovered by the 60s watchdog |
| Reading cadence | 51 of 57 intervals on cadence (<70s) |
| Worst data gap | 301s — a history-backfilled 5-min log entry, not a hole |
| Store failures | 0 |
| Self-heal firings | 0 — no `idle` status, so the teardown race did not recur |

Conclusions:

- **The link survives a locked screen.** This was the whole point of the design
  and had never been observed before this run.
- **The watchdog is sufficient** as the sole recovery path, which matters
  because `EnableAutoReconnect` is rejected on this device.
- **Drops degrade rather than break.** When the link goes down the scanner
  falls back to advertisement scanning, and history sync backfills the period
  at the tag's 5-min log resolution — so even a 16-minute outage left no gap
  worse than 301s.

**Battery: inconclusive, no red flag.** All 47 unplugged samples read 100%, so
drain over 68 minutes was below measurement resolution — but the phone started
full, and iOS holds 100% for a while after unplugging. Needs a run starting
nearer 50% to produce a real number. (Note iOS 26 no longer breaks out per-app
battery in Settings, which is why this is sampled in `DiagnosticSample`.)

**Not separable from this data:** recovery latency. The three drops recovered
after 4m09s, 2m03s and 16m30s, but those track how long the tag was out of
range, not how quickly the watchdog acted once it returned. Measuring that
needs a controlled out-and-back with known timings.

### 9. ✅ Upper bound on session duration

Longest scheduled flight in service is roughly 19h (SIN–JFK). Cap sessions at
~21h and auto-end past that, so a session that never sees an `onGround`
indicator can't run forever and drain the battery.

Verify the current longest-flight figure rather than hardcoding blindly.

### 16. ✅ Handle contention for the tag's single connection slot

Verified 2026-09-07: the RuuviTag accepts one connection at a time. While Ruuvi
Station holds it, the tag advertises non-connectable and `connect` hangs until
timeout. History sync therefore fails silently whenever another app is
connected.

Done:
- Dashboard "Tag History" card shows sync state, last result, and the failure
  reason naming Ruuvi Station as the likely cause.
- Manual "Sync Now" button.
- Automatic retry with a shorter backoff (2 min) after failure vs 15 min after
  success.
- Fixed: `historyState` stayed `.failed` after an error, which would have
  blocked every subsequent sync permanently.

### 17. ✅ Promote history sync to periodic mid-flight

Now that the protocol is hardware-verified, sync no longer has to be confined
to session end. Since live BLE is dead in the background (confirmed), periodic
sync is the **only** route to gap-free cabin data across a locked screen.

Done: syncs every 15 min during a session, driven off the liveness loop.

Key fix along the way — sync previously located the tag by *scanning*, which is
dead in the background, so periodic sync could never have worked there. It now
remembers the tag's identifier and uses
`retrievePeripherals(withIdentifiers:)` to connect without scanning, which
**is** permitted in the background.

The data watermark only advances on success, so a failed sync re-requests the
same window instead of losing it.

### 19. ✅ (investigated) NUS heartbeat frames — partially implemented

**Verified on hardware.** While connected over NUS the tag streams its current
reading as an 18-byte Data Format 5 payload — the advertisement format minus
the trailing 6-byte MAC. Measured cadence **1.98s**, with the DF5 sequence
number incrementing by exactly 1 each frame (no dropped measurements).

`parseRAWv2` was rejecting these purely on length: it guards on size but only
ever reads bytes 0-6. Now accepts both real shapes (24 with MAC, 18 without)
while still rejecting truncated payloads, which a loose `>= 18` would not.

Done: heartbeats received during a sync connection are recorded as
`SensorReading`s. Confirmed on device at a steady 2.0s spacing.

**Not done — the actual win needs a decision.** Heartbeats only flow while
connected, which today means the ~45s sync window every 15 min. Capturing
continuous background cabin data at 2s resolution requires holding a
**persistent connection** for the flight. That is a real design change, not a
tweak:

- Unverified: whether iOS keeps delivering GATT notifications indefinitely to a
  backgrounded app. Plausible — notification delivery is a supported background
  path, unlike scanning — but everything else assumed today has needed checking.
- Battery cost of a persistent BLE connection over a long-haul flight.
- The tag has one connection slot, so holding it locks out Ruuvi Station for
  the entire flight.
- Live scanning and a held connection are mutually exclusive (the tag stops
  advertising when connected), so this replaces the advertisement path rather
  than supplementing it.

If it works backgrounded, it supersedes periodic history sync as the primary
source: 2s resolution versus ~5 min, and no gap across a locked screen. History
sync would remain as the backfill for anything missed.

### 20. Apple Watch — ruled out, do not revisit

Investigated 2026-09-07. The Watch cannot work around the background BLE
constraints; it is strictly worse than the phone:

- **Peripherals are disconnected when a watchOS app is suspended**, so a held
  link — the whole basis of our approach — dies.
- **"Waking up the app when something happens over BLE is not supported in
  watchOS."** The connection-wake mechanism we depend on does not exist there.
- The `com.apple.developer.bluetooth-central-background` entitlement is granted
  very selectively — reportedly only to watchOS apps talking to continuous
  glucose monitors. Not obtainable for this.
- watchOS restricts apps to central role and at most two peripherals.
- The tag has one connection slot, so a Watch link would contend with the phone
  rather than supplement it, and the Watch battery is far smaller.

### 18. ✅ Tag log interval — measured and surfaced

The app cannot set this — it is configured in Ruuvi Station — so instead it
measures the cadence from backfilled readings and shows it in the flight
detail. Median rather than mean, since one missing log entry doubles a gap and
would drag an average well off the true interval.

Much less pressing than when filed: heartbeats over the persistent link give
60s resolution, so the tag log is now only the backfill path for periods when
the link was down. Lowering it costs tag battery for data that is usually
redundant.

### 10. ✅ Auto-stop reliability

Two changes.

The `onGround` indicator now has to hold for 3 consecutive polls (~90s) before
ending a session. It is also true during taxi and pushback, and a single
transient reading would have ended a recording that cannot be resumed. The cost
is ~90s of extra tail data.

Manual sessions, which have no `onGround` signal at all, now auto-end after 2h
with no data from *either* source. Deliberately generous: ending early is worse
than running long, and a dropped tag plus no airline API is a plausible
mid-flight state. The 21h cap remains as the outer bound.

---

## P2b — Additional sensors

Investigated 2026-09-08 against the iOS 26.5 SDK headers, not from memory.

**Consent principle:** environmental measurements are what the app is *for* and
need no separate opt-in. Motion and health data are different in kind — they
describe the user, not the cabin — so each is gated behind an explicit Settings
toggle that defaults to off and is what triggers the system permission prompt.
Nothing is collected before the user asks for it, and the app should say plainly
that the data stays on device.

### 22. iPhone barometer as a second cabin-pressure source

`CMAltimeter` is available, with relative and absolute altitude
(`isAbsoluteAltitudeAvailable`, iOS 15+). It measures cabin pressure directly —
the same physical quantity as the RuuviTag, from a wholly independent sensor
with no BLE involved.

Why this is the highest-value addition:

- **Cross-comparison**, which was the original motivation: two sensors, one
  quantity, plotted on the shared time axis the charts already provide.
- **Redundancy that matters.** The 2026-09-08 commute had a 16-minute link
  outage; the barometer would have covered it at ~1 Hz with no tag involved.
- **Works with no tag at all**, which makes the app useful before the user owns
  or remembers one.

No opt-in needed — this is cabin environment, the app's stated purpose.

Open question: sampling rate and whether it survives backgrounding as well as
the location keep-alive does. Verify on device rather than assuming; that
assumption has been wrong repeatedly on this project.

### 23. Log the location data we already collect

`CLLocationManager` runs continuously for the keep-alive and every fix is
currently discarded. `CLLocation` carries `altitude`, `ellipsoidalAltitude`,
`verticalAccuracy`, `speed` and `course`.

This is free — the sensor is already running and already costing battery. It
gives an altitude and groundspeed trace on **every** flight, including the
majority with no airline WiFi, where `FlightDataPoint` is currently empty.

Design note: keep it distinguishable from API-reported altitude rather than
merging them. They disagree (GPS altitude vs pressure altitude vs the airline's
figure), and the disagreement is interesting rather than a defect to hide.

### 24. Motion / turbulence — requires opt-in

`CMMotionManager` vertical acceleration variance gives a real turbulence metric
on the same time axis as cabin pressure. Novel, and genuinely informative about
a flight.

**Gated behind a Settings toggle**, default off. Motion access carries its own
system prompt (`NSMotionUsageDescription`) and describes the user's movement,
not the cabin.

Cost to check before committing: continuous accelerometer sampling is not free
on battery, and the useful output is a summary statistic rather than raw
samples — decide the aggregation window before storing anything.

### 25. HealthKit: SpO2, heart rate, HRV — requires opt-in

**SpO2 is read-only and cannot be polled.** `HKQuantityTypeIdentifierOxygenSaturation`
exists for reading, but there is no API anywhere in HealthKit to trigger a
measurement — no `startBloodOxygen` equivalent. The Watch samples on its own
schedule, largely when the wearer is still. Log opportunistically; do not design
around a cadence.

Legal status resolved: the ITC found Apple's redesigned blood oxygen feature
non-infringing and terminated the Masimo case (March–April 2026), so the feature
is available again on US watches.

**Heart rate is the better physiological signal** precisely because its cadence
*can* be driven: an `HKWorkoutSession` on the Watch samples roughly every 5s.
`HeartRateVariabilitySDNN` and `RespiratoryRate` are also available.

Cabin altitude is typically 6,000–8,000 ft equivalent, so the physiological
response to it is the interesting cross-comparison against cabin pressure.

**Gated behind a Settings toggle**, default off, with HealthKit's own
authorisation flow. This is health data: request read-only access to the
specific types used, nothing broader, and state that it is never transmitted.

Scope warning: high-frequency heart rate needs a **watchOS app target**, which
is a substantially larger piece of work than items 22–24. Worth splitting the
HealthKit read (phone-only, opportunistic) from the Watch workout session
(new target) if this is picked up.

### Not available — do not go looking

Neither the iPhone nor the Watch exposes **ambient temperature or humidity**.
CoreMotion has nothing, and the Series 8+ temperature sensor only produces
overnight sleeping wrist-temperature deviation, not real-time ambient. The
RuuviTag is the only source for those two, which is the argument for keeping it
central rather than treating it as replaceable.

---

## P3 — Features

### 11. ✅ Metric / imperial unit preference

Already complete — this entry was wrong. `UnitPreference` implements formatting,
chart-value conversion and labels; `SettingsView` has the picker; `DashboardView`
and `FlightDetailView` both consume it; `.system` reads
`Locale.current.measurementSystem`. Storage stays SI, conversion is UI-only.

### 12. ✅ Chart zoom and dynamic fit

Built in `FlightProfileCharts`. Fit-all is the default and tracks newly arriving
points rather than pinning to a stale window; pinch zooms, clamped to a 2-minute
floor and the full span as ceiling; a "Fit All" button appears only once zoomed.

The larger problem found while doing it: each panel owned its own scroll state,
so panning one left the others behind — which defeats the main reason to open
the screen, correlating cabin pressure against altitude. Pan, zoom and scrub
state now live in one place and apply to every panel.

Also added touch-to-scrub with a shared rule and per-panel value readout, and
fixed a degenerate domain (a session with one reading rendered an empty panel).

### 13. Log export for Grafana

Needs design first. Likely CSV or line-protocol export per session, shared via
the system share sheet. Decide on schema, timestamp format, and whether to
export raw rows or a resampled series.

### 14. Live Activity

Lock Screen / Dynamic Island display of cabin pressure, humidity, and altitude.

**Important:** this is a *display* layer, not an execution mechanism — it grants
no background runtime, so it depends on #4 and does not substitute for it.
Update locally via `activity.update()` on each poll; do **not** design around
ActivityKit push, since APNs needs real internet and in-flight captive portals
generally block it (the airline API itself is local, which is why polling works
without internet).

Note the ~8h active / ~12h total Live Activity lifetime cap — that collides with
long-haul flights and with #9. Verify current limits against Apple's docs.

Soft benefit: an active Live Activity makes continuous background location
legible to the user, which helps justify #4 in App Store review.

### 15. ✅ App icon / logo

Log shown end-on so the growth rings carry the shape — a set of concentric
circles stays legible at 40pt, where a side-on log collapses into a brown
smudge. White plane crossing it for contrast, on a night sky.

Generated by `Tools-AppIcon.swift` (CoreGraphics) and checked at 60px before
committing, rather than only judged at full size. Keeping the generator in the
repo means the icon is reproducible rather than an opaque binary.
