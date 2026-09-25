# Problem report: TerrainStreamer shutdown heap corruption

**Status:** diagnosed  
**Severity:** test-blocking; six TerrainStreamer scenes were reported as failing at process shutdown

## Cause

The loaded `libterrain_streamer.linux.template_debug.x86_64.so` was stale. It was not built from
the checked-in ESM implementation that the TerrainStreamer source includes and expects.

This was proven from the old binary itself:

- Its `EsmFile` destructor closes a `FILE *` and then walks a container at offset `0x100`.
- It contains the obsolete `ensure_gmst_cache` identifier.
- Neither the current `native/src/esm/esm_file.h` nor `.cpp` contains that method or a `FILE *`.
  The current class instead owns `std::vector<uint8_t> file_data_` and reads the ESM into memory
  in `EsmFile::open()`.

The original shutdown instruction (`terrain_streamer + 0x21ce3`) is therefore inside the old
`EsmFile` destructor, not `WorldCatalogue` cleanup. It dereferences a bad tree node while that
old reader is being destroyed. The later `shared_ptr` frames are incidental destruction frames,
not evidence that the process-lifetime catalogue cache corrupted the heap.

The extension is gitignored build output, so its September 2 timestamp falsely suggested it was
current even though the ESM source was changed on September 13. Source and artifact provenance,
not the artifact's freshness relative to one TerrainStreamer source file, is the relevant check.

## Evidence

1. Before rebuilding, `test_terrain_region_stager.tscn` completed every assertion and then
   crashed during teardown. The faulting frame was `terrain_streamer + 0x21ce3`.
2. Disassembly of that address begins by calling `fclose`, then destroys the old reader's internal
   tree. That layout cannot be produced by the current `EsmFile` definition.
3. Rebuilding the extension from the checked-in sources produced a 16.7 MB debug-symbol artifact
   (the prior stripped artifact was 1.3 MB). The rebuilt binary no longer contains
   `ensure_gmst_cache`.
4. With the rebuilt artifact, both of these exit 0 with `ALL CHECKS PASSED` and no shutdown crash:

   - `tests/test_terrain_region_stager.tscn`
   - `tests/test_terrain_streamer_phase3_completion.tscn`

This is a direct before/after reproduction using the same project, data, and test scenes; only
the TerrainStreamer binary changed.

## Excluded hypotheses

- **Static `shared_catalogues_` lifetime:** it holds only standard C++ payload data and is not the
  object being destroyed at the faulting instruction. No cache-policy change is needed to address
  this crash, though bounded cache ownership remains a separate design concern.
- **Two copies of ESM code in `nv_engine` and TerrainStreamer:** both extensions having private
  ESM implementations is not what caused this failure. No ESM object crosses their boundary; the
  bad object belongs to TerrainStreamer's obsolete private implementation.
- **Terrain composition buffer overflow:** rebuilding identical checked-in composition code removes
  the reproduction, so there is no evidence for this as the cause.

## Required remediation

1. Treat `project/addons/terrain_streamer/bin/libterrain_streamer*.so` as stale whenever anything
   under `native/terrain_streamer/`, `native/src/esm/`, or `native/src/common/` changes. Rebuild it
   before running TerrainStreamer tests.
2. Repair `native/terrain_streamer/SConstruct` so the documented rebuild command works: it invokes
   `subprocess.run()` without `import subprocess`, and calls `_strip_quotes()` without defining it.
   Those defects prevented a normal rebuild in this environment; the verification build used a
   temporary external shim only.
3. Add a build/version fingerprint or CI step that rebuilds the extension before the TerrainStreamer
   suite. Timestamp comparisons cannot establish source/artifact compatibility.
4. Run all six affected scenes after the canonical build-script repair. The two representative
   tests above establish the cause and verify the rebuilt artifact; the remaining four still need
   a clean, canonical-suite confirmation.

## Not part of this incident

The unrelated `EsmServer` thread shutdown abort described in the original investigation brief
remains out of scope.
