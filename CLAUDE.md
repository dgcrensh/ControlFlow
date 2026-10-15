# CLAUDE.md

ControlFlow is a personal iPad app (SwiftUI + Metal) for drawing keyframed vector presentations with the Apple Pencil, forked from Character Studio. See [docs/plans/animation-app.md](docs/plans/animation-app.md) for the plan, [README.md](README.md) for the user-facing behaviour of each milestone and [Schema/README.md](Schema/README.md) for the file format.

## Layout

- `ControlFlow/`: the app target. SwiftUI shell, panels, the Metal canvas (`Canvas/`), and the `.controlflow` document (`Document/`). Shaders are compiled at launch from `Canvas/ShaderSource.swift`; there are no `.metal` files.
- `Packages/ControlFlowCore/`: a UI-free Swift package with everything that can be tested: geometry, camera, curve fitting, Bézier paths, the `Drawing` model and its `Viewport`, `DrawingEditor` and its commands, undo, keyframes (`Presentation`, `Timeline`) and their interpolation, tessellation, touch routing, snapping and the JSON file format. The app links it as a local package.
- `Schema/`: JSON Schema for `presentation.json`, the `demo.controlflow` example, the interpolation test vectors and `validate.py`.
- `.github/workflows/ci.yml`: the three CI jobs. `scripts/check.sh` runs the same three locally.
- `docs/plans/`: planning docs (feature reviews, implementation plans). This is the source of truth for plans: read the relevant one before starting planned work, and update it in the same PR when a plan changes or an item ships. Don't keep plans only outside the repo.

## Rules of the codebase

- **Logic goes in ControlFlowCore, not the app.** ControlFlowCore imports only Foundation (no UIKit, SwiftUI, Metal or CoreGraphics) because CI tests it on Linux. Editing behaviour, input routing and file I/O belong there with unit tests; the app should stay a thin layer that forwards touches and draws what the core produces.
- **Swift 6 language mode** with strict concurrency, in both the package and the app.
- **The file format is stable byte for byte.** `JSONValue` keeps key order and numbers are written with at most 4 decimals, and `DocumentTests` re-saves `Schema/examples/demo.controlflow` and expects identical bytes. When changing the format: update `controlflow-1.0.schema.json`, `Schema/README.md` and the example together, keep new keys optional so older files still read, and add a step to `PresentationFormat.migrations` if the version changes. When changing how transitions play, regenerate `Schema/vectors` with `UPDATE_VECTORS=1 swift test --filter TestVectorTests` and say why in the PR.
- **Undo** stores `EditorSnapshot`s (the whole `Presentation`, copy-on-write, and the current keyframe); one user gesture or command is one undo step. Ids are never reused within a session.
- Coordinates are points with y down; angles are degrees, clockwise on screen; colors are `#RRGGBBAA`.
- When a change alters what the user sees, update the matching milestone notes in `README.md`.

## Building and testing on a Mac

Requirements: **Xcode 26** (the app's deployment target is iPadOS 26, which needs the iOS 26 SDK) with an iOS Simulator runtime installed (Xcode > Settings > Components). Python 3 for the schema check.

Run everything CI runs, from the repo root:

```sh
scripts/check.sh              # core tests, schema check, iPad Simulator build
scripts/check.sh core         # or one step: core, schema, app
```

The steps, if you want to run them by hand:

| CI job | Local command |
| --- | --- |
| ControlFlowCore tests (Linux, `swift:6.1`) | `swift test --package-path Packages/ControlFlowCore` |
| File format schema | `python3 -m venv .venv && .venv/bin/pip install "jsonschema>=4.18" && .venv/bin/python Schema/validate.py` |
| App build (iPad Simulator, `macos-latest`) | `xcodebuild build -project ControlFlow.xcodeproj -scheme ControlFlow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` |

Notes:

- `swift test` on a Mac uses Xcode's toolchain and Apple's Foundation; CI uses Linux's swift-corelibs-foundation. They rarely differ, but formatting, `Decimal` and some string APIs can. To reproduce the Linux job exactly: `docker run --rm -v "$PWD":/src -w /src swift:6.1 swift test --package-path Packages/ControlFlowCore`.
- The ControlFlow scheme also lists `ControlFlowCoreTests` as its test target, so Cmd-U in Xcode runs the same tests. From the command line that needs a concrete simulator: `xcrun simctl list devices available | grep iPad` to pick one, then `xcodebuild test -project ControlFlow.xcodeproj -scheme ControlFlow -destination 'platform=iOS Simulator,name=<iPad name>'`.
- `PerformanceTests` time the hot paths on a generated stress drawing and never fail on speed; see "Measuring performance" in `docs/plans/performance-audit.md` for the full-size, optimized run and the app's Instruments signposts.
- The schema check uses a `.venv` in the repo (git-ignored) because Homebrew's Python refuses a global `pip install`.
- Running on a real iPad needs your personal team under Signing & Capabilities; CI builds with signing off and never runs the app.
- In the Simulator there is no Pencil: a single finger (the mouse) draws, and Option-drag gives two fingers for pan, zoom and rotate.

## In the cloud (no Xcode)

Cloud sessions run on Linux with no Xcode, so only the core tests and the schema check can run there. A SessionStart hook (`.claude/hooks/session-start.sh`) installs Swift 6.1 at session start, taken from the official `swift` image on Docker Hub because download.swift.org is blocked there, so `swift test` works without setup. The app target cannot be built off a Mac; CI's `app-build` job is the check for it. Say so plainly rather than claiming an app change was built.
