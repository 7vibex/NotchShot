# NotchShot performance pass — 20 October 2026

Conversation parsing now selects the newest 80 visible messages before processing older discarded rows. Five alternating pairs of optimized executable runs measured **56.685 → 5.140 ms (90.9% lower latency)** for a synthetic 1,500-message transcript. Every pair improved. Visible outputs, ordering, identifiers, privacy filtering and input limits remain covered by regression checks.

This is a bounded follow-up performance pass, with one retained optimization. It does not establish a whole-app speedup, conversation-view readiness time, battery-life improvement or app-wide performance plateau.

## Results and decision

Each value below is the median of five fresh-process run medians, on an arm64 Apple M5 MacBook Air with 16 GB RAM, macOS 26.5.2 and Swift 6.3.3. Each group performs three untimed warmups and nine timed reads. Baseline/candidate order alternates between pairs. All results include the completed synchronous parser call; fixtures and output validation are outside timing.

| Synthetic workload | Before | After | Interpretation |
|---|---:|---:|---|
| 20 visible messages | 0.725 ms | 0.739 ms | +0.014 ms / 2.0%; short-path equivalence is inconclusive under the observed noise. |
| 80 visible messages | 2.859 ms | 2.682 ms | 6.2% lower aggregate median; no short-path speedup claim. |
| 1,500 visible messages | 56.685 ms | 5.140 ms | 90.9% lower latency; improved in all five pairs. |
| 1,500 messages with 1,800 extra text characters each | 141.624 ms | 46.607 ms | 67.1% lower latency; improved in all five pairs. |
| 1,500 visible messages followed by 6,000 ignored nonempty rows | 77.313 ms | 22.793 ms | 70.5% lower latency; ignored rows still require validation until 80 visible messages are found. |
| Unchanged fixed CPU control | 7.617 ms | 8.104 ms | 6.4% higher aggregate median; indicates background-load noise. |

For the primary 1,500-message fixture, baseline run medians ranged from 52.652–78.372 ms and candidate medians from 4.703–9.186 ms. Paired reductions ranged from 88.3–91.2%. The five independent pairs give useful directional evidence for the large effect; they do not establish tail latency or a population confidence interval. No runs were discarded or repeated to obtain a favorable result.

Short-path paired results were noisy: 20-message medians ranged from 0.647–1.025 ms before and 0.676–1.630 ms after. The predeclared aggregate-median guardrail of no more than 10% regression was met, but the sample does not prove equivalence within 10%. No claim of faster short conversations is made.

The median process peak RSS for the complete fixture sequence was **99.391 → 49.000 MiB**, below the guardrail of a 10% increase plus 2 MiB. This includes framework temporary objects across repeated reads and fixture creation in one synthetic process. It is not a retained-memory, leak, real-session footprint or whole-app memory claim.

Raw per-iteration timings, run ordering, RSS, source/binary fingerprints and the frozen protocol are in [measurements.json](2026-10-20-evidence/measurements.json). All 60 group summaries were valid, all 540 timed iterations succeeded, and every journal ended normally.

## Cause and preserved contract

`ClaudeCodeActivityView.reload()` already reads the conversation off the main actor. The original reader nevertheless decoded JSON, extracted visible text and parsed timestamps for every eligible row, retaining only the last 80. Baseline sampling localized substantial work to `NSISO8601DateFormatter.dateFromString` and ICU parsing. The competing explanation was input scanning/JSON cost; the large-text fixture and candidate sample show whole-input string splitting remains a substantial cost after the change.

The intervention is confined to `ClaudeConversationReader.messages(from:)`:

- Validate the complete input's existing 4 MiB limit and UTF-8 encoding first.
- Enumerate nonempty lines before traversing backward, preserving original fallback line IDs.
- Apply the existing extraction and privacy rules until 80 visible messages are selected. Malformed JSON, metadata, hidden reasoning, tool results and invisible commands do not consume visible slots.
- Restore original message order, then parse timestamps with one formatter owned by the read. Missing/invalid timestamp fallbacks are evaluated in forward order.

Duplicate IDs, text limits, tool labels, timezone handling and concurrent reads remain covered. File lookup, file access, caching, permissions, UI/layout, polling, notification and freshness policies are unchanged. The reader still validates the full input and scans its string to split lines; the change does not claim constant time with respect to file size.

The sampling captures are separate from the timing campaign and cannot establish a sample-count speedup. An Instruments launch recording saved a trace but exported no CPU sample rows, so it was excluded. Ordinary `sample` captures of the owned synthetic benchmark processes supplied localization evidence instead. Only a sanitized [profile summary](2026-10-20-evidence/profile-summary.json) is retained in the repository.

## Checks

