# Actual ScreenCaptureKit interruption and endurance audit — 29 October 2026

Follow-up to the [isolated recovery audit](2026-10-29-recording-recovery-audit.md).
The [cadence controls follow-up](2026-10-29-recording-cadence-audit.md) investigates
the measured frame rate and records the locked-desktop validation gap.
This pass exercises the real `RecordingService` and `SCRecordingOutput`, replacing
the earlier synthetic-media-only evidence for the checked interruption schedules.
It does not repeat the app's UI/History publication journeys.

## Scope and isolation

- Starting task revision: `977d545`. The separately committed agent-card change
  `9a2ddaf` and notification change `b70a998` are outside this audit and preserved.
- macOS 26.7.2, arm64; debug library objects linked into a private audit executable.
  Its disposable app bundle passes strict nested signature verification and has
  the exact existing app's designated requirement. Screen Recording preflight
  succeeds without requesting/resetting permissions or changing signing identity.
- Only a generated 1280×720 animated fixture window is recorded, at 720p/30 fps.
  Microphone, system audio and cursor capture are off. No user desktop pixels or
  audio are part of the fixture. Test roots are newly created with mode `0700`.
- The original app stays running. Its bundle, preferences, History and recordings
  are not changed by the audit. The harness bypasses app/coordinator startup and
  injects only a private scratch directory into the real recording service.
  The public `start` route retains the original permission/preparation ordering.
- Acceptance: kill only the spawned audit process; recover through production
  validation/move logic; compare settled bytes and decode the resulting movie;
  run a sustained session, finalize it, and inspect duration, all video frames,
  process resources, and session teardown. The sustained target is 30 minutes.
  A controller time budget and 2 GB free-space reserve bound the run.

## Executed results

| Actual writer case | Evidence |
|---|---|
| Abrupt client SIGKILL after about 30 seconds | Child exits with signal 9. Recovery produces a playable 32.542-second H.264 MP4, 1280×720, 956 frames, 4,574,932 bytes. SHA256 is unchanged by recovery. Full decoding succeeds with empty diagnostics. |
| Early SIGKILL two seconds after start, final candidate | After file settlement, recovery produces 2.225 seconds / 65 frames / 211,541 bytes. SHA256 is unchanged, the scratch source is gone after the successful move, and all frames decode without diagnostics. |
| Healthy short control, final candidate | 62.103 seconds / 1,822 frames / 8,804,478 bytes; playable, `hasActiveSession=false`, full decode without diagnostics. |
| Sustained recording | 1,852.285 seconds (30 min 52 s), 48,338 frames, 237,252,728 bytes. Playable H.264 at 1280×720; full probe/decode exit zero with empty diagnostics, private scratch empty, `hasActiveSession=false`. Early/late extracted frames show the generated fixture; seven late frame samples have seven distinct checksums. |

The long session collected 370 process samples over 1,849.97 seconds. After
the first minute, resident memory ranged from 21,728 to 37,648 KiB and ended
at 23,376 KiB; client CPU snapshots had a 1.3% median and 8.8% maximum.
These are resident/client samples, not total encoder/GPU allocations or a proof
of leak freedom. Finalization plus the subsequent playable check took about
0.091 seconds, measured between the last pre-stop progress write and completion.

The configured 30 fps is a cap: observed mean cadence was 26.10 fps, with a
maximum adjacent presentation-timestamp gap of 0.250 seconds. No gap exceeded
that value. Builds and additional isolated capture controls ran during parts of
this session. This is **not** evidence of constant 30 fps; the source of cadence
variation is unconfirmed and needs a quiet-machine comparison before attributing
it to the app. The test loop's timed waits also accumulated about 52 seconds of
overhead beyond its nominal 1,800 seconds; the recorded duration is reported above.

