# NotchShot performance pass — 29 October 2026

The once-a-second AI Activity poll now takes **7.2 → 1.4 ms on the real 2,160-file folder (81% less)** and retires **145 → 27 M instructions per poll**. It is cheaper at every folder size, including tiny ones. In both live profiles it was the largest single cost, about two-thirds of the app's CPU on a locked Mac with music playing and agents at work.

Also fixed:

- A Lock Screen log line that was written about four times a second is now written only when its values change.
- Unlocked layout passes no longer send two Notification Center removal requests each when there is nothing to remove.
- A launch on a locked Mac now starts locked. Before, the notch, media, Instant Replay and the notification mirror all ran as unlocked until the next lock.
- The 5 Hz brightness poll pauses while the session is locked, as it already did while displays sleep. While locked its readings could never reach the screen. In a probe, that poll cost 5.5–7 wakeups and 0.5–0.8 mJ a second.
- The OSD replacement's strict signature check runs once per launch, off the main thread, and again only when the app bundle has changed on disk. It hashes the whole 59 MB bundle and ran on the main thread twice per launch, once per helper pause, and on every redraw of Settings → Notch. One launch spent 0.92 s of main-thread time on the two checks. A check of the bundle's file stamps, 3–14 ms, now decides whether the last answer still holds. In a matched series of locked, warm launches (five old, four new, alternated), process start to "launched" went from 0.25–0.43 s (median 0.39) to 0.25–0.26 s (median 0.26). The old check held three of the five launches for another 140–150 ms.
- Waiting for a child process could hang forever. `Process.waitUntilExit()` on a worker thread never returned in 13 of 568 probe runs, after the child had already exited. A full test run sat in the Terminal runner for five hours this way. The Terminal runner, archive extraction, the Bluetooth battery report and the Screen Recording reset now poll `isRunning` instead, and none of 384 probe runs hung.
- History rows decode their thumbnails at the size they are drawn and keep them for the window. Scrolling the 179-capture History list end to end used to add 51 MB to the heap, and about 33 MB of it stayed after the window closed. Now a pass adds 11–13 MB, all of it freed on close, and the process retires 23–25% fewer instructions.
- The Apple Events media poll asks for Spotify and Music by bundle identifier instead of reading the identifier of every running app every 2 s, which went to LaunchServices for most of them. In a probe at the poll's cadence that's 10.15 → 0.13 M instructions and 4.76 → 0.43 ms of main-thread time per poll. It was 31 of 38 busy main-thread samples in a locked sample of the live app.
- Unlocking with Spotify playing no longer downloads the cover again. Each unlock, wake and player re-selection builds a new media source, and the 8-cover cache belonged to the source, so every one of the four unlocks of the 02:47 process fetched the same cover over a new TLS connection, and the notch's first media update after unlock waited for it. The cache now belongs to the process, so an unchanged track costs no request.
- The test suite no longer leaves a preferences file in `~/Library/Preferences` for each test that makes its own defaults: 20–28 a run, and 11,809 had built up since July. Those 11,809 are now in the Trash.
- An agent's progress percentage no longer rolls its digits. Each change kept the main thread rendering for 750 ms and 11.9–12.1 G instructions offscreen; it now costs 26–30 M and one 50 ms slice, like any other agent update.
- While the Mac is locked and the Lock Screen shows no notch, the Spotify and Music poll runs every 10 s instead of every 2 s. It was about two-thirds of what a locked app did. With the Lock Screen song card on, as it is on this Mac now, the poll stays at 2 s. Confirmed live with both opt-ins turned off for single launches only: polls 10.2 s apart, and the locked app at 6.1–6.2 M instructions a second, against 10.3–10.4 M with the card on.
- AI Activity status files are pruned: a file outside the 32 newest is removed once it is 8 days old, and an abandoned temporary file after an hour. On a copy of this Mac's folder, pruning took it from 2,163 entries to 337, and each poll from 28.8 to 10.2 M instructions (1.25 to 0.43 ms) with the same activities read. Live, with AI Activity on for single launches (the saved setting stayed off, and the removed files were put back): 2,165 → 326 files, and the app at 23.7–26.3 M instructions a second, against 41.4–59.8 M with the full folder.
- Each Spotify or Music poll sends 7 Apple Events instead of 10. It asked the player state twice, and it built its field separator with `ASCII character`, a scripting addition that went to Spotify, was refused, and was sent again to NotchShot. Counted live while locked: 127 → 94 ms from a poll's first event to its last reply (medians of 52 and 30 polls). In the matched series, every old poll sent 10 events and every new one 7, and the app went from 6.2–6.7 to 5.6–5.9 M instructions a second.
- A Claude hook refreshes the island once, not twice: 15.6–16.3 → 9.2–9.7 M main-thread instructions per hook (offscreen, debug, three alternating runs each of old and new). A live profile of 16 hooks found no second pass.
- A full test run leaves 0.1 MB in the temporary folder instead of about 80 MB. The 1,701 fixture folders already there (5.1 GB) were removed. So were 26 GB of kernel-trace files that this pass's own Instruments recordings had left in the same folder, which had filled the disk.

This pass profiled the live app twice with the screen locked and once unlocked with the user at the Mac, all on code from before these changes. Another session then rebuilt `dist/` from `1b6d211` (every change here except the signature check) and relaunched it at 02:47 with the Mac locked. That gave the after-numbers below, including a real lock → launch → unlock. A 03:35 relaunch from a build with the signature check showed one full check per launch instead of two. A 12:52 relaunch from `8507f95`, with every change here, took the locked app with Spotify playing from 9.7–10.6 to 5.1–5.2 M instructions a second and from 0.8–1.1 to 0.4 mJ/s. A 15:53 relaunch with the afternoon follow-up ran the launch's signature check off the main thread. A 22:56 relaunch from `f966908` took each Spotify poll from 10 Apple Events to 7. On 31 October, old and new builds were alternated through four launch pairs while the Mac was locked (see Matched series). Apart from that series, none of this establishes a whole-app speedup or a battery-life gain: the before and after profiles ran under different load and use.

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

Locked, the same process, from 03:03:33. Two full 60 s windows before the unlock at 03:09:48:

| Metric | New build, locked | Old build, locked (second profile) |
|---|---:|---:|
| CPU | 0.52–0.56% of one core | 3.1–4.4% |
| Instructions | 10.4–10.6 M/s | 224–225 M/s |
| Energy | 1.0–1.1 mJ/s | 13.5–20.8 mJ/s |
| Wakeups | 3.0/s | 14.1–14.6/s |
| Physical footprint | 39.8 MB | 30.5–30.7 MB |

This is not a clean before and after. AI Activity was on in the old profile, where it took about 77% of busy main-thread samples, and the user has turned it off since. So this pair can't split the drop between AI Activity and the other locked fixes (the brightness pause, removals and the log line). Wakeups fell from about 14 to 3 a second; the brightness timer alone was about 5 of them.

Projected over an eight-hour lock, not measured: 1.0–1.1 mJ/s is about 30 J, or 0.008 Wh, against 390–600 J (0.11–0.17 Wh) for the old build. `ri_energy_nj` is the kernel's estimate for the process, not the battery's drain, and the longest locked stretch sampled was six minutes.

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

At one poll a second on the live folder, that comes to about 6 ms less main-thread time and about 117 M fewer instructions each second. That is roughly half of what the relaunched app retired. This is a prediction from bench numbers, not a live measurement. The cost still grows with file count (about 0.6 µs per file); status files are now pruned after 8 days (see the afternoon follow-up).

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

Preserved: the same flags, the Team ID comparison, a failed verdict (kept, so a broken helper still blocks suppression), the executable check on every call, and the error log. The verdict lasts only for the process, so every launch still runs one full check.

What a launch asks for, timed on `dist/NotchShot.app` with the old and new sequences alternating in one process (8 rounds each, load average 3.9–4.3):

| Sequence | Median | Range |
|---|---:|---:|
| Old: two full checks | 538 ms | 522–814 ms |
| New: stamp + full check, then stamp | 274 ms | 267–417 ms |

That's 49% less signature time on the launch path, with one full check per launch in every new round. Every pause after the first and every Settings redraw save a whole check as well. The 03:35 relaunch, the first from a build with this change, ran one check instead of two (next section). Moving the remaining check off the main thread would change when suppression starts relative to `setEnabled`, so it wasn't done.

Evidence: [osd-signature-probe.swift](2026-10-29-evidence/osd-signature-probe.swift), [osd-signature.json](2026-10-29-evidence/osd-signature.json) and [osd-signature-launch.json](2026-10-29-evidence/osd-signature-launch.json). `SignatureVerdictCacheTests` checks four things:

- One validation for an unchanged bundle.
- A failed verdict is kept.
- A same-size edit with the old modification time, an added file, a replaced file and a mode change each validate again.
- A missing bundle never caches.

### Launch timelines

From the unified log, exec (`xpcproxy`) to the WindowServer connection to the app's "launched" line:

