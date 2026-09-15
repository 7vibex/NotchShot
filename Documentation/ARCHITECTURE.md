# Architecture

Source of truth: `Sources/NotchShotKit/App/AppCoordinator.swift` (`@MainActor @Observable`).

Services stay dumb and testable (`CaptureService`, `RecordingService`,
`HistoryRepository`, `ClipboardStore`, `MediaCoordinator`,
`ContextCoordinator`). Ordering rules and user-visible behaviour live in the
coordinator and are pinned by `ActivityPriorityTests`.

## Module boundaries

All product logic ships in one `NotchShotKit` target (`Package.swift`).
Only `NotchShotAIReporterSupport` is split out so the reporter helper and the
app share the socket wire format without pulling in AppKit.

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
  recovery, fails open if recovery dies.

## AppCoordinator decomposition

`AppCoordinator` is the known aging risk (~3.9k lines). Narrow interfaces for
extraction:

- `push(_: ShelfItem)` + `history.record` + `persistHistory()`
- `refreshActivity()` -> `windowController.update`
- `present(error:)` / `beginProcessing()` / `endProcessing()`

Planned controllers (in order):

1. `NotchChromeController` — arbiter/activity/peeking/media-panel, system
   levels/OSD, notification queue.
2. `CapturePipelineController` — selection/countdown/scrolling/automation.
3. `RecordingPipelineController` — segments/timelines/finalization/recovery.
4. `ShelfLibraryController` — shelf/stack/file-ops/editor routing.
5. `IntelligenceController` — OCR/document-summary/detected-items.
6. `ProductivityContextBridge` — thin facade over context/clipboard/focus/voice.

Done: `ShelfItem` -> `App/ShelfItem.swift`, `VideoThumbnail` ->
`App/VideoThumbnail.swift` (pure moves, no behaviour change).

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
