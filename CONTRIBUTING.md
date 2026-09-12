# Contributing to NotchShot

Thanks for taking the time to contribute. This document covers what you need to build the
project, what a good pull request looks like, and the invariants that every change must keep.

## Requirements

- macOS 26 (the package targets `.macOS(.v26)`)
- Xcode 26 with the macOS 26 SDK
- Swift 6.2 toolchain

## Build and test

```bash
swift build          # library and executables
swift test           # full unit and lifecycle suite
```

For the real `.app` bundle, including the code signature that Screen Recording and
Microphone grants are tied to:

```bash
./Scripts/build_app.sh --release
open dist/NotchShot.app
```

`swift run` is not enough for capture testing: macOS binds privacy grants to a bundle
identifier plus a stable signature, so a bare binary is re-prompted or denied on every
launch. Use `--adhoc` only for a disposable build where re-granting permission is fine.

## Before you open a pull request

- Small, focused changes are reviewed fastest. If a change touches several subsystems,
  consider splitting it.
- For non-trivial behavior changes, open an issue first so we can agree on the approach.
- Every behavior change should come with a test in `Tests/NotchShotKitTests/`. The
  existing suite is the reference for style and assertion patterns.
- Run `swift test` before pushing. CI runs `swift build` and `swift test` on every PR.

## Invariants every change must preserve

NotchShot's value is that captures, recordings, OCR text, and history stay on the Mac. A
PR that breaks any of these will not be merged:

- **Redaction burns pixels before export.** Blackout and pixelate rewrite the bitmap
  before crop, rotation, annotation, and background composition. Do not replace that with
  an opaque overlay on an intact layer. `RedactionExportTests` asserts the hidden content
  is unrecoverable and must keep passing.
- **No network calls without an explicit user action.** The Spotify artwork fetch,
  Open-Meteo refresh, LocalSend transfer, and Sparkle update check are the only network
  paths, each user-visible and documented in the README.
- **Permissions are requested just-in-time.** Screen Recording and Microphone are never
  requested at launch.
- **Experimental integrations stay opt-in and fail open.** The OSD replacement, media
  adapter, and clipboard history are off by default and must degrade gracefully.
- **No capture content in tests, fixtures, logs, or bug reports.** Use synthetic images
  and fake paths (`/Users/example/...`).

## Style

- Match the surrounding code. Swift 6 language mode is enabled for every target.
- Keep the existing module boundaries (`Sources/NotchShotKit/<Area>/`).
- Prefer small, testable types over logic in views; `AppCoordinator` is the integration
  point, not a place for new feature logic.

## Commit messages

Write imperative, concise subjects that say what changed and why it matters, for example:

```
Fix capture exclusion for pinned windows on secondary displays
```

## Reporting bugs and security issues

- Bugs: use the issue templates in `.github/ISSUE_TEMPLATE/`.
- Security issues: do not open a public issue. See [SECURITY.md](SECURITY.md).

All participation is covered by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
