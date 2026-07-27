# NotchShot

A local-first macOS 26 capture utility that lives in the MacBook notch. Screenshots,
recording, annotation, OCR, history and floating captures, with the notch acting as the
capture launcher, the recording HUD, and the post-capture shelf.

No account, no backend, no telemetry, no subscription. Captures, recordings, transcripts,
OCR text, projects and history stay on the Mac. If the Spotify Apple Events fallback is
enabled, NotchShot fetches the current track's artwork from Spotify's HTTPS CDN; it never
uploads capture content.

## Build and run

```bash
./Scripts/build_app.sh --release
```

Then `open dist/NotchShot.app`.

To verify screenshot and recording under the app's actual Screen Recording identity:

```bash
dist/NotchShot.app/Contents/MacOS/NotchShot --self-test
```

The check captures a small temporary area, writes PNG and MP4, validates them, and removes
both immediately.

A real `.app` bundle is required, not `swift run`: macOS ties Screen Recording, Microphone
and Automation grants to a bundle identifier plus a stable code signature, so a bare binary
gets re-prompted or silently denied every launch.

```bash
swift build          # library + executable
swift test           # full unit and lifecycle suite
```

The app bundle build now stops if it cannot find a stable signing identity. That protects
the existing Screen Recording grant from being replaced by a new ad-hoc code identity.
Use `--adhoc` only for a disposable build where re-granting permission is acceptable.

## Architecture

