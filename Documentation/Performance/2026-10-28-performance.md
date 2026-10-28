# NotchShot performance assessment — 28 October 2026

Already-fitting byte-limited PNG saves measured **70.391 → 37.402 ms, 46.9% lower completed latency**. Every pair improved. The retained change reuses the encoding that already passed the byte-size check. Ordinary and resized images retain their normal final encoding path. All final PNG/JPEG files are byte-identical to the frozen original-code baseline.

This is a broad source/component assessment with one retained optimization. The measured outcome is a warm-fixture recipe/helper call through a completed atomic file write. It does not establish faster shortcut-to-selection, shelf appearance, cold launch or smoother on-screen animation. Capture animation/landing timing is preserved.

## Final measurements

Values are medians of five independent process medians, each with two warmups and nine timed iterations per workload. Baseline/candidate order alternates between pairs. All 360 final timed outputs completed and validated; fixture setup, reference encoding, decoding/checks and cleanup are outside timing.

| Workload | Before | Final candidate | Latency change |
|---|---:|---:|---:|
| Ordinary PNG control | 37.440 ms | 37.471 ms | +0.08% |
| Bounded PNG, already fits (primary) | 70.391 ms | 37.402 ms | -46.87% |
| Bounded PNG, resized | 48.123 ms | 48.160 ms | +0.08% |
| Bounded JPEG, resized | 45.535 ms | 45.689 ms | +0.34% |

The primary reduction is **32.989 ms**. Baseline process medians ranged 70.203–72.159 ms; candidate medians ranged 37.250–37.436 ms. Paired reductions ranged 46.7–48.3%. The three controls differ by less than 0.4% in aggregate; their overlapping samples do not establish a separate speedup or a population equivalence interval. No tail-latency claim is made from five processes.

Median process peak RSS was **301.69 → 302.42 MiB** (+0.73 MiB). Median whole-sequence user CPU was **2.36 → 2.02 seconds** (14.4% lower); system CPU was 0.27 seconds for both. These include initialization, warmups, fixture creation and output validation, so they are resource guards for this process, not whole-app footprint, energy or battery-life results. The unchanged fixed-CPU control was 5.528 → 5.558 ms. No compiler was present at any of the ten recorded final run starts; all task builds/tests had finished before timing.

The synthetic main-actor delivery probe remained below 0.02 ms in aggregate for both variants. It checks an unrelated Swift task during the helper call; it is not an AppKit input-to-frame or animation measurement.

Acceptance was established before production edits: at least 10% lower primary completed latency, no greater than 10% aggregate slowdown in any other workload, matching bytes/dimensions/scale/source geometry, and peak RSS below a 10% increase plus 2 MiB. The margins are laboratory assumptions, not product SLAs. The final candidate passes all guards, with no observed transfer of the resize cost. Raw samples, run order, controls and resources are in [measurements.json](2026-10-28-evidence/measurements.json), [capture-samples.jsonl](2026-10-28-evidence/capture-samples.jsonl) and [control-samples.jsonl](2026-10-28-evidence/control-samples.jsonl).

## Cause, intervention and rejected experiments

The original call trace is `finishStillCapture → prepare → CaptureRecipeWorker → renderToFit → ImageExport.encode`, followed by `persist → ImageExport.write → ImageExport.encode`. A bounded image that already fit paid twice for the same final encoding. This was identified by source tracing and tested with a controlled intervention; no interval-specific Instruments CPU attribution is claimed.

The final implementation:

- Keeps the original eight fitting attempts, scale/rounding, final verification, errors and image-only APIs.
- Carries immutable accepted bytes, actual fallback format and the matching image/settings in `PreparedCaptureExport` only when the fitter returns the identical input bitmap.
- Uses the existing capacity guard and atomic writer. Destination selection, extension repair, source geometry, cancellation checkpoints, operation IDs, cleanup, clipboard behavior and shelf/animation ordering remain in place.
- Leaves resized images on the original final encode/write path. There is no shared or persistent encoding cache, background prewarming, new polling, reduced resolution/quality, or changed timeout/debounce/freshness policy.

The first candidate reused every accepted encoding. Its initial five-pair campaign was noisy and included compiler activity at one recorded start; those results are provisional. A subsequent quiet-host campaign showed the intended primary gain but **49.109 → 53.658 ms (+9.3%)** for resized PNG, with every pair slower. Although inside the original guard, that scope was rejected. The narrowed second candidate retains only the demonstrated already-fitting-image gain; resized PNG returned to 48.123 → 48.160 ms. Retaining the small resized encoding was a hypothesis for the slowdown, not a separately proven allocator/root-cause diagnosis. All campaigns remain in the evidence; none were silently discarded or repeated to obtain a favorable unchanged-code result.

The first resize fixture used an 88 KB PNG ceiling and hit the existing bounded fitter's failure. That incomplete run has no completion marker and is excluded. The repaired PNG fixture uses a 17,630-byte ceiling (10% of the original 176,302-byte PNG); JPEG uses half its original encoding size at quality 0.72. The repaired pre-change run completed all four workloads before production edits. Failure/attempt policies were preserved.