An initial early-kill measurement hashed immediately after `waitpid` and saw a
changed hash after recovery. A follow-up captured the file itself growing from
209,836 to 219,463 bytes within 0.105 seconds after client exit. The harness now
waits for two seconds of stable inode/size/mtime, bounded by 15 seconds, before
its integrity snapshot. This corrects the audit measurement; it is not a
production writer-synchronization fix. The successful integrity claim applies
to settled bytes, not every byte present at the instant of SIGKILL. No lost or
corrupted footage was demonstrated by that initial mismatch.

Decoder checks use `-fps_mode passthrough -enc_time_base demux`. A null-output
muxer with a guessed fixed frame rate produced DTS rounding messages; preserving
the source time base removed those messages. Zero exit status alone is not the
acceptance check: stderr must also be empty.

No new production recorder defect is confirmed in the completed checks. The
source change is an internal test seam, with public behavior preserved, plus
opt-in runtime tools. It does not change the capture backend or recovery format.

## Validation and evidence

- Focused recovery regression suite passes; its two desktop/media integrations
  remain opt-in and were not enabled in this run.
- Final compiled suite reports **1,212 tests / 200 suites passed in 29.753 seconds**,
  excluding clipboard-mutating `PasteboardRaceTests`. It includes `b70a998` plus
  this audit's final service source. The two opt-in fixture/Trash unit integrations
  are disabled; the separate signed ScreenCaptureKit runs above are executed.
- Repository hygiene, Python syntax and whitespace checks pass.
- An independent read-only High review of the frozen service, harness,
  controller and runtime evidence found no actionable issue. The reviewer
  inspected artifacts and did not rerun the captures or test suite.
- Raw private artifacts: `/tmp/notchshot-sck-audit-2026-10-29-run2/` and
  `/tmp/notchshot-sck-early-settled-2026-10-29/` and
  `/tmp/notchshot-sck-final-control-2026-10-29-run2/`. Movies and raw runtime logs are
  not committed. An initial signing-check parser refusal occurred before capture;
  it was corrected to compare only the designated-requirement line.

The long run used service SHA256 `2e0ba0b8…c6`. The final source is
`7cb12d32…8e88`: its only difference removes an extra root-policy check introduced
with the isolation seam, restoring the original public directory acceptance.
That condition accepted this run's private directory in both versions. Writer,
meter, stop and recovery implementations are identical. The final source was
rebuilt and the signed early-kill/short controls and full suite rerun. The Swift
fixture is `39f10753…3ca`, and controller `88d382de…c65c`.

Sources: [recording service](../../Sources/NotchShotKit/Recording/RecordingService.swift),
[Swift fixture](../../Scripts/RecordingRuntimeAudit.swift),
[controller and media checks](../../Scripts/audit_screencapturekit.py).

## Reproduction

Build the debug package using the CLT/plugin/Testing flags in the
[initial audit](2026-10-28-app-audit.md). With installed FFmpeg/ffprobe and Python
3.11+, pass the existing signed app and its verified signing certificate:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
python3 -B Scripts/audit_screencapturekit.py /tmp/notchshot-new-sck-audit \
  --app dist/NotchShot.app --identity "$NOTCHSHOT_AUDIT_SIGN_IDENTITY" \
  --duration 1800 --interrupt-after 2
```

The directory must not exist. No test process receives a new TCC grant. A missing
permission is reported as a blocker. Only controller-owned child processes are
signaled; failed outputs stay in the private tree for inspection.

## Explicit limits

- Client-process interruption is checked. OS/media-service crashes, power loss,
  actual disk exhaustion, volume removal and destructive failure testing are not.
- Thirty minutes at this configuration does not prove multi-hour, native/4K/60 fps,
  audio/microphone sync, or cross-volume endurance. No claim of leak freedom or
  energy efficiency follows from resident-memory samples of one process; system
  capture/encoder services and GPU memory are outside those samples.
- Large recordings approaching the existing 20 GB owned-file admission limit
  remain untested. The app's UI recovery prompts and History insertion were not
  driven in this isolated pass.
- No signed Release/distribution artifact is rebuilt or installed by this pass.