| Launch | Build | Session | Exec → WindowServer | → "launched" | Total |
|---|---|---|---:|---:|---:|
| 19:58, pid 15379 | old | locked | 0.88 s | 0.48 s | 1.36 s |
| 02:34, pid 26921 | new, first run of the binary | unlocked | 1.02 s | 1.00 s | 2.02 s |
| 02:41, pid 77312 | new | unlocked, busy Mac | 0.14 s | 2.90 s | 3.04 s |
| 02:47, pid 80372 | new (`1b6d211`) | locked | 0.66 s | 0.37 s | 1.03 s |
| 03:19, pid 11180 | `1b6d211`-era, first run of the binary | unlocked | 2.26 s | 0.93 s | 3.18 s |
| 03:35, pid 35435 | with `57e3eb1`, first run of the binary | locked | 1.81 s | 1.77 s | 3.58 s |

The 02:41 launch's extra time is mostly the two signature checks (0.92 s). The unlocked launches also create the panel, set up notifications and order the window in. A locked launch does none of that until unlock. The first run of a freshly linked binary pays a cold page-in before AppKit starts (1.02, 2.26 and 1.81 s). Six launches under different load can't separate the old and new code. **No whole-launch claim.**

The 03:19 relaunch (by another session) came from a build without `57e3eb1`: its binary has no `SignatureVerdictCache` or `BundleFileStamps` type names, though it has `ScreenLockSignal` and `LockedOrderingTally`. Its log shows the same two bursts of nested-code verification as the older launches (37–39 `SecKeyVerifySignature` events each), taking 0.22 s in all.

The 03:35 relaunch (also by another session) came from a build with `57e3eb1`, nine seconds after it was linked. Its log has 23 verify events against 39: the same lone event at start-up, one burst of 17 for the first check (46.273–46.424), and the same four after "launched". The second burst is gone. On the 03:19 launch that second check took about 0.1 s (29.28–29.39), so that is the size of the live saving on a launch like that one; on the 02:41 launch it was about 0.45 s. The whole launch can't show it: this one was the first run of a new binary, on a Mac at load average around 90, and took 3.58 s.

### Open and close memory

An offscreen harness ([open-close-memory-harness.swift](2026-10-29-evidence/open-close-memory-harness.swift)) hosts `NotchRootView` in a window that is never shown. One cycle opens and closes the island, then hovers in and out, and draws each state. It ran 20 warm-up cycles and then four blocks:

| Run | Live heap after warm-up | After each block |
|---|---:|---:|
| 4 × 100 cycles | 10.68 MB | 14.35, 12.95, 12.37, 12.20 MB |
| 4 × 10 cycles | 10.80 MB | 10.88, 11.74, 11.73, 10.88 MB |

There is no per-cycle growth: after 400 cycles the heap is 1.5 MB above warm-up and falling. A state change and its layout cost under 0.5 ms in debug. On-screen Core Animation, WindowServer and GPU memory aren't covered. Raw values: [open-close-memory.json](2026-10-29-evidence/open-close-memory.json).

### Footprint peaks

A one-second footprint watch on the live app (pid 80372) from 03:08 to 03:11 caught the spikes behind the peaks. At the 03:09:48 unlock the footprint went from 39.8 to 86.4 MB, with 729 M instructions in that second, and was back at 42.6 MB three seconds later. It did the same four more times in the next 90 s, while the user was at the Mac: 78–81 MB for 2–4 s, with 245–363 M instructions each.

A `footprint` breakdown taken during the first spike puts it in graphics memory, not the heap:

| Category | During the spike | Idle |
|---|---:|---:|
| Owned physical footprint (unmapped) (graphics) | 38 MB | 0.9 MB |
| IOAccelerator (graphics) | 6.5 MB | 1.8 MB |
| IOSurface | 2.8 MB | 0.2 MB |
| `MALLOC_SMALL` | 24 MB | 24 MB |

That is Metal and Core Animation render memory for the panel, which the renderer frees within seconds. It fits the island's glass and unlock animations, and none of it is retained. So the new process's 124 MB peak is most likely a stack of these transients, not a leak. The old 228 MB peak can't be traced after the fact. One way to reach it on the old code was a History window scrolled end to end, which added 51 MB (next section). Shrinking the transients would mean changing how the glass is rendered, which is a design decision. **No change.**

### History thumbnails and scrolling

A harness ([scroll-harness.swift](2026-10-29-evidence/scroll-harness.swift)) hosts the real `HistoryView` and `ClipboardView` over the app's own stores, read only: 179 History rows with their stored thumbnails, and 49 clipboard rows. Each list sits in an offscreen window and scrolls end to end, 40 pt or 120 pt per 8.33 ms frame. Every frame is laid out, displayed and flushed, and the run loop gets the rest of the frame so thumbnail loads land. Each window is closed and checked freed before the next opens. Debug build, one process per run.

Each row decoded its stored thumbnail at full size: up to 512 px, about 0.6 MB decoded, for a 52 × 36 pt frame. A `List` row that scrolls out of view loses its `@State`, so a row that comes back decodes again. One History pass grew the live heap by 51 MB. About 33 MB of that stayed live after the window was freed, and four windows in one process left 107 MB.

The first fix decoded straight to the drawn size with ImageIO's thumbnail call. The heap growth fell to 11–12 MB, but the process retired 31% more instructions, because that decode costs more per file than a full one and recycled rows paid it again. That moved the cost to the CPU, so it was not kept on its own. Decode cost per stored thumbnail, `swiftc -O`, 4 interleaved rounds ([thumbnail-decode-bench.swift](2026-10-29-evidence/thumbnail-decode-bench.swift)):

| Decode | Instructions | Time | All 179 decoded |
|---|---:|---:|---:|
| Full size (before) | 9.44–9.53 M | 0.88–1.05 ms | 107.7 MB |
| ImageIO thumbnail | 16.39–16.41 M | 1.15–1.25 ms | 7.17 MB |
| Full decode, then draw smaller | 21.04–22.78 M | 1.83–2.12 ms | 7.12 MB |

Kept: the ImageIO thumbnail, plus a cache for the window. `HistoryThumbnailCache` holds each decoded row image under the file's path, inode, size, modification time and change time, so a thumbnail rewritten in place is decoded again. It is capped at 16 MB, about 400 rows, and `NSCache` also gives way under memory pressure. It belongs to the History window and goes with it. Before and after, alternating in time, three rounds each plus one more run of the committed source:

| Per History pass | Before | Kept change |
|---|---:|---:|
| Live heap growth | +50.8–51.1 MB | +10.7–12.1 MB |
| Live heap after the window was freed, against before it opened | +32.9–34.4 MB | −5.6 to −6.0 MB |
| Live heap after all four windows | 106.8–107.1 MB | 25.7 MB |
| Process instructions, 40 pt frames | 11.93–12.15 G | 9.20–9.32 G (−23%) |
| Process instructions, 120 pt frames | 10.99–11.32 G | 8.21–8.54 G (−24 to −26%) |
| Main-thread instructions, 40 pt frames | 7.08–7.25 G | 7.01–7.12 G |
| Main-thread instructions, 120 pt frames | 6.12–6.38 G | 6.08–6.34 G |

The main thread does the same work: decoding already ran off it, and its time goes to laying out rows. Frame times followed machine load, which ran from about 4 to 90 across rounds. In the quiet round they were equivalent: median 2.86 against 2.96 ms and no frame over 8.3 ms at 40 pt; median 4.59 against 4.42 ms and 0 against 1 of 180 frames over 8.3 ms at 120 pt. The clipboard list grew 1.0–1.4 MB per pass either way, and all of it went with the window (see the coverage table). **Retained** for memory and CPU, not for frame time.

Every one of the 179 stored thumbnails decodes to a size that still covers the row's 104 × 72 pixels at 2x after its aspect fill, and never to more than the original ([thumbnail-decode.json](2026-10-29-evidence/thumbnail-decode.json)). An image smaller than the row stays at full size. The pixels come from ImageIO's downsample rather than Core Animation's scaling at draw time; the two were not compared on screen. `HistoryThumbnailCacheTests` covers the size rule over eight shapes, the decoded size of a 512 × 346 PNG, one decode for two reads, a decode again after a same-size rewrite with the old modification time, and a removed file. Raw runs: [scroll-history.json](2026-10-29-evidence/scroll-history.json).

This harness has no WindowServer, GPU or display link, so it can't show on-screen hitches.

### Test preference files

Each test that made its own `UserDefaults` suite left a plist in `~/Library/Preferences`, 20–28 a run. 11,809 had built up since 25 July: 46 MB on disk, 92% of the 12,827 files in that folder. Removing the domain doesn't stop it. A probe tried three cleanups before exit, each ending with a sync and deleting the file: removing the domain, removing each key, and removing the domain then waiting a second. In all three, cfprefsd wrote an empty plist again 5–10 s after the process exited. A first fix that deleted the files at exit was undone the same way: a count right after a full run showed none, but 20 had appeared 7 s later.

`TestDefaults` now names each suite by an absolute path inside a temporary folder for the test process, and removes the folder when the process exits. A suite named that way keeps its plist at that path. In a probe it read, wrote, registered defaults and removed its domain like a named suite. Nothing appeared in `~/Library/Preferences`, and the folder was still gone 15 s after exit. A full run then left **0** new files 20 s after it ended, against 20 for the first fix. The 11,809 files already there were moved to the Trash on 30 October (see the afternoon follow-up).

### A long lock on the current build

The 03:35 process (with `57e3eb1`) launched into a lock that began at 03:34:59 and was still running at 04:13. Three 120 s windows, 34–40 minutes in, load average 1.4–2.1:

