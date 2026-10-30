# NotchShot performance pass — 29 October 2026

The once-a-second AI Activity poll now takes **7.2 → 1.4 ms on the real 2,160-file folder (81% less)** and retires **145 → 27 M instructions per poll**. It is cheaper at every folder size, including tiny ones. In both live profiles it was the largest single cost, about two-thirds of the app's CPU on a locked Mac with music playing and agents at work.

Also fixed:

- A Lock Screen log line that was written about four times a second is now written only when its values change.
- Unlocked layout passes no longer send two Notification Center removal requests each when there is nothing to remove.
- A launch on a locked Mac now starts locked. Before, the notch, media, Instant Replay and the notification mirror all ran as unlocked until the next lock.
- The 5 Hz brightness poll pauses while the session is locked, as it already did while displays sleep. While locked its readings could never reach the screen. In a probe, that poll cost 5.5–7 wakeups and 0.5–0.8 mJ a second.
- The OSD replacement's strict signature check runs only when the app bundle has changed on disk. It hashes the whole 59 MB bundle on the main thread and ran twice per launch, once per helper pause, and on every redraw of Settings → Notch. One launch spent 0.92 s of main-thread time on the two checks. A check of the bundle's file stamps, 3–14 ms, now decides whether the last answer still holds.
- Waiting for a child process could hang forever. `Process.waitUntilExit()` on a worker thread never returned in 13 of 568 probe runs, after the child had already exited. A full test run sat in the Terminal runner for five hours this way. The Terminal runner, archive extraction, the Bluetooth battery report and the Screen Recording reset now poll `isRunning` instead, and none of 384 probe runs hung.

This pass profiled the live app twice with the screen locked and once unlocked with the user at the Mac, all on code from before these changes. Another session then rebuilt `dist/` from `1b6d211` (every change here except the signature check) and relaunched it at 02:47 with the Mac locked. That gave the after-numbers below, including a real lock → launch → unlock. It does not establish a whole-app speedup, a launch-time change or a battery-life gain: the before and after profiles ran under different load and use.

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

### Third profile, unlocked and in use

At 02:20 on 30 October the screen was unlocked and the user was at the Mac: the time since the last input went from 23 s to 0 during the first window. This is still the 19:58 process, with none of this pass's changes. AI Activity was switched off in its settings by then (`notchshot.aiActivity = 0`), so its scan is not in these numbers. One 60 s window, then six 30 s windows:

| Metric | Value |
|---|---:|
| CPU | 3.6% of one core (60 s window) |
| Instructions | 32–46 M/s |
| Energy | 5.6–7.5 mJ/s |
| Wakeups | 12–37/s |
| Physical footprint | 97.2 MB, flat for 3 minutes (peak since launch 227.6 MB) |

In a 10 s sample, NotchShot's own code is about 1% of the main thread. The rest of the time is spent waiting. The largest busy items are the notification mirror's Accessibility scan, every 0.45 s (28–32 samples, on its own queue), the 5 Hz brightness poll (13–14) and the mouse monitors (9).

The footprint is mostly heap: 74 MB of dirty `MALLOC_SMALL`. `heap` counts 38.2 MB of live allocations in 279,952 blocks, so about 36 MB is freed memory that malloc has not returned to the system since the 227.6 MB peak. What caused the peak is unknown. The live heap holds 5 MB of Swift metadata, about 3 MB of SF Symbol (CoreSVG) data and 893 `CFBundle` objects. A probe of the app launcher's `ApplicationCatalog.discover()` rules it out as the source of those bundles: it finds 102 apps, takes 229 ms cold and 9–10 ms warm, runs off the main thread, and keeps about 5 MB. The count is close to the 936 frameworks loaded into the process, and Core Foundation keeps one `CFBundle` per framework once something has asked for it. That is system state, not an app cache. **No change** to either.

### Fourth profile, the new build

