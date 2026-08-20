# 2.11 — Exterior Cell Lookup Index (fix `find_exterior_cell()`'s real bottleneck)

Parent: [Phase 2](README.md)

## Goal

`EsmFile::find_exterior_cell(wrld_form_id, x, y)` is the actual dominant cost in
`WorldStreamer` streaming — not resolve threading (2.10), not Node construction, not
terrain building. Measured directly (headless, `RADIUS_LOAD=10`, 441 tiles, real
WastelandNV data): **15,114ms of an 18,654ms total settle time (81%)** was spent inside
this one function, at ~34ms per call, called once per newly-entering tile on the main
thread, completely unthreaded and untouched by any of 2.10's work.

This is the SECOND time this exact function has turned out to be the real cost after a
round of unrelated work chased something else first (the first time: the ~41ms/call
`find_exterior_cell()` cost hiding behind what looked like a rendering-performance
investigation, fixed only for `WorldStreamer.get_current_cell_form_id()`'s own single
cached coordinate — see `world_streamer.gd`'s existing `_current_cell_form_id_cache`
comment). `_start_tile_load()`'s own call to the same function was never touched by that
fix, because the fix cached one GDScript call site's result instead of fixing the
underlying C++ function — a symptom fix, not a root-cause fix. This task is the
root-cause fix: make `find_exterior_cell()` itself fast, so every current and future
caller benefits, not just whichever one gets special-cased next.

## What's already true, confirmed against real data (not assumed)

`find_exterior_cell()`'s own doc comment already states why it's a linear scan: *"Full-
scan of the worldspace's children, same rationale as 1.0's interior lookup — block/sub-
block coordinate hashing is a Phase 2 streaming optimization, not needed for one
hardcoded cell."* That was true when the only caller loaded one hardcoded startup cell
once. It stopped being true when `WorldStreamer` (2.8) started calling it continuously,
and nobody revisited the function itself.

Bethesda's own file format already has the spatial index this function should be using —
confirmed directly against real `WastelandNV` bytes (`FalloutNV.esm`, worldspace
form_id `0xDA726`), not just documentation:

```
World Children GRUP (group_type=1, label=WRLD's own form_id)
  ├─ the worldspace's persistent CELL record (plain record, not a GRUP — always first)
  ├─ that CELL's own Cell Children GRUP (group_type=6, label=the persistent CELL's form_id)
  └─ Exterior Cell Block GRUPs (group_type=4)
        └─ Exterior Cell Sub-Block GRUPs (group_type=5)
              └─ actual CELL records (each may be followed by its own group_type=6
                 Cell Children GRUP holding its REFRs — skip these whole, don't descend)
```

- Block size: 32×32 cells (4×4 sub-blocks of 8×8 cells each) — confirmed via UESP's Mod
  File Format documentation (`curl` with a browser User-Agent; plain `WebFetch` was
  blocked with a 403).
- Block/sub-block coordinate: `(floor(cell_x / 32), floor(cell_y / 32))` for blocks,
  `(floor(cell_x / 8), floor(cell_y / 8))` for sub-blocks. **Must use real floor
  division, not C++'s truncating `/`** — negative block/sub-block coordinates are real
  and common (Goodsprings' own block label decodes to x=-1), the same lesson this
  codebase already applied correctly in `CellStreamBuilder`'s own grid math
  (`int(floor(pos.x / cell_size_m))`).
- **Label encoding, confirmed against 6 real cells** (not assumed from the docs' own
  wording, which reads ambiguously — "short[2], Grid Y, X, note the reverse order"):
  the label's **low 16 bits are the block/sub-block's own X coordinate**, the **high 16
  bits are its Y coordinate**, both signed `int16`. Verified pairs (grid coordinate →
  sub-block label, sub-block = floor(coord/8)):
  - `(7,7)` → label `0x00000000` → sub `(x=0,y=0)` ✓.
  - `(7,15)` → label `0x00000001` → sub `(x=1,y=0)` ✓.
  - `(7,23)` → label `0x00000002` → sub `(x=2,y=0)` ✓.
  - `(7,31)` → label `0x00000003` → sub `(x=3,y=0)` ✓.
  - `(15,7)` → label `0x00010000` → sub `(x=0,y=1)` ✓.
  - `(15,15)` → label `0x00010001` → sub `(x=1,y=1)` ✓.
  - A real negative example: block label `0x0000FFFF` decodes to `(x=-1,y=0)` — the
    block Goodsprings itself (grid x=-17, `floor(-17/32) = -1`) lives in.

This gives a real O(few header reads down one tree branch) lookup instead of O(every
CELL in the worldspace, each fully decompressed and subrecord-parsed) — expected to take
the ~34ms/call cost down to sub-millisecond, without needing any cache at all for a
single call.

## Parked: caching/indexing on top of the direct-navigation fix

Explicitly deferred, not part of this task's first pass — implement direct navigation
first, measure it for real, decide whether caching is worth adding afterward.

**What was considered:**
1. **A disk-file cache** of `(wrld_form_id, x, y) → RecordInfo` results.
2. **A lazy in-memory full-worldspace index**, built once per worldspace on first
   `find_exterior_cell()` call and cached for the rest of the session — the exact same
   pattern `find_record_by_form_id()`'s own `form_id_index_`/`ensure_form_id_index()`
   already uses for a different key shape.
3. **No cache at all** — direct per-call navigation only, touching just the one
   block/sub-block branch relevant to that call, nothing cached between calls.

**Why disk caching looks unnecessary, measured, not assumed:** `find_exterior_cell()`
returns a `RecordInfo` — a 4-char type tag + a few `uint32`s + a file offset, ~24 bytes
of real payload, not the cell's actual content (`get_cell_references()`/
`get_land_data()` are separate calls). Building a **complete** in-memory index of
**every** exterior cell in WastelandNV (16,396 real cells, confirmed by direct count) —
via the same block/sub-block navigation, one `get_exterior_cell_grid()` call per cell —
measured at **91.19ms cold** (first disk read) and **10.04ms warm** (OS page cache
already warm, second call in the same process). That's cheaper than a **single** call
under the current linear scan (~34ms). A disk cache would only be trying to save that
one-time ~10-91ms per-session cost, at the price of real added complexity (cache
invalidation against ESM/mod changes, file I/O failure modes) — very likely not worth
it, but not implemented/verified either way yet.

