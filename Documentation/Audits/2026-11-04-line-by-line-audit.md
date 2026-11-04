# Line-by-line audit, 4 November 2026

Base commit `29d87cc`, branch `codex/liquid-glass-notch`, macOS 26.7.2, arm64.
Fixes in `e611fe4`; Sparkle moved from 2.9.6 to 2.10.1 in the commit after it (M-08).

The request was a literal line-by-line review of the whole app, combined with
scanners and runtime checks, followed by fixes. It also asked about brief freezes
("freezes for a bit").

## Coverage

| Technique | What it covered |
| --- | --- |
| Reading every line | All of `Sources/`, `Resources/`, `Scripts/` and the package files, in 12 batches (A–M). Each file was opened and read first line to last; each batch has a coverage table. About 100,000 lines. |
| Scanners only | `Tests/` (about 29,500 lines) was covered by jscpd and Periphery, **not read line by line**. |
| Duplicates | jscpd: 10 clones, 0.26%. |
| Unused code | Periphery 3.8.0: 172 unused, 50 assign-only, 521 redundant `public`. Redundant `public` was left alone. Everything flagged in `NotchShotAIReporter/main.swift` is a false positive from top-level code. |
| Runtime | `sample` of the live app, system logs and hang reports, small probes of Core Audio, disk capacity and `NSUpdateDynamicServices` costs, and `NotchShotBench` old against new. |
| Review of the fixes | Four adversarial read-only passes over the finished diff, then a repair pass over what they found. |

298 findings: 21 high, 94 medium, 183 low. By kind: 116 bugs, 82 freezes,
48 performance, 15 dead code, 12 data loss, 10 security, 8 concurrency,
4 duplicates, 3 build. 204 were confirmed from the code, 75 likely, 19 red flags.

Outcome across the eight fix teams: 281 fixed, 2 rejected as wrong, 18 deferred.
Three IDs appear twice, because a second team finished what the first handed off.
The full ledger is at the end of this file.

## The freezes

**No hang report for NotchShot exists in the system logs**, so no single logged
event identifies the cause. What the reading found is many separate main-thread
waits, each short enough to read as "freezes for a bit". The Mac itself makes them
worse: 16 GB of RAM, swap at 17–20 GB, and load averages from 30 to 280. Calls to
system daemons that normally take a millisecond take hundreds under those conditions.

Everything below moved off the main thread.

| Path | When it ran | Cost on main | Basis |
| --- | --- | --- | --- |
| Volume and mute keys: Core Audio reads | Every press and repeat | p50 53 ms, p95 443 ms, max 551 ms | Measured in a probe of the same read pattern |
| Disk capacity while recording | 1 Hz for the whole recording | p50 78 ms, p90 294 ms, max 800 ms | Measured |
| Brightness read over XPC | 5 Hz | About 3.75 ms per read | Measured live |
| Stop recording, Save As, Move, stack export | Per action | Whole file copy: seconds for a large recording | Derived from file size |
| Clipboard payload read | Every copy | Waits on the app that owns the clipping | From the code |
| Dictation insert (Accessibility) | Every insert | Waits on the target app's main thread | From the code |
| Crewline refresh | Up to about 2 Hz in a busy run | 30–150 ms | Estimated |
| Audio output listing when the player opens | Each open | Several Core Audio calls | From the code |
| Notification mirror | 2.2 Hz | Accessibility calls | From the code |
| Shelf app lookups in `body` | Each shelf evaluation | Up to 6 LaunchServices lookups | Estimated |
| Root view recomputation | Each pass | About 240 display checks and 40 layouts | Counted |
| Notes rewrite, history writes | Per keystroke, per change | Synchronous file writes | From the code |

**These fixes have not been seen on the running app.** Whether the freezes are
gone can only be told from use, so the app now logs them: `MainThreadStallLogger`
writes a line for every main run-loop pass of 100 ms or longer, at the cost of two
clock reads per pass and no timer.

```bash
/usr/bin/log show --last 1d --predicate 'subsystem == "com.notchshot.app" AND eventMessage BEGINSWITH "Main thread busy"'
```

## The most serious other bugs

- **E-02, data loss.** Recovering from a corrupt `history.json` could permanently
  delete every file in `Captures/` and `Recordings/`, because the sweep treated them
  as untracked. A corrupt store now places a durable hold on cleanup.
- **E-01, crash.** Duplicate custom words crashed the whole app at the start of dictation.
- **B-02, data loss.** Joining a paused recording could drop an audio track when
  system audio and the mic were on separate tracks.
- **A-04, privacy.** A pixelate placed over a blackout could bring back the pixels
  under the blackout.
- **A-02.** An unbounded bitmap request of 6–30 GB is now refused.
- **D-01, L-01, L-07.** The click region did not match what was drawn, so the buttons
  of a scrolling capture could not be clicked.
- **D-06.** `ExtrasPreferences` wrote preferences just by being created.
- **G-06, G-07.** A sibling event could clear an approval card, and a hook that gave
  up left its card behind.
- **H-04, H-09, H-10, H-05, H-11.** Reporter failure modes, and secrets the redactor missed.
- **F-05.** The Music queue script never compiled.
- **G-10, G-11.** The HTML summary parser is now bounded.

## Dead and copied code

About 950 lines of dead agent UI were removed, plus the unused declarations each
team's ledger lists. Duplicate logic in dictation and recording was merged (E-31).
`jscpd` found little real copying, 0.26%, so this was never a large problem here.

## Verification

- `swift build --build-tests`: passes. `./Scripts/check_hygiene.sh`: passes.
- **1,465 tests in 242 suites pass**: with `--no-parallel` at load 5, in four parallel
  runs at load 4–5, and with `--no-parallel` on Sparkle 2.10.1 at load 30–85.
- Parallel runs at load 50–97, from other work on this Mac, still fail timing-bound
  tests such as `PrivacyIndicatorWorkerTests` and the focus timer test. Those suites
  pass alone. Under that load single tests took 400 s of wall clock.
- Three flaky tests were traced and fixed in the tests themselves: an unchecked
  `[0]` in `SpotlightCaptureIndexTests` that crashed the whole run, and waits too
  short for a loaded machine in `ClipboardImageOverlapMeasurements` and
  `Standard 1x publishes matching pixels`. The last one also failed on the
  unmodified base.
- `HistoryThumbnailCacheTests` missed its cache on an unchanged file twice. The
  exact cause was not found: a probe showed no `NSCache` eviction, and 8 runs alone
  passed. A miss only costs a decode, so the test now requires a hit rather than a
  hit every time.

