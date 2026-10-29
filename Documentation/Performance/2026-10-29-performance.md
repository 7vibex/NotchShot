# NotchShot performance pass — 29 October 2026

The once-a-second AI Activity poll now takes **7.2 → 1.4 ms on the real 2,160-file folder (81% less)** and retires **145 → 27 M instructions per poll**. It is cheaper at every folder size, including tiny ones. In both live profiles it was the largest single cost, about two-thirds of the app's CPU on a locked Mac with music playing and agents at work.

Two smaller leaks are also fixed:

- A Lock Screen log line that was written about four times a second is now written only when its values change.
- Unlocked layout passes no longer send two Notification Center removal requests each when there is nothing to remove.

This pass measured the live app only with the screen locked, plus the code paths that state uses. It does not establish a whole-app speedup, a launch-time change, an unlocked idle number or a battery-life gain. The running app's after-numbers need a relaunch from `dist/` and were not taken.

## The live app, before

Measured on the user's running NotchShot (the `dist/` build from 28 October, close to `f55e42f` in the files this pass touches) on an Apple M5 MacBook Air, 16 GB, macOS 26.7.2. The screen had been locked for about five hours, Spotify was playing, and three Claude Code sessions were active. `proc_pid_rusage` deltas over 60 s, no profiler attached:

| Metric | Value |
|---|---:|
| CPU | 4.0% of one core (211 M instructions/s) |
| Energy (`ri_energy_nj`) | 17.6 mJ/s |
| Wakeups | 6.3/s |
| Physical footprint | 68 MB |

A 10 s `sample` (attribution only, it inflates CPU) put almost all of it on the main thread; the seven other threads were idle and there were no helper processes. Main-thread busy time split roughly:

- **53%** `AIActivityMonitor.loadActivities()`: listing 2,143 status files, a URL and bridged resource dictionary per file, every second.
- **34%** `NotchWindowController.applyLayout()` → `orderOut` waiting in `SLSConnectionSynchronizeSLSCATransaction`. This is time blocked waiting on the WindowServer, not CPU (see open leads).
- **12%** Claude hook events flowing into an island refresh, and 3% Crewline's unpaired-credential keychain retry.

The same window logged `Locked presentation: show=false, …` **2,422 times in 10 minutes**.

### Second profile, after a relaunch

At 19:58 another session relaunched the app from a new `dist/` build. That build still had none of this pass's changes, and the screen stayed locked. Two 30 s `proc_pid_rusage` windows, ten minutes apart:

| Metric | Value |
|---|---:|
| CPU | 3.1–4.4% of one core (224–225 M instructions/s) |
| Energy | 13.5–20.8 mJ/s |
| Wakeups | 14.1–14.6/s |
| Physical footprint | 30.5–30.7 MB |

In a 10 s sample, the AI Activity refresh was 243 of 314 busy main-thread samples (77%). The rest was Crewline (15), the brightness poll (9), the presence poll (5), island refresh (5) and Notification Center removals (4). The bench puts the old scan at 145 M instructions per poll, about 64% of the 224 M instructions a second this process retired.

This process never ran its Lock Screen branch. It started after the lock, and the window controller starts out assuming an unlocked session (see leads). So it ran the unlocked path while locked, which is how the removal requests below came to light.

## Results

Release `NotchShotBench ai.activity`. The `f55e42f` implementation (`Baselines.AIActivityListingLoaderBefore`) and the new one alternate in one process for three rounds each, both caches warm. Each cell is the range of the three round medians. Before timing, every pair is checked to return the same activities in the same order, on both the synthetic folders and the real one.

| Status files | Before | After | Change |
|---:|---:|---:|---:|
| 1 | 0.038–0.044 ms | 0.024–0.025 ms | −40% |
| 3 | 0.063–0.065 ms | 0.041–0.042 ms | −35% |
| 32 | 0.430–0.451 ms | 0.294–0.302 ms | −32% |
| 500 | 1.93–1.96 ms | 0.58–0.59 ms | −70% |
| 2,000 (synthetic) | 6.50–7.07 ms | 1.24–1.29 ms | −81% |
| **2,160 (the live folder, read only)** | **7.15–8.22 ms** | **1.37–1.47 ms** | **−81%** |

30–50 timed iterations per round, all succeeded; load average 7–12 from other sessions' builds. The fixed CPU control read 5.6 ms in the full sweep that followed. Raw per-iteration samples are in [ai-activity-ab.json](2026-10-29-evidence/ai-activity-ab.json).

Instructions retired per poll come from the new `Benchmark.instructions` counter: the whole bench process, 30 calls after one warm call, in two separate runs. Machine load barely moves this count, so it backs up the timings on this busy Mac. The two runs agree within 0.6%.