**What's still an open call:** direct-navigation-only (option 3) is simplest and adds
zero persistent state, but re-walks the block/sub-block tree on every single call —
cheap per call, but `WorldStreamer` calls this dozens to hundreds of times as a player
walks around and tiles evict/reload, including real repeat visits to the same
coordinate. The lazy full-index (option 2) trades a one-time ~10-91ms build for making
every repeat lookup a plain dictionary hit. Needs real measurement of option 3 alone
first — it may already be fast enough on its own that option 2 isn't worth the added
memory/bookkeeping.

**If implemented later, what to test:**
- Real per-call timing for option 3 (direct navigation, no cache) against the same
  headless walk-through-Goodsprings methodology already established (2.2's frame-budget
  measurement, 2.10's benchmark script) — confirm it's actually fast enough alone before
  building anything on top.
- If option 2 is added: confirm the index is built exactly once per worldspace (not
  rebuilt per call), confirm memory cost is bounded and reasonable (~16k cells × ~24-32
  bytes ≈ 400-500KB worst case for a fully-explored worldspace — should be measured for
  real, not assumed), and confirm it's invalidated correctly if `WorldStreamer`
  `deactivate()`s and a different worldspace `activate()`s later in the same session (no
  stale cross-worldspace index reuse).
- If a disk cache is ever reconsidered: a real invalidation test (modify/replace the
  underlying ESM, confirm the cache doesn't serve stale results) — this is the one thing
  that would make disk caching a real correctness risk, not just an unnecessary
  optimization.

## Step-by-step implementation TODO — DONE

1. ✅ Block/sub-block label decode + real floor-division helpers added to `esm_file.cpp`
   (`floor_div()`, `decode_grup_label()`, `kSubBlockCells`/`kBlockCells`).
2. ✅ `find_exterior_cell()` rewritten to navigate World Children → Block (`group_type
   4`) → Sub-Block (`group_type 5`) → exact-`XCLC`-match CELL, skipping the persistent
   cell and every non-matching branch by its own declared byte size.
3. ✅ Doc comment updated (both `esm_file.h` and a fuller note directly above the
   implementation in `esm_file.cpp`).
4. ✅ Verified directly, and it caught two real bugs before landing, not zero:
   - **A genuine x/y-axis swap** in the label decode: the GRUP label's low-16 half
     tracks our own `grid.y`, not `grid.x` as first assumed. Hidden by the initial hand-
     picked test set (block `(0,0)`'s own cells are all `x==y`, symmetric, so the swap
     was invisible) — caught only once a *different*, asymmetric block was cross-
     checked. Fixed by swapping which parameter feeds `target_block_x/y`/
     `target_sub_x/y`.
   - **A real pre-existing bug in the OLD implementation**, not a regression: the
     worldspace's persistent cell record carries a placeholder `XCLC` of `(0,0)`, and
     the old linear scan (file order) returned it instead of the real grid tile also at
     `(0,0)` — silently, for as long as this function has existed. The new
     implementation excludes the persistent cell by construction (never part of the
     Block/Sub-Block structure) and returns the genuine tile. Confirmed via a dedicated
     new test (`test_exterior_cell_lookup.gd`) checking the resolved `(0,0)` cell has
     real terrain (`LAND` data), which the persistent cell never has.
   - Final verification: 729/729 exhaustive coordinate sweep matches (old vs. new,
     step ±3 over `[-40, 40]²`) plus a dedicated hand-picked set covering multiple
     blocks, negative coordinates, and a worldspace-edge miss — all exact matches
     except the explained `(0,0)` case.
5. ✅ Re-measured with the same headless methodology already established this phase, on
   the exact scenario the 81%/15,114ms number came from (`RADIUS_LOAD=10`, 441 tiles):
   **total settle time 18,654ms → 3,116ms (6x)**; `find_exterior_cell()`'s own total
   **15,114ms → 15ms (~1000x)**, matching a standalone timing comparison's measured
   **1179x** per-call speedup (~31.1ms → ~0.026ms) almost exactly.
6. Caching/indexing decision: still parked, per the section above — not revisited as
   part of this pass. Direct navigation alone was enough to make the bottleneck
   disappear; no immediate need established for anything on top.

## Acceptance criteria

- [x] `find_exterior_cell()` returns identical results to the old linear-scan
      implementation for every real cell checked, including at least one negative-
      coordinate case and one block boundary case, not just Goodsprings — confirmed via
      a 729-point exhaustive sweep, with the one real discrepancy (`(0,0)`) traced to a
      genuine pre-existing bug in the old implementation, not a flaw in the new one.
- [x] Real measured per-call cost drops from ~34ms to sub-millisecond, confirmed
      directly: ~31.1ms → ~0.026ms (1179x), same standalone timing harness used for both.
- [x] The 15,114ms / 81%-of-settle-time cost measured in this task's own investigation
      is re-measured after the fix and shown to have dropped correspondingly: 15,114ms →
      15ms, total settle time 18,654ms → 3,116ms.
- [x] The caching/indexing question stays explicitly parked (this doc) — not
      implemented as part of this pass.
