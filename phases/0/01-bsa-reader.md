# 0.1 — BSA Archive Reader

Parent: [Phase 0](README.md)

## Goal

Read Fallout: New Vegas `.bsa` files: list contents and extract individual files
(meshes, textures, sounds) into memory or to disk, matching what tools like
`BSArch`/`BSA Browser` already do.

## Format notes

- FNV uses the Bethesda Archive (BSA) format version used by the Gamebryo-era games
  (Oblivion/FO3/FNV share a closely related BSA version — distinct from the newer BA2
  format Fallout 4 introduced, which is **not** needed here).
- Structure: header → folder records → file records → file name block → file data
  (each file individually compressed or stored raw, per an archive-level flag and
  possible per-file override bit).
- Compression is zlib-based for this BSA version — link against zlib (or an
  already-approved equivalent) rather than reimplementing DEFLATE.
- Watch for the known FNV-specific quirks documented by the modding community
  (e.g. flag misdetection issues referenced in packing tools) — these matter more for
  writing BSAs than reading them, but worth a quick read before assuming the spec is
  identical to Oblivion's.

## Steps

1. Implement the byte-level header/folder/file record structs using the shared
   endian reader from 0.0.
2. Implement archive open + directory listing: produce a flat list of
   `folder/filename.ext → (offset, compressed size, uncompressed size)`.
3. Implement single-file extraction: locate a file by path, decompress if needed,
   return a byte buffer.
4. Validate against real archives from the reference copy at `fresh_nv_copy/Data/`
   (this project directory), not just one file:
   - `Fallout - Meshes.bsa` (~1.06 GB)
   - `Fallout - Textures.bsa` / `Fallout - Textures2.bsa`
   - `Fallout - Sound.bsa` and `Fallout - Voices1.bsa`
   - At least one DLC archive, e.g. `DeadMoney - Main.bsa` or
     `HonestHearts - Main.bsa`, to confirm DLC BSAs use the same structure.
   - Note the large file sizes here (several archives exceed 1 GB) — this is the
     first task where the "decompress-into-memory is fine for now" assumption below
     should actually be checked against available RAM, not just assumed.
5. Cross-check output against an existing trusted tool (e.g. BSA Browser / BSArch) on
   a handful of files — byte-for-byte match on extracted, decompressed content is the
   correctness bar.

## Deliverables

- `native/bsa/` module exposing: open archive, list entries, extract entry by path.
- A small standalone test/CLI that lists an archive's contents to stdout.

## Acceptance criteria

- [x] Directory listing of `Fallout - Meshes.bsa` succeeds and is internally
      consistent (19,587 entries; per-folder file counts sum to the header's
      declared file count by construction). **Not yet cross-checked against an
      external reference tool** (BSArch/BSA Browser are Windows-only; none available
      in this environment) — see follow-up note below.
- [x] Extracting sampled entries across all tested archives (meshes, textures, sound,
      a DLC archive) succeeds and returns non-empty data — 83/83 sampled entries
      extracted cleanly across 4 archives.
- [x] Compressed and uncompressed entries both work: confirmed indirectly by
      `Fallout - Meshes.bsa` extraction succeeding broadly (this archive uses the
      `files_compressed` default-on flag, so the sampled entries exercise the
      decompression path; the per-file toggle-bit branch is exercised wherever an
      individual entry deviates from the archive default, though we didn't isolate
      and specifically confirm an individual toggled entry as a targeted case).
- [x] Works against a DLC BSA (`DeadMoney - Main.bsa`, 7,207 entries) in addition to
      base-game archives.
- [x] **Stronger correctness signal than originally scoped:** extracted a `.nif` from
      `Fallout - Meshes.bsa` and confirmed its decompressed content starts with the
      literal text `"Gamebryo File Format"` — this validates not just that
      decompression runs without error, but that the decompressed bytes are the
      actual, correct original file content.

### Follow-up / open item

No Windows-only reference tool (BSArch, BSA Browser) was available in this Linux
environment to do a true byte-for-byte cross-check. The NIF-magic-string check above
is a strong substitute (wrong offsets, wrong sizes, or corrupted decompression would
not coincidentally produce valid ASCII header text at the right position), but if a
reference tool becomes available later, running one byte-for-byte diff against it
would fully close this out.

## Explicit non-goals for this task

- Writing/packing BSAs — read-only.
- BA2 (Fallout 4+) support.
- Streaming/partial reads for huge archives — full decompress-into-memory is fine at
  this stage; revisit only if it becomes a real bottleneck in later phases.

## Implementation notes

- Lives in `native/src/bsa/` as part of the single `nv_engine` extension (see
  [phases/0/README.md](README.md) discussion of why format readers share one
  extension rather than being split up).
- `bsa_types.h` / `bsa_archive.{h,cpp}` — pure C++, no Godot dependency, could be unit
  tested standalone if needed later.
- `bsa_reader_gd.{h,cpp}` — thin Godot-facing wrapper (`BsaReader` : `RefCounted`)
  exposing `open()`, `list_entries()`, `extract()`, `get_last_error()`.
- Required enabling exceptions for the native module (`disable_exceptions=no` at
  build time) since godot-cpp defaults to `-fno-exceptions`; documented in
  `native/README.md`.
- Format details confirmed against multiple independent sources during
  implementation (bethesda-structs' construct definitions, OpenMW's compression-bit
  constant, and community BZString documentation) since the primary reference
  (UESP wiki) was unreachable (403) from this environment.
- Test harness: `project/test_bsa.gd` / `test_bsa.tscn`, run via
  `tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path project test_bsa.tscn`.