The 02:47 process (pid 80372, `1b6d211`), unlocked, with the user at the Mac (last input 0.2 s before the end) and AI Activity still off. Other sessions were building: load average 13–31. One 60 s window, then four 30 s windows, from 02:55:40:

| Metric | New build | Old build (third profile) |
|---|---:|---:|
| CPU | 1.5% of one core (60 s); 1.0–4.0% (30 s) | 3.6% (60 s) |
| Instructions | 32 M/s (60 s); 18–80 M/s (30 s) | 37 M/s (60 s); 32–46 M/s (30 s) |
| Energy | 4.5 mJ/s (60 s); 2.2–13.0 mJ/s (30 s) | 6.4 mJ/s (60 s); 5.6–7.5 mJ/s (30 s) |
| Wakeups | 30–37/s | 12–37/s |
| Physical footprint | 83 MB, then 39–41 MB after a 4 s lock at 02:56:39 | 97.2 MB |
| Peak since launch | 123.6 MB after 13 minutes | 227.6 MB after 6.5 hours |

The ranges overlap, so the unlocked steady state is **equivalent within noise**, not faster. Nothing in this pass targeted it except the Notification Center removals.

Log counts in the first 16 minutes, over three locked stretches (the first from launch) and three unlocks:

- 2 Notification Center removal lines, both at launch (02:47:01.6). The old process sent about 200 lines a minute, mostly these.
- 4 `Locked presentation` lines: one per lock, plus one when media appeared. Before: 2,422 in 10 minutes.

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

### Launch while locked

`NotchWindowController`, `MediaCoordinator`, `InstantReplayController` and `SystemLevelMonitor` started out assuming an unlocked session. They learn of a lock only from `com.apple.screenIsLocked` and `sessionDidResignActive`, and a launch on a locked Mac comes after both. The 19:58 relaunch therefore ran the unlocked path for the rest of the lock: its panel was ordered in, the presence poll ran, and the removal requests above went out on every pass.

`ScreenLockSignal.current()` now reads `CGSessionCopyCurrentDictionary()`: `CGSSessionScreenIsLocked` means locked, and `kCGSSessionOnConsoleKey` false means switched out. With no session dictionary, it keeps the old assumption (active, unlocked). Each component seeds its state from it at `start()`:

- The window controller seeds before the first panel exists, so no panel is ever ordered in.
- The media coordinator seeds only where it installs the observers that end the lock.
- Instant Replay seeds before its first refresh, so it can't start buffering the Lock Screen.

Unlock runs the transitions it always ran: the window controller's rebuild and layout, media's fresh source selection, `observeMedia`'s unlock animation and Instant Replay's restart.

Evidence:

- New test `screenLockStateAtLaunch` covers nil, unlocked, locked, a locked key set to false, and switched out.
- A probe using the same bridging read the live session on this locked Mac as present, locked and on console, so `sessionIsActive` is false.

Verified on this Mac by the 02:47 relaunch, which happened while the Mac was locked:

- At 02:47:01.432 it logged "Starting with the session locked" and showed no panel.
- No notification removals went out after the launch cleanup.
- At the 02:50:15 unlock it rebuilt the panel ("panels: 1") and picked a media source again.
- After two more lock/unlock cycles, the notch panel (window 4414, 720 × 480 at the top of the screen) is on screen.
- The OSD helper is suspended under a watchdog that this process started.

### Brightness poll while locked

`SystemLevelMonitor` reads `DisplayServicesGetBrightness` five times a second on the main thread, and it kept doing so on the Lock Screen. A reading reaches the notch only through `BrightnessKeyIntentGate`, which requires a recent brightness key, and key events don't reach the app's monitors while the Lock Screen is up. Brightness keys intercepted by the OSD replacement still take their own path (`adjustBrightness`), which doesn't use the timer.