- Before changing production code, the new contract tests plus existing Claude session and performance-sweep tests passed: **15 tests / 3 suites**.
- Final `swift test --skip PasteboardRaceTests`: **1,066 tests / 173 suites passed**, including concurrent date parsing, mixed visibility, duplicate/fallback IDs, fallback timestamp order and whole-input rejection.
- The one excluded existing test writes to the general system clipboard. It was left unexecuted to preserve user data; the suite was not edited.
- `swift build -c release`, the release benchmark build, hygiene and diff whitespace checks passed. Existing `String(cString:)` deprecation warnings remain.
- The existing performance sweep completed all 10 groups with no warmup/timed failures. Its unrelated groups are smoke checks, not additional speedup claims.
- An independent read-only review of the frozen reader, benchmark and test changes found no actionable correctness or privacy findings. The reviewer inspected the primary's build/test evidence; it did not rerun checks independently.

Commands, review scope and unexecuted proof lanes are recorded in [checks.json](2026-10-20-evidence/checks.json). No live personal transcript, general clipboard write, production/shared load test, model/provider call, app replacement or deployment was used for the experiment.

## Coverage and remaining leads

Discovery sampled the current source rather than treating the earlier performance report as current runtime proof. Depth followed a bounded follow-up pass: one measured, attributable experiment, then reconciliation of remaining leads.

| Surface | Evidence sampled / disposition | Remaining check |
|---|---|---|
| Conversation loading | Reader, caller, extraction rules, tests, baseline/candidate sampling and release measurements; retained optimization. | Measure the complete loading indicator → usable conversation journey with a representative user-approved transcript. |
| Launch, history and clipboard | AppCoordinator startup/cleanup wiring; history search/load and serialized background write queue; clipboard polling gates; release clipboard sweep and regression suite. Existing caches and off-main writes are already present. | Cold launch with a large disposable library; no new launch or disk-I/O gain claimed. |
| Capture, annotation, comparison, recording | Stitch limits/SIMD matching, render-worker boundaries, comparison plane reuse, pixel-sampler reuse, recording entry points and audio RMS; existing sweep and regression coverage. | Actual capture completion, slider/gesture pacing, sustained recording and allocation traces remain unmeasured here. |
| Media activity | `MediaCoordinator.apply` writes position fields through the observable snapshot struct; AppCoordinator observes fields of the same snapshot and refreshes activity. Existing guards avoid repeated artwork/icon work. Source-only lead. | Count activity reconciliations on position-only updates and measure their cost before changing observation boundaries. |
| Bluetooth activity | Battery report actor has completed-result caching/backoff, but no in-flight task sharing across suspension. Rapid route changes could duplicate a report. Source-only burst lead. | Inject a suspended report and prove overlapping reachable requests, identical shared results and invalidation semantics. No idle-energy claim. |
| Other system monitors | Privacy worker/listener teardown and generations, brightness sleep/preferences gates and Focus backstop gates inspected. Existing polling policies preserved. | Controlled idle/active CPU and energy measurements; intervals were not changed. |
| Memory | Repeated fixture-process peak RSS guardrail passed; no new persistent cache introduced. | Retained growth across actual open/close cycles, long-session allocations and leak diagnosis. |
| Network, remote services, dictation inference, packaging and size | No network/service/inference performance experiment; release package products compile. | Representative opted-in workloads and release-size analysis are deferred; no provider, quality, build-speed or shipped-size change claimed. |

The pass stops after the frozen five-pair experiment and final validation. The two independent background leads lack measured contribution to a user outcome, so changing them in this batch would not be evidence-backed. The highest-value next check is full conversation-view readiness; background leads need their own workloads and concurrency/observation guardrails.

## Reproduction

The new fixture group runs with:

```sh
swift run -c release NotchShotBench transcript-window
```

To reconstruct the comparison without altering a working checkout, export base commit `723fb1b96b00fe4e20aabbb6bd0cf33a7c8885b4` and the completed candidate into separate disposable directories. Copy the candidate's `TranscriptWindowBenchmarks.swift` and benchmark `main.swift` into the baseline export so both variants use exactly the same harness; leave the baseline library unchanged. Build `NotchShotBench` with `swift build -c release --product NotchShotBench` in each directory.

Run each executable in five fresh-process pairs, baseline first on odd pairs and candidate first on even pairs. Set `NOTCHSHOT_BENCH_RESULTS` to a fresh scratch JSONL path for each invocation and wrap it in `/usr/bin/time -l -o <fresh-resource-path>`. Require six valid summaries, zero failures and a closing `run_end`; retain all nine raw samples per group. Compare medians of the five process medians separately per workload. Do not pool the iterations as independent processes or aggregate unlike fixtures. Use the source and binary fingerprints in the evidence when assessing this recorded comparison.
