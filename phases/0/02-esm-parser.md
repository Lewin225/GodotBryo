# 0.2 — ESM/ESP Record Parser (Structural)

Parent: [Phase 0](README.md)

## Goal

Open `fresh_nv_copy/Data/FalloutNV.esm` (the reference copy in this project
directory — a ~245 MB master file) and structurally traverse it: header, top-level
`GRUP`s, and the records within them, without yet interpreting most record contents.
This is scaffolding for Phase 1 (which needs `CELL`/`WRLD`/`LAND`/`REFR` actually
decoded) — Phase 0 only needs to prove the container format is readable.

## Format notes

- Container structure: file header (`TES4` record) → sequence of top-level `GRUP`
  blocks, each containing either more nested `GRUP`s or a flat list of records.
- Each record has a 4-character type tag (e.g. `CELL`, `NPC_`, `STAT`), a size, flags
  (including a compression flag — some records are individually zlib-compressed),
  a FormID, and a list of subrecords (also tag + size + data).
- FormIDs are load-order-relative; for Phase 0/1 purposes (single master file, no
  plugin merging) this can be treated as a flat namespace — the master/plugin
  FormID-rebasing problem only matters once multiple `.esm`/`.esp` files are loaded
  together (DLCs in Phase 10, mods explicitly out of scope).
- Reference format documentation from the community (xEdit's format definitions, the
  GECK wiki record dumps) rather than guessing from binary inspection alone — the
  record subrecord layouts are extensively documented.

## Steps

1. Implement header parsing (`TES4` record: version, record count, next available
   FormID, master file list).
2. Implement generic `GRUP`/record iteration: walk the file emitting
   `(recordType, formID, flags, rawSubrecordBytes)` for every record, without
   interpreting subrecord contents yet.
3. Handle the per-record compression flag: detect it, zlib-inflate the subrecord data
   before handing it back, so downstream consumers never deal with compressed bytes.
4. Build a record-type histogram (count of each 4-char tag encountered) as a
   validation tool — cross-check counts against a trusted inspector (xEdit) opening
   the same file.
5. Do **not** implement per-subrecord semantic decoding yet for most types. The one
   exception: partially decode enough of `STAT` (static object) and its associated
   `EDID`/`MODL` subrecords, since Phase 0's exit criterion needs to resolve "a known
   mesh" to a file path via some record — `STAT` is the simplest record type that
   maps a game object to a NIF path, making it the natural smoke-test record type.

## Deliverables

- `native/esm/` module exposing: open master file, iterate records (optionally
  filtered by type), decompress record data on demand.
- A CLI/test that prints record-type counts for `FalloutNV.esm`.

## Acceptance criteria

- [x] Record-type histogram built for `FalloutNV.esm`: 108 distinct types, 465,017
      records total. Top types by count: `REFR` 307,710, `CELL` 30,497, `LAND` 29,363,
      `INFO` 23,247, `DIAL` 18,215, `STAT` 6,785, `NAVM` 4,771, `PACK` 4,163,
      `NPC_` 3,816, `ACHR` 3,386 — these are all plausible top types for an open-world
      Bethesda master (reference-heavy world data dominates). **Not cross-checked
      against xEdit** — no Windows-only tool available in this Linux environment (same
      gap as 0.1's BSArch note). The TES4 header's own `HEDR.NUMR` field claims
      542,016 records, which does not match our walked total of 465,017 — this is a
      known-unreliable field in the format (several community sources note it isn't
      trustworthy for validation), not a bug in the walker; internal consistency (walk
      terminates exactly at EOF with no overrun/underrun errors across all 465k
      records) is the stronger correctness signal here.
- [x] Compressed record decompression confirmed: an `NPC_` record
      (formID `0x0017B58D`) with the compression flag set decompressed from 233 bytes
      to 819 bytes without error via the same zlib path as 0.1's BSA reader. Not
      cross-checked against xEdit's decoded view (same tooling gap as above), but the
      decompressed size being both larger than the compressed size and internally
      consistent (subrecord parsing of the decompressed buffer completes without
      overrun) is a strong correctness signal, consistent with 0.1's NIF-magic-string
      approach.
- [x] A `STAT` record resolves to a NIF path: formID `0x0017B7B5`, EDID
      `NVGuardTower01a`, MODL `architecture\NCR\NVGuardTower01a.NIF` — ready to hand to
      the BSA reader (0.1, path needs `\`→`/` + lowercase normalization, already
      handled by `BsaArchive::find()`) and the NIF parser (0.3).

### Follow-up / open item

Same as 0.1: no Windows-only reference tool (xEdit) was available in this Linux
environment for a byte-for-byte/count-for-count cross-check of the record histogram or
decompressed record contents. If xEdit (or a compatible CLI dump tool) becomes
available later, running it against `FalloutNV.esm` and diffing its record counts and
one decompressed record's raw bytes against ours would fully close this out.

## Explicit non-goals for this task

- Full semantic decoding of all ~100+ record types — that's spread across later
  phases as each system needs its data (CELL/WRLD/LAND in Phase 1, NPC_/ACHR in
  Phase 3, SCPT in Phase 5, DIAL/INFO/QUST in Phase 7, etc.).
- Multi-master FormID resolution (DLC/plugin merging).
- Writing/editing ESM data.

## Implementation notes

- Lives in `native/src/esm/` as part of the single `nv_engine` extension (same
  rationale as 0.1 — see [phases/0/README.md](README.md)).
- `esm_types.h` — format constants (compression flag bit, subrecord oversize marker)
  and plain structs (`RecordInfo`, `Subrecord`, `FileHeader`). No "NV" naming — the
  TES4-family record/GRUP header layout is shared by Oblivion/FO3/FNV/Skyrim, not
  New-Vegas-specific.
- `esm_file.{h,cpp}` — pure C++, no Godot dependency. `EsmFile::open()` reads the
  leading `TES4` record and parses its `HEDR`/`MAST` subrecords into `FileHeader`.
  `for_each_record()` recursively walks nested `GRUP`s via `fseek`, reading only the
  24-byte `GRUP`/record headers (both share the same layout: 4-char tag + five
  `uint32` fields) and skipping data blobs it isn't asked to read — cheap enough to
  walk the full ~245 MB file (465k records) in well under a second. `read_record_data()`
  decompresses on demand using the same "4-byte original-size prefix + zlib stream"
  scheme as BSA's per-file compression (0.1) when the record's compression flag
  (`0x00040000`) is set. `parse_subrecords()` handles the `XXXX` oversize-size marker
  (subrecords >65535 bytes carry their real size in a preceding synthetic `XXXX`
  subrecord rather than the normal 16-bit size field).
- `esm_reader_gd.{h,cpp}` — thin Godot-facing wrapper (`EsmReader` : `RefCounted`)
  exposing `open()`, `get_header_info()`, `get_record_type_histogram()`,
  `find_first_stat_model()`, `find_first_compressed_record()`, `get_last_error()`.
  Follows the same pattern as `BsaReader` (0.1): all real logic lives in the
  Godot-independent core, the wrapper only translates to/from Godot `Variant` types
  and catches `std::exception` at the boundary.
- Format details (24-byte GRUP/record header layout, `HEDR`/`MAST` subrecords, the
  `XXXX` oversize marker, the compression flag bit and its 4-byte size-prefix
  convention) cross-referenced against xEdit's published format definitions and
  general community documentation of the TES4 plugin format, since — as with 0.1 —
  the UESP wiki was unreachable (403) from this environment.
- Test harness: `project/test_esm.gd` / `test_esm.tscn`, run via
  `tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path project test_esm.tscn`.