## Behavior and build checks

- Final full suite: **1,157 tests in 192 suites passed**. The new export suite covers PNG/JPEG output against the original fitter, DPI/geometry, zero/negative limits, cancellation before preparation, impossible limits, write failure, accepted PNG fallback metadata and concurrent independent exports. Its five tests, including parameter cases, passed independently and within the final suite.
- `PasteboardRaceTests` was deliberately excluded because it writes to the system general clipboard. No existing assertion was weakened. The fallback unit test supplies accepted PNG bytes; it does not force an actual HEIC encoder failure. Mid-write/UI cancellation and save-panel extension repair were reviewed in source, not exercised through a live window.
- Final optimized benchmark and app executable builds, hygiene and whitespace checks passed. Existing deprecation/Sendable warnings and local tool-search-path warnings remain.
- Independent read-only High review of the initial production path and the changed final condition found **no actionable findings**. The reviewer read primary build/test evidence and completed journals; it did not execute validation workloads.

The final source and binary identity are recorded in [source-fingerprints.json](2026-10-28-evidence/source-fingerprints.json). Detailed executed/unexecuted checks and review boundaries are in [checks.json](2026-10-28-evidence/checks.json).

## Coverage ledger

This repository ships a native macOS app, SwiftUI/AppKit UI, CLI helpers and local
socket services. It has no web frontend or owned remote backend. Optional network
integrations are clients of external services or a separately installed Crewline
server; those services were not modified or load-tested.

| Journey / costs | Participating paths assessed | Evidence and boundary |
|---|---|---|
| Launch to usable state; startup I/O | `main.swift`, `AppDelegate`, `AppCoordinator.start`, History/Clipboard store initialization, cleanup, Spotlight indexing and monitor startup | Source assessment and disposable large-store benchmarks. Full cold launch through usable UI remains a distinct proof lane. Existing recovery checks and retention semantics must stay intact. |
| Screenshot selection, capture and save; CPU, memory, storage | `selectRegion`, `CaptureService.prepareSelection`, `SelectionOverlay`, frozen-frame cut, recipe worker, `persist`, thumbnail and clipboard delivery | Initial signed baseline self-test passed while unlocked; the later candidate/control probes were blocked while locked. The completed prepare/save experiment is retained only for already-fitting bounded images. The selection backdrop already caches dimming, freeze/window inventory is shared, frozen crops own their pixels, export/thumbnail work runs off the main actor, and clipboard encoding is promised. |
| Opening and scrolling history | `HistoryView`, `HistoryRepository.search/load`, row thumbnail decoding and Quick Look fallback | Existing search caching, one filtered result per body evaluation and worker thumbnail decoding assessed. Large-store benchmark coverage is separate from real list frame pacing. |
| Annotation, comparison, export and scrolling capture | Annotation model/renderer/worker, comparison plane reuse, `SmartExportService`, scrolling stitcher/session | Existing worker and cancellation boundaries, ordering, pixel fidelity and allocation limits assessed. Synthetic rendering/hit-test/stitch benchmarks do not prove interactive FPS. |
| Data updates, durable completion and recovery | History write queue/revisions, synchronous termination save, clipboard store, Spotlight replacement/coalescing | Existing serialized writes, atomic output, recovery and data-integrity contracts assessed. No schema, save cadence, retention or durability change is authorized by the experiment. |
| Recording, audio and background work | Recording lifecycle/segment completion, Instant Replay encoder/backpressure, audio RMS, privacy worker, media and context monitors | Live baseline signed screenshot/recording smoke check; source and existing regression/benchmark coverage. Sustained A/V synchronization, dropped frames, thermal behavior and long-session memory need dedicated workloads. |
| Activities, networking and system integration | Island engine/transfer store/external registry, AI transcript readers, Crewline subscriptions, lyrics cache/in-flight sharing, Bluetooth report cache and clipboard polling gates | Source and local fixture coverage. Polling, retry, notification, freshness and permission policies are preserved. No live user transcript, paid provider, third-party load or real upload is used. |
| Idle CPU, memory and energy | Running signed app, main-thread sample and `vmmap` | Baseline sample: about 68.4 MiB footprint, with the main thread predominantly waiting for events. This is one installed-bundle observation, not leak, battery-life or energy proof. |


## Component survey observations

The survey completed **18 runs / 106 valid benchmark groups** across the frozen baseline and first candidate. Representative candidate observations included 5,000-row history load **106.9 ms**, completed history save **33.9 ms**, 500-row clipboard load **2.26 ms**, 1,500-message transcript parsing **4.32 ms**, 120-element annotation export render **17.95 ms**, complete 4K difference generation **14.29 ms**, and eight-frame stitching **12.83 ms**. Island synchronization, transfer publication, cached filtering, hit testing, thumbnail generation, PNG/HEIC encoder attempts and audio RMS groups also passed.

These are component/synthetic observations, not additional improvements attributed to this task. Survey source in those other components is unchanged by the final narrowing. The final candidate repeated the affected four-case persistence workload and full regression suite. Actual list scrolling, live canvas gestures, frame pacing, remote latency and cold app readiness remain distinct proof lanes. See [coverage.json](2026-10-28-evidence/coverage.json).

