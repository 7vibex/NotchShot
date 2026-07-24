# NotchShot

A local-first macOS 26 capture utility that lives in the MacBook notch. Screenshots,
recording, annotation, OCR, history and floating captures, with the notch acting as the
capture launcher, the recording HUD, and the post-capture shelf.

No account, no backend, no telemetry, no subscription. Everything stays on the machine.

## Build and run

```bash
./Scripts/build_app.sh --release
```

Then `open dist/NotchShot.app`.

A real `.app` bundle is required, not `swift run`: macOS ties Screen Recording, Microphone
and Automation grants to a bundle identifier plus a stable code signature, so a bare binary
gets re-prompted or silently denied every launch.

```bash
swift build          # library + executable
swift test           # 121 tests
```

## Architecture

```
Sources/NotchShotKit/
  Core/         domain model — NotchActivity, CaptureIntent, CaptureAsset,
                RecordingConfiguration, MediaSnapshot, Preferences, ScreenGeometry
  Window/       NotchPanel (nonactivating NSPanel), per-display controller,
                notch detection, capture-exclusion registry
  Capture/      ScreenCaptureKit service, selection overlay, scrolling stitcher, export
  Recording/    SCRecordingOutput session, audio metering
  Annotation/   document model, renderer, background composer, .notchshot package, editor
  OCR/          Vision text recognition and data detectors
  Floating/     pinned always-on-top captures
  History/      local JSON-backed history with retention
  Media/        MediaSource protocol, MediaRemote bridge, Apple Events fallback
  Permissions/  staged requests and remediation
  HotKeys/      Carbon global shortcuts
  UI/           notch views, shelf, settings, history browser
  App/          AppCoordinator (the brain), AppDelegate
```

### The three things worth knowing

**State priority.** `ActivityArbiter` resolves one activity from every live source, in the
order `error → selecting → countdown → recording → processing → result → file drop →
expanded → media → idle`. A track change or a stray pointer can never disturb a capture in
flight. `ActivityPriorityTests` pins the whole ordering.

**Coordinate spaces.** Cocoa is bottom-left origin, ScreenCaptureKit is top-left, and
displays sit at arbitrary offsets. Every conversion goes through `ScreenGeometry`, which is
pure and unit-tested against multi-display layouts, because getting it wrong silently
captures the wrong part of the wrong screen.

**Redaction.** Blackout and pixelation are burned into the pixel data *before* crop,
rotation, annotation and background composition — the export path rewrites the bitmap
rather than drawing an opaque shape over an intact layer. `RedactionExportTests` reads the
exported bitmap back and asserts the hidden content is unrecoverable. The editable
`.notchshot` project deliberately keeps the untouched original; only the export is
sanitised.

## Notch behaviour

- Hover reveals a compact peek after a delay. The full interface only opens on a click, a
  shortcut, or a drag — crossing the top of the screen never flares it open.
- One panel per display. Notchless displays get a matching top-centre island (optional).
- Panels are `sharingType = .none` *and* excluded by window id from every capture, so
  NotchShot never appears in its own output.
- Survives Space switches, fullscreen apps, display hot-plug, resolution change, and wake.

## What is in V1

Area / window / display / previous-area capture, 3s and 10s timers, crosshair, pixel
magnifier, frozen-screen selection, aspect lock. PNG / JPEG / HEIC. Manual vertical
scrolling capture with overlap stitching, seam confidence and preserved frames on failure.
H.264 MP4 recording with system audio, microphone, live meters, mic toggle and crash
recovery. Annotation (arrow, rectangle, ellipse, line, text, pencil, highlighter, numbered
steps, blackout, pixelate) with crop, rotate, undo/redo. Background composer with presets,
padding, radius, shadow, aspect presets and optical balancing. Editable `.notchshot`
projects. On-device OCR with link/email/phone detection. Floating pinned captures. Local
history with retention and opt-in text search. Now Playing with artwork, progress and
transport controls.

Phase 2 (not built): horizontal and automatic scrolling, combine images, GIF, webcam,
presenter mode, keystroke overlay, pause/resume, video trimming, colour picker, QR reader,
URL scheme / Shortcuts / Raycast actions.

## Media integration

`MediaSource` has three implementations, tried in order:

1. **MediaRemote bridge** — covers Spotify, Music, Safari and Chrome. Requires the
   BSD-licensed `mediaremote-adapter`, which is **not bundled**: point NotchShot at your own
   copy in Settings → Media. It rides on undocumented system behaviour, so a compatibility
   check runs on first launch and after every macOS build change, and any failure degrades
   silently to the next source.
2. **Apple Events** — Music and Spotify only, needs Automation permission.
3. **Disabled** — the notch simply drops its media layout.

The whole thing sits behind the protocol so an App Store build could delete
`MediaRemoteAdapterSource.swift` and lose nothing else.

## Permissions

Requested lazily, at the moment the feature needs them, never at launch:

| Permission | When |
|---|---|
| Screen Recording | first screenshot or recording |
| Microphone | first recording with the mic enabled |
| Automation | only if the Apple Events media fallback is used |

Denials surface in the notch with a button that deep-links to the right System Settings
pane, and a short poll picks the grant up without a restart.

## Privacy

Captures, recordings, OCR text, projects and history all stay in
`~/Library/Application Support/NotchShot` or wherever you choose to save. Recognised text
enters the search index only if you switch on "Search capture text", and switching it back
off deletes the text already stored. History retention removes rows and thumbnails; it
never deletes your capture files.

## Notes

CleanShot X is proprietary; this is a clean-room implementation of the same product ideas
on Apple's own frameworks. GPL-licensed notch projects were not used as source material.
