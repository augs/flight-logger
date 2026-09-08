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

### 21. Verify the persistent-link restructure on hardware — mostly verified

**Verified on device 2026-09-08:**

1. ✅ Link comes up from a cold start — ready ~1s after launch.
2. ✅ Heartbeat readings land at exactly the 60s throttle (5/5 consecutive
   samples, gaps 60.2–60.3s), store writable throughout.
3. ✅ History sync completes over the existing link, including a ~9 hour
   backfill of 111 entries at 300s spacing — the idle-timeout change handles
   long windows.
4. ✅ No suspension across a real 40-minute commute: 39 samples, max gap 72s,
   nothing over 90s, off charger, in a pocket.
5. ✅ Restored connections rebuild their state (see DESIGN.md).

**Still unverified:**

- **The link across a locked screen for a sustained period.** The commute run
  was invalidated by the teardown race (fixed in `aa8bd23`), so this — the whole
  point of the design — has still never been observed working. Needs a repeat
  of the commute test.
- **Watchdog recovery of a dropped link.** `EnableAutoReconnect` is rejected on
  this device, so the 60s watchdog is the only recovery path and nothing has
  ever exercised it. Walk the tag out of BLE range and back.
- **Battery cost.** Check Settings → Battery → flight-logger after a long run.

**Known cosmetic issue:** two `Linking to…` log lines appear per connect. The
`connectLink` duplicate guard checks `peripheral.state`, which has not yet
transitioned to `.connecting` when the second call arrives in the same run loop
turn. CoreBluetooth dedupes the requests, so this is noise rather than a defect,
but it makes logs harder to read.

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

### 18. Consider lowering the tag's log interval

Observed cadence was ~301s (5 min), which is coarse for a flight profile.
Adjustable in Ruuvi Station. Worth deciding what resolution the charts actually
want before recommending a value — shorter intervals cost tag battery.

### 10. Review auto-stop reliability

`AirlineAPIService.swift:179-182` ends the session on the `onGround` indicator.
With no airline API (manual sessions) there is no auto-stop at all — #9 becomes
the only backstop. Consider also ending on sustained loss of both data sources.

---

## P3 — Features

### 11. ✅ Metric / imperial unit preference

Already complete — this entry was wrong. `UnitPreference` implements formatting,
chart-value conversion and labels; `SettingsView` has the picker; `DashboardView`
and `FlightDetailView` both consume it; `.system` reads
`Locale.current.measurementSystem`. Storage stays SI, conversion is UI-only.

### 12. Chart zoom and dynamic fit

Charts should be zoomable, default to fit-all-data, and resize dynamically as
points arrive. Currently `FlightDetailView` has scrollable axes but no zoom or
auto-fit.

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

### 15. App icon / logo

Plane + log. Twin Peaks Log Lady standing in front of a plane is the stated
inspiration.
