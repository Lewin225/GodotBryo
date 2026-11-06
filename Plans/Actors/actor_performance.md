# Actor performance

Parked. Findings from `tools/Tracy-Profiles/190 NPC's.tracy` (190 NPCs on screen, 213 frames,
~52 ms a frame) for when this is picked up. Terrain shader cost is issue #87.

## Facts

Per frame, main thread:

- Rendering 22.8 ms: scene update 8.4 (culling and instance updates; skinning not confirmed),
  render viewport 9.6, end frame 4.6.
- Process 19.2 ms: NifServer drain 4.7 (730 `duplicate` calls, ~1 ms each, while actors load),
  actor node and FaceGen deliveries ~2 (loading), ActorFacialPlayer 1.15, Script Engine debug tab
  1.0 (an 8 ms refresh every ~8 frames while the window is open), ActorHeadTracking 0.45. ~9 ms
  has no GDScript zone; the engine's animation processing is the suspected cause, not confirmed.
- Physics 9.7 ms over two steps a frame: NpcController 3.9 (~10 µs a call), PackageRunner 2.5,
  ActorAnimator 0.9.
- SimulationWorker waits and route finding run on worker threads.

## Candidates

- Animation level of detail: advance distant actors' animation every Nth frame or not at all
  off screen; facial player and head tracking off beyond a distance. Every actor runs all of
  them at full rate now.
- Copying actor meshes in NifServer (`duplicate`) spreads over frames or gets cheaper; it causes
  hitches when entering crowded areas.
- NpcController and PackageRunner per-actor cost (~30 µs per actor per physics step).

## Open

- What the ~9 ms without a zone is: needs Tracy zones on the engine's animation step, or a trace
  with actor animation turned off (`DebugActorCost` does whole actors).
- Whether scene update's 8.4 ms is skinning.
- Traces should be taken with the Debug Tools window closed.
