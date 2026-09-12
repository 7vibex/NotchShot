# NotchShot

[![CI](https://github.com/7vibex/NotchShot/actions/workflows/ci.yml/badge.svg)](https://github.com/7vibex/NotchShot/actions/workflows/ci.yml)

A local-first macOS 26 capture utility that lives in the MacBook notch. Screenshots,
recording, annotation, OCR, history and floating captures, with the notch acting as the
capture launcher, the recording HUD, and the post-capture shelf.

No account, no backend, no telemetry, no subscription. Captures, recordings, transcripts,
OCR text, projects and history stay on the Mac. If the Spotify Apple Events fallback is
enabled, NotchShot fetches the current track's artwork from Spotify's HTTPS CDN; it never
uploads capture content. Weather coordinates are sent to Open-Meteo only after an explicit
Refresh, and LocalSend sends only the files the user selects directly to a private-network
receiver. Configured public builds also contact their HTTPS Sparkle feed to check for signed
updates.

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
  Annotation/   document model, renderer, background composer, local subject lifting,
                .notchshot package, editor
  OCR/          Vision document recognition, tables, lists, data detectors and barcodes
  Privacy/      on-device privacy suggestions and explicit redaction handoff
  Comparison/   before/after slider and pixel-difference rendering
  Reporting/    inspectable, opt-in bug-report packages
  Floating/     pinned always-on-top captures
  Files/        shelf rename / move / compress, Quick Look presenter
  History/      local JSON-backed history with retention
  Clipboard/    opt-in local clipboard history, monitor and store
  Media/        MediaSource protocol, MediaRemote bridge, Apple Events fallback
  Context/      AI activity, calendar, document summary, power and audio-route modules
  Productivity/ local notes and lyrics, weather, stats, terminal, app launcher,
                window snapping, pointer locator, camera preview and LocalSend client
  Permissions/  staged requests and remediation
  HotKeys/      Carbon global shortcuts
  UI/           notch views, shelf, settings, history browser
  App/          AppCoordinator (the brain), AppDelegate
```

### The three things worth knowing

**State priority.** `ActivityArbiter` resolves one activity from every live source, in the
order `error → selecting → countdown → dictation → recording → processing → file drop →
result → expanded → system notification → system level → interrupting context → media →
passive context → idle`. A track change or a stray pointer can never disturb a capture in
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
magnifier, frozen-screen selection, aspect lock. PNG / JPEG / HEIC. Manual or automatic
vertical and horizontal scrolling capture with overlap stitching, seam confidence and
preserved frames on failure. H.264 MP4 recording with system audio, microphone, a real
live audio-history waveform, click highlights and background framing, optional presenter
camera and privacy-filtered shortcut overlay, optional post-process click zoom and cursor
smoothing, optional on-device transcript / `.srt` captions,
pause/resume, video trimming, sleep prevention, and crash recovery. Recording audio sources are chosen before a take so
the direct ScreenCaptureKit file cannot be silently finalized by a mid-recording stream
reconfiguration. Annotation (arrow, rectangle, ellipse, line, text, pencil, highlighter, numbered
steps, blackout, pixelate) with crop, rotate, undo/redo. Background composer with presets,
padding, radius, shadow, aspect presets and optical balancing. Editable `.notchshot`
projects. On-device structured OCR with paragraphs, lists, table copy as TSV/Markdown,
link/email/phone/address detection, and QR/barcode reading. Floating pinned captures. Local
history with retention, favorites, tags, collections, opt-in text search and opt-in local
Spotlight discovery. Screenshots can be OCR'd and translated on-device; recording captions
can use the same Translation framework flow. Now Playing with artwork, progress and
transport controls, and unlock refresh. The retired lock-screen media cover/wave
is no longer built.
Capture Stack collection with reorder, per-shot annotation, numbered
storyboard, long-image, filmstrip and PDF exports. Named GitHub Issue, App Store,
Documentation, Social Post and Bug Report recipes. On-device privacy suggestions for
email, phone, token, account ID and faces; nothing is selected or redacted automatically.
Interactive before/after comparison with a thresholded difference overlay and share/export.
Shelf files can be opened normally or with a chosen compatible app, previewed with Quick
Look, renamed, moved, compressed to a ZIP, or sent straight to AirDrop without going through
the whole share sheet. Holding Finder files over the notch now opens an AirDrop-style tray:
release over **Shelf**, **AirDrop**, **Share**, or **ZIP**. AirDrop, Share, and ZIP keep the
validated multi-file batch together; Shelf retains its visible five-item cap and reports any
overflow. The Basket-style shelf shows aggregate file count/size, offers
persistent detail and grid presentations, and separates non-destructive **Remove from Shelf**
from an explicitly destructive **Move File to Trash**. Six immediate shelf actions are
user-configurable; the rest stay in a grouped **More** menu. Finder's Services menu can
park selected regular files in the shelf without copying or moving them. An opt-in local
clipboard history keeps text, links, colours, images and file copies, with search, type filters,
user labels, explicit on-device OCR for searching image clippings, pinning, retention,
optional clear-on-quit, and per-app exclusions. **Remove
Background** uses Apple's on-device foreground-instance mask
to lift noticeable subjects into a full-size transparent PNG; it needs no account, network,
or additional permission.
Pixel inspection with HEX/RGB/HSL, pixel measurement and WCAG contrast. Outcome-based image
export presets with dimension, format, real encoded-byte fitting and estimated-size previews.
Recipes can add OCR, library tags, a collection and a target file-size ceiling. Recordings
can export to an exact even-pixel MP4 canvas or a bounded animated GIF. Seven discoverable
App Shortcuts cover area, display, previous-area and scrolling capture, area recording,
clipboard OCR and the latest capture; the bundle build fails if App Intents metadata is absent.
The system Share Sheet is
available for results, History, annotations and comparison output. Inspectable bug report
folders keep every diagnostic detail off until selected.

The expanded Now Playing card stacks artwork, title and artist over a seek bar with elapsed
and remaining times, and a transport row that also opens two in-island lists: the current
public Core Audio output, for switching among available local, Bluetooth, display, and
AirPlay routes, and Playing Next, which reads the next few tracks from Music's own scripting
interface. Playing Next appears only for Music — Spotify publishes no queue and neither does
MediaRemote — and it follows playlist order, so shuffled playback is not reflected. Opt-in Calendar
Glance adds compact, hover, and expanded agenda/month states without
persisting event titles. Explicit document drops can be summarized locally through PDFKit,
Vision OCR, and Apple Intelligence when available, with a visible local extractive fallback
and copy/open/save/forget controls. Event-driven charging feedback is enabled by default;
public Core Audio route feedback is optional and never invents accessory battery values.
Low-battery transitions reveal a compact alert that reads the public Low Power Mode state and
opens macOS Battery settings from its action pill. Foundation exposes that state as read-only,
so NotchShot does not run privileged power commands or present the pill as a direct system toggle.
An explicit local reporter lets Claude Code, Codex, Cursor, scripts, and build tools show
working, waiting, finished, failed, step, and measured-progress states in the island. Claude
Code sessions can also expose multiple live sessions, approve or deny a pending permission,
and open a bounded, on-demand local conversation view. Hook events never manufacture a
percentage, read private app UI, or leave the Mac. Setup and the wire-format boundary are
documented in [`Documentation/AI_ACTIVITY.md`](Documentation/AI_ACTIVITY.md).
Voice Notes show progressive words in the island while the microphone is recording, save the
complete audio independently, and run a final on-device pass after Stop. A missing local speech
model or live-analysis failure never uploads or discards the recording; the island shows the
fallback state and keeps the saved audio available in Finder.
The app-owned Focus Timer and natural-language Planner are also live: Planner writes only the
Calendar event or Reminder the user confirms. The Focus Timer deliberately does not claim to
sync with Apple's Clock app, whose timers are not part of EventKit's public calendar/reminder API.
The Productivity Center adds local notes, user-supplied per-track lyrics, manually
refreshed weather, public system statistics, a bounded local terminal, an installed-app launcher,
Accessibility-authorized window snapping, a temporary pointer locator, and a camera preview.
The app-owned Notification Center schedules local alerts, reconciles only NotchShot's delivered
and pending requests, and supports Mark Done plus a bounded **Reply in NotchShot** action stored
locally against the alert. A separate Accessibility opt-in mirrors only banners macOS is visibly
presenting; recognized Messages and WhatsApp cards can open the source app for a real reply there.
NotchShot still does not read hidden history, dismiss cross-app notifications, or send a reply on
another app's behalf.
The lock-screen music player and song notifications are disabled, including legacy opt-ins.
An independently opted-in, display-only locked-session activity stack presents the latest
due NotchShot alert, and Focus in translucent cards; it is an AppKit panel, not a WidgetKit Lock
Screen widget. The public API boundary and runtime proof requirements are documented in
[`Documentation/NOTIFICATIONS_AND_LOCK_SCREEN.md`](Documentation/NOTIFICATIONS_AND_LOCK_SCREEN.md).
LocalSend v2 transfers are available from the shelf and the Finder drop tray. HTTPS receivers
require the user to compare and approve the receiver certificate's SHA-256 fingerprint before any
file bytes are uploaded; public internet destinations are rejected.
The hardware-connected island shell stays opaque black. Expanded capture, shelf, Now Playing,
and AI activity place native macOS Liquid Glass only on interactive control chrome inside that
shell, while Reduce Transparency and Increase Contrast use solid, outlined controls instead.
Recording, processing, errors, and dense context content remain stable and opaque.

Later (not built): live audio-source changes during an active ScreenCaptureKit recording.
The Productivity Center now provides a standalone camera preview, window snapping, and an
installed-app launcher; none is allowed to interfere with an in-flight capture or recording.

Droppy parity stops at public, consented integrations. NotchShot does not read another app's
Notification Center history or inject replies into WhatsApp/iMessage, control an unrelated
VPN configuration, switch macOS Low Power Mode, expose another player's private Up Next queue,
or extract proprietary animated artwork. It can manage its own notifications and explicit AI
reporter events, manage a VPN it ships under the required Network Extension entitlement, read
Low Power Mode, and control an app-owned MusicKit queue—but those are not faithful substitutes
for the cross-app Droppy behaviors, so the UI does not pretend they are.

Two things that were on that list have since moved off it. The shelf already held real
files, so Quick Look, Rename, Move and Compress were missing from a surface that already
implied them rather than new modules bolted onto it. And a clipboard history is the one
"generic module" that the capture workflow genuinely reaches for — copying a capture and
copying its recognised text are both already core paths. Both are described above; the
clipboard is off until you switch it on.

The product rationale, privacy boundaries, acceptance criteria, and implementation status
for calendar, local document summaries, charging/audio-route feedback, and music behavior
across lock/unlock are documented in [`FEATURE_PROPOSALS.md`](FEATURE_PROPOSALS.md).

## Automation URLs

NotchShot registers a narrow, documented `notchshot://` scheme for Shortcuts, Raycast,
Alfred and browser launchers:

```text
notchshot://capture/area?action=copy
notchshot://capture/display?display=2&preset=bug-report&action=annotate
notchshot://capture/previous?action=annotate
notchshot://record/area
notchshot://ocr?source=clipboard&format=markdown
notchshot://ocr?source=clipboard&format=tsv
notchshot://open/latest
notchshot://pin?file=/absolute/path/to/image.png
```

Capture actions are `copy`, `save`, or `annotate`. Presets are `standard`,
`github-issue`, `app-store`, `documentation`, `social-post`, and `bug-report`.
Clipboard OCR formats are `text`, `markdown`, and `tsv`; TSV returns detected tables only
and falls back to ordinary recognized text when the image has no table.
Display 1 is the current main display; the remaining displays are ordered by macOS desktop
position from left to right, then top to bottom. Selection and measurement coordinates use
global display points for UI and source-image pixels for exported imagery.

Unknown or repeated parameters are rejected. Requests are rate-limited, file paths are
canonicalized and inode-validated before use, and every URL request requires foreground
confirmation. The scheme cannot execute programs, open arbitrary schemes, or change
experimental/private settings.

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
| Calendar | only after Calendar Glance is enabled in Settings |

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

Clipboard history is off until you turn it on, and turning it back off deletes what was
already kept. It honours the `org.nspasteboard.*` concealed and transient markers that
password managers set on a copied password, so those clippings are never recorded whatever
app they came from, and it ships with the common password managers on a per-app exclusion
list as well. The store lives in `~/Library/Application Support/NotchShot/clipboard.json`
at owner-only permissions, is never included in a bug report, and pinned items are the only
ones exempt from retention.

Calendar event titles and unsaved document summaries stay in memory and never enter History
or diagnostics. Document reading starts only after confirmation; nothing is uploaded, and a
saved summary contains the visible summary plus source filename and timestamp rather than an
invisible copy of the full source text.

AI activity is written only after an explicitly connected hook or reporter command. Records
live in the owner-only `AI Activity` support folder, never enter capture History or bug
reports, and are ignored after their bounded display lifetime; up to 20 finished or failed
records persist in the owner-only `AI Activity History.json` for the Recent list until
cleared. The hook bridge reads lifecycle labels and short task metadata, not tool contents.
A Claude conversation is read only after the user opens that session's button, stays in
memory, and omits hidden reasoning and tool payloads.

## Distribution boundary

The current bundle is a hardened-runtime, directly distributed Mac app. It is deliberately
not sandboxed because its opt-in OSD replacement, system-shortcut takeover and external
Now Playing helper conflict with App Sandbox and public-API-only App Store requirements.
An App Store variant must remove those integrations, enable App Sandbox, and complete the
normal archive, notarization/review, privacy and real-device validation gates.

Local builds use `./Scripts/build_app.sh`. A public direct-distribution release
must use the stricter pipeline below; it refuses Apple Development and ad-hoc
identities, waits for notarization, staples the accepted ticket, and requires a
successful Gatekeeper assessment before producing `dist/NotchShot.zip`:

```bash
./Scripts/release_app.sh \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --keychain-profile "notchshot-notary" \
  --version 1.2.0 \
  --build 42
```

Create the named profile once with `xcrun notarytool store-credentials`; never
put App Store Connect credentials or signing material in this repository.

Public builds use Sparkle 2 only when both release-time values are supplied. The app refuses
non-HTTPS feeds and malformed public keys, while local builds remain updater-disabled instead
of contacting a placeholder service:

```bash
NOTCHSHOT_SPARKLE_FEED_URL="https://updates.example.com/notchshot/appcast.xml" \
NOTCHSHOT_SPARKLE_PUBLIC_KEY="BASE64_ED25519_PUBLIC_KEY" \
./Scripts/release_app.sh \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --keychain-profile "notchshot-notary" \
  --version 1.2.0 \
  --build 42
```

Keep the EdDSA private key outside the repository and update host. Publish only notarized,
stapled, code-signed archives and a signed HTTPS appcast. The app menu exposes **Check for
Updates…**; configured release builds also enable automatic checks and installation.

The current product UI is intentionally English-only. The bundle declares
English as its sole supported localization; no translated or RTL-ready release
is claimed until the UI strings have been moved into a localization catalog and
tested in those layouts.

## Notes

CleanShot X is proprietary; this is a clean-room implementation of the same product ideas
on Apple's own frameworks. GPL-licensed notch projects were not used as source material.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first: it covers
requirements, build and test commands, and the privacy invariants every pull request must
preserve. Participation is covered by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Report
security issues privately as described in [SECURITY.md](SECURITY.md).

## License

NotchShot is released under the [MIT License](LICENSE).

