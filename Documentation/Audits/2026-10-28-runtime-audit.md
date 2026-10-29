# Capture, recording and accessibility follow-up — 28 October 2026

Continuation of the [source audit](2026-10-28-app-audit.md), requested specifically
to execute the real app's capture, recording, keyboard and VoiceOver paths.

The [29 October automated recovery follow-up](2026-10-29-recording-recovery-audit.md)
adds isolated recovery/discard checks and bounded long-media evidence.

## Scope and environment

- macOS 26.7.2, arm64; the built-in Retina display was tested. The existing Screen Recording
  grant is usable; no TCC grant, reset or signing-identity change was made.
- Initial source was `269fd85`. A concurrent agent-card update, `63b610a`, was
  separately committed and pushed during this pass. It was preserved. Final
  builds/tests include that source plus this follow-up's focused changes.
- The current executables are assembled into the local app bundle and signed
  with the exact existing certificate/designated requirement. Strict nested-code
  verification passes. Existing resources and App Intents metadata are retained
  for this local test; this is not distribution/notarization validation. The final
  Release app remains installed locally and running after the audit.
- Native UI actions use the computer-use driver. A loopback-only Safari fixture
  supplies text, colored boundaries, an animated marker and an explicit audio
  test control. Test outputs are local. Desktop capture contents are not published.
- Temporary evidence: `/tmp/notchshot-live-audit-2026-10-28/`. Tests use the
  command/toolchain paths recorded in the source audit; the Xcode license wrapper
  remains unchanged. Normal distribution packaging remains an environment gap.

Acceptance: exercise selection/confirmation/cancellation and output publication;
record start/pause/resume/stop and check actual media; inspect keyboard commands
and assistive control semantics; reproduce and repair confirmed defects; report
physical-input and hardware limits without substituting source proof for them.

## Confirmed repairs

### R-013 / Medium — Standard capture ignored both output switches

With Standard selected, Save captures to disk **on**, Copy captures to the
clipboard **off**, and a temporary output folder selected, a real keyboard-selected
capture reached the shelf but was written to the managed Captures folder.
`CaptureRecipe.all` assigned Standard `.clipboardOnly`, which also forced a
clipboard copy regardless of the switch. Its UI promises regular capture settings.

Standard now uses the existing configured-folder path: the Save switch decides
between the configured folder and managed storage, and the Copy switch controls
copying. Other named recipes retain their existing clipboard-first contract.
Duplicating Standard also preserves the previous clipboard-first custom-recipe
default, preventing an unrelated change to automatic file creation.

Sources: [CaptureRecipe](../../Sources/NotchShotKit/Capture/CaptureRecipe.swift),
[publication and persistence](../../Sources/NotchShotKit/App/AppCoordinator+Capture.swift).
The regression rejected the old Standard destination before repair; named presets,
duplication and rendering checks pass afterward. Final live confirmation is recorded
with the remaining runtime results below. The repaired live check produced a
1472×956 PNG in the chosen directory. A read-only pasteboard change-count probe
returned **87 before and 87 after**, establishing no clipboard write in that
interval. No clipboard content was read or printed by the probe.

### R-014 / Low — Command-W could not close Settings

Repeated Command-W in the actual Settings window left it open. The application
menu supplied only Settings and Quit, with no Close key equivalent. A File → Close
command now targets the normal responder chain, so auxiliary windows can close
without redefining the nonclosable notch panel's lifecycle.

Source: [AppCommandMenu](../../Sources/NotchShotKit/App/AppCommandMenu.swift).
The menu regression checks actual Command-W dispatch to an injected receiver and
retains a nil production target. The unbundled runner cannot supply a real key
window; actual responder-chain behavior passes in the signed app: Command-comma
opens General, then Command-W closes it and returns to the island.

### R-015 / Medium — Shortcut recorder accessibility exposure

The live Shortcuts accessibility tree exposed eight configured actions
as merged text rather than their visible recorder/clear buttons: Capture Window,
Full Screen, Previous Area, Scrolling, OCR, Start/Stop Recording and Open the Notch.
Other recorder buttons were announced only by their symbolic key combination.

Each row now contains its controls explicitly; recorder buttons name their action
and expose the current binding or recording state. Visible layout and shortcuts
are unchanged. A subsequent live tree contains **all 17 recorder buttons** with
action labels and binding values, plus the applicable Clear controls. Source:
[ShortcutSettings](../../Sources/NotchShotKit/UI/SettingsView+System.swift).
This finding concerns the observed accessibility tree. It is not a claim that a
physical VoiceOver navigation session passed.

### R-016 / Medium — Recording thumbnails advertised an inactive preview

A saved recording's thumbnail was labeled “Open capture preview” and promised a
larger image preview, but clicking it made no change. Its only call was
`openPreview(for:)`, whose image-only guard correctly refuses recordings.

The shared detail thumbnail now preserves the image-preview route for images
and uses the existing identity-checked Open action for other files. The label
and hint describe that action. The image-only coordinator contract remains
unchanged; its existing routing regressions pass. Source:
[ShelfContent](../../Sources/NotchShotKit/UI/ShelfContent.swift).

In the repaired signed app, clicking the new recording thumbnail opened that
exact MP4 in QuickTime. Space started playback; the timeline advanced from zero
to **6.498 seconds** and stopped at the end. The test player was then closed.

## Executed runtime evidence

