# 2.2 — Async / Streamed Cell Loading

Parent: [Phase 2](README.md)

## Goal

Turn the frame-spread loading pattern prototyped in `project/exterior_viewer.gd` (an
editor `@tool` scene, built to load an *area* of exterior cells rather than one
hardcoded default) into the production loading path Phase 2's actual cell-streaming
system uses. Directly serves Phase 2's own exit criterion: "walk from Goodsprings to
Primm without load screens... at a stable frame rate."

## What's already been proven (not assumed)

`exterior_viewer.gd`'s `_do_load()` is a GDScript coroutine that yields
(`await get_tree().process_frame`) after every cell's terrain and every
`objects_per_frame` placed REFRs, instead of building an area synchronously in one
frame. Verified working, headless, no C++ changes:

- A 2-cell area streamed over multiple real frames rather than blocking one (confirmed
  by polling `_loading` across `await get_tree().process_frame` calls in a separate
  verification scene and counting frames — more than one frame elapsed, not an
  instant/blocking completion).
- Goodsprings' 108 objects + its terrain streamed over 8 frames at
  `objects_per_frame=15`, printing incremental progress each batch.
- Cancel-and-restart was verified safe: a generation counter
  (`_load_generation`, `_loading`, `_cancel_load()`) lets a newer "Load Area" press (or
  an explicit cancel) invalidate an in-flight coroutine without it touching a
  freed/replaced node tree — checked after every yield point, not assumed safe by
  construction.

This is entirely GDScript-side. No C++ threading was needed for this part — every
individual `EsmReader`/`BsaReader`/`NifReader` call is already fast; the cost was doing
hundreds of them with no yield point, and yielding between batches is sufficient to
keep a frame budget.

## Steps

1. Extract the streaming/cancellation pattern out of `exterior_viewer.gd` into a
   reusable loader (used by both the editor tool and the eventual runtime streaming
   system) rather than duplicating it per-consumer — same "fix/build at the true
   source" discipline as the rest of this project.
2. Tune batch size against a real frame-time budget. `objects_per_frame=15` was picked
   arbitrarily for the prototype, not measured — needs an actual target (e.g. "stay
   under Xms of loading work per frame") and a way to measure it.
3. Investigate moving the CPU-bound byte-level work (BSA extraction, NIF parsing, DDS
   decoding — not Godot resource/RID creation) to a `WorkerThreadPool`. Checked this
   session: `bsa_archive.cpp`, `esm_file.cpp`, and `nif_loader.cpp` have no
   static/global mutable state — every reader instance owns its own file handle and
   buffers, so separate instances per worker thread should be safe by construction.
   Two things this does NOT yet cover and must be verified, not assumed, before
   trusting it: (a) `nifly` (third-party, not this project's code) may have its own
   internal state not audited here; (b) needs an isolated repro proving real
   concurrent correctness, same discipline `HeightMapShape3D` needed in 1.4 before it
   was trusted or discarded.
4. Godot resource creation (`ArrayMesh`, `ImageTexture`, RID upload) needs to stay
   main-thread-driven regardless of where the byte-level work happens (or go through
   `RenderingServer`'s own thread-safe command queue — TBD, needs its own check, not an
   assumption). Scope this boundary explicitly in whatever design comes out of step 3.
5. Depends on [2.0](00-resource-caching-instancing.md): once mesh/texture/material
   caching exists, a streamed loader should skip the yield entirely for a cache hit
   (already-resolved resource, no BSA/NIF/DDS work to spread across frames) — worth
   re-measuring batch pacing after 2.0 lands, not just before.

## Deliverables

- A reusable streaming/cancelable loader, not duplicated between the editor tool and
  runtime use.
- A stated, measured frame-time budget the batch size is tuned against.
- Either a verified-safe threading design for the byte-level work, or an explicit,
  documented deferral with the reason (not silently dropped).

## Acceptance criteria

- [ ] Streaming behavior verified on a genuinely large area (multiple cells across
      both grid axes), not just the single-cell prototype run.
- [ ] Frame time stays under a stated, measured budget during a load.
- [ ] Cancel/restart correctness re-verified once the pattern moves out of the
      prototype script.
- [ ] Threading investigation concludes with either a verified-safe implementation or
      an explicit documented deferral.
