# Automated recording recovery audit — 29 October 2026

Follow-up to the [runtime audit](2026-10-28-runtime-audit.md), against `09ebb88`.
All media and filesystem tests use unique private temporary directories. No real
capture session, user recording, preferences, TCC grants or installed app bundle
was changed. Successful Trash checks leave only their own small disposable
checkpoints in recoverable Trash; no pre-existing Trash items were inspected.

## Confirmed fixes

- **R-017 / Medium: recovery accepted a redirected scratch parent.** The old
  candidate check compared lexical parent paths and rejected leaf symlinks but
  followed a parent-directory symlink. Recovery could therefore select and move
  a movie outside its managed scratch tree. The common candidate/identity gate
  now checks canonical containment with the existing ownership policy. An
  isolated valid-media test verifies rejection and unchanged foreign bytes.
- **R-018 / Medium: direct recovery ignored deliberate-discard markers.** The
  orphan scanner filtered markers, but candidate admission and direct recovery
  accepted marked files. Both now reject the marker, including the identity
  recheck after asynchronous metadata validation. A retained discard is no
  longer eligible for recovery, and direct recovery leaves it untouched.

Source: [RecordingService](../../Sources/NotchShotKit/Recording/RecordingService.swift).
Public signatures are unchanged. Internal directory/destination and Trash
operation seams run the production validation, move/copy and discard disposition
against isolated fixtures. Live cancellation retains its previous stop/finalize
lifecycle and delegates only its existing disk-disposition step to the helper.

## Executed evidence

| Case | Result |
|---|---|
| Pre-fix gates | Four failed assertions across redirected-parent, marked-file/direct recovery and retained-discard admission checks. |
| Invalid movie | Recovery rejects it and preserves both source bytes and the existing destination. |
| Valid movie / occupied destination | Move/copy fails without replacing the existing document or losing source footage. |
| Concurrent recoveries | Both succeed at different unique destinations; naming occurs after validation, immediately before the synchronous move on the main actor. |
| Real Trash | The test-created file moves to actual macOS Trash; bytes are identical there, with no source remaining. The checkpoint is retained. |
| Trash denied | The entire file moves to the isolated retained-discard directory. |
| Trash and fallback denied | Source bytes remain, an exclusion marker is written, and recovery admission rejects the source. |
| Abrupt writer interruption | A private FFmpeg H.264/AAC fragmented-MP4 writer is killed after five seconds. Its surviving file is 4.032 s / 262,172 bytes. Production recovery accepts it as AVFoundation-playable, moves it without changing bytes and preserves available footage. |
| Continuous encode | A real-time writer runs for 119.64 wall-clock seconds, producing 120.021 s / 8,072,157 bytes. Production recovery succeeds; FFmpeg decodes all 1,800 video frames with no diagnostics. |
| Long timeline | A native AVAssetWriter sparse 10,800-second fixture recovers with the full three-hour duration and identical bytes; repeated recovery of the moved source is rejected. This is 11 frames and does **not** simulate three hours of sustained load. |

The abruptly interrupted file is not a clean whole-file decode: FFmpeg reports a
partial trailing AAC packet, even though AVFoundation reports it playable.
Recovery preserves the supplied bytes; it does not remux or repair a damaged
tail. Decoder exit status zero alone is not treated as error-free validation.

Ten focused tests pass, including both environment-gated integrations. The full
suite passes **1,209 tests in 200 suites in 29.107 seconds**, with
`PasteboardRaceTests` excluded. Debug compilation succeeds through the existing
per-command CLT/plugin/Testing-framework paths documented in the initial audit.
Repository hygiene, Python syntax and whitespace checks pass.

An independent read-only High review identified an early destination-selection
race in the initial test-seam refactor. It was corrected before completion with
a deferred destination provider and a concurrent-recovery regression. The
second review found no new actionable issue. Its frozen hashes begin
`144e1a5bad50` (service), `28a997235849` (new tests), and `bde8539f08a1`
(existing video-fixture helper). No review verdict is claimed for later code.

## Reproduction

The normal suite covers deterministic temporary-file cases. Real Trash is
opt-in to avoid imposing a desktop Trash requirement on normal CI. The supplied
media integration is also opt-in and requires installed FFmpeg/ffprobe:

```sh
python3 Scripts/audit_recording_media.py /tmp/notchshot-new-recovery-fixtures
NOTCHSHOT_RECOVERY_FIXTURES=/tmp/notchshot-new-recovery-fixtures \
NOTCHSHOT_RECORDING_DISCARD_INTEGRATION=1 \
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
swift test --skip-build --no-parallel --filter RecordingRecoveryAuditTests
```

Build first with the toolchain flags in the [initial audit](2026-10-28-app-audit.md).
The generator requires a new directory and serves no network content. Raw
local logs and probes for this execution are in
`/tmp/notchshot-recovery-audit-2026-10-29/`; no captured user media is committed.

## Remaining limits and risks

- This does not kill the user's app or exercise an actual interrupted
  ScreenCaptureKit writer. Other non-playable crash fragments remain on disk
  for recovery; successful metadata validation is not exhaustive decoding.
- Two minutes of continuous synthetic encoding and a sparse three-hour timeline
  do not prove hours of physical capture, energy/memory stability, audiovisual
  synchronization, or very large-file usability. Owned-file byte limits and
  long hardware sessions require separate validation.
- Filesystem failure injection covers selected deterministic failures, not
  adversarial replacement schedules, actual disk exhaustion or power loss.
- A failure to write an exclusion marker as well as move the file still relies
  on the existing truthful retained-file warning; this pass does not simulate
  every combination of permission, volume and writer-finalization failures.
- No new signed Release bundle or distribution artifact was installed. The
  app already running on the Mac was left undisturbed.