| Journey | Observed result and boundary |
|---|---|
| Signed capture/recording self-test | The final bundle reports its existing grant usable, writes a 640×400 PNG (38,646 bytes), then a 640×400 MP4 (1.54 s, 30,092 bytes, AVFoundation `isPlayable=true`). The helper owns and removes its temporary directory; log: `final-release-self-test.log`. |
| Area capture | Real overlay; arrow creates/moves selection, Shift-arrow resizes; accessibility value reports 1492×956; Return creates the same-sized shelf asset. The output-switch defect above was observed on this path. |
| Window capture | Tab cycles real shareable windows and announces their names in the selection value; Return captures the isolated Safari fixture, including its actual window bounds. |
| Full-display capture | Real 2940×1912 output. NotchShot's own panel is excluded; the VoiceOver caption/cursor are visible system overlays and remain capturable. Desktop contents are retained locally only. |
| Window recording | Select the fixture with Tab/Return; expanded HUD exposes labeled Pause, Stop and Discard controls. Pause shows 00:13 and remains paused; Resume resumes the clock; Stop reaches finalization and a saved MP4. |
| Recording file validation | H.264 2940×1664, 21.653 s, 4,501,056 bytes; 48 kHz stereo AAC. All 22 one-second frame samples differ, and the inspected frame contains the synthetic moving-marker page. Complete decoding succeeds with the demux time base. Presented packets have unique PTS and increasing DTS; discard/preroll packets explain the extra demux packet count. Merely having an AAC track does not establish non-silent or correctly synchronized audio. |
| Controlled system audio | A second window recording captures an explicit eight-second 440 Hz browser tone. Its MP4 is 28.939 s / 6,480,712 bytes. Decoded audio contains the known tone across seconds 13–21, with RMS 0.030 in the complete one-second blocks. This proves a real non-silent system-audio path; microphone, listening quality and audiovisual synchronization remain separate gaps. |
| Area recording / discard recovery | A 1472×956 recording reaches the discard dialog. Keep Recording returns to an active clock, and Stop saves a 31.077 s / 6,099,798-byte MP4. Move to Trash was not chosen. |
| Display recording / playback | A full-display 2940×1912 recording saves a 6.498 s / 4,796,351-byte MP4. The repaired thumbnail opens it in QuickTime; actual keyboard playback reaches the end. |
| Capture cancellation | Escape leaves the real selection overlay; the configured-folder PNG count remains one. No new image is published for the cancelled operation. |
| Settings keyboard | Command-comma opens Settings. Baseline Command-W failure is reproduced above; after repair the actual key closes Settings. |
| VoiceOver | System VoiceOver and its output helper run; visible speech captions respond to notch activity. Later, the system switch is explicitly confirmed On before and after the input-driver check; the configured modifier is Control-Option or Caps Lock. Control semantics are inspected through the accessibility API. Physical VoiceOver command navigation remains limited as described below. |

The final full test run passes **1,199 tests in 199 suites in 108.405 seconds**,
excluding `PasteboardRaceTests`. Nine focused recipe/menu/preview tests pass.
The final Release build passes in **504.96 seconds**; the earlier Release candidate
passed in 511.47 seconds. These are separate builds on a shared machine, not a
controlled performance comparison. A temporary
key-window test was corrected after proving the unbundled runner has no key
window; it is not retained as false responder-chain evidence. One compile attempt
was invalidated by a concurrent source touch and is not counted as a passing build.

Final source/config/test snapshot: 380 tracked files, SHA-256
`f7f3f53db711eec1a2dcff9ae99dcaea74f97fec13b8924176c4015633e47cab`
for the local `final-source-manifest.json`. Only the two expected late repairs
(the menu test harness and shelf renderer) differ from the earlier complete
snapshot. The built Release executable and installed bundle have the same Mach-O
UUID, `9AE389D2-4222-30B0-BECF-ECE22E1C5E60`; final strict bundle verification passes.
The final Release UI again exposes all 17 recorders and closes Settings with
Command-W. Repository hygiene and whitespace checks pass.

## VoiceOver input-driver limit

Control-Option-Right did not produce verifiable VoiceOver cursor traversal. To
separate an app defect from a driver problem, the synthetic page logged the received
key event with the system switch confirmed On before and after, and the modifier
confirmed in VoiceOver Utility: `ArrowRight`, Control=true, Option=true. Thus the
driver delivered a VoiceOver command to the target webpage as ordinary input.
Global capture-shortcut input likewise reached the page with its modifiers.
These generated keys cannot certify the system's physical VoiceOver/global-hotkey
path. The user confirmed they were away from the Mac and asked to continue
automated checks; no human navigation result is assumed.

## Restoration and retained evidence

- Capture settings again show Desktop, Save to disk Off, Copy to clipboard On.
  Other recording settings were not changed.
- VoiceOver is Off; its utility and the audit-created windowless tutorial helper
  are retired. System Settings is returned to its previous Menu Bar page.
- The dedicated Safari fixture window and QuickTime test session are closed;
  the loopback fixture server is stopped. Other Safari windows were preserved.
- Test media/logs and rollback app bundles remain local. The evidence directory
  and capture subdirectory are owner-only. No test media or desktop contents are
  included in the Git commit.

## Remaining boundaries

- Physical VoiceOver traversal/activation, rotor use, braille, audio intelligibility
  and Full Keyboard Access mode require a physical-input check. Accessibility API
  exposure and a running speech engine do not prove those tasks.
- No microphone/camera grant or device-input test, multi-display/Spaces/hot-plug,
  Lock Screen, scrolling capture, hard crash/power-loss recovery, or long recording
  endurance test was performed in this follow-up.
- The discard dialog's Keep Recording branch is exercised; physical Trash and
  interrupted-recording recovery are not established by that check.
- Denial/regrant and privacy resets were not exercised by altering existing TCC
  permissions. They retain source/test evidence from the initial audit.
- No external service, distribution signing/notarization, update-feed or release
  readiness claim follows from the local app launch.