| Status files | Before | After | Change |
|---:|---:|---:|---:|
| 1 | 0.53 M | 0.34 M | −36% |
| 3 | 0.99 M | 0.65 M | −34% |
| 32 | 7.80–7.83 M | 5.21–5.24 M | −33% |
| 500 | 39.1–39.2 M | 11.0 M | −72% |
| 2,000 (synthetic) | 140.2–141.0 M | 24.8–25.3 M | −82% |
| **2,160 (the live folder)** | **144.6–144.7 M** | **27.3 M** | **−81%** |

Values per run are in [ai-activity-instructions.json](2026-10-29-evidence/ai-activity-instructions.json).

At one poll a second on the live folder, that comes to about 6 ms less main-thread time and about 117 M fewer instructions each second. That is roughly half of what the relaunched app retired. This is a prediction from bench numbers, not a live measurement. The cost still grows with file count (about 0.6 µs per file) because nothing prunes status files. Pruning is still the open retention decision.

## Cause and preserved contract

`loadActivities()` needs the 32 newest status files. It got them by listing the whole folder with five prefetched keys, building a URL and a bridged `URLResourceValues` for every file, and sorting. A probe on 2,143 files put the `getattrlistbulk` system call itself at about 2.9 ms. The rest of the time went to per-file Foundation objects.

`AIActivityMonitor.newestEntries(in:limit:)` makes one `getattrlistbulk` pass for name, device, type, date, flags, file ID and data length. It keeps a running newest-`limit` list and builds a URL only for entries that make that list. Type, size, date and identity for validation and the decode cache come from the same pass. The first version read them again per candidate, which made the 32-file case 20% *slower*; that was measured and replaced.

Preserved, each checked against Foundation by `newestEntriesMatchListing`:

- Same entries and order as `.skipsHiddenFiles` plus a stable sort on `contentModificationDate`: dot files and `UF_HIDDEN` entries are skipped, symlinks rank by their own date, folders still rank, unreadable entries rank last, and equal dates keep listing order. Checked at limits 0, 1, 32 and 200.
- Validation reads the same facts as before: regular file, not a symlink, size limit, ownership and `.json` extension, re-checked every poll even on a cache hit.
- An atomic replacement with identical bytes and date still reads as a different file. `FileIdentity` (device, file ID) replaces `fileResourceIdentifier`.
- A folder that can't be listed still clears the cache and returns nothing. `activityURLs()` (Dismiss) uses the same scan.

The poll interval, the 32-file budget, the decode cache, history and the visible policy are unchanged.

### Lock Screen log line

While the session is inactive, every island refresh runs the locked branch of `applyLayout`, and it logged its presentation line every time. It is now logged when the line's values change, and again on the first pass of each lock. It still states, in public form, whether the card was asked for. Before: 2,422 lines in 10 minutes. After: not measured in the live app (needs a relaunch); by construction, one line per lock plus one per change. No test covers it: `NotchWindowController` builds real panels and has no test seam.

### Notification Center removals

Every unlocked `applyLayout` pass calls `LockedMediaNotificationController.clear()`. Each call asked usernoted to remove pending and delivered song notifications: two XPC requests and two persisted log lines. The app no longer posts these notifications, since nothing calls `update(snapshot:…)`; the removal is there to clean up after a build that did.

In the relaunched app it ran about 1.5 times a second, which was nearly all of the app's persisted log volume (about 200 lines a minute). The sample put roughly 0.3 ms per call on the main thread, and usernoted measured 0.03% of a core.

The controller now tracks whether a notification could exist. That is true at launch, so the first removal still cleans up after an older build. It becomes true again before every submission and false after each removal. Delivery's own removals, before a replacement and after a stale submission, are unchanged.

The new test `repeatedClearsRemoveOnce` checks three things:

- Five clears and a custom-panel toggle send one removal request.
- After a submission, one clear removes the notification.
- Further clears send nothing.

With the guard removed, the test fails both of its count checks. The ten existing delivery tests pass unchanged. Live after-number: not taken. The prediction is no "Removing … notification" lines after the first second of a launch.

## Checks