The poll now pauses on `com.apple.screenIsLocked` or `sessionDidResignActive`, and on a launch while locked. On unlock it re-baselines and resumes, exactly as it already did around display sleep. The unlocked cadence is unchanged.

Cost removed while locked, from a probe making the same read-only call: two interleaved 21 s windows each.

| | Idle | 5 Hz poll |
|---|---:|---:|
| Wakeups | 0.0/s | 5.5–7.0/s |
| Instructions | 0.01 M/s | 1.15–1.20 M/s |
| Energy (in process) | 0.01 mJ/s | 0.49–0.78 mJ/s |

corebrightnessd's side of each call comes on top; it runs as root, so `rusage` couldn't read it. In the relaunched app, the timer was about a third of its ~15 wakeups a second.

### Locked ordering report

In the first process, AppKit took its full hide path on every locked pass: `_orderOut:calculatingKeyWithOptions:` → `_bestKeyWindowCandidateOnScreen` → a WindowServer query that waits on `SLSConnectionSynchronizeSLSCATransaction`, then a synchronous key-window proposal to the window manager. A probe on this locked Mac reproduces that cost only once: the first hide of a panel that was asked to become key costs 10.9–18.9 ms, and later hides cost 0.07 ms. A panel can't become key while the Mac is locked, so the probe can't check the remaining suspect: the panel was the key window when the lock began, and the hide never completes.

The locked branch now tallies its ordering passes and logs one line at unlock: the pass count, how many took 2 ms or more, the slowest pass, and how often a hidden panel was still visible afterwards. Cost: two clock reads and one `isVisible` per locked pass.

The new build's first three locks:

| Lock | Passes | 2 ms or more | Slowest | Hide failed |
|---|---:|---:|---:|---:|
| Launched locked, 02:47–02:50 | 9 | 0 | 0.3 ms | 0 |
| 02:52:46–02:53:48 | 30 | 2 | 9.7 ms | 0 |
| 02:56:39–02:56:43 | 3 | 1 | 2.3 ms | 0 |

So the wait is no longer on every locked pass. It shows up once or twice per lock at up to 9.7 ms, which matches the probe's first-hide cost, and no hide failed. The launch that began locked never had a key panel and never waited. That fits the key-at-lock explanation, but doesn't prove it. The old process's every-pass wait didn't recur, so there is nothing to fix for now.

### Waiting for a child process

The full test run for this pass stopped making progress at 20:39 and was still stuck five hours later. A sample showed one worker thread in `TerminalRunner.run`, inside `-[NSConcreteTask waitUntilExit]`, sleeping in its run loop. The child shell was gone, and so was its zombie, so Foundation had already reaped it.

A probe reproduces it (`2026-10-29-evidence/process-wait-probe.swift`). It runs eight Terminal-runner-shaped commands at once, killing each process group on timeout, with unrelated short `Process` launches in the background. Runs were interleaved by mode, and a wait still blocked after 8 s counts as hung:

| Wait | Runs | Never returned |
|---|---|---|
| `waitUntilExit()` (the old code) | 568 | 13 |
| `waitUntilExit()` on a global dispatch queue | 144 | 3 |
| `waitUntilExit()` with a termination handler set | 240 | 0 |
| poll `isRunning` with `Task.sleep` (the fix) | 384 | 0 |

Every hung wait had `isRunning == false`, and the child's pid no longer existed. One stuck wait was still blocked 30 s later. Another was still blocked when the probe was stopped after inspecting it in lldb. Its task state word read `0x100000000`: "running" cleared, "terminated" never set. Foundation's exit handler (`launchWithDictionary:` block 191) reaps the child and clears "running". If a termination handler exists, it sets "terminated" straight away. If not, it queues a block on the run loop of the thread that launched the process. `waitUntilExit()` on that thread wakes every 62.5 ms and keeps waiting until the block has run. On a dispatch or Swift concurrency worker, that block sometimes never runs.

