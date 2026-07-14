# Poly Shelf

A native macOS library manager for 3D model files (STL, 3MF, OBJ, STEP, GCODE, …).
It indexes, previews, tags, and searches your existing folders **without ever
moving, renaming, or modifying a file on disk**. See
[requirement-poly-shelf.md](requirement-poly-shelf.md) for the full PRD.

## Building

Requirements: **Xcode 15+** (macOS 14 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
xcodegen generate          # produces PolyShelf.xcodeproj (gitignored)
open PolyShelf.xcodeproj   # build & run the PolyShelf scheme
```

Core logic lives in the local Swift package `PolyShelfCore` and can be built
and tested standalone:

```sh
cd PolyShelfCore
swift build
swift test                 # requires Xcode (XCTest is not in the CLT)
```

## Architecture

- `PolyShelfCore/` — SwiftPM package, no UI: GRDB database (FTS5 search),
  scanner (xxHash64 incremental, inode/hash rename matching), format registry,
  parsers (STL sniffer, 3MF zip reader, GCODE/blend thumbnail extractors,
  ModelIO stats), thumbnail pipeline (SceneKit offscreen → embedded → QuickLook
  → icon), auto-tagger, AI tagging client (OpenAI-compatible), export/import,
  FSEvents watcher, duplicate finder.
- `PolyShelf/` — SwiftUI app target: library grid, sidebar, detail inspector,
  settings. AppKit interop for NSOpenPanel/NSWorkspace.
- `project.yml` — XcodeGen manifest (sandbox entitlements, read-only
  user-selected files).

## The invariant

The app opens user files **read-only**. The sandbox entitlement is
`com.apple.security.files.user-selected.read-only`, so writes to watched
folders fail at the OS level. Verify any build with:

```sh
scripts/verify-nondestructive.sh snapshot ~/path/to/test-corpus
# ... exercise the app fully ...
scripts/verify-nondestructive.sh verify ~/path/to/test-corpus
```

Any code path that obtains a writable handle to a file inside a watched folder
is a bug.