- `swift test --filter LockedMediaNotificationDeliveryTests` (debug): 11 tests passed. Control: `repeatedClearsRemoveOnce` fails with the new guard removed.
- `swift test --filter "AIActivity|AI activity|AgentUsage"` (debug): 15 tests / 3 suites passed, including the listing-equivalence test.
- Full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` (debug), with these changes: **1,274 tests / 208 suites passed**. `PasteboardRaceTests` writes the system clipboard and was left unexecuted to protect user data. `idleClientsRecover` is a known flake under full-suite load.
- Release `NotchShotBench ai.activity` twice with instruction counters: every precondition held. The earlier full sweep completed every group.

## Coverage and leads

| Surface | Evidence / disposition | Next check |
|---|---|---|
| Background polling (AI Activity) | Two live samples, probes, interleaved release A/B on synthetic and real folders, instruction counts. **Retained.** | Live after-number once the user relaunches. |
| Notification Center removals | Live log rate, sample, usernoted `rusage`, fixture test with control. **Retained.** | Live log count after a relaunch. |
| Lock Screen log line | Live log rates. **Retained.** | Live log count after a relaunch. |
| `orderOut` wait while locked | Seen only in the first process: ~11–13 ms per locked refresh. Two suspects ruled out. (1) The Lock Screen Space: no attach was logged in 6 h, and both locked opt-ins are off. (2) Hiding a panel whose content changed while hidden: a probe on this locked Mac measured 0.1–0.9 ms per pass and no WindowServer waits, interleaved over 30 rounds, for layer and SwiftUI content. The relaunched app never ran the locked branch, so it can't show the wait. Remaining suspect: the panel was on screen when the lock began. **Not changed.** | Debug build: lock with the notch visible, then log `isVisible` and time `orderOut`. |
| Launch while locked | `NotchWindowController` starts with `isSessionActive = true` and `isScreenLocked = false` and learns of a lock only from notifications. A launch after the lock therefore runs the unlocked path until the next lock: the panel is ordered in, the presence poll runs, and removals are sent on every pass. `MediaCoordinator`, `InstantReplayController` and the notification mirror (fed by `MediaCoordinator`) share the pattern. **Not changed here:** the fix changes launch behaviour in four components and needs a lock → launch → unlock check on the Mac. | Seed the state from `CGSessionCopyCurrentDictionary` at start. Proposed as a separate task. |
| Brightness poll | A 5 Hz `DisplayServicesGetBrightness` XPC on the main thread, which keeps running while locked: about 5 of the app's ~15 wakeups a second, and ~0.9 ms/s of main thread in the sample. **Not changed:** pausing it while locked, or switching to a change notification, alters polling policy and needs a brightness-key check on hardware. | Product decision; then measure wakeups and energy before and after. |
| Island refresh fan-out | Each Claude hook event refreshes the island twice, about 15 ms apart: once from `context.onSnapshotChange`, once from `observeIslandSources` → `scheduleIslandRefresh`. About 1 ms CPU per refresh while locked, and 5 of 314 busy samples in the second profile. **Not changed:** the unlocked cost (SwiftUI) isn't measurable with the screen locked, and refresh ordering is delicate. | Count refreshes per hook and measure CPU with the notch visible. A generation check taken in the observation's `onChange` could skip the redundant pass. |
| Crewline unpaired retry | Keychain miss every 5 s on main. A warm miss costs 0.18 ms. **Rejected** as negligible. | — |
| Network | No sockets or traffic in the relaunched app (`lsof`, `nettop`). Lyrics are opt-in and cached (40 entries), with in-flight de-duplication and 8 s / 12 s timeouts. Sparkle runs only in configured release builds. Reachability uses `NWPathMonitor`, which is event-driven. **No change.** | Traffic while lyrics are on and tracks change. |
| Memory | The relaunched app stayed at 30.5–31.3 MB footprint for 25 minutes while locked. The first process was at 68 MB after 5 h (187 MB peak). **No change:** the growth was not reproduced. | Open/close cycles while unlocked, footprint before and after. |
| Launch | One launch observed, at 19:58, of a freshly built and signed binary: exec → WindowServer connection 0.85 s → notch panel 1.13 s → retention cleanups done 1.25 s. The logs don't account for the 0.85 s before AppKit; a first launch of a new 55 MB binary pays cold page-in and signature checks. Startup cleanups scale with the store (181 history rows, 176 captures here). History load at 5,000 rows is 100 ms, already tuned and fuzz-tested. **No change.** | Repeated warm launches. Blocked here: one GUI instance at a time, and a second instance would share sockets, hotkeys and the system-overlay lease. |
| Opening/scrolling History, capture, clipboard, island engine | Full release sweep: search cache hit ~0, cold search 3–5 ms at 5,000 rows, record 6.9 ms, save 29 ms (off main), PNG encode 33 ms (detached), island sync/present ≤ 10 µs. **No change.** | On-screen scrolling and hitch traces. |
| Rendering loops | Every SwiftUI `repeatForever` and `TimelineView(.animation)` loop in the notch is now a layer. Only 1 Hz countdowns and a 6 Hz Productivity view remain. **No change.** | — |
| Unlocked steady state, size | Not measurable this session (screen locked, user away). | Unlocked idle and agent-active CPU/energy after the relaunch. |

## Reproduction

```sh
swift build -c release --product NotchShotBench
NOTCHSHOT_BENCH_AI_DIRECTORY="$HOME/Library/Application Support/NotchShot/AI Activity" \
  .build/release/NotchShotBench ai.activity
```

`NOTCHSHOT_BENCH_AI_DIRECTORY` is optional. With it, the real folder is only listed and read: `loadActivities()` never writes, and the benchmark keeps its history file in its own run folder. The run prints timings and instructions per call; `NOTCHSHOT_BENCH_RESULTS=<file>` keeps both as JSON Lines.