`Process.waitForExit()` (async) and `blockUntilExit()` (synchronous callers) poll `isRunning` every 5 ms. Foundation's exit handler clears that flag itself. Reading `terminationStatus` afterwards worked in every polled run. Four call sites matched the hang's shape, launching and then waiting on a worker thread with no termination handler, and all four use the helpers now:

- `TerminalRunner.run`: both waits. This is the one that hung.
- `ArchiveExtractor.run`: runs inside `Task.detached`. A hang would leave "Extracting" up for good.
- The Bluetooth battery report reader: the 5 s timeout child can't end its task group while the reader is stuck, so a hung wait never returned and permanently held a concurrency thread.
- `resetScreenRecordingPermission`.

The relaunch helper in `main.swift` waits on the main thread, and the bench harness on its main thread, so they keep `waitUntilExit()`. The cost of the change is one atomic read per 5 ms during a wait that, outside a kill, lasts a few milliseconds after the output has already ended.

### OSD helper signature check

The 02:41 launch had two 0.45 s main-thread stalls before "launched". Both followed `SecTrustCopyAppleTrustAnchors` and ended in `SecKeyVerifySignature`. They came from `SystemOSDSuppressor.recoveryExecutableURL`, which runs `SecStaticCodeCheckValidity` with strict, all-architecture and nested-code flags on the app, then on the recovery helper. That hashes the whole bundle. The check is reached:

- from `setEnabled(true)` through `isCrashRecoveryAvailable`, then again from `armWatchdog`: twice per launch with the overlay replacement on;
- once per helper pause (the helper relaunching);
- from Settings → Notch's `body`, on every redraw, including every toggle on that page.

Its cost depends on load, because the nested-code checks run on worker threads while the main thread waits:

| Where | Two checks | One check |
|---|---:|---:|
| 02:41 launch, busy Mac | 0.92 s | |
| 02:47 launch | ≤ 80 ms | |
| 02:34 launch | no gap over 0.13 s | |
| Probe on `dist/NotchShot.app`, load average 13 | | 270–634 ms (median 377 ms, n = 6) |

The answer can only change when a file in the bundle does. `SignatureVerdictCache` now keeps the last verdict with a `BundleFileStamps` of the bundle: the path, inode, size, mode, modification time and change time of all 176 entries. Any difference, or a bundle that can't be read, runs the full check again. The change time catches an edit whose modification time was set back, since `utimes` can't set it. Listing and `lstat`-ing the bundle took 8–14 ms on a busy Mac (load average 13, and during a full test run), and 2.5–3.2 ms warm on a quieter one, and 24 of 24 stamps came back unchanged. Settings now reads the answer once when the page appears and keeps it in `@State`.

Preserved: the same flags, the Team ID comparison, a failed verdict (kept, so a broken helper still blocks suppression), the executable check on every call, and the error log. The verdict lasts only for the process, so every launch still runs one full check. Predicted saving: one check per launch (up to about 0.5 s on a busy Mac), every pause after the first, and all of the Settings redraw cost. The 02:47 build doesn't have this change, so the live launch saving is **not measured**. Moving the remaining check off the main thread would change when suppression starts relative to `setEnabled`, so it wasn't done.

Evidence: [osd-signature-probe.swift](2026-10-29-evidence/osd-signature-probe.swift) and [osd-signature.json](2026-10-29-evidence/osd-signature.json). `SignatureVerdictCacheTests` checks four things:

- One validation for an unchanged bundle.
- A failed verdict is kept.
- A same-size edit with the old modification time, an added file, a replaced file and a mode change each validate again.
- A missing bundle never caches.

### Launch timelines

From the unified log, exec (`xpcproxy`) to the WindowServer connection to the app's "launched" line:

| Launch | Four launches from the unified log, 1.03–3.04 s from exec to "launched". The worst one spent 0.92 s of main-thread time on the OSD signature check. **Fixed** for the second check of each launch (see OSD row). Startup cleanups scale with the store (181 history rows, 176 captures here). History load at 5,000 rows is 100 ms, already tuned and fuzz-tested. | Launch timings after a rebuild with the signature cache. A controlled warm-launch series needs the user's instance stopped: one GUI instance at a time, and a second would share sockets, hotkeys and the system-overlay lease. |
| OSD signature check | 270–634 ms per check in a probe on a busy Mac, ≤ 80 ms for two in a quiet launch. Reached twice per launch, per helper pause, and on every Settings → Notch redraw. **Fixed:** the verdict is kept until a bundle file's stamp changes (3–14 ms), and Settings reads it once per appearance. Tests cover hits, failed verdicts, four kinds of change and an unreadable bundle. | Live launch timeline after a rebuild. Moving the first check off main is a possible follow-up that changes start-up ordering. |
|---|---|---|---:|---:|---:|
| 19:58, pid 15379 | old | locked | 0.88 s | 0.48 s | 1.36 s |
| 02:34, pid 26921 | new, first run of the binary | unlocked | 1.02 s | 1.00 s | 2.02 s |
| 02:41, pid 77312 | new | unlocked, busy Mac | 0.14 s | 2.90 s | 3.04 s |
| 02:47, pid 80372 | new (`1b6d211`) | locked | 0.66 s | 0.37 s | 1.03 s |

The 02:41 launch's extra time is mostly the two signature checks (0.92 s). The unlocked launches also create the panel, set up notifications and order the window in. A locked launch does none of that until unlock. Four launches under different load can't separate the old and new code. **No launch-time claim.**

### Open and close memory

An offscreen harness ([open-close-memory-harness.swift](2026-10-29-evidence/open-close-memory-harness.swift)) hosts `NotchRootView` in a window that is never shown. One cycle opens and closes the island, then hovers in and out, and draws each state. It ran 20 warm-up cycles and then four blocks:

| Run | Live heap after warm-up | After each block |
|---|---:|---:|
| 4 × 100 cycles | 10.68 MB | 14.35, 12.95, 12.37, 12.20 MB |
| 4 × 10 cycles | 10.80 MB | 10.88, 11.74, 11.73, 10.88 MB |

There is no per-cycle growth: after 400 cycles the heap is 1.5 MB above warm-up and falling. A state change and its layout cost under 0.5 ms in debug. On-screen Core Animation, WindowServer and GPU memory aren't covered. Raw values: [open-close-memory.json](2026-10-29-evidence/open-close-memory.json).

The 227.6 MB peak in the old process happened before any footprint watch was running, so its cause is unknown. The new process peaked at 123.6 MB in its first 13 minutes. It released about 42 MB around a 4 s lock, from 83 MB to 40 MB, and stayed there after the unlock. That looks like transient memory given back rather than retained growth.

## Checks

- `swift test --filter "screenLockStateAtLaunch|screenLockSignalMapping|LockedMedia|LockScreen"` (debug): 18 tests / 3 suites passed, including the new session-dictionary test.
- `swift test --filter LockedMediaNotificationDeliveryTests` (debug): 11 tests passed. Control: `repeatedClearsRemoveOnce` fails with the new guard removed.
- `swift test --filter "AIActivity|AI activity|AgentUsage"` (debug): 15 tests / 3 suites passed, including the listing-equivalence test.
- `swift test --filter "ProcessExitTests|ProductivitySuiteTests|SystemUtilitiesTests|NotchMetricsTests|LockedMediaNotificationDeliveryTests|HistoryAndMediaTests"` (debug): 165 tests / 17 suites passed, including both Terminal runner tests and the new process-exit tests. Control: `ProcessExitTests` also passes 40 repetitions with `waitUntilExit()` restored, so the probe, not the tests, shows the race.
- Full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` (debug), with every change in this report: **1,277 tests / 209 suites passed** twice in a row (27 s and 24 s). The run before those had one failure: "An oversized answer is refused as it arrives" took 5.6 s against its 5 s bound under full-suite load, and it passes alone in 2.0 s. The run before that one is the five-hour Terminal runner hang described above. `PasteboardRaceTests` writes the system clipboard and was left unexecuted to protect user data. `idleClientsRecover` is a known flake under full-suite load.
- After the signature check change: `swift test --filter "SignatureVerdictCacheTests|SystemIntegrationSafety|ProcessExitTests"` passed 8 tests / 3 suites. A full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` passed **1,283 tests / 211 suites**. Debug build: no new warnings in the changed files.
- `swift build -c release` of every product, with every change in this report except the signature check: built in 406 s, with no warnings in the changed files.
- Release `NotchShotBench ai.activity` twice with instruction counters: every precondition held. The earlier full sweep completed every group.