| Metric | Each window |
|---|---:|
| CPU | 0.55–0.57% of one core |
| Instructions | 10.2–10.5 M/s |
| Energy | 0.8 mJ/s |
| Wakeups | 2.9/s |
| Disk writes | 0 |
| Physical footprint | 28.8 MB |

Over its first 39.5 minutes, all of them locked and including the launch, the process used 15.8 s of CPU, 3.80 J, 7,081 wakeups and 68 KB of disk writes. Its footprint peaked at 62.1 MB. The OSD helper recorded 0.00% CPU and no wakeups. The rates are flat across the three windows, so the six-minute profile above held for the longer lock.

### Media player lookup

A 10 s sample from that lock had 38 busy main-thread samples. 31 of them were the Apple Events media poll, which runs every 2 s and is following Spotify here. `runningPlayer()` read `bundleIdentifier` from every one of the ~99 running apps to see whether Spotify or Music was among them. Most of those reads went to LaunchServices over XPC, on every poll. The clipboard poll's frontmost-app lookup was 4 more samples; at about 0.3 ms/s it was left alone.

`runningPlayer()` and the media fallback retry now ask for the two players by bundle identifier. A probe alternated the two lookups every 2 s for 16 rounds, matching the poll's cadence ([player-lookup-probe.swift](2026-10-29-evidence/player-lookup-probe.swift)):

| Lookup | Instructions | Main-thread time |
|---|---:|---:|
| Every running app's identifier (before) | 10.15 M (10.09–10.33) | 4.76 ms (2.00–7.51) |
| The two players by identifier | 0.13 M (0.13–0.24) | 0.43 ms (0.20–0.69) |

Both found the same players in every round. At one poll per 2 s that is about 5 M fewer instructions and 2 ms less main-thread time a second, locked or unlocked, whenever the Apple Events source is active. That is about half of the 10.3 M instructions a second the locked app retires. That was a prediction from the probe. Measured live after the rebuild below, with the Mac locked and Spotify playing in both runs, the app retires 5.1–5.2 M instructions a second against 9.7–10.6 M before: the predicted 5 M. The order players are tried in, the playing-first preference and the scripts are unchanged. A test checks that `isRunning` agrees with the app list for the apps actually running.

### Unlock

The 03:09:48 unlock (pid 80372) didn't rebuild the panel from scratch: no "Rebuilt notch panels" line, since nothing was attached to the Lock Screen. It ordered the existing panel in, and 0.35 s later `scheduleRebuild` reassigned the hosting view's `rootView`. In an offscreen harness ([root-reassign-harness.swift](2026-10-29-evidence/root-reassign-harness.swift), debug), that reassignment costs 0.38–0.42 M instructions (0.31–0.33 ms), against 0.05–0.07 M for a render with no change. A whole new hosting view with its first render costs 24–25 M. Neither explains the 729 M instructions of that second. Media re-selection runs at unlock too, along with its first Apple Events round trip and artwork, and so does the first on-screen frame of the glass. The sample that would split them has to be taken at a real unlock. A passive sampler was left waiting for one and didn't catch one in this pass.

The log of that process does show one piece of the media re-selection. About 0.8 s after each of its four unlocks, including one after a 4-second lock, the app opened a new HTTPS connection to Spotify's image CDN and downloaded the cover of the track that was already showing. At 02:50 and 02:53 it did so 2–3 times within 7 s, once per re-selection. `MediaCoordinator.selectSource` builds a new `AppleEventsMediaSource` for every selection, and the artwork cache was an instance property, so each new source started empty. The source's first snapshot waits for `artwork(for:)` before it is sent, so the notch's first media update after unlock waited on a TLS handshake and a download (about 150 ms here, up to the 12 s timeout on a bad network). For Music the same miss is a `raw data of artwork` Apple Event instead of a request.

The cache now belongs to the process: `AppleEventsArtworkCache`, the same 8 covers keyed by artist and title, behind a lock. Only one source exists at a time, so the most it keeps is what one source kept before. An unchanged track after an unlock or re-selection now costs no request and no wait. A new track still fetches its cover once, with the same size and format checks. A test covers eviction and repeated inserts. Not measured live: the running copy is still the old build. **Fixed.**

### Agents with AI Activity on

AI Activity is off on this Mac, so its cost was measured apart from the live app, without opening its socket or touching its folder:

- The 1 Hz folder poll: 1.37–1.47 ms and 27 M instructions a poll on the real folder (the bench above). The folder now holds 2,144 files, and hooks still write to it with AI Activity off.
- Each agent update into a real island, offscreen and debug, with three working agents ([agent-update-harness.swift](2026-10-29-evidence/agent-update-harness.swift)): 7.9–9.8 M main-thread instructions in the 50 ms after the update. Then the island is back to its quiet 0.17–0.20 M per 50 ms. That holds in compact and expanded form, and an update that moves only the timestamp costs the same as one with new text. The timestamp is visible as the expanded list's "updated" time, so skipping those updates would change what is shown.
- An update that changes a reported percentage, in compact form only, keeps the main thread rendering for 150–750 ms. The compact island shows the percentage as rolling digits (`IslandNumericText`, `.numericText()`). Offscreen that renders on the CPU, which overstates the on-screen cost. The code's own note on `IslandClockText` measured the same transition on screen at about 45% of a core for a clock that changed every second. Claude sessions report no percentage, so the user's agents show "Working" instead. A reporter that sent progress every second would keep the island rendering. **Fixed** in the afternoon follow-up: the user chose plain digits.

At, say, two hook events a second, the island part is about 16–20 M instructions a second in debug, before release optimisation. The folder poll is about 27 M a second, and it grows with the folder until status files are pruned.

### Live after the rebuild

At the user's go-ahead, `dist/` was rebuilt from `8507f95` (every change in this report) with `Scripts/build_app.sh --release`. It was signed with the same Apple Development identity, and the designated requirement is unchanged, so permissions carry over. It was relaunched at 12:52:34 on 30 October. The Mac had locked again by then, and the log's first line was "Starting with the session locked". Readings are `proc_pid_rusage` over 60 s windows ([followup-2026-10-30.json](2026-10-29-evidence/followup-2026-10-30.json)):

| Locked, Spotify playing | Instructions/s | CPU | Wakeups/s | Energy | Footprint |
|---|---:|---:|---:|---:|---:|
| Old build (pid 35435), 04:45 and the 40-min lock | 9.7–10.6 M | 0.52–0.56% | 2.9–3.0 | 0.8–1.1 mJ/s | 28.8–30.1 MB |
| New build (pid 65032), three windows from 12:53 | 5.1–5.2 M | 0.36–0.39% | 3.0 | 0.4 mJ/s | 27.1–27.2 MB |

A 10 s `sample` of the new build has 13 busy main-thread samples out of 7,691, against 38 in the old build's, 31 of which were the player lookup. The poll still runs every 2 s on its script thread. Wakeups are unchanged, which fits: the lookup cost instructions on a wakeup the poll already makes.

