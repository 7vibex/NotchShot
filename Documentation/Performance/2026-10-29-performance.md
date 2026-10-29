# NotchShot performance pass — 29 October 2026

The once-a-second AI Activity poll now costs **7.2 → 1.4 ms on the real 2,160-file folder (81% less)**, and less at every folder size, including tiny ones. It was about two-thirds of the CPU the live app used on a locked Mac with music playing and agents at work. A Lock Screen log line that was written about four times a second now appears only when it changes.

This pass measured the live app in one state (screen locked) and the code paths that state exercises. It does not establish a whole-app speedup, a launch-time change, an unlocked idle number or a battery-life gain.

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

At one poll a second, the live folder's saving is about 6 ms of main-thread time per second, about 0.6% of a core. The live app's own after-number needs a relaunch from `dist/` and was not taken. The cost is still linear in file count (about 0.6 µs per file), because nothing prunes status files. Pruning is still the open retention decision.

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

While the session is inactive, every island refresh runs the locked branch of `applyLayout`, and it logged its presentation line every time. It is now logged when the line's values change, and again on the first pass of each lock. It still states, in public form, whether the card was asked for. Before: 2,422 lines in 10 minutes. After: not measured in the live app (needs a relaunch); by construction, one line per lock plus one per change.

## Checks

- `swift test --filter "AIActivity|AI activity|AgentUsage"` (debug): 15 tests / 3 suites passed, including the new listing-equivalence test.
- Full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` (debug): **1,273 tests / 208 suites passed**. `PasteboardRaceTests` writes the system clipboard and was left unexecuted to protect user data. `idleClientsRecover` is a known flake under full-suite load.
- Release `NotchShotBench` full sweep: every group completed and every precondition held.

## Coverage and leads

| Surface | Evidence / disposition | Next check |
|---|---|---|
| Background polling (AI Activity) | Live sample, probes, interleaved release A/B on synthetic and real folders. **Retained.** | Live after-number once the user relaunches. |
| Lock Screen state | Live `rusage`, sample, log rates, WindowServer window list, AppKit probe on this locked Mac. Log line **retained**. | See the `orderOut` lead. |
| `orderOut` wait while locked | Every locked refresh blocks ~11–13 ms in `orderOut`. The WindowServer lists the panel off screen, and a probe on this locked Mac hides an already-hidden panel in 3–6 µs. Suspected cause: AppKit still treats the panel as visible after a Lock Screen Space attach. **Not changed:** the cause is unconfirmed, and a wrong guard could show the panel on the Lock Screen. | Debug build on a locked session: log `isVisible` around `orderOut`. |
| Island refresh fan-out | Each Claude hook event refreshes the island twice, about 15 ms apart: once from `context.onSnapshotChange`, once from `observeIslandSources` → `scheduleIslandRefresh`. About 1 ms CPU per refresh while locked. **Not changed:** the unlocked cost (SwiftUI) isn't measurable with the screen locked, and refresh ordering is delicate. | Count refreshes per hook and measure CPU with the notch visible. A generation check taken in the observation's `onChange` could skip the redundant pass. |
| `LockedMediaNotificationController.clear()` | Sends two `UNUserNotificationCenter` remove requests on every unlocked `applyLayout`. usernoted measured 0.02% while locked. **Not changed:** the cost is unmeasured. | Measure usernoted while unlocked under agent load. |
| Crewline unpaired retry | Keychain miss every 5 s on main. A warm miss costs 0.18 ms. **Rejected** as negligible. | — |
| Launch | Cleanups scale with the store (181 history rows, 176 captures here). History load at 5,000 rows is 100 ms (27 ms decode, 55 ms `AppPaths.owns` row checks), already tuned and fuzz-tested. **No change.** | End-to-end launch is blocked: one GUI instance at a time, and a second instance would share sockets, hotkeys and the system-overlay lease. |
| Opening/scrolling History, capture, clipboard, island engine | Full release sweep: search cache hit ~0, cold search 3–5 ms at 5,000 rows, record 6.9 ms, save 29 ms (off main), PNG encode 33 ms (detached), island sync/present ≤ 10 µs. **No change.** | On-screen scrolling and hitch traces. |
| Rendering loops | Every SwiftUI `repeatForever` and `TimelineView(.animation)` loop in the notch is now a layer. Only 1 Hz countdowns and a 6 Hz Productivity view remain. **No change.** | — |
| Memory | 68 MB footprint, 187 MB peak. **No change.** | Open/close cycles for retained growth. |
| Unlocked steady state, network, size | Not measurable this session (screen locked, user away). | Unlocked idle and agent-active CPU/energy after the relaunch. |

## Reproduction

```sh
swift build -c release --product NotchShotBench
NOTCHSHOT_BENCH_AI_DIRECTORY="$HOME/Library/Application Support/NotchShot/AI Activity" \
  .build/release/NotchShotBench ai.activity
```

`NOTCHSHOT_BENCH_AI_DIRECTORY` is optional. With it, the real folder is only listed and read: `loadActivities()` never writes, and the benchmark keeps its history file in its own run folder.