## Environment, signing and live proof boundary

Hardware: Apple M5, 16 GiB RAM, ten logical CPUs; macOS 26.7.2. Source base: `6fc82ef00280e943165bc994bf7334ff20208a17`, plus this task's fingerprinted patch. The primary checkout contains unrelated concurrent work, so experiments and publication use an isolated worktree and task branch. The running installed app was preserved.

The selected Xcode has an unaccepted license gate. CLT Swift 6.3.3 lacks the required SwiftUI macro plugin; a minimal probe confirmed the installed Swift 6.4 plugin cannot load into that compiler. The working route invokes the installed **Swift 6.4 compiler, macOS 27 SDK and matching SwiftUI/Testing macro plugins explicitly**, retaining macOS 26 deployment. Testing also uses the matching developer framework/module paths. No license, system toolchain or signing setting was changed to repair this environment. This is executable/build proof, not a standard release archive or distribution-package verification.

Before the Mac locked, the existing signed bundle's self-test passed Screen Recording preflight and produced a **640 × 400 screenshot and a playable 640 × 400 recording lasting 1.73 seconds**. Its 3.38-second total includes the intentional 1.5-second recording interval and is not a screenshot latency result. The installed Settings window was visually inspected using a native screenshot, without a quantitative frame-pacing trace.

A temporary validation copy using the same installed signing identity and matching entitlements passed strict signature verification. Its initial missing app-framework rpath was repaired using the normal packager's rpath. It launched with Screen Recording preflight granted, but ScreenCaptureKit returned no displays. A same-time control using the installed original app returned the same failure, and the console reported **screen locked**. No unlock, permission change, logout, restart or installed-app replacement was performed. **Live final-candidate capture/recording and interactive visual validation remain unverified.** The signed copy predates the final narrowed retention condition; the final app executable was rebuilt successfully.

The idle installed-bundle sample showed about **68.4 MiB footprint**, with the main thread predominantly waiting for AppKit events. That single observation is not a matched idle improvement, leak result or energy measurement. Only a [sanitized profile summary](2026-10-28-evidence/profile-summary.json) is in Git; private screen pixels and raw traces remain outside repository evidence.

## Reproduction

With a working matching Apple toolchain, build `NotchShotBench` in release mode. Its `capture-persistence` filter exercises completed output using disposable files. `NOTCHSHOT_CAPTURE_MODE=baseline` uses the image-only prepare plus ordinary writer flow; `reused` (default) uses the current prepared export. Use a fresh `NOTCHSHOT_CAPTURE_RESULTS` path to retain raw samples.

For an exact pre-change comparison, export base commit `6fc82ef`, copy the current benchmark `main.swift` into that export, and install [baseline-capture-persistence.swift](2026-10-28-evidence/baseline-capture-persistence.swift) as `Sources/NotchShotBench/CapturePersistenceBenchmarks.swift`. The other benchmark sources are unchanged. Build original and final libraries with identical compiler/SDK/link arguments and keep each executable's Sparkle framework available. This avoids requiring the new API in the original library. The frozen baseline source and both executable fingerprints are preserved in the evidence; the runtime Git header alone is insufficient to identify a dirty-tree binary.

Run the comparison from the repository with fresh output:

```sh
python3 Scripts/benchmark_capture_persistence.py \
  --baseline /absolute/path/to/baseline/NotchShotBench \
  --candidate /absolute/path/to/candidate/NotchShotBench \
  --output /absolute/path/to/fresh-results
```

The runner alternates five process pairs, validates all completed journals and cross-variant byte/dimension fingerprints, records compiler activity at starts, and runs the unchanged CPU control. [protocol.json](2026-10-28-evidence/protocol.json) records the fixed decision rules and invalid attempts. Keep Debug, warm-image microbenchmarks, live UI, field measurements and power measurements separate.

## Remaining proof gaps and stopping point

- Full cold launch through usable UI, actual shortcut-to-selection/clipboard/shelf completion, live scrolling/canvas input, UI frame pacing and accessibility operation need a matched unlocked-app trace. A static screenshot does not demonstrate smoothness.
- Long-session retained memory/leaks, large high-entropy photos/scrolling images, post-capture OCR peaks, GPU/thermal cost and controlled energy/battery use are unmeasured. Fixed-fixture peak RSS and CPU time do not answer those questions.
- Real uploads, optional remote/provider integrations, external-device transfers, dictation inference, multi-display and permission edge cases were assessed in source/local tests where available; live service performance was not established and no third-party load test was run.
- Position-only media observation and Bluetooth in-flight report sharing remain source leads requiring attributable workloads and cancellation/freshness/invalidation checks. No policy was changed on that evidence alone.

The pass stops after the attributed gain, removal of the observed resize regression, source/component coverage, final behavior checks and independent delta review. Remaining lanes are explicitly unverified; this is not an app-wide performance plateau or a guarantee that every operation is free of lag.