The old build's last unlock, at 12:35:21 after about eight hours locked, was caught by a passive watcher. In a 3 s `sample` starting 0.28 s after the unlock, the main thread was idle in 2,586 of 2,599 samples: the 729 M burst of the 03:09 unlock didn't recur after the first 0.3 s. That process downloaded the cover again 0.85 s after unlocking (a new connection with the artwork session's 8 s / 12 s timeouts), which makes 5 of 5 unlocks seen. Over the next 3 minutes unlocked, with the user replying in this session, it averaged 21.3 M instructions a second (median 17.4 M), 0.89% of a core, 16 wakeups a second and 2.6 mJ/s. The Animation Hitches trace recorded with it never finished saving (`xctrace` stuck in a semaphore wait for 15 minutes), so it was abandoned.

The new build's first unlock came at 13:51:50, and a watcher armed on it caught it ([followup-2026-10-30.json](2026-10-29-evidence/followup-2026-10-30.json)):

- **Cover:** no network task at all in the 20 s after the unlock, against a fresh download at every one of the old build's five. The artwork fix holds live.
- **The burst is still there, and it isn't the cover.** 597 M instructions in the first second (21% of a core, 91 wakeups), 294 M in the next, 47 M in the third, then 3–14 M. The footprint went from 31 to 78 MB and back to 35 MB within 3 s. A `sample` that attached 0.95 s after the unlock found the main thread busy in only 46 of 2,563 samples, so the cost sits in the first second: the panel ordered back in, the "Unlocked" padlock (shown 350 ms after unlock, its symbol replaced 260 ms later), and the media source re-selected.
- **The lock costs as much without a padlock.** The lock at 13:54:00 took 439 M instructions in a second, and the footprint reached 73 MB, though nothing is shown in the notch at lock. So most of the transition cost is the app's reaction to the session change itself. Earlier island openings while in use cost 245–363 M with the same 40-odd MB of graphics memory. A rolling Time Profiler is now attached to catch the next unlock and lock from before they start.
- **Unlocked, 13:51:54–13:53:59 (124 s):** 11.1 M instructions a second on average (median 9.6 M), 0.71% of a core, 13.5 wakeups a second, 1.14 mJ/s, against 21.3 M (median 17.4 M), 0.89%, 16.0 and 2.64 mJ/s for the old build at 12:35. The use differed between the two, so only the 5 M of the lookup fix is attributable.
- **Hitches:** a 30.9 s Animation Hitches trace from 8 s after the unlock saved cleanly. It has 0 hitches, 0 potential hangs and 0 frame updates from NotchShot. The notch wasn't used in that window, so this shows that nothing animates while it sits idle, not how an open or a scroll performs.
- **Memory:** a 30-minute footprint watch from the unlock never passed 120 MB. The process's lifetime peak is 79 MB.
- **Lifetime of the new process,** 98 minutes from launch, almost all locked: 37.6 G instructions (6.4 M a second), 23.5 s of CPU (0.40%), 4.55 J (0.77 mJ/s), 3.2 wakeups a second, 144 KB written. The old process over its first 39.5 minutes, all locked: 14.3 M a second, 0.67%, 1.6 mJ/s.

While locked, the script thread running the Spotify queries is now about two-thirds of the app's CPU: 57 of 86 ms in a 20 s profile. Polling less while locked, when nothing on screen shows the result, would change a freshness policy and is a product decision. The user chose to slow it; see below.

## Afternoon follow-up, 30 October

The user asked for every open item to be fixed: rolling agent percentages and status-file retention were decided as plain digits and pruning, and polling less while locked was approved. Everything below is in the working tree after `4a2a75b`, which was built into `dist/` and relaunched at 15:53:06 with the Mac locked. Readings are in [followup-2026-10-30.json](2026-10-29-evidence/followup-2026-10-30.json) under `afternoon_followup` and `agent_updates.progress_changes_after_plain_text`.

### Agent percentages

The compact island's progress percentage for agents, transfers and external activities, and the expanded island's progress percent, now use `IslandClockText` (plain digits, as running clocks already do) instead of `IslandNumericText`. The HUD's level percentage keeps the rolling digits: it changes only while a key is held. The same harness, rerun at load average about 40:

| Compact, new progress | Instructions in the 2 s after one update | Busy slices |
|---|---:|---:|
| Before, rounds 2–3 | 11,869–12,122 M | 15 (750 ms) |
| After, rounds 2–3 | 26.2–29.9 M | 1 (50 ms) |
| Before, round 1 | 1,742 M | 3 |
| After, round 1 | 436 M | 3 |

The control rows in the same run (timestamp-only and new-tool-text updates) went from 13.4–18.3 to 22.3–25.3 M under the heavier load, so the harness ran about 1.7 times slower across the board, not 400 times faster. The expanded form was already cheap and stays so (23.6–24.6 M). Offscreen rendering is on the CPU, so this overstates the on-screen saving. The user's Claude sessions report no percentage, so nothing visible changes for them.

### Locked media poll

`AppleEventsMediaSource` now polls every 10 s when `MediaCoordinator.pollsInBackground` is true: the Mac is locked and neither Lock Screen opt-in (the song card or the activity stack) is on. That is the same test the window controller uses to decide whether a panel may appear without login. The coordinator sets it on each lock change and on every source it attaches, since a wake or a fallback retry can select a source while locked. Unlock already selects a fresh source, which starts at 2 s. One test covers all eight combinations of the policy, and another that a source switches between 2 s and 10 s when told (it is only created, so it sends no Apple Events).

The prediction from the 13:54 profile, taken with both opt-ins off: the script thread was 57 of 86 ms in 20 s, so four of every five polls removed is about half of the locked app's CPU. **Not confirmed live:** between 13:54 and 15:40 the Lock Screen song card was turned on (the 15:40 lock logs `songOptIn=true, show=true`). The new build correctly kept the 2 s poll: 14 script-thread bursts 2.2 s apart in a 30 s profile. Locked, with the card showing in both:

| Locked, song card on | Instructions/s | CPU | Wakeups/s | Energy |
|---|---:|---:|---:|---:|
| Old build (pid 65032), three 60 s windows from 15:49 | 6.5–7.9 M | 0.49–0.60% | 2.8–3.3 | 0.6–0.7 mJ/s |
| New build (pid 1696), three 60 s windows from 15:54 | 6.3–6.6 M | 0.53–0.54% | 3.1–3.9 | 0.5–0.6 mJ/s |

Equivalent, as expected: nothing in this pass changes a locked Mac that shows the song card.

The new build then stayed locked for four hours under a one-second footprint watch (16:06 to 20:06), which logs any move of 3 MB or more. It logged none: the footprint was 34.4 MB at the start and 37.0 MB at 20:12, and it never passed the 120 MB capture threshold. Over its whole life to 20:12 (4 h 19 min, launched and kept locked), the process used 83.5 s of CPU (0.54% of a core), 10.5 J (0.68 mJ/s), 3.1 wakeups a second and 144 KB of disk writes. Its lifetime peak, 83.5 MB, was before the watch started. So there's no growth while locked.

Each poll also asked Spotify for the player state twice. That was left at first and changed in the evening (see below).

### Status file pruning

`AIActivityMonitor` now runs `pruneStatusFiles` when it starts and every 6 hours, on a utility task off the main actor. It removes a `.json` status file only if it is outside the 32 newest (the only ones the poll reads), older than 8 days, a regular file (checked with `lstat`, so a symbolic link is never followed) and inside the app's own storage (`AppPaths.owns`). A `.tmp` file left by a reporter that died mid-write goes after an hour. Nothing else in the folder is touched. An activity hides at most 30 minutes after its last update, and History keeps its own copies, so nothing on screen or in History changes. `ClaudeUsageMonitor` already deletes `Claude Status` files after 8 days, and this uses the same age. A test builds 40 status files, temporary files, a symbolic link, a text file and a directory; it checks that the poll's result is identical before and after, that exactly the 10 expected files go, and that a second pass and a monitor that doesn't own the folder remove nothing.

AI Activity is off on this Mac, so the monitor doesn't start and the files here stay until it is turned on. To measure what pruning does to this folder without touching it, it was copied twice with its dates (`cp -Rp`). [prune-copy-harness.swift](2026-10-29-evidence/prune-copy-harness.swift), a temporary test, pruned one copy with the real `pruneStatusFiles`. It went from 2,163 entries to 337 and removed 1,826 files (every `.tmp` and the old status files) in 0.12 s (debug); a second pass removed nothing. `loadActivities()` returned the same 32 activities from both copies. The release bench then ran on each copy, alternating, two runs each:

| Copy | Entries | Poll, median of 3 × 30 | Instructions per poll |
|---|---:|---:|---:|
| Untouched | 2,163 | 1.251–1.273 ms | 28.8 M |
| Pruned | 337 | 0.417–0.449 ms | 10.2 M |

That is 66% less time and 65% fewer instructions per poll, about 0.8 ms of main-thread time and 18.6 M instructions a second at the 1 Hz poll once AI Activity is on. The bench's own precondition, that the scan agrees with a full listing, held on both copies.

### OSD check off the main thread

The verdict cache only lives in memory, so every launch with the OSD replacement on, as it is here, ran one full strict check on the main thread before "launched". `SystemOSDSuppressor` now runs the launch's first check on a detached task and enables when the answer arrives. A second enable while it runs only merges the input-access request, and a disable or stop withdraws it. The answer is kept either way. A bundle that can't be read leaves no verdict, and the enable that follows checks on the main thread as before, so it can't loop. Until the answer arrives the system OSD behaves as it did before any enable, and as it did while the main thread was blocked.

| Launch, Mac locked | First line → "launched" | Verify events on the main thread before "launched" |
|---|---:|---|
| 12:52:34, pid 65032, old build | 0.42 s | the start-up event, then the burst at 34.372–34.426 |
| 15:53:06, pid 1696, new build | 0.33 s | only the start-up event; the burst (07.004–07.042) ran on worker threads |

After the launch `OSDUIHelper` was stopped under a running watchdog, as before. This is one pair under different load: the check alone measured 270–634 ms in a probe and up to 0.45 s in a live launch, and took about 60–100 ms in the 12:52 launch. A test covers recording a verdict made elsewhere.

### Lock and unlock transitions

Rolling Time Profilers caught both transitions of the old build (pid 65032):

- **Unlock (15:08:46):** 660 ms of main-thread CPU in the 20 s window, most of it in two bursts of about 1.4 s and 1 s: the padlock expanding and collapsing. 344 ms of it is inside `CA::Transaction::commit`, made of `NSHostingView.layout` → `ViewGraphRootValueUpdater.render` (273 ms), the view-graph update (120 ms) and the display list. No NotchShot code is in the hot path. This is the padlock animation rendering at the display's 240 Hz, about 1 ms a frame. The padlock has its own setting ("Padlock opens in the notch when you unlock").
- **Lock (15:40:19):** 709 M instructions in that second. In the profile, the main thread spent about 150 ms in SwiftUI updates, `NSHostingView` layout and constraints, and the CA commit, with one sample in `NotchRootView.lockedPresentationContent`. That is the root view switching to its locked layout. The panel then shows the song card or is ordered out.

Per frame this is cheap. During the padlock's two bursts the whole process used 15–40 ms of CPU per 100 ms, which at 240 Hz is 0.6–1.7 ms a frame against a 4.2 ms frame. The total comes from the frame rate and the animation's length. The same profile caught the user opening the notch about 7 s after the unlock: 71 ms of CPU in one 100 ms slice, with type-metadata setup and `NotchTabBar`, `MediaControlButton` and `MarqueeText` bodies, which is a first open's view creation. The open and close cost per frame (20–40 M instructions) was profiled in the 18–19 October pass: the arrival blur was about 25% of it, and the rest is the shell's layers. Both are part of the look.

**No change:** neither has an app-side hot spot. Making them cheaper means animating less, at a lower frame rate, or not laying out a panel that is about to hide. The first two change the motion, and the third changes Lock Screen presentation logic that has needed several fixes. The lock's first second used 199 mJ; an unlock retires a similar 0.6–0.9 G instructions.

### Leftover test preferences

The 11,809 files from before the test-defaults fix (`notchshot.tests.*`, `notchshot.system-integration-tests.*` and `notchshot.lyrics-tests.*` with a UUID, the newest from 03:52 on 30 October) were moved to `~/.Trash/NotchShot test preferences 2026-10-30`, not deleted. `~/Library/Preferences` went from 12,827 entries to 1,018. Files from other projects' tests were left alone. Neither full test run this afternoon added any.

### Other leads

- **Notification mirror walk, unlocked:** with Notification Center closed it is one Accessibility call that finds 0 windows, 2–4 ms median. **No change:** an event-driven mirror would trade that for latency risk.
- **Island refresh fan-out:** fixed in the evening (see below).

## Evening follow-up, 30 October

### Spotify poll events

The app logs each Apple Event it sends (`com.apple.appleevents`, category `send`, info level), so a poll can be counted directly. Each poll of the 15:53 build, locked with the song card on and Spotify playing, sent 10: the player probe, then a script that asked the state, the five track fields, the state again as text, and `ASCII character 31` twice. `ASCII character` is a scripting addition. Inside a `tell` block it goes to the target application first, Spotify refuses it, and AppleScript sends it again to NotchShot. Spotify takes about 16 ms to answer each event.

The script now asks the state once, as text (the form `runningPlayer()` already relied on), checks that text for "stopped", and builds the separator with AppleScript's built-in `character id 31`, which sends nothing. `osascript` confirmed that `character id` and `ASCII character` give the same character for 3, 30 and 31. The playback-mode and Up Next scripts got the same separator change. A test pins the poll script: one state query, no `ASCII character`, and the text the parser reads.

| Locked, song card on, Spotify | Events per poll | First event to last reply | Polls |
|---|---:|---:|---:|
| 15:53 build (pid 1696), 22:40–22:42 | 10 (9 to Spotify, 1 to itself) | median 127 ms (120–275) | 52 |
| `f966908` (pid 68210), from 22:56:30 | 7 (all to Spotify) | median 94 ms (86–103) | 30 |

The first poll after the 22:56 launch had the track: `hasMedia=true` 0.53 s after the process's first log line, against 0.51 s at 15:53. Three 60 s windows of the locked app afterwards read 6.1–6.2 M instructions/s, 0.44–0.47% of a core and 0.5 mJ/s, against 6.3–6.6 M, 0.53–0.54% and 0.5–0.6 mJ/s for the 15:53 build at 15:54. That's consistent with three fewer events a poll, but the windows are seven hours apart. A 30 s Time Profiler can't resolve the difference: the script thread was 68 ms before and 74 ms after, at 1 ms sampling. Spotify also handles three fewer events a poll. Its own cost wasn't measured.

### Island refresh per Claude hook

A Claude hook changes `context.claude.sessions`. The observation in `observeIslandSources` then schedules a refresh, and the monitor's publish reaches `context.onSnapshotChange`, which refreshes directly. That made two refreshes about 15 ms apart, and the second read the same values as the first. `refreshActivity` now records the observed sources as it reads them (`IslandSourceValues`: the AI snapshot, Claude sessions, timer, voice note and recording pause), and the observation schedules a refresh only when the current values differ. It compares values, not a counter: tracking is one-shot and is renewed in the scheduled task, so a change made between the two must still be refreshed. Two tests cover that: one checks that a refresh records what it read, the other that two hooks with no direct refresh still end refreshed. The second fails when the scheduled refresh is always skipped.

An offscreen harness ([refresh-harness.swift](2026-10-29-evidence/refresh-harness.swift)) wires the app's `onSnapshotChange` path and the observation to a real `NotchRootView`, feeds synthetic `PreToolUse` hooks straight to the monitor (no socket), and counts main-thread instructions for 150 ms after each hook. Five rounds of 20 hooks per run, three runs each, old and new alternating, debug. The direct refresh fired for 20 of 20 hooks in every round:

| Per hook (round medians) | Old (`e0f14f7`) | New |
|---|---:|---:|
| Run 1 | 15.63–16.28 M | 9.16–9.63 M |
| Run 2 | 15.71–15.84 M | 9.15–9.48 M |
| Run 3 | 15.70–16.15 M | 9.34–9.65 M |

About 6.5 M instructions saved per hook, 41%. On this Mac AI Activity is off, so Claude hooks don't reach the app and nothing changes live. Raw values: [followup-2026-10-30.json](2026-10-29-evidence/followup-2026-10-30.json).

### Temporary files

At 22:37 a test failed because the disk had 128 MB free. `$TMPDIR` held 32 GB:

- **Kernel traces:** `instruments*.ktrace` and `xrgpu_aps_*` files that `xctrace` leaves after every recording, even after "Output file saved". The 90 s Animation Hitches recording at 12:35 alone left 18.5 GB of kernel trace and 2 GB of GPU files, and the 30 s one at 13:53 left 4.4 GB. Time Profiler recordings left 50–190 MB each. The times of all of them matched this pass's recordings, and no process had them open. They were removed: 26 GB.
- **Test fixtures:** each full test run left about 80 MB of folders. The consolidated-fix suite's Notes and Lyrics budget tests write 8–32 MB each, the History overflow tests up to 16 MB, and the clipboard store tests 3 MB. The 1,701 folders built up so far (5.1 GB) were removed, and those three suites now remove their own folders. A full run now leaves 34 entries and 0.1 MB, all empty folders from other suites.

Free space went from 128 MB to 31 GB. The scratch watcher now deletes its trace file after each recording.

## Night follow-up, 30 October

### The new build's first unlock

The unlock at 23:07:26 was the first for a build with this pass's changes (pid 68210, `f966908`). A rolling Time Profiler and a footprint watch were attached:

- **Burst:** 458, 336 and 115 M instructions in the first three seconds, then 6–40 M. That's the same size as the old builds' 0.6–0.9 G. The main thread used 376 ms of CPU in the 20 s window. The old build's 15:08 unlock used 660 ms, but that was a different unlock, so this isn't claimed as a change. No NotchShot frame is hot: 264 ms of it is AppKit and SwiftUI under `main`, and the largest app frames are the media poll's script thread (67 ms, its own thread) and the clipboard poll (29 ms).
- **Cover:** no CFNetwork task in the 40 s around the unlock, so the cache fix holds on this build.
- **Memory:** 85–88 MB for three seconds, then 36.5 MB. It stayed below the 120 MB capture threshold.

### Launch, profiled

One relaunch at 23:39, unlocked, ran under a system-wide Time Profiler, so the trace starts before the process exists. From `open` at 18.584 the process started (xpcproxy) at 18.676, logged "launched" at 19.104, and had its first media answers at 19.250. Its main thread used 357 ms over the launch:

| Main thread during launch | CPU |
|---|---:|
| AppKit and SwiftUI under `main`, including the notch's first `NSHostingView.layout` (102 ms) | 147 ms |
| `KeyboardStateMonitor.currentInputSource()`: the first Text Input Sources call, which sets that framework up | 24 ms |
| `applicationDidFinishLaunching` itself | 22 ms |
| `NotchPanel.init` | 14 ms |
| `installStatusItem` | 11 ms |
| Everything else, 7 ms or less each (default input device, panel rebuild and frame, EventKit store) | the rest |

The OSD signature check ran on worker threads (32 ms), so none of it was on the main thread. **No change:** no item is large, and the input-source call is a one-time framework setup that would move to the first keystroke if deferred.

Tonight's three launches, each read from the unified log:

| Launch | Process start → "launched" | → first media answer |
|---|---:|---:|
| 22:46, locked (pid 65986) | 0.47 s | 0.64 s |
| 22:56, locked (pid 68210) | 0.28 s | 0.45 s |
| 23:39, unlocked, under the profiler (pid 27370) | 0.43 s | 0.57 s |

The six launches read earlier took 1.03–3.58 s to "launched", on a busier Mac and with the signature check on the main thread, so the two sets aren't a matched comparison. The matched series below is.

### Network with lyrics on

Lyrics are on here, but Spotify was paused all evening (0.4% CPU, no audio assertion). The 15:53 process logged CFNetwork tasks only in its first second, and none in the seven hours after. With no track changes, the lyrics path couldn't be observed.

The request count per track is now a test instead (`requestsPerTrackChange`, with a stubbed session). The Lock Screen card and the lyrics panel asking for a new track at the same moment cost one request between them. Coming back to a track is free while fewer than 40 others have been looked up since; after the 41st it costs one more. So lyrics add at most one request per new track, whichever surfaces show them. A live count still needs a track change with lyrics on.

### Child processes and tonight's lock

A sample of the live app (pid 27370) found 10 threads, none in `wait4`, `waitpid`, `waitUntilExit` or the new polling helpers. Its only child process was the OSD helper. The lock at 23:07 (pid 68210, `f966908`) reported 9 ordering passes, none of 2 ms or more (slowest 1.9 ms), and no failed hides.

## Matched series, 31 October

Two release builds, alternated on the live Mac while it was locked:

- **Old:** `59af292` with the source changes of `65fa6a1` (the OSD check off the main thread) and `f966908` (seven Apple Events, one island refresh) reversed. Built twice, with the same code hash both times.
- **New:** the `f966908` build in `dist/`.

Both builds were signed by the same team. Each phase quit the app, swapped the bundles by renaming them, and opened it. The old binary got a warm-up launch first. After 25 s to settle, three 60 s `proc_pid_rusage` windows of NotchShot and Spotify ran side by side. Times come from the unified log.

The first run, at 23:50, stopped after one and a half pairs when the Mac was unlocked; the script put the new build back. The second ran three full pairs from 00:18, after a lock that had lasted two minutes.

| Locked, warm launch | Old (5) | New (4) |
|---|---:|---:|
| Process start → "launched" | 0.245, 0.269, 0.392, 0.409, 0.432 s | 0.253, 0.253, 0.258, 0.263 s |
| → first media reply | 0.306–0.499 s | 0.316–0.330 s |
| Signature check burst before "launched" | 40, 41, 139, 144, 149 ms | none |

**Launch: improved.** Both builds log 23 signature-verify events per launch. The old build logs the check's burst before "launched", partly on the main thread. Its launch was fast when the burst was short (40 ms) and 0.39–0.43 s when it was long (140–150 ms). The new build logs the burst after "launched", on worker threads, and launched in 0.25–0.26 s every time. In the three full pairs the old launches were 8 ms faster, 151 ms slower and 179 ms slower. The first run of a new binary took 1.07–1.10 s in both warm-ups, so it is excluded.

| Locked, 60 s windows | Old (14) | New (12) |
|---|---:|---:|
| NotchShot, M instructions/s | 6.2–6.7 | 5.6–5.9 |
| NotchShot, % of a core | 0.51–0.54 | 0.46–0.50 |
| NotchShot, mJ/s | 0.5–0.6 | 0.4–0.5 |
| NotchShot, wakeups/s | 3.0–3.3 | 2.9–3.2 |
| Apple Events per poll, all runs | 10 | 7 |
| Poll, first send → last line (median per run) | 127.1–129.1 ms | 93.3–94.7 ms |
| Spotify, M instructions/s | 4.8–10.7 | 4.3–16.2 |
| Spotify, % of a core | 0.41–0.67 | 0.37–0.58 |

**Media poll: improved.** NotchShot retired about 10% fewer instructions a second, with no overlap between the two sets of windows. Each poll was 34 ms shorter, about 80 polls per run. Spotify answers each event about 16.5 ms after it arrives (all but the first two in a poll), so the poll's length is mostly Spotify's reply pacing. Spotify's dictionary has no `properties` record for a track, so each field still costs one event.

**Spotify's own cost: inconclusive.** Three fewer events every 2 s are smaller than Spotify's own variation: medians of 6.3 and 5.6 M instructions a second, with overlapping ranges.

A footprint watch on the new build ran across three locks and two unlocks from 00:00 to 00:19. It peaked at 72.6–82.9 MB for 1–3 s at each change, then settled at 34.5–38.9 MB. Its lifetime maximum was 84.5 MB.

## Live checks, 31 October

Three items needed settings this Mac doesn't have, or playback. Each was checked on the `f966908` build in `dist/`.

Settings were changed through launch arguments only. These put a value in that process's argument domain. `Preferences.load()` never writes back (it is guarded by `isLoading`), and only the Settings screen writes these keys. The saved values were read before and after each run and hadn't changed: song card on, activity stack unset, AI Activity off. The user approved the AI Activity run on the condition that the folder was backed up and restored.

### Lock Screen opt-ins off: the 10 s locked poll

The run was at 01:39–01:49, locked, alternating launches with both opt-ins off and normal launches, two of each:

| Locked | Opt-ins off (2 launches) | Song card on (2 launches) |
|---|---:|---:|
| "Locked presentation" | `songOptIn=false, stackOptIn=false` | `songOptIn=true` |
| Polls in 120 s | 12 and 12 | 56 and 55 |
| Interval, median | 10.20 and 10.18 s | 2.11 and 2.14 s |
| M instructions/s | 6.1–6.2 | 10.3–10.4 |
| % of a core | 0.25–0.28 | 0.53–0.56 |
| mJ/s | 0.7–0.8 | 1.1–1.2 |
| Footprint | 26.4–26.8 MB | 33.4–33.8 MB |

**Confirmed live.** With nothing on the Lock Screen, the poll slows to 10 s and the locked app costs about half as much. The second column includes the card itself, so the difference is the cost of that configuration, not of the poll alone.

### AI Activity on: pruning, the poll, and hook refreshes

First, the folder (2,165 files, flat) was copied to the scratch folder. Its name, date and size manifest matched the original. Two launches then ran with AI Activity on, unlocked, with nobody at the Mac. Each was measured with the folder pruned, then with the full folder restored, in the same process. Pruning runs once at start and then every 6 hours, so the restore holds for the rest of the process.

| AI Activity on, 60 s windows | Pruned (326 files) | Full folder (2,165 files) |
|---|---:|---:|
| Launch 1, M instructions/s | 26.3, 25.2 | 59.8, 45.1 |
| Launch 2, M instructions/s | 24.3, 23.7 | 41.6, 41.4 |
| % of a core | 1.07–1.26 | 1.51–2.14 |
| mJ/s | 1.3–1.6 | 2.2–8.2 |

**Confirmed live.** Pruning took the folder from 2,165 to 326 files at both launches. The pruned poll cost 17–20 M instructions a second less, which matches the copied-folder benchmark (18.6 M a second at one poll a second). The window just after the first restore is the high one (59.8 M). The order wasn't alternated within a process, but it was repeated across the two launches.

Afterwards the app was relaunched normally and every file from the backup was put back with its date: 2,165 files, none missing. The only file that differed was this session's own Claude status file, which a hook had rewritten during the run. The backup copy was then deleted.

A third AI-on launch ran a 40 s Time Profiler while this session's own tool calls sent 16 hooks. Results on the main thread:

- **Samples:** 11 in `receiveHookData`, 8 in `refreshActivity`, 2 in `observeIslandSources` (the value check), and none in `scheduleIslandRefresh`.
- **After each refresh:** in the 5–40 ms after each of the 8 refresh samples, the main thread had no samples, apart from one Core Animation flush.
- **Why that rules out a second pass:** before the fix, a second pass followed the first by about 15 ms. Half of the first passes were sampled, so a second pass of the same size would have been sampled about half the time too. Missing it eight times would have odds of about 1 in 250. **Confirmed live:** one refresh per hook.

### Lyrics traffic

Lyrics are looked up only by a surface that shows them: the Lock Screen card, the pinned line, or the panel. The unified log shows that live:

- **The matched series' locked launches, 23:50–00:36:** the card appeared with a paused track, and each launch made one lyrics request (LRCLIB's exact match, 2.5 KB, HTTP/3, 72–176 ms) besides the cover (113 KB).
- **One process, 00:36–01:39:** from 01:17 to 01:29 it played seven tracks while unlocked, with no lyric surface on screen. It made one cover request per track, and the lyrics session made no requests.
- **The 01:32 lock:** the card showed the current track, and the lyrics session made its second and third requests: the exact match, which logged no completion, then the search fallback, which returned 5.5 KB.
- **Locked relaunches at 01:42 and 01:47:** with the card on, the same two requests each. At 01:47 the exact match came back 503 from LRCLIB after 0.55 s. With both opt-ins off, no lyrics request at all.

