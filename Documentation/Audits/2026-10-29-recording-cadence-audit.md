# Recording cadence controls — 29 October 2026

The historical 26.1 fps result did not repeat in a lower-load, profiled 15-minute
control: it recorded **29.28 fps**, including after the old ten-minute transition.
An independent uninstrumented long control remains **pending an unlocked Mac**.
No production cadence fix or causal explanation for the historical stalls is
claimed. This pass confirms and fixes a benchmark session-validity gap.

## Protocol and identity

Starting revision: `e34e317`; initially clean. Production `RecordingService` is
unchanged, SHA256 `7cb12d32…8e88`. Completed controls used the prior signed audit
binary and Swift fixture `39f10753…3ca`, using the same real `SCRecordingOutput`
pipeline, 1280×720 generated window, 30 fps setting, no cursor or audio.

Hardware: Apple M5, ten CPU cores, 16 GB RAM, built-in 2560×1664 display;
macOS 26.7.2. Battery power and Low Power Mode off were observed. `pmset` reported
no thermal/performance warning before/after; processor/GPU clocks were not logged.
These are Debug-library, physical-Mac experiments, not Release or field proof.

Each capture uses a new owner-only temporary directory. Setup/builds precede
recording; decoding follows it. No deliberate competing build, encoding, or
second audit recording overlaps these controls. Other user applications remain
running. Before capture, three consecutive five-second host CPU windows must
report at least 80% idle. All subsequent host samples are kept; passing that
preflight does not establish exclusive or continuously idle host conditions.

Primary metric: encoded video samples divided by actual container duration.
Ten-second margins also give a steady-window density; presentation-time gaps,
first/last three-minute windows, and minute bins detect stalls and duration effects.
The helper's nominal timed waits accumulate overhead, so actual media duration,
not the requested duration, is the denominator. No hardware FPS threshold is
added to CI. A meaningful comparison requires the same active-content workload;
a low sample count alone does not identify an encoder defect.

## Observed outcomes

| Trial | Actual duration | Whole-file fps | Largest PTS gap | Gaps >100 ms | Host idle median |
|---|---:|---:|---:|---:|---:|
| Historical mixed-work session | 1,852.285 s | 26.096 | 250 ms | 1,170 | Not measured |
| Uninstrumented pilot 1 | 185.975 s | 29.337 | 50 ms | 0 | 76.7% |
| Uninstrumented pilot 2 | 186.150 s | 28.321 | 2,293 ms | 7 | 80.6% |
| Extended control, two five-second thread samples | 934.132 s | 29.279 | 68.334 ms | 0 | 85.0% |

All three completed controls finalized with `hasActiveSession=false`, were
AVFoundation-playable, and fully probed/decoded without diagnostics. The extended
file has 27,350 video frames. Its first/last three-minute densities are
29.335/29.235 fps. In contrast, the historical file's first three minutes are
29.382 fps, with the sustained approximately 24 fps section beginning around
minute ten. Thus short controls alone were insufficient to investigate the old
aggregate, and no inherent ten-minute degradation appeared in the extended run.

The second pilot is retained, including its 2.293-second gap. It is not a clean
constant-cadence success. Host idle briefly reached 59.5%; correlation is not a
causal diagnosis. The extended run's host idle median was 85.0%, mean 82.4%, with
nine of 185 logged windows below 70% and a minimum of 0.84%. These are mostly-idle
controls with interruptions, not a perfectly isolated machine. Its host samples
span the process lifetime, including a final partial/post-capture window.

Early/late five-second `sample` traces found capacity checks in 34/3,833 and
45/3,812 main-thread samples, respectively (about 0.9%/1.2%). Most main-thread
samples were event-loop waits. These snapshots do not support a sustained
250 ms-per-second main-thread capacity stall in this control; they do not rule
out rare stalls outside their intervals. Sampling is itself instrumentation,
which is why the separate uninstrumented long control is still required.

