# Phase 0 — Results

Parent: [Phase 0](README.md)

Written on completion of [0.5](05-integration-tool.md), the last Phase 0 sub-task.
Covers: what worked as expected, what surprised us, and what changes before Phase 1
starts.

## Definition of done — final status

From [phases/0/README.md](README.md):

- [x] Native module builds and loads inside a Godot 4.x editor build on Linux (the
      primary dev platform — see [native/README.md](../../native/README.md)).
- [x] Given a path to a legally-owned FNV install, the tool lists the contents of
      `Fallout - Meshes.bsa` (0.1; re-exercised by every later task).
- [x] The tool extracts a specific known mesh and parses it with the NIF library
      without errors — done for 15 distinct STAT-resolved meshes in the 0.5 run below,
      not just one.
- [x] The parsed mesh's geometry is exported to glTF and opens correctly (structurally
      validated; see 0.3's write-up for the byte-level verification method) — and,
      going further than the original criterion asked, was also rendered live in the
      Godot editor with real GPU rendering and visually confirmed against the
      expectation (0.4, 0.5).
- [x] A texture referenced by that mesh's material is located via BSA, decoded from
      DDS, and displays correctly on the mesh — confirmed with a real render (0.4's
      NCR guard tower, 0.5's Hoover Dam piece), not just "did it decode."
- [x] The ESM parser opens `FalloutNV.esm` and enumerates top-level record groups
      without crashing (0.2), and this held up under integration: 0.5 re-walked the
      entire file (6,780 STAT records with a MODL subrecord) with no crashes.

**All Phase 0 exit criteria are met.**

## 0.5 run: end-to-end resolution of 15 objects

`native/tools/dump_object` (see [05-integration-tool.md](05-integration-tool.md)) was
run against the full `fresh_nv_copy/Data` install, auto-selecting STAT records spread
across the file (to get area/BSA/format variety without hand-picking objects) rather
than a fixed hardcoded list:

```
15/15 objects resolved successfully (15 candidates attempted)
11/15 are multi-submesh
Mesh BSA sources: Fallout - Meshes.bsa=13  HonestHearts - Main.bsa=1  Update.bsa=1
Texture BSA sources: Fallout - Textures.bsa=14  Fallout - Textures2.bsa=39
DDS variants seen: DXT1=44  DXT3=1  DXT5=8
```

Every one of the 15 auto-selected candidates round-tripped on the first attempt (ESM
→ NIF found in some BSA → NIF parsed → at least one texture resolved) — no candidate
needed to be skipped and replaced, once the two bugs below were fixed. Objects ranged
from single-submesh props to a 49-submesh, 12-texture Hoover Dam structure
(`NVHooverDamLowerL`), and mesh sources spanned the base archive, the always-applied
patch archive (`Update.bsa`), and a DLC archive (`HonestHearts - Main.bsa`) — this
satisfies the "spanning multiple BSAs and texture formats" acceptance criterion with
real breadth, not just the minimum count.

Two of the 15 (`NVGuardTower01a`, `NVHooverDamLowerL`) were additionally re-resolved
through a **second, independent implementation** of the same pipeline —
`project/test_integration.gd`, which uses the actual GDExtension wrappers
(`EsmReader`/`BsaReader`/`NifReader`/`Image.load_dds_from_buffer`) rather than
`dump_object`'s plain-C++ core — and rendered live in the Godot editor with a real
GPU. Both implementations agreed on every resolved path, archive source, and submesh
count. Screenshots: the NCR guard tower (0.4) and the Hoover Dam piece (0.5) — both
show correct textures, no channel swaps, no mirrored UVs, at real scale relative to
each other's geometry.

## What surprised us

Two real bugs were found and fixed specifically *because* this task integrated the
sub-tasks together — neither was visible from any individual 0.1–0.4 test, which is
exactly the risk Phase 0 exists to de-risk:

1. **`MODL` paths are relative to `Data/Meshes/`, not `Data/`.** A STAT record's MODL
   subrecord stores e.g. `architecture\NCR\NVGuardTower01a.NIF`, but BSA archives
   index the full path including the `meshes\` folder
   (`meshes\architecture\NCR\NVGuardTower01a.NIF`). 0.2 never resolved a MODL path
   against a real BSA (it only validated the string shape), and 0.3's tests used
   hand-written `meshes/...` paths rather than ones sourced from an actual ESM record
   — so each sub-task's own tests passed while the seam between them was broken. Fixed
   in `dump_object.cpp` and `test_integration.gd` by prepending `meshes\` before
   lookup; **this needs to become a permanent, documented convention** (not a one-off
   fix) wherever MODL paths are resolved in Phase 1+.

2. **`esm::Subrecord::as_string()` didn't strip the subrecord's trailing NUL.** Many
   Bethesda string subrecords (`EDID`, `MODL`, `FULL`, `ICON`, ...) include their
   `\0` terminator *within* the declared subrecord size. `as_string()` was returning
   that trailing null as part of the C++ `std::string`'s content. This was invisible
   in every prior test: printing the string to a terminal renders an embedded null as
   blank, and every Godot-facing use of the value went through `String(s.c_str())`,
   whose `const char*` constructor silently truncates at the first `\0` — coincidentally
   masking the bug because the null was always the *last* byte. It only surfaced when
   `dump_object` compared the raw `std::string` directly against a `std::unordered_map`
   key (no C-string conversion in between), causing **100% of BSA path lookups to
   fail** on the first `dump_object` run. Fixed at the root in `esm_types.h`'s
   `Subrecord::as_string()`, which is shared by both `EsmReader` (Godot) and
   `dump_object` (standalone) — one fix closed the gap everywhere. Documented in the
   code as a warning to future subrecord-string consumers.

Both are now fixed at the shared-library level (`native/src/esm/esm_types.h`,
`native/tools/dump_object.cpp`), not patched around at the call site, so Phase 1 code
built on top of `EsmFile`/`EsmReader` inherits the fix automatically.

## What changes before Phase 1 starts

- **BSA "load order" is currently a heuristic, not a simulation.** `dump_object` and
  `test_integration.gd` both search archives in a fixed, hardcoded priority order
  (`Update.bsa` → DLC archives alphabetically → base `SArchiveList` reversed →
  everything else alphabetically) rather than replicating the game's actual plugin/
  archive load order. This was good enough for Phase 0 (single master file, no
  plugin merging in scope) but Phase 1+ needs a real load-order model once DLC
  `.esm` files are loaded alongside `FalloutNV.esm` — two DLCs could plausibly ship
  the same relative path with different content, and our current heuristic would
  pick one arbitrarily rather than correctly.
- **The Z-up (NIF) → Y-up (Godot) conversion is still a one-off in test scripts**
  (`rotation_degrees.x = -90` on a scene root), not a permanent part of the
  NIF-loading pipeline. Flagged in 0.3, addressed ad hoc in 0.4/0.5's demo scenes —
  Phase 1's actual mesh-instancing code needs to bake this in properly rather than
  relying on every caller remembering it.
- **Collision data (`bhk*` nodes) is still fully unextracted**, as scoped out in 0.3.
  Phase 1 will need this for any static-world collision, so it's worth an early pass
  rather than discovering the gap mid-phase.
- **No multi-master FormID rebasing** — explicitly out of scope through Phase 0, but
  worth restating now that DLC content (which uses multi-master FormIDs) has actually
  been touched (`HonestHearts - Main.bsa` resolved successfully above, but only
  because we searched for it as a raw path, not through any FormID-aware DLC-ESM
  logic). Phase 1 needs an explicit plan for this before loading DLC world content.

## Deliberately deferred: editor/engine integration depth

Two forms of tighter Godot integration were discussed but are **explicitly deferred
past Phase 0**, marked here as next steps for whenever they become load-bearing:

- **`ResourceFormatLoader`** — registering a custom loader so game/GDScript code can
  `load("bsa://meshes/...")` and transparently get back a `Mesh`/`Texture2D`, instead
  of every caller manually going through `BsaReader`/`NifReader`/`Image` by hand. This
  *is* expected to become load-bearing once Phase 1's world-streaming code needs to
  resolve `CELL`/`REFR` records to actual resources at runtime — recommended as one of
  the first things Phase 1 sets up, not deferred indefinitely.
- **`EditorFileSystem` / `EditorResourcePreview` integration** — browsing BSA contents
  and seeing thumbnails directly in Godot's editor file dock. Lower priority: this
  project's scope is loading/completing the base game programmatically, not
  hand-authoring content in the editor (that's GECK-replacement-shaped work, explicitly
  out of scope per [ROADMAP.md](../../ROADMAP.md)). Worth revisiting only if a
  hand-authoring workflow actually becomes part of the plan later; a read-only CLI/
  debug lister (already covered by `test_bsa.gd` and `dump_object`'s resolution logs)
  covers most of the "let me poke around the archive" need far more cheaply in the
  meantime.

## Implementation notes

- `native/tools/dump_object.cpp` — standalone CLI, no Godot/godot-cpp dependency
  (links directly against the same `bsa`/`esm`/`nif` core modules the GDExtension
  uses). Built via `native/tools/build.sh` (plain `g++`, not SCons — simplest option
  for a tool with no Godot dependency at all). Usage:
  `native/tools/dump_object [install_path] [out_dir] [target_count]` — all arguments
  optional, defaulting to `fresh_nv_copy`, `dump_object_output`, and `10`
  respectively, per the phase doc's "hardcode the reference path" guidance.
- Candidate selection: scans every `STAT` record with a non-empty `MODL`, seeds the
  0.2/0.3/0.4 guard tower object first for continuity, then spreads remaining picks
  across the full candidate list (rather than sequential/first-N) to get area/BSA/
  format variety without hand-picking filenames — STAT records cluster by game area
  in file order, so a spread avoids overfitting to one zone's assets.
  Falls back to a dense scan if the spread doesn't reach the target count (not needed
  in the runs recorded above — every spread pick succeeded once the two bugs were
  fixed).
- Each resolved object gets its own output directory (`<out_dir>/<EditorID>/`)
  containing `model.gltf`, a `textures/` folder with the raw (still BSA-compressed)
  `.dds` files copied out, and `resolution_log.txt` documenting exactly which archive
  each piece came from, its DDS FourCC variant, and any warnings — deliberately
  copied instead of decoded (DDS decoding is Godot's job, already proven in 0.4; a
  standalone tool re-implementing a DXT decoder would be pure duplicated effort).
- `project/test_integration.gd` / `test_integration.tscn` — the from-Godot half of the
  verification, reimplementing the same BSA-priority search independently in GDScript
  against the real `EsmReader`/`BsaReader`/`NifReader` wrappers, specifically so the
  standalone tool and the GDExtension aren't just trusting the same code twice. Run
  the same way as 0.4's demo (`DISPLAY=:0 tools/Godot_v4.7.1-stable_linux.x86_64
  --path project test_integration.tscn --resolution 1200x900` — headless mode still
  can't drive an actual render, see 0.4's note).