**Confirmed live:** one lookup per track shown on a lyric surface. That's one request, or two when the exact match fails, and no repeats. Covers come from Spotify's CDN over HTTP/2. `lrclib.net` resolves to Cloudflare addresses, which serve HTTP/3.

### Notch use: not measured

The user agreed to use the notch while it was recorded, but nobody was at the Mac then: the keyboard and trackpad had been idle for 168 s. Two 30 s Animation Hitches recordings attached to the app stalled in "Stopping recording" and were stopped; their 9.3 GB of kernel traces were deleted. Computer use can't be granted the app, because it isn't in this Mac's app index. A passive footprint watch now starts at the next activity at the Mac. Hitches and peaks during notch use are still unmeasured.

## Checks

- `swift test --filter "screenLockStateAtLaunch|screenLockSignalMapping|LockedMedia|LockScreen"` (debug): 18 tests / 3 suites passed, including the new session-dictionary test.
- `swift test --filter LockedMediaNotificationDeliveryTests` (debug): 11 tests passed. Control: `repeatedClearsRemoveOnce` fails with the new guard removed.
- `swift test --filter "AIActivity|AI activity|AgentUsage"` (debug): 15 tests / 3 suites passed, including the listing-equivalence test.
- `swift test --filter "ProcessExitTests|ProductivitySuiteTests|SystemUtilitiesTests|NotchMetricsTests|LockedMediaNotificationDeliveryTests|HistoryAndMediaTests"` (debug): 165 tests / 17 suites passed, including both Terminal runner tests and the new process-exit tests. Control: `ProcessExitTests` also passes 40 repetitions with `waitUntilExit()` restored, so the probe, not the tests, shows the race.
- Full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` (debug), with every change in this report: **1,277 tests / 209 suites passed** twice in a row (27 s and 24 s). The run before those had one failure: "An oversized answer is refused as it arrives" took 5.6 s against its 5 s bound under full-suite load, and it passes alone in 2.0 s. The run before that one is the five-hour Terminal runner hang described above. `PasteboardRaceTests` writes the system clipboard and was left unexecuted to protect user data. `idleClientsRecover` is a known flake under full-suite load.
- After the signature check change: `swift test --filter "SignatureVerdictCacheTests|SystemIntegrationSafety|ProcessExitTests"` passed 8 tests / 3 suites. A full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` passed **1,283 tests / 211 suites**. Debug build: no new warnings in the changed files.
- After the History thumbnail change: `swift test --filter "HistoryThumbnailCacheTests|HistoryAndMediaTests|History"` passed 149 tests / 24 suites. `HistoryThumbnailCacheTests` is 3 tests, one of them over eight image shapes.
- After the test-defaults change: `swift test --filter "PreferencesTests|LyricsTests|SystemIntegrationSafety|HistoryThumbnailCache"` passed 57 tests / 6 suites. A full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` passed **1,288 tests / 212 suites**, and 20 s after it ended `~/Library/Preferences` had no new files and the temporary defaults folder was gone.
- After the player lookup change: `swift build` with no warnings in the changed files, and `swift test --filter "AppleEventsMediaTimelineTests|HistoryAndMediaTests|MediaCoordinator|Media"` passed 126 tests / 20 suites, including the new `runningCheckMatchesTheAppList`. A full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` passed **1,289 tests / 212 suites** and left no preference files.
- After the artwork cache change: `swift build` with no warnings, `swift test --filter "AppleEventsMediaTimelineTests|HistoryAndMediaTests|Media"` passed 127 tests / 20 suites, including the new `artworkCacheEviction`, and a full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` passed **1,290 tests / 212 suites** and left no preference files.
- `swift build -c release` of every product, with every change in this report except the signature check: built in 406 s, with no warnings in the changed files.
- Afternoon follow-up: `swift build` with no warnings in the changed files. `swift test --filter "pruningKeepsWhatThePollReads|lockedPollRate|artworkCacheEviction"` passed 3 tests, `SignatureVerdictCache` 5 tests, and the targeted AI Activity, media and island run 152 tests / 24 suites. A full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` passed **1,292 tests / 212 suites**, and **1,293** after the OSD change, with no new preference files either time. `Scripts/build_app.sh --release` signed with the same identity and designated requirement; `codesign --verify --deep --strict` passed.
- Afternoon follow-up, second round: `swift test --filter "backgroundPollInterval|lockedPollRate"` passed 2 tests, and a full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` passed **1,294 tests / 212 suites** with no new preference files. The release bench's `ai.activity` group ran twice on each copy of the real folder with every precondition holding.
- Release `NotchShotBench ai.activity` twice with instruction counters: every precondition held. The earlier full sweep completed every group.
- Evening follow-up: `swift test --filter "IslandSourceRefreshTests|AppleEventsMediaTimelineTests|MediaQueue|PlaybackMode"` passed. Control: the refresh test fails with the scheduled refresh always skipped. Three full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` runs passed **1,297 tests / 213 suites**, with no new preference files and 0.1 MB left in `$TMPDIR`. A release `Scripts/build_app.sh` with the same signing team, relaunched twice.
- Night follow-up: a full `swift test --skip PasteboardRaceTests --skip idleClientsRecover` passed **1,298 tests / 213 suites**, including the new `requestsPerTrackChange` (`935dcab`). The matched series' old build was rebuilt from scratch with the same code hash, and the new build's code hash was checked again after both restores.
- Live checks: saved Lock Screen and AI Activity values were read before and after every overridden launch, and were unchanged. The AI Activity folder was compared with the backup's manifest after each run: all 2,165 files present.

