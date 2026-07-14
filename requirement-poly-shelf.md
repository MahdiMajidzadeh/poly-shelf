# Poly Shelf — Requirements Document

**Product:** macOS app for managing 3D model files
**Version:** 1.0
**Date:** 2026-07-14
**Stack:** Native Swift / SwiftUI (macOS 14+)
**Status:** Draft for implementation

---

## 1. Problem Statement

3D printing hobbyists and designers accumulate hundreds of model files (STL, 3MF, OBJ, STEP, …) spread across download folders, project folders, and archives. Finder gives no useful preview, no tagging, no search by content, and renaming files for clarity breaks slicer profiles, links, and folder conventions. The result: people re-download models they already own and waste time hunting for files.

Poly Shelf is a **non-destructive library layer** over the user's existing folders: it indexes, previews, tags, and searches 3D files **without ever moving, renaming, or modifying them on disk**.

## 2. Goals

1. A user can add any folder and see all contained 3D models with visual previews within one scan pass.
2. Every indexed model is findable by tag, display name, original filename, format, or folder within ~1 second of typing.
3. 100% of file operations are non-destructive — the app never writes to, renames, moves, or deletes user model files.
4. Auto-tagging works fully offline out of the box; AI tagging is an opt-in enhancement using a user-supplied endpoint.
5. The entire library (or any single folder's metadata) can be exported and re-imported losslessly on another machine.

## 3. Non-Goals (v1)

- **No slicing or printing integration.** Poly Shelf is a library manager, not a slicer front-end.
- **No file editing/repair** (mesh repair, decimation, conversion between formats). Separate initiative; keeps the non-destructive guarantee simple.
- **No cloud sync or accounts.** Export/import is the portability mechanism. Sync is a P2 architectural consideration only.
- **No moving/organizing files on disk.** Virtual organization only (tags, display names, collections later).
- **No Windows/Linux version.** Native Swift is a deliberate choice.
- **No in-app model marketplace/downloader.**

## 4. Personas & User Stories

Primary persona: **the printing hobbyist** — downloads models from Printables/Thingiverse/MakerWorld, keeps them in a few big folders, prints regularly.

Secondary persona: **the designer/engineer** — mixes CAD (STEP) and mesh files across project folders.

**P0 stories**

- As a hobbyist, I want to add my `~/3D Models` folder so that everything inside it appears in one searchable library.
- As a hobbyist, I want to see a 3D preview thumbnail for each file so that I can recognize models visually instead of by cryptic filenames (`dragon_v3_final_FINAL.stl`).
- As a hobbyist, I want files auto-tagged (e.g. `articulated`, `vase`, `benchy`, `multi-part`) so that I can browse by category without manual work.
- As a hobbyist, I want to give a file a readable display name ("Articulated Dragon — small") while the file on disk keeps its original name, so that my slicer links and folder structure never break.
- As a hobbyist, I want to search across display names, original names, and tags so that I find any model in seconds.
- As a designer, I want to choose which formats the app indexes so that my library isn't polluted by intermediate files I don't care about.
- As a user, I want to export my library metadata and import it on a new Mac so that years of tagging and renaming survive a machine migration.
- As a user, I want to export/import metadata for a single folder so that I can share a curated folder (files + metadata sidecar) with a friend.

**P1 stories**

- As a hobbyist, I want the app to detect new/changed/deleted files automatically so that the library stays current without manual rescans.
- As a hobbyist, I want duplicate detection (same content, different names/locations) so that I can clean up my collection.
- As a power user, I want to plug in my own LLM endpoint (URL, API key, model name) so that AI generates richer tags and descriptions from previews.
- As a user, I want a detail view (dimensions, triangle count, size on disk, print-bed fit hint) so that I can judge a model before opening a slicer.

**Edge cases (must be handled, all priorities)**

- Folder on an external drive that is currently unmounted → items shown as *offline*, metadata preserved.
- File deleted outside the app → item marked *missing*, metadata retained for 30 days (configurable), user can relink or purge.
- Corrupt/unparseable model file → indexed with generic icon, tagged `unreadable`, never crashes the scanner.
- Two watched folders where one is inside the other → deduplicate; the file is indexed once.
- Zero-state: no folders added → onboarding screen with "Add Folder" call to action.

## 5. Functional Requirements

### 5.1 Folder management — **P0**

- FR-1.1: User adds one or more root folders via `NSOpenPanel` or drag-and-drop onto the window/dock icon.
- FR-1.2: Folder access persists across launches via security-scoped bookmarks (App Sandbox).
- FR-1.3: User can remove a folder; its items leave the library. Prompt: keep or discard metadata (kept metadata re-attaches if the folder is re-added, matched by content hash).
- FR-1.4: Nested watched folders are detected and deduplicated (warn user, index once).

**Acceptance**
- [ ] Adding a folder with 5,000 files completes an initial index pass with progressive UI updates (items appear as scanned, no frozen UI).
- [ ] After relaunch, previously added folders load without re-prompting for permission.
- [ ] Removing and re-adding a folder with "keep metadata" restores all tags and display names.

### 5.2 Scanning & indexing — **P0**

- FR-2.1: Recursive scan of each root folder; discovers files matching the **enabled format list** (see 5.3).
- FR-2.2: For each file, extract: original filename, relative path, size, created/modified dates, content hash (xxHash64 for change detection; SHA-256 lazily for dedupe/export identity), format, and — where parseable — geometry stats (bounding box, triangle count, part count for 3MF).
- FR-2.3: Manual "Rescan" per folder and global; incremental (hash/mtime-based), not full re-parse.
- FR-2.4 (**P1**): Live monitoring via FSEvents — additions, deletions, renames, and modifications reflected within seconds. A rename on disk keeps the library item (matched by hash/inode) and its metadata; the *original name* field updates.
- FR-2.5: Archives (`.zip`, `.rar`) are **not** unpacked in v1; listed only if the user enables "show archives" (tagged `archive`). *(P2: index inside zips.)*

**Acceptance**
- [ ] Touching one file and rescanning re-parses only that file.
- [ ] Renaming a file in Finder (P1, with watching on) preserves its tags and display name.
- [ ] Scanner never blocks the main thread; cancel is always available.

### 5.3 Format support & selection — **P0**

- FR-3.1: Supported format registry (all shipped, each individually toggleable in Settings):

| Group | Extensions | Preview capability (v1) |
|---|---|---|
| Print mesh | `.stl`, `.3mf`, `.obj` (+`.mtl`), `.ply`, `.amf` | Full 3D render |
| Universal/DCC | `.usdz`, `.usd`, `.gltf`, `.glb`, `.fbx`, `.dae`, `.abc` | Full 3D render where ModelIO/SceneKit supports; else QuickLook; else icon |
| CAD | `.step`, `.stp`, `.iges`, `.igs` | Metadata + icon (see FR-4.4) |
| Source | `.blend`, `.f3d`, `.scad`, `.shapr` | Embedded thumbnail if extractable (`.blend`), else icon |
| Slicer output | `.gcode`, `.bgcode`, `.gx` | Embedded thumbnail if present (PrusaSlicer/Bambu embed PNG), else icon |

- FR-3.2: Default-enabled: Print mesh + `.usdz`/`.gltf`/`.glb` + slicer output. Others off by default.
- FR-3.3: Toggling a format off hides (does not delete) its items and their metadata; toggling back on restores instantly, then incremental rescan picks up anything new.

**Acceptance**
- [ ] Disabling `.gcode` removes those items from all views and search without a rescan.
- [ ] Format list is data-driven (single registry), so adding a future extension is a one-line change.

### 5.4 Previews — **P0**

- FR-4.1: Grid view with generated thumbnails (default 512×512 PNG, cached on disk in Application Support, keyed by content hash — a re-downloaded identical file reuses its thumbnail).
- FR-4.2: Rendering pipeline, first match wins:
  1. **ModelIO/SceneKit** offscreen render for mesh formats — neutral studio lighting, consistent camera (isometric ~30°/45°), matte single-color material for STL/mesh-only formats.
  2. **Embedded thumbnail** extraction (3MF package thumbnail, GCODE embedded PNG, `.blend` preview).
  3. **QuickLook thumbnail** (`QuickLookThumbnailing`) — covers `.usdz` and anything with a QL plugin installed.
  4. **Format-specific fallback icon.**
- FR-4.3: Detail view (**P0**): large interactive 3D viewer (SceneKit) with orbit/zoom for renderable formats; shows metadata panel (5.7).
- FR-4.4: CAD (`.step`/`.iges`): v1 renders no geometry natively (no first-party parser). Show metadata + icon, tag `cad`. *(P2: optional bundled converter — e.g. OCCT-based `step → glTF` — behind a setting.)*
- FR-4.5: Thumbnail generation runs in a bounded background queue (max N concurrent, N = performance-core count), lowest priority, resumable.

**Acceptance**
- [ ] A 100 MB STL renders a thumbnail without exceeding ~1.5 GB transient memory (decimate/stream for preview if needed).
- [ ] Scrolling a 2,000-item grid stays at 60 fps with placeholder → thumbnail swap-in.
- [ ] Corrupt mesh → fallback icon + `unreadable` tag; no crash, error logged per-file.

### 5.5 Auto-tagging — **P0 (local)** / **P1 (AI)**

**Local pipeline (always on, offline, runs at index time):**

- FR-5.1: **Filename/path heuristics** — tokenize original filename + parent folder names; match against a curated keyword→tag dictionary (e.g. `articulated`, `flexi`, `vase`, `benchy`, `calibration`, `keychain`, `planter`, `miniature`, `terrain`, `bracket`, `mount`, `enclosure`, `lithophane`, `supported/presupported`). Dictionary ships as an editable JSON resource.
- FR-5.2: **Structural tags** — derived from parsed data: format tag (`stl`, `3mf`…), `multi-part` (3MF with >1 object / OBJ with >1 group), size class (`tiny/small/medium/large/xl` by bounding-box longest edge, thresholds configurable), `flat` (Z ≪ X,Y — plates, lithophanes, signs), `high-poly` (> 1M triangles), `presliced` (gcode).
- FR-5.3: **Source tags** — recognizable download patterns (Thingiverse/Printables/MakerWorld ID patterns in filename or folder) → `printables`, `thingiverse`, etc.
- FR-5.4: Auto tags and user tags are visually distinct (auto tags shown dimmed/with a sparkle glyph). User can remove an auto tag (suppressed for that file, not re-applied on rescan) and add manual tags. Tag rename/merge is P1.

**AI pipeline (opt-in, P1):**

- FR-5.5: Settings → AI Tagging: **Base URL, API key, model name** — OpenAI-compatible `/v1/chat/completions` contract (works with OpenAI, OpenRouter, Ollama, LM Studio, or any proxy). API key stored in **Keychain**, never in plist/DB/exports.
- FR-5.6: When enabled, the app sends the **rendered preview image + filename + structural stats** to the model with a fixed system prompt requesting strict JSON: `{"tags": [...], "description": "...", "suggested_display_name": "..."}`. Response is validated; malformed JSON → retry once → skip and log.
- FR-5.7: AI tagging runs: (a) on-demand per file/selection ("Generate AI tags"), (b) optionally as a batch over untagged items — never automatically on every scan without the user enabling batch mode. Rate limit + concurrency setting (default 2 concurrent, to be safe with local Ollama).
- FR-5.8: "Test connection" button in settings performs a 1-token dry call and reports success/failure with the raw error.
- FR-5.9: AI tags are marked with provenance `ai` (vs `auto`/`user`) and are individually removable; the suggested display name is offered, never applied silently.

**Acceptance**
- [ ] With no network and no AI config, every indexed file still receives ≥1 tag (format tag at minimum).
- [ ] `flexi_dragon_presupported.stl`, 240 mm long → tags include `articulated` (or `flexi`), `presupported`, `large`, `stl`.
- [ ] Deleting an auto tag from a file, then rescanning, does not resurrect it.
- [ ] Wrong API key → clear inline error; no crash; no key ever appears in logs or exports.

### 5.6 Display names (virtual rename) — **P0**

- FR-6.1: Every item has `original_name` (read-only, mirrors disk) and optional `display_name`. UI shows `display_name` when set, with the original name available in the detail panel and as a tooltip.
- FR-6.2: Rename via inline edit (Return key / double-click on name / context menu), exactly like Finder ergonomics — but writes only to the app database.
- FR-6.3: The file on disk is **never** renamed. No "apply to disk" option in v1 (deliberate: keeps the guarantee absolute). *(P2: explicit "rename on disk" as a separate, clearly-labeled action.)*
- FR-6.4: Clearing a display name reverts UI to the original name.
- FR-6.5: Search matches both names (5.8).

**Acceptance**
- [ ] After setting a display name, the file's name, mtime, and hash on disk are byte-identical.
- [ ] Display names survive relaunch, rescan, on-disk rename (P1 watching), and export/import.

### 5.7 Item detail & metadata — **P0**

- FR-7.1: Detail panel shows: preview/3D viewer, display + original name, full path ("Reveal in Finder"), format, file size, dates, bounding box (mm), triangle/part count, tags (editable), free-text notes field, AI description (if generated).
- FR-7.2: "Open with…" hands the file to the default or chosen app (slicer) — read-only handoff via `NSWorkspace`.

### 5.8 Search, browse & filter — **P0**

- FR-8.1: Library-wide instant search over: display name, original name, tags, notes, folder path. Prefix + substring matching; diacritic/case-insensitive.
- FR-8.2: Sidebar: All Models, per root folder (with subfolder tree), Tags (with counts), Missing/Offline.
- FR-8.3: Filter bar: format, size class, tag (multi-select AND), date added.
- FR-8.4: Sort: name, date modified, date indexed, file size, triangle count.
- FR-8.5 (**P1**): Saved searches ("smart folders").

**Acceptance**
- [ ] On a 10,000-item library, typing in search returns filtered results in < 100 ms per keystroke (SQLite FTS5).

### 5.9 Export / Import — **P0**

Two distinct operations; both available **globally and per root folder**:

**A. Metadata export (portability of the library itself)**
- FR-9.1: Export → single `.polyshelf.json` (schema-versioned) containing, per item: content hash (SHA-256), relative path, original name, display name, tags (with provenance), notes, format, and folder-level settings. **Never** contains API keys or absolute machine-specific paths beyond the root-relative structure.
- FR-9.2: Import → user selects the JSON (+ points at the corresponding root folder if not already added). Matching order: **content hash first**, then relative path fallback. Conflict policy prompt: *merge (default — union tags, keep local display name unless empty)*, *overwrite*, *skip*.
- FR-9.3: Per-folder export writes the same schema scoped to one root; suitable as a sidecar to hand to someone along with the files.

**B. Bundle export (share files + metadata)**
- FR-9.4 (**P1**): "Export folder as bundle" → copies files + the sidecar JSON into a target folder/zip. Original files untouched (copy, never move).

**Acceptance**
- [ ] Export on Mac A → fresh install on Mac B → add same folder → import: 100% of tags, display names, and notes restored (hash-matched even if the folder was reorganized).
- [ ] Import of a newer schema version fails gracefully with a clear message (forward-compat guard).
- [ ] Round-trip export→import on the same library is a no-op (idempotent).

### 5.10 Duplicate detection — **P1**

- FR-10.1: Group items by SHA-256; "Duplicates" smart view lists groups with locations. App only *reports*; deleting stays in Finder (reveal action) — consistent with the non-destructive rule.

## 6. Data Model (sketch)

SQLite via **GRDB** (FTS5 needed for search; SwiftData lacks it). All metadata local, single DB file in Application Support.

```
folders(id, bookmark_data, display_name, path_hint, added_at, settings_json)
items(id, folder_id, rel_path, original_name, display_name?, ext, size_bytes,
      created_at, modified_at, xxhash64, sha256?, status[ok|missing|offline|unreadable],
      bbox_x, bbox_y, bbox_z, triangle_count?, part_count?, notes?, indexed_at)
tags(id, name UNIQUE, kind[user|auto|ai])
item_tags(item_id, tag_id, provenance[user|auto|ai], suppressed BOOL)
items_fts(FTS5: display_name, original_name, notes, tags_concat)
thumbnails: filesystem cache keyed by sha256/xxhash
settings: UserDefaults + Keychain (AI api_key)
```

## 7. Technical Notes & Constraints

- **macOS 14+, Swift 5.10+, SwiftUI** app lifecycle; AppKit interop where SwiftUI is weak (inline table renaming, NSOpenPanel).
- **App Sandbox on** from day one (security-scoped bookmarks); required if Mac App Store distribution is ever wanted.
- Parsing: `ModelIO` (`MDLAsset`) for STL/OBJ/PLY/USD/ABC; custom lightweight 3MF reader (ZIP + XML — `Foundation` + `libcompression`, plus thumbnail extraction from `/Metadata/thumbnail.png`); GCODE thumbnail extractor (base64 PNG comment blocks, Prusa/Bambu variants).
- Rendering: SceneKit offscreen (`SCNRenderer`) on Metal; deterministic camera framing from bounding box.
- Concurrency: Swift structured concurrency; scan/parse/render as separate `TaskGroup` stages with backpressure.
- AI calls: `URLSession`, OpenAI-compatible request builder; streaming not required (single JSON response).
- Binary STL vs ASCII STL detection by header sniffing, not extension trust.
- Privacy: nothing leaves the machine except opt-in AI calls; state this in the UI next to the AI toggle.

## 8. Success Metrics (personal-tool scale)

- **Activation:** first folder indexed + first search performed in the first session.
- **Scan performance:** ≥ 50 files/sec metadata pass, ≥ 2 thumbnails/sec sustained on Apple Silicon (M1 baseline).
- **Trust invariant:** zero writes to user files — verifiable in QA by checksumming a test corpus before/after a full app exercise.
- **Search latency:** < 100 ms at 10k items.
- **Migration fidelity:** 100% metadata restoration in export→import test.

## 9. Phasing

| Phase | Scope |
|---|---|
| **v1.0 (P0)** | Folders, scan/index, format registry + toggles, previews (mesh + embedded + QuickLook), local auto-tagging, display names, search/browse/filter, detail view, metadata export/import (global + per-folder) |
| **v1.1 (P1)** | FSEvents live watching, AI tagging (custom endpoint), duplicates view, saved searches, bundle export, tag rename/merge |
| **v2 (P2)** | STEP/IGES geometry preview via converter, index inside zip archives, "rename on disk" explicit action, collections/projects, optional sync design |

## 10. Open Questions

1. **(Product)** Should folder-level format toggles override global ones (e.g. index `.gcode` only inside the "Sliced" folder)? Leaning **no** for v1 — global only.
2. **(Engineering)** Thumbnail cache eviction policy — cap by size (e.g. 2 GB LRU) or never evict? Proposal: 2 GB LRU, configurable. Non-blocking.
3. **(Product)** Keyword→tag dictionary language: English-only in v1, or ship a Persian keyword set too (your download folders may mix both)? Non-blocking, dictionary is user-editable either way.
4. **(Engineering)** `.blend` thumbnail extraction is reverse-engineered (embedded PNG at a known offset in newer versions) — worth the fragility, or icon-only for v1? Proposal: attempt, fall back silently. Non-blocking.

---

*Invariant worth repeating in every code review: the app opens user files read-only. Any code path that obtains a writable handle to a file inside a watched folder is a bug.*
