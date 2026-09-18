# Architecture

Source of truth: `Sources/NotchShotKit/App/AppCoordinator.swift` (`@MainActor @Observable`).

Services stay dumb and testable (`CaptureService`, `RecordingService`,
`HistoryRepository`, `ClipboardStore`, `MediaCoordinator`,
`ContextCoordinator`). Ordering rules and user-visible behaviour live in the
coordinator and are pinned by `ActivityPriorityTests`.

## Module boundaries

All product logic ships in one `NotchShotKit` target (`Package.swift`).
Only `NotchShotAIReporterSupport` is split out so the reporter helpers
(`notchshot-ai`, `notchshot-cli`) and the app share socket wire formats without
pulling in AppKit.

- `App/` — `AppCoordinator` facade, `AppDelegate` lifecycle, `ShelfItem`
  model, `VideoThumbnail` poster frames.
- `Capture/` + `Export/` — capture pipeline vs. export/staging. Export never
  reads TCC state directly; it receives validated assets.
- `Recording/` — `RecordingService` owns the ScreenCaptureKit writer.
  Termination joins via `finishForTermination()` so quit never races the writer.
- `History/` + `Files/` + `Floating/` — persistence, file ops, pinned captures.
  `SafeAssetFile.isCurrentAndSafe` gates Save As / bug reports against path swaps.
- `Updates/` — `SecureUpdateController` is fail-closed: without an HTTPS
  `SUFeedURL` and a 32-byte EdDSA `SUPublicEDKey` the updater stays `nil`
  (`isConfigured == false`). Local builds are updater-disabled.
- `Automation/` — `notchshot://` router rejects unknown params, rate-limits,
  canonicalizes + inode-validates paths, requires foreground confirmation.
- `System/` — OSD suppression arms the recovery lease first, refuses without
  recovery, fails open if recovery dies. `FocusStatusMonitor` reads Focus
  on/off only through `INFocusStatusCenter` and stays inert without the
  entitlement.
- `Core/Island/` + `UI/Island/` + `Input/` — the multi-activity island: pure
  activity model, adapters, presentation engine and burst queue; the
  container, shared-element layer and compact/expanded views; swipe tracking.
  See [ACTIVITY_ENGINE.md](ACTIVITY_ENGINE.md).
- `External/` — the local Live Activity API: owner-only Unix socket server and
  the bounded `ExternalActivityRegistry`. The wire format lives in
  `NotchShotAIReporterSupport/LiveActivityProtocol.swift`, shared with the
  `notchshot-cli` executable (`Sources/NotchShotCLI`).

## AppCoordinator layout

`AppCoordinator` is the one integration point for every pipeline. Stored state
lives in `AppCoordinator.swift`; behaviour is grouped by pipeline in sibling
files so no single file carries the whole surface:

- `AppCoordinator.swift` — state, wiring, error presentation, processing label
- `AppCoordinator+Capture.swift` — selection, countdown, scrolling, capture flow
- `AppCoordinator+Recording.swift` — segments, interaction timelines, finalization
- `AppCoordinator+Shelf.swift` — shelf, capture stack, shelf file operations
- `AppCoordinator+System.swift` — dictation, level HUD, notification mirror
- `AppCoordinator+Automation.swift` — `notchshot://` routing, Finder drops
- `AppCoordinator+Island.swift` — island activity collection, selection,
  expansion, bursts, external activities, Focus
- `AppCoordinator+Clipboard.swift` — clipboard history

The same pattern applies to the largest views: `NotchRootView+*` and
`SettingsView+*` split by surface. `Scripts/check_hygiene.sh` keeps every Swift
file under 2500 lines.

## Activity resolution

`ActivityArbiter.resolve()` still returns one `NotchActivity`. Modal takeovers
(selection, countdown, dictation, processing, file drop, shelf, menu, banners)
keep their own cases. Long-lived work resolves to
`NotchActivity.island(IslandLayoutDescriptor)`, whose descriptor names the
primary, the satellites, the level and the burst kind — structure only, so live
values never re-trigger shell animation. `IslandPresentationEngine` decides that
structure; `ActivityPriorityTests` pins the legacy order and
`IslandArbiterTests` / `IslandPresentationEngineTests` pin the island rules.

## State, navigation, async rules

- UI state is `@Observable` on the coordinator; services expose shared
  singletons but never drive `NotchActivity` directly.
- Navigation uses `onOpen*` closures set by `AppDelegate` (14 aux windows).
  Sessions call back `onExported/onStageChange` into history/shelf.
- Async work is `Task` + operation IDs (`captureOperationID`,
  `recordingStartOperationID`) with explicit cancel paths
  (`cancelCurrentOperation`, `cancelPendingRecordingStart`).
- Redaction burns into pixels before crop/rotate/annotate/compose; preview
  and export share the resolved opaque fill (`RedactionExportTests`).
- Coordinate conversions go through `ScreenGeometry` (`ScreenGeometryTests`).