## Coverage and leads

| Surface | Evidence / disposition | Still open, and what it needs |
|---|---|---|
| Background polling (AI Activity) | Two live samples, probes, interleaved release A/B on synthetic and real folders, instruction counts. **Retained.** With AI Activity on and agents working: 27 M instructions a second for the poll on today's 2,144 files, plus 8–10 M (debug) per agent update. Status files are now pruned after 8 days outside the 32 newest, off the main actor, with a test that the poll reads the same before and after. On a copy of the real folder, pruning took it from 2,163 entries to 337 and the poll from 1.25–1.27 to 0.42–0.45 ms and 28.8 to 10.2 M instructions (release, alternating runs), with the same 32 activities read. **Confirmed live** with AI Activity on for single launches: 2,165 → 326 files at start, and 23.7–26.3 against 41.4–59.8 M instructions a second with the folder restored (see Live checks). | — |
| Notification Center removals | Live log rate, sample, usernoted `rusage`, fixture test with control. New build: 2 removal lines in 16 minutes, both at launch. **Retained, confirmed live.** | — |
| Lock Screen log line | Live log rates. New build: 4 lines in 16 minutes over three locks (was 2,422 in 10 minutes). **Retained, confirmed live.** | — |
| `orderOut` wait while locked | First process: ~11–13 ms on every locked refresh, through AppKit's full key-window hide path. New build's ordering report over three locks: 0, 2 and 1 passes of 2 ms or more, slowest 9.7 ms, no failed hides. A probe reproduces that size only for the first hide of a panel that asked for key. **Not recurring, so no fix:** the every-pass wait is gone in this build, cause still unproven. The ordering report stays. `f966908`'s lock at 23:07: 9 passes, none slow, slowest 1.9 ms. | — (the ordering report stays as a tripwire: a lock with most passes slow would reopen it) |
| Launch while locked | Window controller, media, Instant Replay and brightness poll started as unlocked; the 19:58 relaunch ran the unlocked path while locked. **Fixed:** seeded from `CGSessionCopyCurrentDictionary`, with a parser test. **Verified on the Mac:** the 02:47 relaunch began locked, showed nothing, and brought the panel back at unlock. | — |
| Brightness poll | A 5 Hz `DisplayServicesGetBrightness` XPC on the main thread, which kept running while locked even though no locked reading can reach the screen. **Fixed:** it pauses while locked and re-baselines on unlock, as around display sleep. Probe: 5.5–7 wakeups/s and 0.5–0.8 mJ/s removed while locked. Live, the new build locked for six minutes: 3.0 wakeups/s for the whole app, against 14.1–14.6/s for the old build with AI Activity on; 34–40 minutes into a later lock, 2.9/s. In the matched series, 26 locked 60 s windows of two builds that both pause it: 2.9–3.3 wakeups/s for the whole app, less than the brightness poll alone cost in the probe. | — |
| Island refresh fan-out | Each Claude hook event refreshed the island twice, about 15 ms apart: once from `context.onSnapshotChange`, once from `observeIslandSources` → `scheduleIslandRefresh`, with the same values. **Fixed:** the scheduled pass runs only when the observed sources differ from what the last refresh read. Offscreen harness with the app's wiring: 15.6–16.3 → 9.2–9.7 M main-thread instructions per hook (debug, 3 alternating runs). Tests cover a change made before tracking renews. **Confirmed live:** a profile of 16 hooks with AI Activity on found one refresh per hook and nothing in the 5–40 ms where the second pass ran (see Live checks). | — |
| Crewline unpaired retry | Keychain miss every 5 s on main. A warm miss costs 0.18 ms. **Rejected** as negligible. | — |
| Network | No sockets or traffic in the relaunched app (`lsof`, `nettop`). Lyrics are opt-in and cached (40 entries), with in-flight de-duplication and 8 s / 12 s timeouts. Sparkle runs only in configured release builds. Reachability uses `NWPathMonitor`, which is event-driven. Spotify covers were fetched again at every unlock and player re-selection (4 of 4 unlocks): **fixed**, one request per track, and confirmed live: no request at the new build's unlock, against 5 of 5 before. Lyrics: one request per new track, shared by both surfaces, by test (`requestsPerTrackChange`). **Confirmed live:** one lookup per track shown on a lyric surface (one request, or two when LRCLIB's exact match fails), none during seven track changes with no lyric surface on screen, and one cover per track (see Live checks). | — |
| Memory | Locked: 30.5–31.3 MB for 25 minutes (old build). Unlocked: 97.2 MB, flat for 3 minutes, peak 227.6 MB (old); 83 MB, then 39–41 MB after a lock, peak 123.6 MB (new). `heap`: 38.2 MB live in the old process; about 36 MB was freed memory not yet returned. Offscreen open/close harness: no per-cycle growth over 400 cycles. Live spikes at unlock and while in use are 38 MB of graphics memory for 2–4 s, freed each time. A History window scrolled end to end added 51 MB of heap and kept about 33 MB after it closed. **Fixed** for History (+11–12 MB, none kept); the graphics transients are glass rendering, **no change**. New build: lifetime peak 79 MB over 98 minutes, including an unlock, a lock and a 30-minute footprint watch that never passed 120 MB. Build at `a85a425`, locked: 34.4–37.0 MB for four hours with no move of 3 MB or more. | A peak while the notch is opened and scrolled. **Needs use:** someone using the notch while a footprint watch runs (the new build's locks and unlocks peaked at 72.6–88 MB for 1–3 s at six changes, then settled at 34.5–38.9 MB). |
| Launch | Six launches from the unified log, 1.03–3.58 s from exec to "launched". The worst one spent 0.92 s of main-thread time on the OSD signature check. First runs of a new binary add 1–2 s of page-in before AppKit. Startup cleanups scale with the store (181 history rows, 176 captures here). History load at 5,000 rows is 100 ms, already tuned and fuzz-tested. **Fixed** for the second signature check of each launch, and the first now runs off the main thread (see the OSD row). A system-wide profile of a new launch found no main-thread hot spot. **Matched series, locked and warm:** 0.25–0.43 s (median 0.39) → 0.25–0.26 s (median 0.26) from process start to "launched", five old and four new launches, alternated. | — (the number is for locked launches; the change is the same unlocked, and the 23:39 unlocked launch, under a system-wide profile, ran the check on worker threads) |
| OSD signature check | 270–634 ms per check in a probe on a busy Mac; 80 ms–0.92 s for two in live launches. Reached twice per launch, per helper pause, and on every Settings → Notch redraw. **Fixed:** the verdict is kept until a bundle file's stamp changes (3–14 ms), and Settings reads it once per appearance. On the real bundle, a launch's checks went from 538 to 274 ms (medians, 8 alternating rounds). Tests cover hits, failed verdicts, four kinds of change and an unreadable bundle. **Confirmed live:** the 03:35 launch of a build with `57e3eb1` ran one check (23 verify events, against 39 for every earlier launch). The cache lives in memory, so that one check still ran on the main thread at every launch. **Fixed:** it runs on a detached task and enabling waits for it. The 15:53 launch ran its verify burst on worker threads only, 0.33 s from first line to "launched" against 0.42 s at 12:52. Matched series: the burst came before "launched" in all 5 old launches (40–149 ms) and after it in all 4 new ones. | — |
| Opening/scrolling History, capture, clipboard, island engine | Full release sweep: search cache hit ~0, cold search 3–5 ms at 5,000 rows, record 6.9 ms, save 29 ms (off main), PNG encode 33 ms (detached), island sync/present ≤ 10 µs. Offscreen scroll harness over the real stores: History decoded full-size thumbnails and decoded them again for recycled rows. **Fixed:** row-size decode plus a cache for the window, 23–26% fewer process instructions per pass and 51 → 11–12 MB of heap growth. Frame times equivalent in a quiet round. Clipboard list: +0.85–1.41 MB while its window is open, and 7.3–7.5 MB below the starting heap once it closes, in all 13 runs. That's the window's own rows, not retained growth: **nothing to fix**. On screen: a 30.9 s Animation Hitches trace of the unlocked new build has 0 hitches, 0 potential hangs and no frames from NotchShot, which means nothing animates while idle; the notch wasn't used during it. | Hitches in use. **Needs use:** a hitch trace while someone opens, scrolls and dismisses the notch. |
| Rendering loops | Every SwiftUI `repeatForever` and `TimelineView(.animation)` loop in the notch is now a layer. Only 1 Hz countdowns and a 6 Hz Productivity view remain. The compact island's rolling percentage (`IslandNumericText`) rendered for 150–750 ms per change offscreen. **Fixed:** progress percentages are plain digits, like running clocks; a change costs 26–30 M instructions and one 50 ms slice, against 11.9–12.1 G and 750 ms. | On-screen cost of a progress change. **Needs use:** an agent that reports a percentage while AI Activity is on (Claude hooks don't). |
| Media poll (Apple Events) | Every 2 s, locked or not: `bundleIdentifier` of every running app, most of them an XPC to LaunchServices, 31 of 38 busy main-thread samples in a locked 10 s sample. **Fixed:** the two players are asked for by identifier, 10.15 → 0.13 M instructions and 4.76 → 0.43 ms per poll in an interleaved probe, same players found every round. Live after the rebuild, locked with Spotify playing: 9.7–10.6 → 5.1–5.2 M instructions/s, 0.52–0.56 → 0.36–0.39% of a core, 0.8–1.1 → 0.4 mJ/s; busy main-thread samples 38 → 13 per 10 s. Locked with no Lock Screen notch, the poll now runs every 10 s instead of 2 s. **Not confirmed live:** the song card was turned on here, so the poll correctly stays at 2 s (equivalent locked readings, old and new). Each poll sent 10 Apple Events, including the state twice and two for a scripting addition. **Fixed:** 7, all to Spotify, and 127 → 94 ms from first event to last reply, counted live (`f966908`). Matched series: 10 → 7 events in every run, 127.1–129.1 → 93.3–94.7 ms per poll, and NotchShot at 6.2–6.7 → 5.6–5.9 M instructions a second (14 and 12 locked windows). Spotify's own cost is inconclusive: the change is smaller than its own variation. **Confirmed live** with both opt-ins off for single launches: polls 10.2 s apart against 2.1 s, and 6.1–6.2 against 10.3–10.4 M instructions a second (see Live checks). | — |
| Unlock | No panel rebuild at the 03:09 unlock; the `rootView` reassignment costs 0.4 M instructions and a fresh panel's first render 24 M (offscreen, debug), so neither explains the 729 M in that second. Every unlock re-downloaded the Spotify cover, and the first media update waited for it: **fixed**, the artwork cache now outlives the source. New build, live: no cover request after unlock (0 network tasks, against 5 of 5 before). The transition still costs 0.6–0.9 G instructions over 1–2 s at unlock and 0.44 G at lock, with +40–47 MB of graphics memory for 3 s; a sample from +0.95 s finds the main thread idle, so it's inside the first second. Rolling Time Profilers of both: the unlock is the padlock animation at 240 Hz (660 ms main-thread CPU, no app code in the hot path), the lock is about 150 ms of the root view's switch to its locked layout. **No change:** cheaper means less motion or reworking Lock Screen presentation. `f966908` at 23:07: the same burst (0.9 G over three seconds), no cover request, peak 88 MB. | — |
| Unlocked steady state, size | Old build: 3.6% of a core, 32–46 M instructions/s, 5.6–7.5 mJ/s, 12–37 wakeups/s. New build: 1.5% (60 s), 18–80 M instructions/s, 2.2–13 mJ/s, 30–37 wakeups/s. The ranges overlap: **equivalent within noise.** About 1% of the main thread is NotchShot code. The notification mirror's 0.45 s Accessibility scan is the largest piece, about 3 ms/s on its queue. It also has an `AXObserver`, so the scan might become event-driven, but that changes a polling policy and needs a product decision. Locked, Notification Center has no windows and a scan is one Accessibility call (0.57 ms); the mirror is paused then anyway. Its per-scan app lookup is 0.1 M instructions, too small to change. The media lookup fix above applies here too, about 5 M instructions a second. **No other change.** New build after the rebuild, 124 s unlocked: 11.1 M instructions/s (median 9.6 M), 0.71%, 13.5 wakeups/s, 1.14 mJ/s, against 21.3 M (median 17.4 M), 0.89%, 16.0, 2.64 mJ/s for the old build the same day, under different use. The mirror's walk unlocked with Notification Center closed: one Accessibility call, 0 windows, 2–4 ms median, **no change**. | — (a summary row: each change that runs unlocked was measured on its own, above) |
| Storage: test preference files | 20–28 empty plists a test run in `~/Library/Preferences`, 11,809 since July (46 MB). cfprefsd rewrites them after exit, whatever cleanup runs first. **Fixed:** test suites live in a temporary folder for the process; a full run left 0. The 11,809 files already there were moved to the Trash. | — |
| Storage: temporary files | A full test run left about 80 MB of fixture folders in `$TMPDIR`, 5.1 GB in total. Each `xctrace` recording leaves its kernel trace there; this pass's left 26 GB and filled the disk. **Fixed:** three suites remove their folders, and a full run now leaves 0.1 MB. Old fixtures and traces removed: 128 MB → 31 GB free. | — |
| Waiting for child processes | A five-hour hang in a full test run, sampled; probe with interleaved modes (13 of 568 old waits never returned, 0 of 384 polled); Foundation's exit path read from disassembly and a hung task's state word. **Fixed** at the four worker-thread sites; helper tests. The tests pass against the old wait too, so the probe is the evidence. A sample of the live app found no thread in any wait and one child, the OSD helper. | — |

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
swiftc -O "$OLDPWD/Documentation/Performance/2026-10-29-evidence/thumbnail-decode-bench.swift" -o thumbnail-decode-bench
./thumbnail-decode-bench "$HOME/Library/Application Support/NotchShot/Thumbnails"   # reads only
```

The scroll harness is a test file. Copy [scroll-harness.swift](2026-10-29-evidence/scroll-harness.swift) into `Tests/NotchShotKitTests/` as `ZZScrollHarness.swift`, run `SCROLL_HARNESS=1 SCROLL_OUT=<file> swift test --filter ZZScrollHarness`, and delete it again. It reads the app's History and clipboard stores and writes only `SCROLL_OUT`.