```
Sources/NotchShotKit/
  Core/         domain model — NotchActivity, CaptureIntent, CaptureAsset,
                RecordingConfiguration, MediaSnapshot, Preferences, ScreenGeometry
  Window/       NotchPanel (nonactivating NSPanel), per-display controller,
                notch detection, capture-exclusion registry
  Capture/      ScreenCaptureKit service, selection overlay, recipes, capture stack,
                scrolling stitcher, export
  Recording/    SCRecordingOutput session, audio metering, click zoom, local captions
  Annotation/   document model, renderer, background composer, .notchshot package, editor
  OCR/          Vision text recognition and data detectors
  Privacy/      on-device privacy suggestions and explicit redaction handoff
  Comparison/   before/after slider and pixel-difference rendering
  Reporting/    inspectable, opt-in bug-report packages
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
flight. `ActivityPriorityTests` pins the whole ordering. A compact volume/brightness strip
is composited independently when the experimental native-overlay replacement is active,
so an in-flight result cannot swallow the only visible level feedback.

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

## System volume and brightness HUD

NotchShot can mirror volume changes and brightness-key changes in the notch. macOS does not
publish whether a sampled brightness value came from a slider or the ambient-light
controller, so brightness publication is conservatively armed only by a recent brightness-key
system event and then checked against the sampled value. Automatic brightness therefore stays
silent; Control Centre and third-party brightness changes may stay silent too. Brightness
mirroring can be switched off independently.

The optional **Replace the macOS overlay** setting is experimental and for direct
distribution only. Apple provides no supported API for suppressing the shared system OSD,
so this mode pauses `OSDUIHelper` only after arming the bundled recovery process. The helper
holds a kernel-backed lease: normal quit, crash, or force-quit closes it and restores the
native overlay. NotchShot refuses to suppress without recovery, fails open if recovery dies,
and leaves the native OSD running whenever the notch/HUD cannot render or VoiceOver is on.
Because the integration controls another process, it is off for new installs, can hide
unrelated Apple overlays, is incompatible with App Sandbox, and is not an App Store feature.

## What is in V1

Area / window / display / previous-area capture, 3s and 10s timers, crosshair, pixel
magnifier, frozen-screen selection, aspect lock. PNG / JPEG / HEIC. Manual vertical
scrolling capture with overlap stitching, seam confidence and preserved frames on failure.
H.264 MP4 recording with system audio, microphone, a real live audio-history waveform,
click highlights and background framing, optional on-device transcript / `.srt` captions,
sleep prevention, and crash recovery. Recording audio sources are chosen before a take so
the direct ScreenCaptureKit file cannot be silently finalized by a mid-recording stream
reconfiguration. Annotation (arrow, rectangle, ellipse, line, text, pencil, highlighter, numbered
steps, blackout, pixelate) with crop, rotate, undo/redo. Background composer with presets,
padding, radius, shadow, aspect presets and optical balancing. Editable `.notchshot`
projects. On-device OCR with link/email/phone detection. Floating pinned captures. Local
history with retention and opt-in text search. Now Playing with artwork, progress and
transport controls. Capture Stack collection with reorder, per-shot annotation, numbered
storyboard, long-image, filmstrip and PDF exports. Named GitHub Issue, App Store,
Documentation, Social Post and Bug Report recipes. On-device privacy suggestions for
email, phone, token, account ID and faces; nothing is selected or redacted automatically.
Interactive before/after comparison with an optional difference overlay. Inspectable bug
report folders where every diagnostic detail is off until selected.

Later (not built): horizontal and automatic scrolling, GIF, webcam, presenter mode,
post-process click zoom and cursor smoothing, live audio-source changes, keystroke overlay,
pause/resume, video trimming, colour picker, QR reader, URL scheme / Shortcuts / Raycast
actions. Generic notch modules such as clipboard, timer, AirPods, calendar and file
transforms remain out of the default product so the capture workflow stays focused.

## Media integration

`MediaSource` has three implementations, tried in order:

1. **MediaRemote bridge** — covers Spotify, Music, Safari and Chrome. Requires the
   BSD-licensed `mediaremote-adapter`, which is **not bundled**: point NotchShot at your own
   trusted copy in Settings → Media. The selected executable runs with your account's
   permissions; NotchShot rejects links/non-files, applies a strict timeout and output cap,
   and still cannot sandbox an external binary. It rides on undocumented system behaviour,
   so a compatibility check runs on first launch and after every macOS build change, and
   any failure degrades silently to the next source.
2. **Apple Events** — Music and Spotify only, needs Automation permission and is off by
   default.
3. **Disabled** — the notch simply drops its media layout.

The whole thing sits behind the protocol so an App Store build could delete
`MediaRemoteAdapterSource.swift` and lose nothing else.

Music artwork is read locally. Spotify exposes artwork as a CDN URL, so the Apple Events
fallback makes one HTTPS request per track and caches the result in memory.

## Permissions

Requested when the feature needs them. Screen Recording and Microphone are never requested
at launch. Automation is requested only after the user enables the Apple Events media
fallback and it finds Music or Spotify already running:

| Permission | When |
|---|---|
| Screen Recording | first screenshot or recording |
| Microphone | first recording with the mic enabled |
| Automation | only if the Apple Events media fallback is used |

Denials surface in the notch with a button that deep-links to the right System Settings
pane. macOS does not apply a newly granted Screen Recording permission to the process that
requested it, so NotchShot explicitly shows **Quit & Reopen** after it detects the grant.
The next signed launch can capture immediately.

## Privacy

Captures, recordings, transcripts, OCR text, projects and history all stay in
`~/Library/Application Support/NotchShot` or wherever you choose to save. Recognised text
enters the search index only if you switch on "Search capture text", and switching it back
off deletes the text already stored. History retention removes rows, thumbnails and hidden
app-managed working files (including clipboard-only captures and their managed projects).
It never deletes captures saved to a user-selected folder or files dragged in from Finder.
An explicit destructive history action can still move a user document to Trash. Privacy
Review runs with Vision on the Mac and only suggests regions. Bug packages never include
logs, serial numbers, account data, system details or an editable unredacted project unless
the corresponding choice is explicit.

## Distribution boundary

The current bundle is a hardened-runtime, directly distributed Mac app. It is deliberately
not sandboxed because its opt-in OSD replacement, system-shortcut takeover and external
Now Playing helper conflict with App Sandbox and public-API-only App Store requirements.
An App Store variant must remove those integrations, enable App Sandbox, and complete the
normal archive, notarization/review, privacy and real-device validation gates.

## Notes

CleanShot X is proprietary; this is a clean-room implementation of the same product ideas
on Apple's own frameworks. GPL-licensed notch projects were not used as source material.