Not run: `WindowExclusionTests` (it shows windows, and needs the user's yes),
`PasteboardRaceTests` (general clipboard), `idleClientsRecover` (flaky socket test).

### Benchmarks

`NotchShotBench` from the base commit and from this tree, taking turns, minimum
per run, median of 3 rounds (7 for the last group). Timing on this Mac is noisy:
`[before]` rows run identical code in both builds and still moved by up to 197%.
Instruction counts are the steadier signal where they exist. **The bench does not
exercise most of the freeze fixes**, so this is a guard against regressions, not
evidence the freezes are gone.

| Benchmark | Base | Now | Note |
| --- | --- | --- | --- |
| `history.save` 5,000 rows | 121 ms | 60 ms | |
| `history.load` 5,000 rows | 230 ms | 220 ms | Within noise |
| `stitch` 8 frames | 64 ms | 17 ms | |
| `annotation.render` 120 elements | 29.0 ms | 27.3 ms | |
| `annotation.render` 40 with redactions | 17.5 ms | 13.7 ms | |
| `capture.encode` PNG | 56.8 ms | 58.1 ms | Within noise |
| `ai.activity` 500 files, current | 11.09 M instr | 11.15 M instr | +0.6% |
| **`annotation.hitTest` 120, per call** | 0.6 µs | 57 µs | **Intended**, see below |
| **`annotation.hitTest` 1,200, per call** | 4.6 µs | 490 µs | **Intended** |
| **`clipboard OCR budget` 500 rows** | 0.016 ms | 0.33 ms | **Intended** |
| `export.render` 3456→1600 | 0.54 ms | 0.76 ms | Not explained, off main |
| `island.present` 8 activities | 12 µs | 16 µs | Not explained; that diff only removes code |

Hit testing now measures the text it draws, so text can be clicked where it appears
(A-22). It runs once per click. The clipboard budget now computes a bound before
choosing to encode, once per OCR result. Neither is worth more code.

## Behaviour changes to confirm

These are deliberate, but a person may want a different choice:

- `StopFailure` shows as waiting, not failed.
- Return on an approval card does nothing for its first 500 ms.
- Foundation Models errors fall back to an extractive summary instead of an error.
- HTML summaries use a byte parser instead of WebKit. A UTF-16 file shows its tags as text.
- Crewline stream subscriptions retry with backoff.
- The gesture monitor runs with "Swipe between activities" off, so track swipe,
  pull-to-open and timer minutes still work.
- The first capture after a network share drops goes to Desktop until the share mounts.
- A dictation toggle is refused during an active recording.
- `Scripts/build_app.sh` exits 3 if the designated requirement changes, since that
  would lose permissions, unless `--allow-permission-loss` is passed.
- Save As shows no progress while it copies.
- Capture and recording shortcuts are ignored while a capture dialog is open.

## Deferred: decisions for a person

| ID | Choice |
| --- | --- |
| A-17 | When a scrolling capture hits its limit: truncate with a warning, or fail and keep the frames |
| H-13 | With AI Activity off: remove the installed hooks, or write a `.disabled` marker the reporter checks |
| M-10 | Run CI on this branch (costs runner minutes per push), or stay on `main` only |
| M-12 | Focus Status has no signing path here: remove it, or keep it for a provisioned build |
| J-15 | The clipboard row's ticking age, or a coarse one that goes stale |
| K-14 | Lyric rows ease their blur over 0.3 s (an offscreen pass per row), or sharpen at once |

Deferred for other reasons: K-16, F-14, D-13, E-26, A-27, A-29, A-34, L-17, E-28.
`CrewlineCredentialStore.save` keeps `SecItemUpdate`; whether it re-prompts on an
ad-hoc rebuild needs a test across two builds.

## Not verified on the running app or hardware

Nothing here has been watched on screen, and the live app was not relaunched.
The list that matters most:

- Volume, mute and brightness keys on built-in, Bluetooth and USB outputs, and key repeat.
- Quit dialogs, and quit during a file copy or a failing recording.
- B-02: record with system audio and mic, pause, resume, stop, then check both
  sources and the track layout.
- Dictation against real apps, especially Electron and Xcode, at the 2 s Accessibility timeout.
- Off-main reads of the general pasteboard with a hung source app. `NSPasteboard`
  has no documented thread-safety guarantee, so the monitor's reads go through one
  serial queue.
- `CBBlueLightClient` off main, likewise undocumented; it is on one serial queue.
- Editor gestures A-13, A-14, A-22; zoom look B-10; seam markers A-03.
- Launch under Apple Development with the Calendars entitlement (M-01).
- Notification mirror end to end, LocalSend with a real receiver, reporter hooks and Crewline live.
- Permission and question cards with parallel subagents in a real Claude Code session.

## Corrections made to the team ledgers

The ledger below records what each team did. These entries were changed afterwards:

- E-02: the hold comes from a marker written when corruption is detected, not from
  an old `corrupt-*` sibling, which would have started it on any past failure.
- E-04: the Accessibility timeout is 2 s, not 0.5 s. 0.5 s was too strict under load.
- E-31, H-15: listed as deferred by one team, then done from its handoff.
- M-08: Sparkle was bumped afterwards. No update has been installed through 2.10.1,
  since the app has no signed release yet.
- D-07: a share still mounts, through a detached `mountOutputFolder`; the main-thread
  read uses `.withoutMounting`.
- C-24: no new global shortcut on existing installs (`actionsPredatingInstalledDefaults`).
- G-series terminal jump: `AppleScriptExecutor`, not `osascript`, so Automation prompts
  still name NotchShot.
- H-27: ignoring SIGTERM is opt-in (`exitsOnTerminate`), not process-wide.
- FX5's removal of `ScreenGeometry.cocoaPoint` was used by Window Snap; the arithmetic was inlined.

## Ledger

`ID | outcome | what changed or why | files`

```text
A-01 | fixed | stack PDF/contact-sheet export runs detached over a snapshot of assets; `isExporting` blocks a second run; only exported ids are removed, so items added during the export stay | Capture/CaptureStack.swift, App/AppCoordinator+Shelf.swift, UI/ShelfContent.swift
A-02 | fixed | framing canvas is bounded by `AnnotationRenderer.canvasFits`; editor render throws "That framing would make the image too large"; a recipe falls back to the unframed image with a warning | Annotation/AnnotationRenderer.swift, Annotation/NotchShotPackage.swift, Capture/CaptureRecipe.swift
A-03 | fixed | seam markers no longer burned into exports; drawn only as an editor canvas overlay | Annotation/AnnotationRenderer.swift, Annotation/AnnotationRenderWorker.swift, Annotation/AnnotationEditorView.swift
A-04 | fixed | security: all pixelates are drawn first, blackouts after, so a pixelate cannot re-expose blacked-out pixels; regression test added | Annotation/AnnotationRenderer.swift
A-05 | fixed | Save Project goes through `beginImageAction` and the render worker off main; disabled while busy | Annotation/AnnotationDocumentController.swift, Annotation/AnnotationRenderWorker.swift, Annotation/AnnotationEditorView.swift
A-06 | fixed | inspector and comparison sessions built from an image decoded off main (`decodeImmediately`), with one display NSImage per session, so hover no longer goes back to the PNG decoder and body makes no new NSImage. `inspectorAccessibilityValue` still reads `hoverSample` in the body, which is only string formatting | Inspection/ImageInspector.swift, Comparison/VisualComparison.swift, Capture/SafeImageFile.swift
A-07 | fixed | `prepareRepresentations` runs detached at utility priority; source image dropped once all formats are cached. A probe showed the provider callback runs on main, so an uncached paste can still encode on main. Product choice left open: skip preparing above a pixel count, since this adds background CPU per copied capture | Capture/CapturedImage.swift
A-08 | fixed | inspector, comparison and editor disk loads run detached with `decodeImmediately`, comparison difference computed off main with a threshold recheck, `openOffMain(projectAt:)` added, custom-background file check off main. AppDelegate caller is HANDOFF 1 | Inspection/ImageInspector.swift, Comparison/VisualComparison.swift, Annotation/AnnotationDocumentController.swift, Annotation/AnnotationEditorView.swift, App/AppCoordinator+Shelf.swift
A-09 | fixed | comparison export and share are async: split draw and write run detached from a value `renderRequest`, errors reported on main, `isExporting` blocks a repeat. No new visible state | Comparison/VisualComparison.swift
A-10 | fixed | sticky footer appended once at the end of the composite, with `validateComposite` | Capture/ScrollingStitcher.swift
A-11 | fixed | blank joins align on a textured band found by `texturedBandTop`; confidence capped to half the warning level when no textured band exists | Capture/ScrollingStitcher.swift
A-12 | fixed | comparison handle offset, drag mapping and left/right arrow deltas now follow the split instead of moving against it | Comparison/VisualComparison.swift
A-13 | fixed | text-edit `.onChange` moved to the always-present status bar HStack, selection change ends coalescing, undo and redo close and reopen an open gesture | Annotation/AnnotationDocumentController.swift, Annotation/AnnotationEditorView.swift
A-14 | fixed | tap with Text/Step places an anchored point, with a `lastPointAdd` guard against a double add | Annotation/AnnotationEditorView.swift
A-15 | fixed | preview keeps the last good frame while a new one renders (`displayedBasePreview`) and shows `basePreviewError` on failure. Not done: backdrop decode cache and display-size previews | Annotation/AnnotationDocumentController.swift, Annotation/AnnotationEditorView.swift
A-16 | fixed | auto-scroll step is `max(24, min(length*0.72, length-170))` | Capture/ScrollingCaptureSession.swift
A-17 | deferred | product decision: when a scrolling capture hits its limit, truncate with a warning, or fail and keep the frames
A-18 | fixed | double-click confirms the selection | Capture/SelectionOverlay.swift
A-19 | fixed | pointer position set in `viewDidMoveToWindow`, `isPointerInside` tracked, so no crosshair at the corner; `updateHoveredWindow` also runs on mouse down, so a click without prior movement works | Capture/SelectionOverlay.swift
A-20 | fixed | `keyWindow(forInitialRect:)` plus makeFirstResponder, so Return works on the display holding the selection | Capture/SelectionOverlay.swift
A-21 | fixed | loupe sample clamped by static `loupeSample(...)`, keeping pixels square at the image edge | Capture/SelectionOverlay.swift
A-22 | fixed | text bounds measured from the anchor; `editingTextID` now focuses the placed text | Annotation/AnnotationModel.swift, Annotation/AnnotationEditorView.swift
A-23 | fixed | `canvasElements` swaps the moved element for its in-progress copy and draws new ones on top; selection overlay follows it | Annotation/AnnotationEditorView.swift
A-24 | fixed | checker tile rect set to 2x2 so one block shows at the real size | Annotation/AnnotationRenderer.swift
A-25 | fixed | highlighter layer uses `.blendMode(.multiply)` in the editor, matching the render | Annotation/AnnotationEditorView.swift
A-26 | fixed | same undo rewrite as A-13: a gesture is one step and a no-op gesture keeps redo | Annotation/AnnotationDocumentController.swift
A-27 | deferred | moving the bake changes pre-overlay latency in the capture path; needs both orders measured on the running app
A-28 | fixed | backdrop thumbnails rendered in `.task` through a nonisolated renderer with a cache; `image(for:)` removed | Annotation/AnnotationEditorView.swift
A-29 | deferred | no measured cost; only worth changing if a profile shows it
A-30 | fixed | pixel sampling unpremultiplies before reporting colour; regression test added | Inspection/ImageInspector.swift
A-31 | fixed | bitmap contexts draw inside `withUnsafeMutableBytes` instead of keeping an inout pointer (`decodedPlane` in comparison) | Comparison/VisualComparison.swift, Capture/ScrollingCaptureSession.swift
A-32 | fixed | frame fingerprint computed only in automatic scrolling mode | Capture/ScrollingCaptureSession.swift
A-33 | fixed | unreadable custom recipes copied to `<key>.unreadable` and logged before anything overwrites them | Capture/CaptureRecipe.swift
A-34 | deferred | hang is unproven; a task group cannot abandon its child, and SCShareableContent is not Sendable, so a timeout needs a different design
A-35 | fixed | removed the dead selection overlay members listed below | Capture/SelectionOverlay.swift
A-36 | fixed | no-caller declarations removed, listed below. `WindowInfo.isActive` stays because a test constructs it | see Dead code removed
A-37 | fixed | shared `acceptedPixelSize(of:limits:)` for file and pasteboard paths; shared `ImageViewFit.rect(source:into:margin:)` for inspector and comparison | Capture/SafeImageFile.swift, Inspection/ImageInspector.swift, Comparison/VisualComparison.swift
B-01 | fixed | `moveOrCopy` is nonisolated async over `Task.detached`; `performStop`, `recover`, `commitPausedSegment` await it; lifecycle stays `.stopping` across the copy; sync core kept for the discard path | Recording/RecordingService.swift, App/AppCoordinator+Recording.swift
B-02 | fixed | joiner keeps every audio track by position, drops no track, stages, validates (playable, video track, audio count, duration within 1 s), then publishes; caller only retires after that. Track layout not observed (would need a real capture), and `SCRecordingOutputConfiguration` exposes no track setting, so the fix handles both layouts: one mixed track is unchanged behaviour | Recording/RecordingSegmentJoiner.swift, Export/RecordingExport.swift
B-03 | fixed | observes `.AVAudioEngineConfigurationChange`; 1 s later, if no buffer arrived since, records `CaptureError.inputChanged` and calls `onInputLost`. Checks buffers rather than `isRunning`, so a change the engine survives ends nothing. `stop()` reports it even before the HANDOFF; the live stop needs the HANDOFF | Recording/LiveVoiceNoteTranscription.swift
B-04 | fixed | done by FX3 in AppCoordinator+Shelf (rename and move detached); `ShelfFileOperations` needed no change | (FX3)
B-05 | fixed | packager no longer main-isolated; displays gathered on main and passed in; session writes in `Task.detached`, `isExporting` disables the button | Reporting/BugReportPackage.swift
B-06 | fixed | same change as D-02 | Recording/RecordingService.swift
B-07 | fixed | all engine calls on a private serial queue; new `beginCapture`/`finishCapture` async; sync `start`/`stop` kept via `queue.sync`; caller edit in HANDOFF | Recording/LiveVoiceNoteTranscription.swift
B-08 | fixed | buffer write detached | Recording/InstantReplayController.swift
B-09 | fixed | `review` returns `PrivacyReviewResult` with `failedChecks`; session `incompleteMessage`; title says "Review Incomplete", sidebar says what was not checked and still lists findings | Privacy/PrivacyReview.swift
B-10 | fixed | new `RecordingZoomGeometry`: scale about the click, ease toward centre with zoom, clamp so the frame stays covered; identity at 1, so no pop and no empty area. Keeps the centring the old code aimed for. Cursor is the real pointer moved by the same transform | Recording/RecordingInteractionEffects.swift
B-11 | fixed | `finishRecordingAfterFailure` joins all parts plus the validated last part in a completion task, then publishes; on join failure reports the files and leaves them for recovery | App/AppCoordinator+Recording.swift
B-12 | fixed | staged duration compared to source when a cap is set; more than 0.5 s short throws before publish | Export/RecordingExport.swift
B-13 | fixed | confirmed and worse than reported: measured 2.8x raw RGBA at Finalize (600 frames: 5.8 GB at 720p, 23 GB at 1440p). Frame count now bounded to half of physical memory, up to the existing 600; AddImage in an autoreleasepool. Choice for the user: the half-of-RAM budget only bites at large widths or on small Macs (8 GB at 1440p: 104 frames); default 720p on 16 GB is unchanged | Export/RecordingExport.swift
B-14 | fixed | effects get a local do/catch; thumbnail, shelf and captions still run; "saved, but its effects could not be applied" | App/AppCoordinator+Recording.swift
B-15 | fixed | samples carry `isInsideTarget`; no cursor drawn outside, clicks outside no longer zoom; window targets refresh bounds about 1 Hz off main | Recording/RecordingInteractionEffects.swift
B-16 | fixed | trim export stages and publishes, so Replace works and a failure leaves no partial; Preview pauses at the end via a one-shot boundary observer | Recording/VideoTrim.swift, Export/RecordingExport.swift
B-17 | fixed | a typed suffix counts only if non-dynamic UTType or equal to the current extension; probed: 30, 2, 1, 04, foo are dynamic | Files/ShelfFileOperations.swift
B-18 | fixed | done by FX3 (C-29) and FX8 (detached keychain reads at both call sites) | (FX3, FX8)
B-19 | fixed | one stored NSImage per session; Privacy load off main done by FX3; new `SmartExportSession(asset:source:)`, Smart Export caller in HANDOFF | Export/SmartExport.swift, Privacy/PrivacyReview.swift
B-20 | fixed | poll stopped on reset success | Permissions/PermissionCenter.swift
B-21 | fixed | low-disk request repeats each check until the session stops; `recordingStoppedForLowDisk` cleared on discard, failure and new start | Recording/RecordingService.swift, App/AppCoordinator+Recording.swift
B-22 | fixed | user cancel finishes the transfer as cancelled and skips `onFailure`; assignment in HANDOFF | Sharing/MacSharePresenter.swift
B-23 | fixed | replaced with `updater(_:userDidMake:forUpdate:state:)` clearing on skip/dismiss; Swift name typechecked against the built Sparkle | Updates/SecureUpdateController.swift
B-24 | fixed | probed with rotated and offset PDFs: canvas swaps for 90/270, translate removed because it offset twice and left the page blank | Files/MediaConversion.swift
B-25 | fixed | agent half: `launchctl bootout` (bounded 5 s, best effort) before Trash. Preferences half rejected by probe: after moving a plist away, `defaults read` already reports the domain gone, and `defaults delete` then fails, so no flush is needed | Files/AppUninstaller.swift
B-26 | fixed | missing scratch returns nil before any Trash attempt | Recording/RecordingService.swift
B-27 | fixed | "Move to Trash" added, using `discardScratchRecording`; the three-per-launch cap is worded separately | App/AppCoordinator+Recording.swift
B-28 | fixed | `stopCapture` bounded at 30 s at all four sites, falls through to the existing finalization wait, which keeps the scratch file. The fixed 12 s finalize wait is left: no evidence of it firing | Recording/RecordingService.swift
B-29 | fixed | GIF size read from the file via ImageIO, off main | Export/RecordingExport.swift
B-30 | fixed | see Dead code | several
C-01 | fixed | Save As copy and fsync run in a private nonisolated `saveCopy(of:to:)`, detached, with the same reporting and verification. Brief forbids new copy, so there is no progress label; for the lead: a 20 GB copy now shows nothing while it runs | App/AppCoordinator+Shelf.swift
C-02 | fixed | Shelf caller only: rename and move wrapped in Task.detached; no new FX4 API needed (FX4 confirmed) | App/AppCoordinator+Shelf.swift
C-02 | fixed | recording half as B-01; Shelf move half done by FX3 (`moveShelfItem` now detached) | Recording/RecordingService.swift
C-03 | fixed | same change as A-01 | Capture/CaptureStack.swift, App/AppCoordinator+Shelf.swift
C-04 | fixed | Menu builders read a cached `ShelfFileFacts` loaded in `.task(id:)`; LaunchServices and stat calls moved off main via `applicationsThatCanOpen` | UI/ShelfContent.swift, App/AppCoordinator+Shelf.swift
C-05 | fixed | `runModalOutsideMainQueue` added; used by the scrolling mode chooser and persist's save panel, with `isCurrentCapture` rechecked after the await. Recording and AppDelegate sites are HANDOFF 3 | App/AppCoordinator+Capture.swift
C-06 | fixed | `NSApp.activate` before the listed modals in my files, written inline rather than through a helper. Agents site is HANDOFF 4 | App/AppCoordinator+Shelf.swift, App/AppCoordinator+Capture.swift
C-07 | fixed | `persistHistory` hands rows to the write queue at once through `saveWithoutWaiting`, same failure message, nothing on main waits. No caller used the old Bool | App/AppCoordinator.swift, History/HistoryRepository.swift
C-08 | fixed | new `loadedImage(for:)` returns the in-memory image or decodes detached; used by the Shelf image actions. Dialogs show before the load in removeBackground and convert. AppDelegate:364 is HANDOFF 1; Automation:70 is HANDOFF 2 | App/AppCoordinator+Shelf.swift
C-09 | fixed | tap thread no longer waits on main for volume keys; `PendingKeyAnswer` waits at most 100 ms, then 250 ms once claimed, and can't apply a key macOS was handed | System/SystemMediaKeyInterceptor.swift
C-09 | rejected | not a separate finding for FX3: only cited inside C-05 as a consequence (`main.sync` from the tap); the tap belongs to another team
C-10 | fixed | Corrected premise: `/net` is commented out in this Mac's `/etc/auto_master`, so that exact path is inert by default; `/home` and `/Network/Servers` are live autofs, and managed Macs can enable `/net`. New `PinPathLocality`: refuses net, network, home by text (case-folded, `..` resolved, Data-volume and automount prefixes stripped), then the nearest mount from `getfsstat(MNT_NOWAIT)` must be local and not autofs; fails closed if the table can't be read. Also found: `URL(fileURLWithPath:)` itself stats the path before the guard, replaced with `URL(filePath:directoryHint:.notDirectory)`. Ran the real code against this Mac's table in a probe | Automation/NotchShotURLRouter.swift
C-11 | fixed | same change as G-05. Island collapses first on Review and Answer in Terminal; jumpToAgent keeps its existing no-collapse on a successful jump | Agents/AgentTerminalJumper.swift, App/AppCoordinator+Agents.swift
C-12 | fixed | as E-16: per-row retention stats off main; sweep deliberately stays synchronous | App/AppCoordinator.swift, History/HistoryRepository.swift
C-13 | fixed | failed pause without a writer: parked parts become a paused take, otherwise `arbiter.isRecording = false`; `refreshActivity()` | App/AppCoordinator+Recording.swift
C-14 | fixed | the seed is unnecessary now that the watcher seeds on call start; needs the HANDOFF edit | Context/MeetingControls.swift
C-15 | fixed | failed finish with parked parts restores the paused island so Stop retries and Discard works; failure path clears state and names the recovery folder | App/AppCoordinator+Recording.swift
C-16 | fixed | cancelled resume is silent, does not clobber a newer task or its overlay | App/AppCoordinator+Recording.swift
C-17 | fixed | a write failure for a configured or ask-every-time destination retries in AppPaths.captures as `.managedTemporary`, so the pixels survive and the clipboard copy still runs; message says where it went and that a History-off copy is removed at next launch | App/AppCoordinator+Capture.swift
C-18 | fixed | `observeMedia` compares a position-free `MediaObservationState`, re-arming tracking every time, so a 2 s position tick no longer refreshes the activity | App/AppCoordinator.swift
C-19 | fixed | guarded the arbiter writes and the call-activity set and dictionary writes | App/AppCoordinator+Island.swift
C-20 | fixed | `lockedCharging` read once per refresh, and cached 5 s. `islandAIActivities` half is outside FX1, see HANDOFF | App/AppCoordinator+System.swift
C-21 | fixed | monitor runs whenever multiple activities are on; `shouldBegin` already checks the swipe preference (read it) | App/AppCoordinator+Island.swift
C-22 | fixed | Automation site only: summary flow holds its label in a local and releases that one. Shelf has no direct writes left. Capture and Recording sites are other teams' files: HANDOFF 3 | App/AppCoordinator+Automation.swift
C-23 | fixed | `SelectionWorkflow.current` token: an older selection's defer no longer clears the newer selection's state | App/AppCoordinator+Capture.swift
C-24 | fixed | (1) both migration keys set on the no-data path. (2) `clearedSystemReplacements` persisted set, also filled when another action takes the combination; Restore Defaults empties it. (3) `installedDefaults` persisted set, one install per action, skipped if the combination is held; first run treats every action but `saveInstantReplay` as already offered, so a cleared shortcut does not return. Also found: migrations were never saved, so the dictation migration and new defaults were lost the launch after; now saved when anything moved | HotKeys/HotKeyController.swift
C-25 | fixed | `item.image = nil` on dismiss, so `lastDismissed` no longer holds the bitmap | App/AppCoordinator+Shelf.swift
C-26 | fixed | `showShelfItem(id:)` selects and expands an item already on the shelf, checked before and after the load. Also moved the file read and thumbnail off main (the Automation:102-105 part of FX3's C-08), so the request now completes asynchronously | App/AppCoordinator+Automation.swift
C-27 | fixed | `SystemInputMuteWatcher` follows the default input and its mute on its own queue while a call uses the mic, from `refreshActivity`; `isMeetingMuted` deleted | Context/MeetingControls.swift, App/AppCoordinator+Extras.swift, App/AppCoordinator+System.swift
C-28 | fixed | (a) "Added to Shelf" only shows if staging will accept the batch, same checks as `stageExternalFiles`. (b) the swallowed move is in FX3's file: HANDOFF 4 | App/AppCoordinator+Clipboard.swift
C-29 | fixed | share-link keychain read runs detached. File identity is still taken synchronously at click, as the comment on `assetForSelection` requires | App/AppCoordinator+Shelf.swift
C-30 | rejected | Measured `NSUpdateDynamicServices` in a probe at load average 37: 8, 2 and 96 ms. It runs once at launch before any panel exists, so nothing is frozen. The gate would cost more: every dev build has version "1 (1)", so a changed Services entry would stay stale until logout, the case the call exists for
C-31 | fixed | window guard added, `reduceMotion` read at its use, `event.window` tested first in all three helpers. Finding's "risk: none" was wrong: `swallowMomentum` reset had to move above the guard, because a swipe with no flick leaves it set and the next gesture in another window would lose its momentum | Input/IslandGestureCoordinator.swift
C-32 | fixed | both `removeValue` lines deleted; the close handlers remove the same entries | App/AppDelegate.swift
C-33 | fixed | `path == home || path.hasPrefix(home + "/")` | Automation/NotchShotURLRouter.swift
C-34 | fixed | My parts: `HotKeyController.start()` second `registerAll`; Automation unreachable lines removed with the dead chain; `stopUtilities` removed (FX5 removed its caller). `isMeetingMuted`, System dictation branch and guard, `observeDictation` tracking, and the popup tag are outside my files: HANDOFF 4 | HotKeys/HotKeyController.swift, App/AppCoordinator+Automation.swift, App/AppCoordinator+Utilities.swift
D-01 | fixed | both sides now build the layout from one `NotchLayoutInputs` (shelfStyle, isScrollingCapture, wings, hold); `update(...)` gained `isScrollingCapture`; caller edit is in HANDOFF 1, without it scrolling stays broken | Window/NotchMetrics.swift, Window/NotchWindowController.swift, UI/NotchRootView.swift
D-02 | fixed | capacity query off main at 1 Hz with one in flight (`checkCapacityOffMain`/`applyCapacity`), start check awaited off main; closure now `@Sendable`; important-usage key kept; Preferences untouched | Recording/RecordingService.swift
D-03 | fixed | rebuild replaces the root only when the context changed or the active display moved since the last rebuild. Finding's "only context varies" missed that a rebuild also healed the unobserved pointer-derived `isActiveDisplay`, so that case still replaces it | Window/NotchWindowController.swift
D-04 | fixed | `applyVisibilityPolicy(force:)`; the per-update pass orders only on a real change and guards level and login visibility; `position()` and the locked branch still force | Window/NotchWindowController.swift
D-05 | fixed | same change as C-01 | App/AppCoordinator+Shelf.swift
D-06 | fixed | `isLoading` guard stops `init` writing anything; missing share-link fields are filled from defaults at read (generic merge, no field list, no edit to FX4's file); undecodable JSON stays stored | Core/ExtrasPreferences.swift
D-07 | fixed | resolve with `.withoutUI` and `.withoutMounting`; failed bookmark retried at most every 10 s so a remounted drive is still noticed; one log line. Behaviour change: an unmounted share no longer auto-mounts on a capture, it goes to the Desktop as any failure already did | Core/Preferences.swift
D-08 | fixed | no poll while hidden for the frontmost app or with no panels; `notchEnabled` early return calls `updatePresencePoll` | Window/NotchWindowController.swift
D-09 | fixed | locked 1 Hz timer only runs while a card is wanted; every change that can want one lands in `applyLayout` | Window/NotchWindowController.swift
D-10 | fixed | `timer.tolerance = interval * 0.2` | Window/NotchWindowController.swift
D-11 | fixed | backoff 5 ms doubling to 100 ms in both waits, `isRunning` still the only condition | Core/ProcessExit.swift
D-12 | fixed | external files report `externalFileIdentity.size` with no stat (all views use this property); owned captures still stat because they are local | Core/CaptureAsset.swift
D-13 | deferred | needs on-screen check: `resignKey()` is documented as a hook not to call, but whether focus returns can't be settled from code and the fix (reactivate or order out and in) has its own risks. Unchanged
D-14 | fixed | unused group deleted (see Dead code removed); test-only group kept (see Dead code kept) | Window/NotchWindowController.swift, Core/ScreenGeometry.swift, Core/Island/IslandPresentation.swift
E-01 | fixed | custom words go through `DictationTextProcessor.customDictionary(from:)`, which tolerates repeats instead of trapping in `Dictionary(uniqueKeysWithValues:)` | Dictation/TextInsertionService.swift, Dictation/DictationCoordinator.swift
E-02 | fixed | durable hold: a `history.json.corrupt-*` sibling or a new `history.json.cleanup-hold` marker stops the untracked sweep and orphan-thumbnail cleanup on every launch, until "Clear History and Move Files to Trash" moves the held files to Trash. Row-based retention still runs. History off with no store still sweeps | History/HistoryRepository.swift
E-03 | fixed | change count, type list and exclusions stay on main; payload read on a serial queue with one latest-wins queued request; change count checked before and after the read; concealed filtering and read limits unchanged; recording re-checks Clear via `recordRead` | Clipboard/ClipboardMonitor.swift, Clipboard/ClipboardStore.swift
E-04 | fixed | all AX messages on a serial queue with a 0.5 s messaging timeout; frontmost pinned from NSWorkspace before the notch moves; a timeout on the secure check counts as secure; a timeout on set counts as unverifiable, never a second typing | Dictation/TextInsertionService.swift, Dictation/DictationCoordinator.swift
E-05 | fixed | engine start and stop on a dedicated queue; stream ends at once on stop; session re-checked after the await | Dictation/DictationAudioCapture.swift, Dictation/DictationCoordinator.swift
E-06 | fixed | feed task is held, awaited in stop and cancelled in cancel/fail; a feed error only fails the session while `.listening` | Dictation/DictationCoordinator.swift
E-07 | fixed | spoken formatting uses word-boundary regexes, so "periodically", "commander", "colonel", "three commas" survive. Choice left as is: a mid-sentence spoken "period" still converts | Dictation/TextInsertionService.swift
E-08 | fixed | hesitations match whole tokens only and keep line breaks. "like" and "you know" go only where punctuation sets them apart (between commas, opening a sentence with a comma, tagged at the end); unpunctuated cases stay | Dictation/TextInsertionService.swift
E-09 | fixed | a push-to-talk release during a queued start is remembered and applied when the session starts | Dictation/DictationCoordinator.swift
E-10 | fixed | budget uses a counted byte scan of real escapes (`storeByteUpperBound`, `encodedStringBound`, about 7 ms per 6.3 MB against 238 ms to encode, best runs on this noisy Mac) instead of encoding on main; encoder only for a row that cannot be bounded | Clipboard/ClipboardStore.swift
E-11 | fixed | `record(contentsOf:)` does one budget pass and one save per import | Clipboard/ClipboardImport.swift, Clipboard/ClipboardStore.swift
E-12 | fixed | budget shortens oldest row first, one at a time, until under; pinned last; re-copying restores full text. Needs HANDOFF 1 or an existing test fails | Clipboard/ClipboardStore.swift
E-13 | fixed | Spotlight items built in `Task.detached`, index call back on main; empty-domain skip | History/CaptureSpotlightIndexer.swift
E-14 | fixed | jiggle requires a drag-pasteboard write since this mouse-down, carrying file URLs or promised files | Floating/FloatingBasket.swift
E-15 | fixed | `clearAllInBackground` does file work off main, sync `clearAll` kept. Takes effect only with HANDOFF 2 | History/HistoryRepository.swift
E-16 | fixed | retention moved off main at launch (`applyRetentionInBackground`). The untracked sweep stays synchronous on purpose: run async it could delete a file whose row does not exist yet, as hotkeys and recording recovery follow it | App/AppCoordinator.swift, History/HistoryRepository.swift
E-17 | fixed | previous-clipboard reads and restore code removed | Dictation/TextInsertionService.swift
E-18 | fixed | chunks never split a surrogate pair | Dictation/TextInsertionService.swift
E-19 | fixed | posted key events carry empty flags | Dictation/TextInsertionService.swift
E-20 | fixed | read source suspended at EOF once handled, resumed after cancel in `retire` | External/LiveActivitySocketServer.swift
E-21 | fixed | pin origin clamped to the visible frame | Floating/FloatingCaptureWindow.swift
E-22 | fixed | preview uses a 1 KB head when the text is long and the head is enough; whitespace-heavy text takes the full path | Clipboard/ClipboardEntry.swift
E-23 | fixed | `sourceText` nonisolated and off main, source bounded | History/CaptureTranslationView.swift
E-24 | fixed | request token rejects a late status for an older language | Dictation/DictationCoordinator.swift
E-25 | fixed | install generation stops an old task clearing a new one's state | Dictation/DictationCoordinator.swift
E-26 | deferred | needs hardware: restarting the tap on a route change must re-read the input format and cannot be checked blind. Done: a configuration-change observer keeps `available` truthful, so the trace falls away instead of looking live. Still open: speech after the change is not captured. `dictationPreferredMicrophoneID` is HANDOFF 6
E-27 | fixed | `publishTask = nil` in stop | External/ExternalActivityStore.swift
E-28 | deferred | red flag only, 80 rows here, OCR off by default. A correct prefilter must enumerate every scalar whose lowercase or canonical form gives ASCII (U+212A, U+0130, also U+037E and U+1FEF through String's canonical matching). A miss silently drops search hits, so that trade is wrong without measured demand
E-29 | fixed | same fix as C-07. The stated reason for the sync write (a quit inside the debounce window) still holds: debounce skipped, quit drains the queue through `save()` | App/AppCoordinator.swift, History/HistoryRepository.swift
E-30 | fixed | see Dead code removed; `handleDictationReturn/Escape` already gone from AppCoordinator+System (other team); test-only names are listed under Dead code kept | several
E-31 | deferred | one copy of each pair is in Recording/, owned by FX4. HANDOFF 5
F-01 | fixed | volume keys and mute run on `SystemVolumeEngine`'s own queue, queued presses coalesced into one read and one write; tap thread gets a bounded answer; brightness stays on main as the finding asked | System/SystemLevelMonitor.swift, System/SystemMediaKeyInterceptor.swift
F-02 | fixed | default-output listener, volume listeners and route reads off main; `AudioRouteMonitor` on its own queue; Lock Screen route read off main. `availableAddresses` narrowing skipped: about 1 ms, secondary | System/SystemLevelMonitor.swift, Context/SystemContextMonitors.swift, UI/LockedNowPlayingCard.swift
F-03 | fixed | all mixer Core Audio moved to `AppVolumeEngine`'s queue; process-list changes settle 250 ms and coalesce; `NSWorkspace.runningApplications` kept (now off main) rather than a per-bundle lookup | Media/AppVolumeMixer.swift
F-04 | fixed | `ProcessAudioTap.start/stop` asynchronous on a setup queue with a failure completion; meter and Shazam report failures with a generation check | Media/ProcessAudioTap.swift, Media/LiveAudioMeter.swift, Media/SongRecognizer.swift
F-05 | fixed | verified with `osacompile`: `repeat with offset` does not compile, so the queue never worked. Renamed. Also `position` is a property in Music's dictionary (`sdef`), so `set position to` inside the `tell` would have failed at run time into the `on error`: renamed too | Media/MediaQueueService.swift
F-06 | fixed | `snapshot()` reports whether a running player answered; poll holds the last track for two unanswered polls, the third publishes the empty as before; a real stop or no player publishes at once | Media/AppleEventsMediaSource.swift
F-07 | fixed | `AdapterPayload.snapshot(mergingLine:into:)` merges `diff` lines over the payload so far (null removes, no flag replaces); actor keeps the payload and resets it on stop and termination | Media/MediaRemoteAdapterSource.swift
F-08 | fixed | the Media half: `apply` assigns `snapshot` once per position tick, not three times. The rest shares C-18 (FX2) | Media/MediaCoordinator.swift
F-09 | fixed | cover fetched apart from the poll, published when it lands; a miss answers with the cover already up; cancelled on key change and stop | Media/AppleEventsMediaSource.swift
F-10 | fixed | `setLevel(_:for:isFinal:)` and Night Shift `setStrength`: bar follows every event, one apply per frame (16 ms), defaults and commit on the final only; final refused returns the bar to what was really applied; `finishDrags` covers the menu closing mid-drag. Native display writes stay on main at one per frame (a sync answer is part of `setLevel`'s contract) | System/ExternalDisplayBrightness.swift, System/NightShiftController.swift, UI/MenuBarDisplayControls.swift
F-11 | fixed | privacy listeners diffed by property; vanished IDs dropped without a removal call, unchanged ones not re-added | Context/PrivacyIndicatorWorker.swift
F-12 | fixed | a track with no cover is asked about at most once per 60 s, not on every poll | Media/AppleEventsMediaSource.swift
F-13 | fixed | CoreBrightness and SkyLight behind `NightShiftBackend`, created off main by `NightShiftController.preload()` from `SystemLevelMonitor.start()`; `refresh` and `refreshNativeLevels` read off main with generation checks | System/NightShiftController.swift, System/ExternalDisplayBrightness.swift, System/SystemLevelMonitor.swift
F-14 | deferred | needs hardware: the watchdog spawn and validation decide whether a system process may be SIGSTOPped, and the hop to main opens a race with disable and helper respawn that I can't exercise without the running app. Wrong order leaves OSDUIHelper stopped with no recovery; the cost is an unmeasured estimate, a few times a day. Worth doing with a live test
F-15 | fixed | seek goes through `MediaTimePolicy.wholeSeconds` (`Int(_:)` trapped on huge values) and `LRCParser.timestamp` rejects more than 6000 minutes. The Spotify and Music seek scripts were identical and are one now | Media/AppleEventsMediaSource.swift, Media/LyricsService.swift
F-16 | fixed | adapter output goes through one `AsyncStream` and one consumer task, so chunks reach the actor in order | Media/MediaRemoteAdapterSource.swift
F-17 | fixed | a stream that ends inside the cooldown schedules a selection for the end of it; wake still does nothing inside the cooldown | Media/MediaCoordinator.swift
F-18 | fixed | silence refusal only for a player this run never heard from; restart on next tick kept | Media/LiveAudioMeter.swift
F-19 | fixed | `AudioTapProcessPolicy.tapTargets` dedupes and sorts, so a helper with many renderers doesn't look like a change | Media/ProcessAudioTap.swift, Media/AppVolumeMixer.swift
F-20 | fixed | coreaudiod restart re-installs listeners and rebuilds taps, from a later queue turn | Media/AppVolumeMixer.swift
F-21 | fixed | one static artwork `URLSession` | Media/AppleEventsMediaSource.swift
F-22 | fixed | dead parts removed (see below). Its `isRefreshing` claim is wrong: ProductivitySuiteView reads it; the stuck-true it mentions is real and fixed. Rest kept with reasons below | System/ExternalDisplayBrightness.swift and others
G-01 | fixed | bootstrap and question decode plus workspace compare moved to Task.detached; stale results refused by connection identity; stream items reduced inside the connection actor to a small Sendable struct; pendingQuestion checks the type before decoding a payload | Agents/Crewline/CrewlineMonitor.swift, CrewlineConnection.swift, CrewlineModels.swift
G-02 | fixed | calendar reads on a chained detached task, latest wins by generation; EKEventStoreChanged debounced 500 ms; planner saves off main. Part rejected: refresh from start() when already started stays, because Settings toggles rely on it, and it is off main now | Context/CalendarGlanceService.swift, ProductivityCoordinators.swift
G-03 | fixed | see K-01 | UI/NotchRootView+Media.swift
G-04 | fixed | hasCredential is a stored observable answer, first read starts the lookup; every Keychain call runs in order on one serial queue; connection.json and root token read off main | Agents/Crewline/CrewlineMonitor.swift
G-05 | fixed | jump is async, ancestry, tmux and scripts run on a serial queue, latest click wins; scripts go through /usr/bin/osascript with the same with-timeout bound plus a 60 s budget for compile and the first-use prompt; activate stays on main | Agents/AgentTerminalJumper.swift, App/AppCoordinator+Agents.swift
G-06 | fixed | sibling events no longer clear a card or overwrite phase and detail; a question ends only on its own tool, prompt, stop or session end; permission only on its own tool name, stop or session end. Same-named sibling tool still clears (PermissionRequest carries no tool_use_id), but any cleared card now hands its hook back with the existing exact-request defer, which approves nothing | Context/ClaudeCodeSessionMonitor.swift
G-07 | fixed | server reports a held request's hook closing through a separate callback a client cannot forge; monitor clears only the card with that ID and says Answer in the terminal; respond reports non-delivery and the monitor corrects Permission approved/denied/answered unless a newer event moved on; permission expiry at 300 s | Context/ClaudeCodeSessionMonitor.swift
G-08 | fixed | an event during a running refresh schedules one more refresh; stale task cannot clear a newer refreshTask (generation) | Agents/Crewline/CrewlineMonitor.swift
G-09 | fixed | list comparison ignores read stamps on live runs; live runs re-stamped when the merged snapshot is built, so a quiet run does not age out; approvals keep a first-seen date for their order | Context/ContextCoordinator.swift, Agents/Crewline/CrewlineModels.swift, CrewlineMonitor.swift
G-10 | fixed | HTML no longer reaches WebKit. Not with the finding's XMLDocument tidy: probes showed it garbles CJK and accents through the data route, leaks comment text, joins list items, and crashes (SIGBUS, exit 138) at about 5,000 nested divs on a cooperative thread; entity decoding through tidy hung over 110 s. Own byte tokenizer instead (HTML4 entities), tested at 2 M nested divs and 15 MB. It loads nothing, so no remote fetch is possible | Context/DocumentSummary.swift
G-11 | fixed | same change as G-10 | Context/DocumentSummary.swift
G-12 | fixed | stopfailure tested before failure so it reaches .waiting; a failed session with an open turn returns to .working once its age reaches terminalLifetime minus the prune interval, so neither the session nor the snapshot row drops out. A closed turn's failure still ages out at 45 s; the Failed phase for PostToolUseFailure stays, as a test pins it | Context/ClaudeCodeSessionMonitor.swift
G-13 | fixed | Clear persists its time in a sidecar beside the history file (`AI Activity History.json.cleared`); merging ignores terminal activity from up to then; dismiss saves history | Context/AIActivityMonitor.swift
G-14 | fixed | GenerationError falls back to the extractive summary with usedLanguageModel false; cancellation still throws | Context/DocumentSummary.swift
G-15 | fixed | the first update naming a number past every row lines the rows up from the first unfinished one; a delete or a low or absurd ID that fits nothing changes nothing | Agents/AgentRunActivity.swift
G-16 | fixed | plan tools end nothing; end's newest-open fallback only when no ID was given; tool-name fallback stays | Context/ClaudeCodeRunTracker.swift, Agents/AgentRunActivity.swift
G-17 | fixed | pause and adjust publish when their own updateElapsed completed the timer | Context/ProductivityCoordinators.swift
G-18 | fixed | a second caller awaits the read in flight; read waits on GCD not the pool; timeout terminates then SIGKILLs after 1 s, and the caller is released regardless | Context/BluetoothAccessoryBattery.swift
G-19 | fixed | battery amendment checks its route and `expiresAt` through `batteryAmendmentApplies` | Context/SystemContextMonitors.swift
G-20 | fixed | `takeRetainedValue` on the Copy result, the leak is gone | Context/SystemContextMonitors.swift
G-21 | fixed | nil-safe IOPS unwrap instead of a crash path | Context/SystemContextMonitors.swift
G-22 | fixed | Crewline's connection.json carries `pid` (apps/server/src/main.ts:1519 in the Crewline repo, checked read-only); port() now returns nil when that process is dead or is pid 1, so a crash-left descriptor gets no token, no root token, and no 401 can unpair. No PID in the file keeps old behaviour for older builds. Not done: a Crewline-specific response header before invalidating, which needs a Crewline change. PID reuse plus a port takeover stays theoretical | Agents/Crewline/CrewlineConnection.swift
G-23 | fixed | server part: held and decision clients have their own allowance of 64 and don't use the 16 short-event slots. Reporter's SO_NOSIGPIPE is FX7's and is in ClaudeHookSocket.swift:56 | Context/ClaudeCodeSessionMonitor.swift
G-24 | fixed | watcher resubscribes after a stream ends with the socket up, then refreshes since events may have been missed; retries back off 3 to 60 s when a stream delivers nothing. Whether Crewline ever ends a stream this way is unverified | Agents/Crewline/CrewlineMonitor.swift
G-25 | fixed | save updates in place first; add only on not-found; delete-then-add only on the ACL errors (errSecAuthFailed, errSecNoAccessForItem, errSecInvalidOwnerEdit); anything else, such as a locked Keychain, keeps the old pairing and reports failure | Agents/Crewline/CrewlineCredentialStore.swift
G-26 | fixed | moved-hook replacement filters the nested hooks and drops an entry only when empty | Context/AIHookInstaller.swift
G-27 | fixed | A: device name through SCDynamicStoreCopyComputerName. B: size guard added. Part rejected: "twice per Settings body" is wrong, Settings caches it in @State (SettingsView+Modules:23, :278) | Agents/Crewline/CrewlineMonitor.swift, Context/AIHookInstaller.swift
G-28 | fixed | files sorted by mtime; decodes those under 30 min old, then on until one with plan windows is found; 8-day retention unchanged | Agents/AgentUsage.swift
G-29 | fixed | scanned-PDF recognition runs in Task.detached with cancellation forwarded | Context/DocumentSummary.swift
G-30 | fixed | activeRuns removed. Test seams kept (see below). isMeetingMuted already gone (FX1). PowerContextPolicy's duplicate branch is FX1's file: handoff below | Agents/Crewline/CrewlineModels.swift
H-01 | fixed | `isScanning` guard first; trust check, Notification Center lookup and walk run on the serial scan queue with results returned to main; same 0.45 s interval, tolerance 0.1; status assigned only on change | Productivity/SystemNotificationMirror.swift
H-02 | fixed | `refreshPermission` acts only while waiting for permission, trust checked off main; observer create and add on the scan queue, run-loop source on main; incomplete walks keep their fingerprints | Productivity/SystemNotificationMirror.swift
H-03 | fixed | New `ProductivityNoteStore.edit`: memory at once, save on a serial queue after 500 ms; `finishEditing` at submit, note switch and view close; `flush` for quit needs HANDOFF a. Locked store refuses up front; failed save keeps the text and shows lastError. Sync `update/create/delete` stay transactional as existing tests pin them, and carry queued typing | Productivity/ProductivitySuiteModels.swift, ProductivitySuiteView.swift, AuthoredContentFile.swift
H-04 | fixed | `try? write` in `hook`; `write` and `writeStatus` share `replace(_:with:temporary:)` using `rename`, temp unlinked on failure; SIGPIPE ignored in `hook` only; permission output code untouched | Sources/NotchShotAIReporter/main.swift
H-05 | fixed | Short options pass only when every command on the line is on an allow-list of everyday tools; anything else fails closed. Chose this over the finding's list of credential tools because that list would narrow the net (a tool missing from it would leak). `ssh -p` stays redacted; full git SHAs stay over-redacted; AKIA/ASIA need 16 capitals or digits; paths with a file extension exempt from the long-token rule | NotchShotAIReporterSupport/CommandSecretRedactor.swift
H-06 | fixed | In my files: base URL then TLS probe then copy; copy off the actor with a cancel handler; `removeStaleSnapshots` added. The launch call is HANDOFF b and `fclonefileat` is HANDOFF d, without which sends still pay one full copy | Productivity/LocalSendClient.swift
H-07 | fixed | Window Snap's AX work on a serial queue, 1 s messaging timeout on app and window; `snapFrontmost` is async and its caller wraps it in a Task | Productivity/ProductivitySuiteModels.swift, ProductivitySuiteView.swift
H-08 | fixed | `AXUIElementSetMessagingTimeout` on each child element returned by the walk | Productivity/SystemNotificationMirror.swift
H-09 | fixed | Shared `OwnerOnlySocket.connection` sets SO_NOSIGPIPE and a 2 s SO_SNDTIMEO | NotchShotAIReporterSupport/ClaudeHookSocket.swift, NotchShotAIReporter/main.swift
H-10 | fixed | `try?` on all three status writes in `runCommand`; the spawn error and the command's exit status are what comes out | NotchShotAIReporter/main.swift
H-11 | fixed | `-F` matched by exact case, split and attached. `-P/-T/-U/-B/-D` deliberately stay case-insensitive, unlike the finding's fix: `zip -P` and `sqlcmd -P` are real credentials, and `-D` over-redaction only matters on lines the allow-list did not clear | NotchShotAIReporterSupport/CommandSecretRedactor.swift
H-12 | fixed | Redacts `prefix(4_096)` in the hook and in `ClaudeRunReport.target` | NotchShotAIReporter/main.swift, NotchShotAIReporterSupport/ClaudeRunReport.swift
H-13 | deferred | product decision: with AI Activity off, either remove the installed hooks or write a `.disabled` marker the reporter checks
H-14 | fixed | `baseURL` brackets IPv6 hosts, now static and tested | Productivity/LocalSendClient.swift
H-15 | deferred | needs an edit outside my files: `Resources/Info.plist`, exact text in HANDOFF c
H-16 | fixed | Prepare request timeout 300 s | Productivity/LocalSendClient.swift
H-17 | fixed | Best-effort `POST .../cancel?sessionId=` with a 2 s timeout when an accepted session did not finish; result ignored; UI not delayed | Productivity/LocalSendClient.swift
H-18 | fixed | Replies bounded at 1 MiB: `bytes(for:)` for prepare, data delegate for uploads | Productivity/LocalSendClient.swift
H-19 | fixed | Mismatch clears `pendingFingerprint`; `.onChange` of host and port clears it too | Productivity/ProductivitySuiteView.swift
H-20 | fixed | Bounded FileHandle read of 300,001 bytes off main, rather than `SafeAssetFile.readData`, to keep symlink behaviour and the exact message. `setLyrics` stays sync: a single user action | Productivity/ProductivitySuiteView.swift
H-21 | fixed | `refresh` saves when screen time is off; the quit save is HANDOFF a | Productivity/ExtrasServices.swift
H-22 | fixed | `loadFailed` flag; `persist` refuses while set; scheduling works in memory and `lastError` says so | Productivity/ProductivityNotificationStore.swift
H-23 | fixed | Typed titles stay raw in memory; tidied at save, submit and note switch; list shows a fallback for an empty title; on disk never empty; untouched legacy titles preserved | Productivity/ProductivitySuiteModels.swift, ProductivitySuiteView.swift
H-24 | fixed | In part: `ToolAppIcons` cache (limit 64) for Today and Running Apps. First lookup per app stays on main, as going off main adds a placeholder frame (visual change). Catalog already bounded per kind, left alone | Productivity/ExtrasToolViews.swift, ProductivitySuiteView.swift
H-25 | fixed | `LockedChargingPolicy.reading()` cached 5 s, dropped by `PowerSourceMonitor` on a change | Context/SystemContextMonitors.swift
H-26 | fixed | Observer now uses the notification's app, so no lookup per switch. Observer itself stays, as the comment and feature need it | Productivity/ProductivitySuiteModels.swift
H-27 | fixed | SIGTERM DispatchSource during `run` kills the group with SIGKILL then `_exit(128+SIGTERM)`; handler restored in defer | NotchShotAIReporterSupport/StatusLineCommand.swift
H-28 | fixed | Same NSApplication startup as `--self-test`; recording cancelled in the catch | Sources/NotchShotDiagnostics/main.swift
H-29 | fixed | See Dead code removed
H-30 | fixed | Socket: `OwnerOnlySocket`. Options: `LongOptions`. Identifier: `ClaudeRunReport.safeIdentifier` (reporter, status line). Temp-replace: `replace`. Process group: `DedicatedProcessGroup`. `AIActivityPolicy.safeIdentifier` is outside my files, left | NotchShotAIReporterSupport/*, NotchShotAIReporter/main.swift, NotchShotCLI/main.swift, Productivity/ExtrasServices.swift, ProductivitySuiteModels.swift
J-01 | fixed | `LiveAccessibilityValue` modifier at all three sites, same position in each chain, same strings; recording readings no longer invalidate the root, compact island or satellite | UI/Island/IslandCompactContent.swift, UI/Island/IslandActivityContainer.swift, UI/NotchRootView.swift
J-02 | fixed | drag no longer writes prefs per event or retries a refused tap per event: `dragLevels` overlay, saved on the final, one try per gesture | Media/AppVolumeMixer.swift
J-03 | fixed | icon loaded through `IslandAppIconCache` in `.task`, not per body; a panel closing mid-drag commits the draft | UI/AppVolumeRows.swift
J-04 | fixed | tap build off main on the engine's queue | Media/AppVolumeMixer.swift
J-05 | fixed | same change as K-04 | UI/IdleAnimationView.swift
J-06 | fixed | transcript attributed string built from the last 400 finalized characters; head truncation and two lines make the output the same; VoiceOver keeps the full text. Not done: skipping `refreshActivity` for text-only changes, because `.dictation` carries the text and `NotchRootView` reads it for its accessibility description and shell height | UI/DictationIslandView.swift
J-07 | fixed | `.receive(on: DispatchQueue.main)`, `import Combine` | UI/BatteryAlertCard.swift
J-08 | fixed | preview keeps the in-memory fast path in init, otherwise loads and decodes detached (`finishedLoading`); no init file read | UI/CapturePreviewView.swift, Capture/SafeImageFile.swift
J-09 | fixed | clipboard rows share a window-scoped `HistoryThumbnailCache` at their 40 x 30 drawn size, with the same byte and pixel limits checked before the decode | UI/ClipboardView.swift, UI/HistoryView.swift
J-10 | fixed | row, context menu and detail resolve existence off main into `@State`, assumed present until answered. Context menu moved into `HistoryRowMenu` so it no longer stats per row | UI/HistoryView.swift
J-11 | fixed | live list computed once per body and passed down; sort precomputes sessions awaiting permission instead of two scans per comparison. IslandAIExpanded's own double computation is FX5's | UI/AgentVibeNotchView.swift
J-12 | fixed | `FileIconImage`: one off-main lookup per URL via `.task(id:)`, used by rows and header | UI/AppUninstallView.swift
J-13 | fixed | icon(for:) and new hasKnownApplication(for:) never call LaunchServices from a body: lookup runs detached and an observable revision redraws. Click paths and sync applicationURL unchanged, so the test on it still holds | Context/AgentIconCatalog.swift, UI/AgentVibeNotchView.swift, UI/AgentActivityView.swift
J-14 | fixed | two `@MainActor` static formatters; `remaining` is `@MainActor`, both callers are View members | UI/Island/IslandExpandedContent.swift
J-15 | deferred | product decision: keep the clipboard row's live-ticking age, or show a coarse age that goes stale until the row next redraws
J-16 | fixed | "Ran for" with the finished phrasing once the run has ended | UI/AgentRunCard.swift
J-17 | fixed | confirmed the detail layout (`ShelfContent:325`) keeps identity across ids; non-animated reset, then rise on the next turn | UI/Island/IslandMotion.swift
J-18 | fixed | four dead structs and phase(for:) deleted | UI/ClaudeVibeNotchView.swift
J-19 | fixed | my part: the two unreachable `else` branches (`AgentPeekHeader`, `AgentCompactStrip`) and the unreachable agent branch in `previewHeader`. The third branch (`AgentActivityList`) IS reachable, with no live run, and stays; it now passes only its required args so it compiles whether or not FX6 drops the optional ones. Rest is FX6's | UI/NotchRootView+Context.swift
J-19 | fixed | views left unreachable after FX5's collapse deleted; recent-only panel with Clear stays | UI/AgentActivityView.swift
J-20 | fixed | row uses AgentVibePresentation.jumpHelp | UI/AgentVibeNotchView.swift
J-21 | fixed | Return approves only after the approval card has been up 500 ms, re-armed per request by .id(interaction.id). Keyboard approval stays. Review sheet untouched (Return there still means the terminal fallback). No other approval-path change | UI/AgentInteractionCard.swift
K-01 | fixed | output-device list read off main with a coalesced refresh; last answer held in `AudioOutputMemory` so the menu has it on open | UI/NotchRootView+Media.swift
K-02 | fixed | selecting an output runs off main; a second click while one is applying is ignored | UI/NotchRootView+Media.swift
K-03 | fixed | see F-10 | System/ExternalDisplayBrightness.swift, UI/MenuBarDisplayControls.swift
K-04 | fixed | hover bar's image read off main (`Data` in `Task.detached`, then `NSImage(data:)` on main once) and kept between hovers; preloaded at launch and on install so no empty first hover; `currentURL` stats once per file. Settings preview keeps its own image, because two views animating one NSImage would step it twice as fast | UI/IdleAnimationView.swift, UI/NotchRootView+Context.swift, App/AppCoordinator+Island.swift
K-05 | fixed | `hasItemsConforming` in validate and update, providers only on enter and perform; pull stepped to eighths and written only on change (`FileDropPullPolicy.steppedPull`). Did not move it to its own modifier: the root now re-evaluates once per eighth crossed, not per pixel | UI/NotchRootView+FileDrop.swift, UI/Island/IslandMotion.swift
K-06 | fixed | see F-13. First-open rows stay correct: the controller takes the read made while loading; an open that beats the preload waits for it, as it always did | System/NightShiftController.swift
K-07 | fixed | Lock Screen card stops its 20 s read while the screens are off; the read goes through the 5 s cached `LockedChargingPolicy`. Interval unchanged. `LockedChargingCard` has no coordinator and relies on the cache | UI/LockedNowPlayingCard.swift, Context/SystemContextMonitors.swift
K-08 | fixed | output list refresh coalesced and off main, see K-01 | UI/NotchRootView+Media.swift
K-09 | fixed | last 4 strip pictures cached by text, width, scale, gap, font and colour | UI/MarqueeText.swift
K-10 | fixed | `overflows` is stored and written only when it differs, so a spring's frames write nothing | UI/MarqueeText.swift
K-11 | fixed | sheen modifier applied only when it can show | UI/NotchRootView+Media.swift
K-12 | fixed | `.onChange(of: now)` replaces the stale read | UI/NotchRootView+Media.swift
K-13 | fixed | dead `animatableData` and the comment claiming it removed, no behaviour change. Not made Animatable: that adds a per-frame update during the spring, and the on-screen effect was never observed. See on-screen list | UI/LayerLiveMeters.swift
K-14 | deferred | product decision: lyric rows ease their blur over 0.3 s (costs an offscreen pass per row) or sharpen at once with only the scale animating
K-15 | fixed | `MonthOverview` built once per day, keyed on day, calendar, locale, time zone and first weekday | UI/NotchRootView+Context.swift
K-16 | deferred | broad: needs position split out of `snapshot` across every `interpolatedPosition` reader, including files outside FX1, for an estimated under 1 ms at 0.5 Hz, and shares its root with C-18 (FX2). F-08's single write is the part in Media/
K-17 | fixed | line deleted | UI/NetworkStatusCard.swift
L-01 | fixed | same change as D-01 | as D-01
L-02 | fixed | per-pass `RootPassMemo` reset at the top of `body`: isActiveDisplay, effectiveActivity, base and final layout, overlaid level, visible tab. Reconciled with D's 7 µs: both are right. D's "no finding" was about ~10 lookups per hover tick (1.4 ms/s); L's is ~240 per root pass, 1.7 ms per panel at 7 µs and up to 7 ms at L's 29 µs. So it is the count that matters: one read per pass, and no cross-pass cache of the pointer, and the controller's hover path stays as is | UI/NotchRootView.swift
L-03 | fixed | same change as J-01 | UI/NotchRootView.swift
L-04 | fixed | same change as C-04: stat, statfs and LaunchServices results cached per item set off main | UI/ShelfContent.swift, App/AppCoordinator+Shelf.swift
L-05 | fixed | microphone discovery runs in `Task.detached`, returns plain `MicrophoneOption` values, picker uses them. Retained-discard count stays on main for now because `RecordingService` is `@MainActor`: HANDOFF 1 moves it | UI/SettingsView+Capture.swift
L-06 | fixed | memo: lockedPresentationContent once and one power read per pass per panel instead of 4-280. Cross-pass cache not added: one read per pass is enough, and `LockedChargingPolicy` is FX1's. Coordinator double read in HANDOFF 2 | UI/NotchRootView.swift
L-07 | fixed | `shelfStyle` in `currentLayout` and `restingLayout`; instead of a refresh call in FX3's `ShelfContent`, the controller observes the preference (same pattern as capture inclusion), so any writer is covered | Window/NotchWindowController.swift
L-08 | fixed | `ShareLinkKeychain.hasSecret(for:)` asks for attributes only (no `kSecReturnData`), off main, via `.task(id: accessKeyID)` with a 200 ms pause while typing (none on first appearance); a revision counter stops an in-flight check undoing a Save. `runTest` also reads the secret off main. `saveSecret` stays synchronous on its button: a double click on an async write could race delete and add | UI/SettingsView+Extras.swift
L-09 | fixed | same as E-15, repository side. Takes effect only with HANDOFF 2 | History/HistoryRepository.swift
L-10 | fixed | one-entry lock-guarded memo keyed on body, title, groupCount (the lock because `NotchLayout.layout` is nonisolated) | UI/SystemNotificationCard.swift
L-11 | fixed | Shadow and Glass level sliders bind `$preferences` directly; confirmed no service reads them and NotchRootView, NotchTabBar and IslandGlassShell read through Observation | UI/SettingsView+Activities.swift
L-12 | fixed | `hasClaudeStatusLine` is `@State`, set on appear and after install (also covers the `@State` half of FX6's G-27 B). `NotchHiddenAppRow` looks up once per bundle ID off main. `ReviewQueueService.executable` and `IdleAnimationStore.currentURL` left in `body`: the finding measures them sub-ms and proposes no change | UI/SettingsView+Modules.swift, UI/SettingsView+System.swift
L-13 | fixed | `CommaSeparatedTextField` holds raw text and only parses outward, used by Dictionary and Library tags (`.id(activeRecipeID)` reseeds on a recipe switch). Library tags now also drop empty entries instead of storing `""` | UI/SettingsView+Capture.swift, UI/SettingsView+Modules.swift
L-14 | fixed | recorder intersects with command, shift, option, control only | UI/SettingsView+System.swift
L-15 | fixed | `AudioLevelBar` deleted; `NotchIconButton` reduced to an enum of its four constants, all references still compile; test-only `usesLiquidGlass` etc. kept | UI/NotchShape.swift
L-16 | fixed | file-size caption `.contentTransition(.identity)`, in line with the rule recorded after a659394 | UI/NotchRootView+Status.swift
L-17 | deferred | no visible defect; only change it if flicker is actually seen
M-01 | fixed | added `com.apple.security.personal-information.calendars` to both entitlements; usage strings for all three EventKit requests already exist and match the calls (`requestFullAccessToEvents`, `requestWriteOnlyAccessToEvents`, `requestFullAccessToReminders`). Designated requirement is unaffected, so existing grants survive. Not confirmed at runtime, and reminders has no documented key of its own | Resources/NotchShot.entitlements, Resources/NotchShot-AdHoc.entitlements, Scripts/build_app.sh
M-02 | fixed | exits 2 before the build without both variables, asserts both landed in the bundle after it; explicit `--no-updater` keeps an updater-less release possible; help text documents them | Scripts/release_app.sh
M-03 | fixed | designated requirement of staging and installed bundle compared just before the swap; a difference exits 3 with both identities and the exact command, unless `--allow-permission-loss` (backup kept). Identity selection untouched. `release_app.sh` forwards the flag, since a first Developer ID release over a dev bundle needs it once. Guard extracted and run against the live bundle read-only and a scratch ad-hoc bundle: same passes, ad-hoc refused, ad-hoc over ad-hoc and no bundle pass | Scripts/build_app.sh, Scripts/release_app.sh
M-04 | fixed | same check: "signed" now means an Authority line, so self-signed is protected and ad-hoc is not; refusal text no longer prints a team | Scripts/build_app.sh
M-05 | fixed | one key, covering meter, song recognition and per-app volume. Recording uses ScreenCaptureKit, not a tap, so it is not mentioned | Resources/Info.plist
M-06 | fixed | added Downloads and Documents strings, stating the real uses including the read-only-folder extraction fallback | Resources/Info.plist
M-07 | fixed | refusal path lets the trap clean both directories; success path removes the temp dir beside `trap - EXIT` | Scripts/build_app.sh
M-08 | deferred | version not bumped, per the brief: lead handles it. Hygiene gate did fix: it now tests any exact pin, so a correct bump will not fail with a misleading message | Scripts/check_hygiene.sh
M-09 | fixed | added `.claude/worktrees/`, `*.p12 *.p8 *.cer *.pem *.key *.mobileprovision *.provisionprofile`; `git ls-files` matches none, nothing untracked; `.claude/settings.json` stays visible | .gitignore
M-10 | deferred | product decision: run CI on `codex/liquid-glass-notch` (add it to `push.branches`, or open a draft PR to main), at the cost of macOS runner minutes per push, or keep CI on main only
M-11 | fixed | accepts a fingerprint through the same identity lookup, refuses an empty value; run against this keychain: Apple Development name and fingerprint refused | Scripts/release_app.sh
M-12 | deferred | product decision: Focus Status has no signing path here. Either remove the monitor, settings row and usage string, or keep it for a future provisioned build. Left as is
M-13 | fixed | default path is `temporaryDirectory` with pid and UUID | NotchShotBench/RecipeResponsivenessBenchmarks.swift
M-14 | fixed | report tests `isValid`; `Benchmark.anyInvalid` drives `exit(1)` after cleanup | NotchShotBench/Harness.swift, NotchShotBench/main.swift
M-15 | fixed | reuse branch and `verifiedDigest` deleted, comment corrected | NotchShotBench/Fixtures.swift
```
