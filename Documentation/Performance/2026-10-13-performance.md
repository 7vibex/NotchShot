# NotchShot performance pass — 13 October 2026

Five behavior-preserving optimizations were retained after an app-wide subsystem review and comparative release benchmarks. The final candidate passed **1,004 tests in 167 suites**, all **100 benchmark groups**, strict signature verification, and the signed app's screenshot/recording self-test on this Mac. The slower audio experiment was reverted completely.

This establishes improvements in the measured paths below. It does not certify that every feature is faster, or establish battery-life, animation-FPS, GPU, or sustained-memory improvements across every workload.

## Retained results

These are medians of five fresh-process run medians per version, on an Apple M5 MacBook Air with 16 GB RAM, macOS 26.5.2 and Swift 6.3.3, using optimized arm64 executables. Each individual measurement used 15 timed iterations and 3 warmups, except transcript loading, clipboard loading and stitching, which used 9 timed iterations and 3 warmups. Versions alternated their execution order. Timings are local synthetic workloads, not whole-app speedup percentages.

| Workload | Before | After | Lower latency | Change |
|---|---:|---:|---:|---|
| Clipboard budget check after OCR, 500 rows | 2.016 ms | 0.031 ms | 98.5% | Prove small stores fit with a conservative encoded-size bound; preserve the exact encoder and trimming policy for uncertain/large stores. |
| Clipboard store load, 500 rows | 3.920 ms | 2.035 ms | 48.1% | The same bound avoids serializing the just-decoded store again during launch/loading. |
| Clipboard SHA-256 spelling, 1,000 × 4,096 bytes | 10.238 ms | 1.922 ms | 81.2% | Construct the same 32 lowercase hex characters directly instead of formatting 16 separate strings. |
| Transcript read, 1,500 timestamped messages | 103.793 ms | 40.791 ms | 60.7% | Reuse one ISO8601 parser within each read, with separate state for concurrent reads. |
| Annotation hit testing, 1,000 queries / 120 elements | 3.720 ms | 2.255 ms | 39.4% | Scan integer indices without allocating/sorting the element array. |
| Annotation hit testing, 1,000 queries / 1,200 elements | 23.335 ms | 10.646 ms | 54.4% | Preserve topmost order and the last-input winner for equal orders. |
| Scrolling stitch, 8 × 1,200 × 900 frames | 46.488 ms | 21.822 ms | 53.1% | Exact widened integer SIMD differences with identical early-exit checkpoints; bound framework temporaries to the stitch job. |

The final stitching comparison's median process peak RSS was **85.953 → 86.047 MiB** (about +0.1%); no memory reduction is claimed. This is a repeated fixture-process peak, not a retained-growth or whole-app memory measurement. Input/output limits and original source pixels remain unchanged.

The desktop had unrelated work running. Timing spread was substantial: the five stitching run medians ranged from 29.252–116.584 ms before and 10.753–33.382 ms after. All five paired stitching comparisons favored the candidate. The fixed CPU control's median moved by about 9.9%; the speed gain remained positive in every pair after normalization against that pair's control. Treat the numerical percentages as this lab's estimates, not guarantees for other Macs.

Raw run medians, samples, peak-RSS records and source/binary identities are in [the evidence directory](2026-10-13-evidence/) and [comparison-summary.json](2026-10-13-evidence/comparison-summary.json).

## Scope and behavior contracts

The final inventory contains 223 Swift source files and 89 Swift test files. The review mapped the package targets, product journeys, background services, main-actor work, file/network boundaries, timers, caches, image/audio pipelines, build scripts and existing tests. It combined broad source searches with focused implementation reads and runtime/benchmark evidence; it was not a manual execution of every feature or inspection of every source line.

Only five library files changed relative to the initial dirty checkout:

- `Clipboard/ClipboardEntry.swift`: exact hash spelling.
- `Clipboard/ClipboardStore.swift`: conservative budget fast path.
- `Context/ClaudeConversationReader.swift`: per-read date parser.
- `Annotation/AnnotationModel.swift`: equivalent hit selection.
- `Capture/ScrollingStitcher.swift`: equivalent matching and temporary-object lifetime.

The benchmark entry point was extended, one benchmark file and two regression files were added, and this report/evidence was saved. All pre-existing source edits were preserved. No UI/style, public API, schema, image/audio quality, model, polling cadence, debounce, retry, timeout, notification policy, permissions, or retention limit was intentionally changed. No commits, staging, pushes, deployments or external messages were performed.