## Coverage and leads

| Surface | Evidence / disposition | Next check |
|---|---|---|
| Background polling (AI Activity) | Two live samples, probes, interleaved release A/B on synthetic and real folders, instruction counts. **Retained.** | Live after-number once the user relaunches. |
| Notification Center removals | Live log rate, sample, usernoted `rusage`, fixture test with control. New build: 2 removal lines in 16 minutes, both at launch. **Retained, confirmed live.** | — |
| Lock Screen log line | Live log rates. New build: 4 lines in 16 minutes over three locks (was 2,422 in 10 minutes). **Retained, confirmed live.** | — |
| `orderOut` wait while locked | First process: ~11–13 ms on every locked refresh, through AppKit's full key-window hide path. New build's ordering report over three locks: 0, 2 and 1 passes of 2 ms or more, slowest 9.7 ms, no failed hides. A probe reproduces that size only for the first hide of a panel that asked for key. **Not recurring, so no fix:** the every-pass wait is gone in this build, cause still unproven. The ordering report stays. | A lock whose ordering line shows most passes slow would bring the key-at-lock case back. |
| Launch while locked | Window controller, media, Instant Replay and brightness poll started as unlocked; the 19:58 relaunch ran the unlocked path while locked. **Fixed:** seeded from `CGSessionCopyCurrentDictionary`, with a parser test. **Verified on the Mac:** the 02:47 relaunch began locked, showed nothing, and brought the panel back at unlock. | — |
| Brightness poll | A 5 Hz `DisplayServicesGetBrightness` XPC on the main thread, which kept running while locked even though no locked reading can reach the screen. **Fixed:** it pauses while locked and re-baselines on unlock, as around display sleep. Probe: 5.5–7 wakeups/s and 0.5–0.8 mJ/s removed while locked. | Wakeups of the live app during a long lock (not sampled: the new build's locks were 1–3 minutes, while other work ran). |
| Island refresh fan-out | Each Claude hook event refreshes the island twice, about 15 ms apart: once from `context.onSnapshotChange`, once from `observeIslandSources` → `scheduleIslandRefresh`. About 1 ms CPU per refresh while locked, and 5 of 314 busy samples in the second profile. **Not changed:** the unlocked cost (SwiftUI) isn't measurable with the screen locked, and refresh ordering is delicate. | Count refreshes per hook and measure CPU with the notch visible. A generation check taken in the observation's `onChange` could skip the redundant pass. |
| Crewline unpaired retry | Keychain miss every 5 s on main. A warm miss costs 0.18 ms. **Rejected** as negligible. | — |
| Network | No sockets or traffic in the relaunched app (`lsof`, `nettop`). Lyrics are opt-in and cached (40 entries), with in-flight de-duplication and 8 s / 12 s timeouts. Sparkle runs only in configured release builds. Reachability uses `NWPathMonitor`, which is event-driven. **No change.** | Traffic while lyrics are on and tracks change. |
| Memory | Locked: 30.5–31.3 MB for 25 minutes (old build). Unlocked: 97.2 MB, flat for 3 minutes, peak 227.6 MB (old); 83 MB, then 39–41 MB after a lock, peak 123.6 MB (new). `heap`: 38.2 MB live in the old process; about 36 MB was freed memory not yet returned. Offscreen open/close harness: no per-cycle growth over 400 cycles. **No change:** no growth reproduced. | The cause of a 120–230 MB peak: run a footprint watch with a `heap` capture at the threshold. On-screen open/close with Core Animation. |
| Launch | One launch observed, at 19:58, of a freshly built and signed binary: exec → WindowServer connection 0.85 s → notch panel 1.13 s → retention cleanups done 1.25 s. The logs don't account for the 0.85 s before AppKit; a first launch of a new 55 MB binary pays cold page-in and signature checks. Startup cleanups scale with the store (181 history rows, 176 captures here). History load at 5,000 rows is 100 ms, already tuned and fuzz-tested. **No change.** | Repeated warm launches. Blocked here: one GUI instance at a time, and a second instance would share sockets, hotkeys and the system-overlay lease. |
| Opening/scrolling History, capture, clipboard, island engine | Full release sweep: search cache hit ~0, cold search 3–5 ms at 5,000 rows, record 6.9 ms, save 29 ms (off main), PNG encode 33 ms (detached), island sync/present ≤ 10 µs. **No change.** | On-screen scrolling and hitch traces (needs Instruments or a driven UI; not run). |
| Rendering loops | Every SwiftUI `repeatForever` and `TimelineView(.animation)` loop in the notch is now a layer. Only 1 Hz countdowns and a 6 Hz Productivity view remain. **No change.** | — |
| Unlocked steady state, size | Old build: 3.6% of a core, 32–46 M instructions/s, 5.6–7.5 mJ/s, 12–37 wakeups/s. New build: 1.5% (60 s), 18–80 M instructions/s, 2.2–13 mJ/s, 30–37 wakeups/s. The ranges overlap: **equivalent within noise.** About 1% of the main thread is NotchShot code. The notification mirror's 0.45 s Accessibility scan is the largest piece, about 3 ms/s on its queue. It also has an `AXObserver`, so the scan might become event-driven, but that changes a polling policy and needs a product decision. **No change.** | Agent-active numbers with AI Activity on. |
| Waiting for child processes | A five-hour hang in a full test run, sampled; probe with interleaved modes (13 of 568 old waits never returned, 0 of 384 polled); Foundation's exit path read from disassembly and a hung task's state word. **Fixed** at the four worker-thread sites; helper tests. The tests pass against the old wait too, so the probe is the evidence. | Whether the hang has shown up in the app: an "Extracting" spinner or a Terminal command that never finished. |

## Reproduction

```sh
swift build -c release --product NotchShotBench
NOTCHSHOT_BENCH_AI_DIRECTORY="$HOME/Library/Application Support/NotchShot/AI Activity" \
  .build/release/NotchShotBench ai.activity
```

`NOTCHSHOT_BENCH_AI_DIRECTORY` is optional. With it, the real folder is only listed and read: `loadActivities()` never writes, and the benchmark keeps its history file in its own run folder. The run prints timings and instructions per call; `NOTCHSHOT_BENCH_RESULTS=<file>` keeps both as JSON Lines.

The process-wait probe builds on its own. From the repository root:

```sh
cd "$(mktemp -d)"
swiftc -O -swift-version 5 "$OLDPWD/Documentation/Performance/2026-10-29-evidence/process-wait-probe.swift" -o process-wait-probe
./process-wait-probe 6 wait   # then poll, handler, queue; interleave the modes
swiftc -O "$OLDPWD/Documentation/Performance/2026-10-29-evidence/osd-signature-probe.swift" -o osd-signature-probe
./osd-signature-probe "$OLDPWD/dist/NotchShot.app" 6   # reads the bundle only
```