Apple defines [`minimumFrameInterval`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval)
as an update-rate ceiling, not a fixed-rate encoder promise. This explains why
exactly 30.000 fps is not the acceptance oracle, but does **not** diagnose the old
stalls. Apple also supports occluded/offscreen desktop-independent window
capture ([WWDC22](https://developer.apple.com/videos/play/wwdc2022/10155/)); this
pass does not blame plain occlusion or restrict production window capture.

## Confirmed benchmark defect and repair

The next uninstrumented attempt passed CPU preflight and kept reporting
`isRecording=true`, but its scratch file stopped growing at 92 KB. The test was
stopped through its verified controller; only its own child group was killed.
Its retained movie recovered as 34 frames / 1.288 seconds. The frame contains
the expected generated label and square. This proves downstream output did not
advance, not which upstream component stopped producing new content.

A subsequent attempt reported `noShareableContent` despite the established TCC
grant. CoreGraphics and I/O Registry then independently reported the desktop
locked, while the user remained on-console. The exact lock transition was not
logged in the old fixture, so it is not retroactively assigned as the cause of
either the historical 26.1 fps or the short pilot's gap. That attempt is invalid
for a cadence conclusion, rather than a low-FPS product result.

CPU-only preflight and `isRecording` were insufficient validity gates. Repairs:

- The controller checks desktop session state before preflight, immediately
  before launch and during capture. A lock/unavailable session invalidates the
  run, stops only the owned group and retains its scratch files.
- A controller-owned `caffeinate -d -i -w` assertion spans preflight and inter-run
  gaps. It changes no power preference, cannot unlock the Mac, and does not
  defeat manual/policy locking. Native helper guards also reject an unavailable
  desktop at start/completion; no new main-thread polling is added during capture.
- The helper logs its own window visibility, minimization, active-space, key and
  application state plus animation attachment. None alone proves compositor
  delivery. The experimental activation idea was not retained or claimed tested.
- Host samples after child exit are marked `postCapture`, not classified as a
  lock during recording. The analyzer includes held boundary frames in its FPS
  denominator and reports boundary gaps; it refuses ambiguous/invalid timestamps
  and verifies native H.264 packet counts against decoded frame counts.

The observed `CGSSessionScreenIsLocked` entry is a Mac-specific diagnostic
signal, not a substitute for TCC authorization. An absent lock entry is retained
as null in evidence rather than represented as an observed false value. Session
sampling can miss short transitions; a successful sample is not an authentication
or continuous-session guarantee. No other app was quit, no grant was reset, no
unlock was attempted, and no user capture/settings/History data was modified.

## Validation and reproduction

Ten deterministic Python tests pass, covering fixed/variable cadence, stalled
and held tails, invalid inputs, locked/off-console rejection, a lock between
preflight and launch, mid-capture ownership/retention, and post-exit phase handling.
The final Swift fixture compiles into a disposable signed bundle; strict signature
verification and the exact existing designated requirement pass. On the actual
locked Mac, the controller rejects before creating a run/capture, and the signed
native helper exits with code 3 before creating `InProgress`. Hygiene, Python
syntax and whitespace checks pass. No full Swift-suite rerun is claimed for this
script-only task; production Swift sources are unchanged.
An independent read-only High review found no blocking correctness, process
ownership or proof-boundary issue. The reviewer inspected sources and artifacts;
it did not rerun captures or tests.

Implementation: [controller/analyzer](../../Scripts/audit_recording_cadence.py),
[native fixture](../../Scripts/RecordingRuntimeAudit.swift),
[regressions](../../Scripts/tests/test_recording_cadence.py).

After unlocking the Mac, using the existing verified signing identity:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
python3 -B Scripts/audit_screencapturekit.py /tmp/notchshot-new-cadence-build \
  --app dist/NotchShot.app --identity "$NOTCHSHOT_AUDIT_SIGN_IDENTITY" --build-only
python3 -B Scripts/audit_recording_cadence.py /tmp/notchshot-new-cadence-control \
  --audit-app /tmp/notchshot-new-cadence-build/NotchShot.app --duration 900 --runs 1
python3 -B -m unittest discover -s Scripts/tests -p 'test_recording_cadence.py'
```

Build the debug package first with the toolchain flags in the
[initial audit](2026-10-28-app-audit.md). New output directories are mandatory.
Use `--sample-at 180 --sample-at 690` only for a separately labelled instrumented
run. Keep the generated fixture available and avoid other deliberate workloads.
Raw artifacts are private under `/tmp/notchshot-cadence-audit-2026-10-29/`;
movies, account/session dictionaries, and raw traces are not committed.

Remaining: the final uninstrumented long positive path and power-assertion
lifecycle require an unlocked desktop. The historical stall mechanism remains
unconfirmed. If a valid unlocked run stalls, a separately instrumented screen
sample-metadata observer is the next discriminator between upstream idle/blank
samples and writer failure. Release, native/4K/60 fps, audio, and multi-hour
coverage remain outside this batch. No application performance gain is claimed.