| Area reviewed | Evidence / disposition | Remaining proof boundary |
|---|---|---|
| Launch and readiness | AppDelegate/AppCoordinator startup, directory/recovery/retention work, store initialization; measured clipboard load improvement; rebuilt app launched. | No complete cold-launch budget for a large real user library or other hardware. |
| UI interaction and navigation | Root/island/window/input paths and observation wiring inspected; measured annotation selection; Capture/Now Playing navigation and call-panel controls checked through native accessibility state. | Every window, display configuration, input gesture and accessibility mode was not exercised. The native panel screenshot returned a blank capture, so no visual-parity screenshot claim is made. |
| Animation, rendering and GPU | Shared motion, Reduce Motion, timelines and Core Animation meters inspected; Time Profiler and SwiftUI traces attempted. Timing and appearance policies were preserved. | No verified FPS, hitch-rate, GPU-energy or active-call performance gain. SwiftUI update export contained no usable rows. |
| Capture and scrolling | Frozen/shareable inventory, capture recipes, cancellation, limits and recovery traced; exact SIMD/tail tests, stitching suite, release fixtures and signed screenshot self-test passed. | Real animated web pages, unusual display scales and every capture target remain unmeasured. |
| Annotation, privacy and still export | Model/renderer/worker/export paths inspected; stable ties/extreme orders, redactions, serialization, undo, geometry and export tests passed; existing render/export benchmarks passed. | No render-quality reduction or renderer speedup was introduced or claimed. |
| Comparison, thumbnails and inspection | Existing decoded-plane reuse, SIMD comparison, tiny pixel-sampler reuse and image bounds inspected; comparison/thumbnail benchmarks and tests passed. | Full live slider/input pacing and large retained sessions were not measured. |
| Recording, audio and post-processing | ScreenCaptureKit writer, meter queue, interaction timeline, joining, trim and export paths inspected; PCM representations/channels, cancellation, GIF/PDF and recording tests passed; playable signed recording produced. | Audio optimization rejected. Hardware microphone/system-audio recording, long recordings and all codecs were not comprehensively exercised. |
| Dictation and voice notes | Capture stream bounds, waveform/elapsed separation, local models, cancellation and insertion paths inspected; existing dictation/transcription tests passed. | No new model downloads or live dictated insertion into another app; no speech quality or inference speed change. |
| OCR, structured text and document tools | Vision actor, reading order, structured results, foreground-removal context and bounds inspected; existing suites and benchmarks passed. | No OCR/model/precision/language changes; all real document languages and sizes were not measured. |
| History, clipboard and persistence | Loader, search/cache invalidation, atomic write queues, retention/orphans, identity checks and Spotlight snapshots inspected; exact budget/pin/truncation/round-trip tests passed. | Disk-size/durability/privacy policies retained; no broad reduction in disk writes or real-library startup certification. |
| AI activities and conversations | Activity metadata caching, source/session limits, transcript privacy and history inspected; transcript speedup and concurrent/offset/fallback tests; AI/registry benchmarks passed. | Provider work/model speed was not changed or benchmarked. No transcript content was added to caches. |
| Background CPU, idle and energy | Power/audio/network/privacy/calendar/AI/focus/notification/wellbeing lifecycle and timer gates inspected; observed live process and recorded profiles. Event/poll/freshness policies retained. | CPU work reduction is not a battery-life result. The original call/media state changed naturally during the pass; those traces cannot support a controlled idle/call speedup claim. |
| Media and accessories | Backend selection, artwork decode/accent cache, queue/modes, lyrics cache/in-flight reuse, Bluetooth report bounds and cleanup inspected; existing suites passed; paused playback position remained unchanged during navigation. | Live provider/battery behavior and all installed players/accessories remain integration checks. |
| Transfers and networking | LocalSend streaming/progress, reachability callbacks, verified share snapshots/signing, weather/lyrics caches and opt-in gates inspected; local transport/control tests passed. | No real bucket upload, production/shared load test, service latency reduction or traffic/freshness policy change. |
| Files, shelf, extras and automation | Identity-safe file operations, thumbnails/Quick Look, conversion workers, bounded command output, URL/AppIntent validation and extras gates inspected; full suite and release benchmarks passed. | All real external helpers, receivers, Finder/Shortcuts and window-management combinations were not exercised. |
| Lock, system integration, permissions and recovery | Lock/display routing, OSD recovery lease, helper trust and monitor shutdown inspected; full regression suite passed; signed self-test retained Screen Recording access. | No comprehensive live lock/OSD/private-API/hardware compatibility certification. |
| Packaging and build efficiency | Release build, helper embedding, App Intents metadata and signature gates passed; same certificate/designated requirement and bundle version retained. | No dependency/compiler/target split, distribution release or smaller-shipped-size claim. The monolithic library still makes optimized rebuilds expensive. |

## Correctness and acceptance

The regression tests exercise exact truncated hashes, Unicode/control strings, all serialized clipboard fields, escaped-text budgets, pinned/unpinned trimming and row retirement, disk round trips, stable selection ties and extreme orders, SIMD tails and early exits, retained stitched images, timestamp offsets/fallback/concurrent reads, and mono/interleaved/planar PCM representations. Existing cancellation, recovery, privacy, rendering, persistence and integration suites remained green.

Acceptance required equivalent outputs/behavior, a practically useful latency reduction (10% target for retained experiments), and no material resource regression. Experiments were compared using frozen executables and the same harness/fixtures. Narrow changes were reviewed independently, with a second review limited to the changed index/pool portions. Both reviews found no actionable issue. Source hashes were rechecked against the reviewed candidate after packaging.

- `swift test --skip PasteboardRaceTests`: **1,004 tests / 167 suites passed**.
- Optimized full benchmark run: **100 groups, zero timed/warmup failures**, complete journal terminator. Historical `[before]` helper comparisons already present in the harness are not attributed to this pass.
- `Scripts/check_hygiene.sh` and `git diff --check`: passed.
- Release compilation and local signed app assembly: passed.
- `codesign --verify --deep --strict`: passed; designated requirement preserved.
- Bundle ID/version/build preserved: `com.notchshot.app`, `1.0`, `1`.
- Signed runtime self-test: Screen Recording granted; **320 × 200 PNG, 25,960 bytes**; **320 × 200 playable MP4, 1.61 s, 7,009 bytes**. Temporary outputs were removed by the self-test. No audio was requested.
- The prior GUI process was quit through its normal command, the newly signed build was launched, and Capture/Now Playing navigation and the expanded call panel were checked. The optimized app remains running.
- A final 12-second Time Profiler recording completed against the running candidate. Its sanitized [localization summary](2026-10-13-evidence/runtime-profile-summary.json) contains 132 running CPU samples. The changed call/media state prevents a controlled before/after claim from these app traces.

The existing deprecated `String(cString:)` warning in PrivacyIndicatorMonitor remains unchanged.

## Rejected experiments and measurement limits

The first annotation scan copied an optional `AnnotationElement` repeatedly inside the loop. Five comparisons showed a regression at 1,200 elements. Keeping only an integer winner index/order removed that cost; the final comparisons above are for the repaired version.

Using temporary stack storage for the audio buffer list measured about 3–13% slower across the first paired set. `AudioMeter.swift` was restored byte-for-byte to the initial source. The final mono/interleaved/planar audio controls remained within roughly 5% of baseline; no audio speedup is claimed. The added PCM tests were retained as useful contract protection.

The first faster stitch run showed a higher repeated-process RSS. A job-scoped autorelease pool was added and returned-image lifetime was verified. In the final comparable run, RSS was equivalent within the guardrail; this does not prove that the pool caused a memory reduction. The Allocations recording failed to attach to the standalone benchmark, so no allocation-stack or leak claim is made.

Operational note: the initial baseline command included the pre-existing `PasteboardRaceTests` suite, whose one test writes the general system clipboard. This was acknowledged during the work, and every subsequent suite run excluded it. Benchmarks use disposable fixtures without general-pasteboard writes or app-preference changes.

The stopping point is a completed broad performance pass: mapped categories have dispositions, justified experiments were validated or reverted, and the full checks, signed runtime smoke check and durable evidence are complete. Further work needs representative workloads for the unmeasured hardware/provider/UI/energy cases above. No safe, measured additional source change was established in those areas; their silence must not be read as proof of an app-wide plateau.

## Reproduction and checkpoints

Run `swift run -c release NotchShotBench performance-sweep` for the added workloads, `... stitch` for the full scrolling fixture, or omit the filter for the complete harness. Set `NOTCHSHOT_BENCH_RESULTS` to a fresh path for raw samples. Use fresh processes and alternating versions; preserve the 3 warmups, 15/9 timed iterations and fixture sizes. Avoid comparing raw timings across unlike desktop load or hardware.

The source baseline is commit `c3b3bba368dafade32289a20d6fa206ea9fb847f` plus the original dirty checkout, not the clean commit. The run checkpoint at `/var/folders/5q/5zgpxz0j15139j1bj7zvks2w0000gn/T/notch-performance-20261013-5nq87dq1` holds original source copies, the initial dirty diff/status, frozen baseline/candidate executables and the previous signed app at `previous-installed.app`. Only this pass's delta and sanitized measurement/log artifacts were copied into the evidence directory. Raw Instruments traces, which can include process environment, were kept outside the repository.
