# 3.0 — Door Completion: Animated Doors + GECK Feature Parity

Parent: [Phase 3](README.md)

## Goal

Two real gaps for `DOOR`, sequenced by actual blocking severity rather than GECK field
order:

1. **A real, currently-blocking gap (ROADMAP.md's own Phase 3 note):** non-teleporting
   ("swinging") doors do nothing on interact. `DoorNode.activate()` returns `{}` when
   `has_destination` is false, and `game.gd`'s `_try_interact()` treats an empty
   outcome as "nothing to do" — so a real door that should swing open is currently
   inert and can gate off map areas with no way through. Confirmed directly against
   real data: `NVCraftsmanRmDoorAnimated.NIF` and `NVCraftsmanRmDoor.NIF` both exist as
   distinct models in `FalloutNV.esm`, referenced by different `DOOR` base records —
   the "Animated" variant is real, not a naming convention assumed from the roadmap
   note alone.
2. **GECK feature-parity gaps** — fields documented on `DOOR` in
   `enginedocs/nv_data_model_reference.html` that `DoorNode` doesn't implement at all
   yet: Open/Close/Loop sounds, the six documented flags (Quest Item, Random Anim
   Start, Sliding Door, Hidden, Automatic Door, Minimal Use), and the "Randomly
   Teleports to Interiors/Worldspaces" mechanic.

Nothing in `native/src/nif` currently parses any animation block at all (confirmed by
direct search — zero references anywhere in the codebase to `NiControllerManager`,
`NiControllerSequence`, `NiTransformInterpolator`, or `NiTransformData`) — Part A below
is genuinely from scratch, not extending existing partial support.

## Steps

### Part A — animated door playback (the real blocker)

1. ✅ **Confirm scope against real data before writing a parser.** Done via
   `native/tools/anim_survey.cpp` (real, not committed — throwaway research tooling,
   same convention as `alpha_survey.cpp`): censused all 1,153 `NiControllerManager`-
   bearing NIFs / 31,012 controlled links across `FalloutNV.esm` + DLC, not just doors.
   Confirmed the chain (`NiControllerManager` → `NiControllerSequence` →
   `NiTransformInterpolator` → `NiTransformData`) directly, and confirmed the door-only
   sample would have under-scoped the real work badly: doors use only linear
   interpolation and per-axis (XYZ) rotation with no translation/scale, while the real
   population is dominated by **quadratic (Hermite) interpolation** for rotation
   (12,691 quadratic vs. 1,703 linear keys) and scale (9,761 vs. 74), and both
   quaternion-keyed and per-axis rotation representations occur (571 real quaternion
   cases). `NiFloatInterpolator`/`NiBoolInterpolator`/`NiBoolTimelineInterpolator`/
   `NiPoint3Interpolator` targets confirmed to be particle/visibility/color animation,
   correctly excluded. `NiBSplineCompTransformInterpolator` (compressed) confirmed
   **zero** real occurrences, not assumed absent.
2. ✅ **Native parsing** (`nif_types.h`/`nif_loader.cpp`): general-purpose extraction —
   `nif::Mesh::animation_sequences`, each a named `AnimationSequence` (cycle type,
   start/stop time) holding any number of `AnimationTrack`s (target node name +
   quaternion and/or per-axis rotation keys + translation keys (meters,
   `kGamebryoUnitsToMeters` applied at the true source) + scale keys), each key
   carrying full fidelity (time, value, forward/backward tangents, TBC
   tension/bias/continuity, interpolation type) — not just linear/door-shaped data.
   Exposed to GDScript via `NifReader.get_animation_sequences()`. Verified end-to-end
   through the real GDExtension binding against both the door case (matches the
   census exactly: pure axis rotation, linear, no translation/scale) and a real
   32-track, 7-sequence silo elevator NIF (quadratic rotation/scale, hundreds of
   linear translation keys, many simultaneously-animated nodes in one sequence) — the
   general case, not just the narrow one. Full regression suite unaffected. No
   `NiSkinInstance`/bone-hierarchy support — that's the harder, later part of Phase 3,
   deliberately still deferred; this only extracts rigid single/multi-node transform
   tracks.
3. ✅ **Playback mechanism, decided not assumed: Godot's native `Animation`/
   `AnimationPlayer`, not a hand-rolled interpolator.** Checked the real API surface
   directly via the vendored `godot-cpp` headers before deciding (`animation.hpp`,
   `animation_player.hpp`, `animation_library.hpp`), not from memory. Real tradeoff
   found: Godot's typed `TYPE_POSITION_3D`/`TYPE_ROTATION_3D`/`TYPE_SCALE_3D` tracks
   only support a fixed interpolation set (`NEAREST`/`LINEAR`/`CUBIC`/`LINEAR_ANGLE`/
   `CUBIC_ANGLE`) — `CUBIC` derives tangents from neighboring keys (Catmull-Rom-style),
   not the explicit forward/backward Hermite tangents our `QUADRATIC_KEY` data
   carries, and there's no native equivalent for `TBC_KEY` at all. That's a real
   accuracy gap, not a rounding error — quadratic interpolation is the *majority* case
   for real rotation/scale data (see step 1's own census). A `Bezier`-track hybrid
   (exact per-key tangent handles exist for `TYPE_BEZIER`, converted from our Hermite
   tangents via the standard cubic-Hermite↔cubic-Bezier equivalence) would close that
   gap but costs real complexity — Bezier tracks are scalar-only (3 tracks per Vector3
   channel), no quaternion-rotation equivalent at all, and per-channel track-type
   branching logic. Decided to start with native typed tracks (`CUBIC` standing in for
   both `QUADRATIC` and `TBC`) and revisit the Bezier hybrid only if a specific real
   animated object is confirmed to look visibly wrong in play — not preemptively, per
   this project's own "verify, don't assume" discipline. The deciding factor: native
   tracks get the *entire* `AnimationPlayer` machinery for free (looping modes,
   `animation_finished`, scrubbing) and are the same system Phase 3's later skeletal
   animation work will need anyway, so this also avoids building a second, throwaway
   playback system now.
4. ✅ **General node-graph preservation (`SceneNode`), additive infrastructure for
   Dynamic objects.** Per direct user request generalizing this past animation ("why
   not preserve the whole graph... anything targeting a NiNode should be able to find
   it in the future"): `nif::Mesh::scene_nodes` now records the NIF's full node graph
   (one entry per non-root `NiAVObject`, both `NiNode` and leaf `NiShape` blocks alike
   — a `target_node_name` can legitimately name either) with LOCAL (not
   flattened-to-root) transforms and a `parent_index` chain, plus an
   `owning_node_index` on `SubMesh`/`CollisionShape` pointing back into it. Zero change
   to Static content's existing flattened `SubMesh.transform`/`CollisionShape`
   transform fields — this is purely additive, read only by the (not yet written)
   Dynamic-path tree builder. Exposed to GDScript via
   `NifReader.get_scene_nodes()`/`get_submesh_owning_node_index()`. Verified end-to-end
   against real data: the door case resolves its animation track's
   `target_node_name` ('DLC04ShackDoor02') to an exact real scene-node entry, with the
   render mesh's `owning_node_index` correctly pointing one level below that pivot
   node (`DLC04ShackDoor02:1`) — proving both that a real animated node is
   independently addressable and that collision/mesh geometry can be correctly
   parented under it via ordinary Godot `Node3D` composition once the tree builder
   exists. The 179-submesh silo elevator NIF also resolves a valid `owning_node_index`
   for every single submesh — confirms the general case, not just door's shallow
   3-node graph. Full regression suite unaffected (`test_door_activate.tscn` passes
   unmodified; only the two pre-existing, unrelated failures remain).
5. ✅ **Build the Dynamic-path tree** in `mesh_resolver.gd`, mesh AND collision both real.
   `GamebryoMeshResolver.populate_dynamic_children()` walks `scene_nodes` to build a
   real `Node3D` per entry (parented per `parent_index`, local transform — Godot
   composes automatically), then parents each submesh's `MeshInstance3D` under the
   correct node via `owning_node_index`, instead of the single flattened transform
   Static content uses — real production code, not a one-off script, sitting right next
   to `populate_mesh_children()`/`populate_collision_children()`. `owning_node_index` is
   now threaded through `_build_collision_shapes()`/`build_geometry_entries()`'s
   `shape_entries` too, and `populate_dynamic_children()` builds one
   `GamebryoCollisionBody` per DISTINCT owning node (not always a single body, unlike
   the flattened path) — confirmed against the real door NIF: its collision box is
   authored on `DLC04ShackDoor02`, the exact same node the `Open`/`Close` animation
   tracks target, and the built tree now nests `CollisionBody` under that node, not the
   root. Exercised via `nif_viewer.tscn` (new: an editor tool, `project/nif_viewer.gd`/
   `.tscn` — pick a preset or a custom MODL-style path, press "Load NIF", inspect the
   real built hierarchy in the Scene dock) against both the door case and the
   180-submesh/234-scene_node silo elevator, calling this exact function — not a
   parallel bespoke copy, so the tool stays honest about what will actually ship.
   `native/src/nif/nif_loader.cpp`'s own `flatten_to_root()` (the Static path's
   flattened-transform computation) was also unified into `flatten_via_scene_nodes()`
   — it now composes the SAME cached per-node local transforms scene_nodes itself was
   built from, instead of independently re-walking the NIF a second way, per this
   project's own "generation of an object from a NIF should be a consistent code path"
   principle. Verified numerically identical to the old algorithm via the full
   regression suite's exact position/AABB assertions (`test_world_streamer.tscn`/
   `test_door_activate.tscn`/`test_collision.tscn` all pass at the same baseline as
   before this change).

   **Two real placement bugs found via visual inspection in `nif_viewer.tscn` (not
   caught by the regression suite, since nothing exercised this function's collision
   path before), both fixed:**
   - `col.transform` was set to `entry["transform"]` — the shape's transform flattened
     all the way to the NIF's root (native's `flatten_via_scene_nodes()`) — but `col`
     is parented under its owning node's own `GamebryoCollisionBody`, which ALREADY
     supplies everything up to that node via ordinary `Node3D` composition. Applying
     the full root-relative transform on top double-composed it, visibly offsetting
     the door's collision box from its own mesh by roughly the door's own width.
     Fixed by dividing out the owning node's own transform (relative to `parent`,
     computed via `global_transform`) before assigning `col.transform`. Confirmed
     numerically after the fix: the collision box's world-space origin now lands
     within millimeters of the door mesh's own AABB center.
   - `owning_node_index == -1` (mesh/collision legitimately attached to the NIF's
     root) fell back to `built[0]` — the block-index-order FIRST scene node, an
     arbitrary, unrelated node whenever the NIF has more than one — instead of
     `parent`, this tree's own root-equivalent (`scene_nodes` never contains an entry
     for the file's own root, by design). Fixed in both the mesh and collision loops.
6. ✅ **Build a real `AnimationPlayer` from `animation_sequences`, scoped to "see it and
   play it," not yet wired into `object_registry.gd`/`DoorNode` (deliberately deferred
   — see step 7).** `GamebryoMeshResolver.populate_animation_player(parent, nif, built)`
   (new, next to `populate_dynamic_children()`) builds one `Animation` per sequence
   (named exactly as authored — `"Open"`/`"Close"`), targeting the real nodes
   `populate_dynamic_children()` already placed via `NodePath`, using native typed
   `TYPE_POSITION_3D`/`TYPE_ROTATION_3D`/`TYPE_SCALE_3D` tracks per the Option 1
   decision in step 3. Quaternion-keyed tracks map straight across; per-axis (XYZ)
   rotation tracks — the real complication, since a real door's x/y/z key counts and
   times can all differ (confirmed: x=1 y=1 z=3 for the DLC04 shack door) while Godot
   wants one combined `Quaternion` per key — are resampled at the union of every
   axis's own key times (each axis linearly interpolated, not its own authored
   type) and combined via `Basis.from_euler(_, EULER_ORDER_XYZ)`. That specific Euler
   composition order is **not verified against a primary NIF-format spec** (nifly only
   stores these curves, never evaluates them — no reference implementation anywhere in
   this codebase to check against) — flagged in `populate_animation_player()`'s own doc
   comment, not silently assumed; the acceptance test below is also this assumption's
   real verification. Wired into `nif_viewer.gd` (called right after
   `populate_dynamic_children()`): the door's real "Open"/"Close" animations and the
   silo elevator's 7 sequences (mixed quaternion/position/scale tracks, up to 262 keys
   on one track) all build without error, confirmed headless (real key values dumped
   and sanity-checked: the door's `Open` track runs identity → ~90° about Z over its
   full length, a plausible door swing) — visual confirmation in the actual editor
   (select `AnimationPlayer`, use its own bottom-panel scrubber) is the next real step,
   not yet done here.

   Real play (step 7) confirmed direction/axis were correct, but reported the NIF-
   authored speed as reading slightly slow — fixed with `player.speed_scale = 1.25`, a
   flat playback-rate multiplier (not a re-timed curve), applied to every
   `AnimationPlayer` this function builds.
7. ✅ **Wire into `object_registry.gd`.** Gated on step 6's editor playback check as
   planned — confirmed correct (animation direction and rotation axis right; the
   collision-offset bug and the `built[0]` fallback bug found and fixed during that
   check, see step 5's own note). Two separate call chains needed the switch, not one —
   `DOOR` has two independent construction paths in this file, easy to miss:
   - `resolve_placement()`/`construct_from_resolved()` → `_resolve_door()`/
     `_construct_door()`, the threaded resolve/construct split `WorldStreamer` uses at
     runtime. `_resolve_visual()` now also stashes the live `NifReader` into
     `result["nif"]` — worker-safe to retain (no RenderingServer/PhysicsServer3D
     dependency, same reasoning already applied to `resolve_raw_geometry()`/`_load_image()`),
     and necessary since `populate_dynamic_children()`/`populate_animation_player()`
     need direct `NifReader` calls (`get_scene_nodes()`, `get_submesh_owning_node_index()`,
     `get_animation_sequences()`) that the RAW `geometry` Dictionary alone never captured.
   - `build()` → `_build_door()`, the synchronous path `CellLoader`'s `@tool`
     editor-preview (and direct test construction) uses — easy to miss entirely, since
     it doesn't touch the threaded split at all. Left un-updated, this would have
     silently shipped a preview/runtime divergence: `CellLoader`'s editor preview
     showing a flattened, non-animated door while `WorldStreamer` streamed a real
     hierarchical one, exactly the kind of drift this phase's own "consistent code
     path" principle exists to rule out. New `_instantiate_dynamic()` (`_instantiate_visual()`'s
     Dynamic-object counterpart) is what `_build_door()` now calls instead.

   **A third real bug found wiring this in** (not caught by `nif_viewer.tscn`, which
   happens to attach its own root to a live tree before building): `populate_dynamic_children()`'s
   collision code used `global_transform`, which requires `is_inside_tree()` — every
   other factory in `object_registry.gd` builds its whole subtree OFF-tree before the
   caller `add_child()`s it into the real scene, so this crashed immediately
   (`ERROR: Condition "!is_inside_tree()" is true`) the first time it ran through
   `_instantiate_dynamic()`. Fixed with a new `_local_transform_relative_to()` helper
   that composes only `.transform` (always LOCAL, always valid regardless of tree
   membership) walking up from a node to a given ancestor — confirmed identical
   collision placement in `nif_viewer.tscn` after the fix, and `test_door_activate.tscn`'s
   real raycast-through-the-collider check passes end to end through the real
   `CellLoader` → `object_registry.gd` path. Full regression suite at the same baseline
   as before this step.
8. ✅ **Wire `activate()`.** A non-teleporting door now toggles a real `is_open: bool`
   (in-memory only, no persistence — save/load's job) and plays the matching real
   animation via its `AnimationPlayer` child, as a side effect before returning `{}` —
   `game.gd`'s own `outcome.is_empty() -> return` needed no changes at all, "nothing
   happens" was always about destination data, not visuals. The exact
   open/closed/opening/closing state VALUES (`GetOpenState`'s own enum) weren't needed
   in the end — real data found via `enginedocs/GeckWiki/scripting/txt/Useful Scripts -
   GECK.txt`'s own `AutoClosingDoor` example script confirms the shape that actually
   matters: `OnActivate` calls the engine's own default `Activate`, and `GetOpenState`'s
   documented values (1 = Open, 3 = Closed, 4 = Closing) confirm a door genuinely
   tracks real state across activations — i.e. **toggle each call**, not "play once."
   Defaults closed, confirmed against the real DLC04 shack door's own animation data:
   `Open` starts at identity rotation, `Close` ends within ~0.5° of identity (a small
   authored settle/overshoot, not an exact match, but close enough to confirm
   identity/unanimated == closed for this door). Does NOT attempt a clean mid-swing
   reversal — re-activating while still animating just switches to the other animation
   via Godot's own default blend, a real, deliberate simplification, not silently
   claimed as exact. `tests/test_door_activate.gd` extended: `NVCraftsmanHomeDoor`
   starts closed, toggles open on `activate()` (only if its own model actually has
   animation data — checked via `AnimationPlayer` presence, not assumed), toggles back
   closed on a second call.
9. **Regression:** `tests/test_door_activate.tscn` (the teleport case) must pass
   unmodified — teleport and animated-swing are two different code paths that only
   share the `activate()` entry point and the `GamebryoCollisionBody`/`owner_ref`
   resolution already built for it. ✅ Confirmed: full regression suite at the same
   baseline as before this step.

### Part B — GECK feature parity (lower priority, not blocking)

10. ✅ **Open/Close/Loop sounds.** Real subrecord tags confirmed via fopdoc (not
    assumed): `DOOR.SNAM`/`ANAM`/`BNAM` (each a `SOUN` FormID), resolved through a
    NEW, deliberately generic `EsmFile::resolve_soun_filename()` (`SOUN.FNAM`) — not
    door-specific, per direct instruction, so any future sound need (ambient markers,
    weapon/footstep sets) reuses it. Real format-feasibility confirmed before writing
    playback code: FNV's own door sounds are plain `.wav`, not the Xbox-only `.xwm`
    some other Bethesda titles use — Godot's `AudioStreamWAV.load_from_buffer()`
    decodes them natively, no third-party decoder needed. `GamebryoMeshResolver.load_sound()`
    (generic, cached, mirrors `load_texture()`) + `DoorNode.apply_door_data()` build
    real `AudioStreamPlayer3D` children (`OpenSound`/`CloseSound`/`LoopSound`, present
    only when that DOOR record actually sets that sound), wired into `_toggle_swing()`
    alongside the animation. Real, important scope note found via the GECK Wiki's own
    Door page (not assumed): **animated doors typically bake Open/Close sound into the
    NIF itself via `NiTextKeyExtraData` instead of these ESM fields** ("only put
    Open/Close sounds on a baseform that is static... common reason for the double
    sound bug in the vanilla game") — `NiTextKeyExtraData` is NOT parsed here (unscoped
    native work), so an animated door plays no sound through this path, a deliberate
    gap matching real GECK guidance, not a bug. Confirmed end-to-end against a real
    static door with real sound data (`NVHooverDamTowerDoorInterior`, `0x175c30`): real
    2.15s decoded audio stream plays on `activate()`.

    **A real behavior gap found and fixed while wiring this in:** `_toggle_swing()`
    previously returned early (never toggling `is_open` at all) when a door had no
    `AnimationPlayer` — meaning a real, sound-only static door would never register as
    open. Fixed: `is_open` now always toggles regardless of whether there's an
    animation or sound to show it (open/closed is real game-logic state, not a label
    for whichever clip last played); animation/sound playback are each independently
    skipped only when that specific thing doesn't exist. `test_door_activate.gd`'s own
    assertion updated to match and re-verified.
11. 🟡 **Flags** — extracted via `esm::DoorData`/`FNAM` (real bit values confirmed via
    fopdoc), stored on `DoorNode` regardless of whether the system each one needs
    exists yet:
    - **Automatic Door** (`is_automatic_door`) — extracted and stored; the
      auto-teleport-within-`fAutoDoorActivateDistance` BEHAVIOR is NOT wired up yet
      (needs a proximity check somewhere in the interact/streaming loop) — real,
      implementable, explicitly left for a follow-up, not attempted alongside this step.
    - **Sliding Door** (`is_sliding_door`) — stored; no navmesh system exists yet, so
      "skip navmesh obstacle generation" is a no-op today.
    - **Hidden** (`is_hidden`) — stored; no local-map UI exists yet.
    - **Minimal Use** (`is_minimal_use`) — stored; needs AI/pathing (NPC shortcut
      suppression) to exist first.
    - **Quest Item** — deliberately NOT extracted. A real, if minor, scope
      finding: it's on the GECK Wiki's own DOOR dialog, but its real fopdoc-confirmed
      `FNAM` layout has only 5 bits (one unnamed/unconfirmed + the four above) — Quest
      Item isn't one of them. Almost certainly a generic record-header flag shared
      across many record types (not DOOR-specific), but its real bit position was
      never confirmed against fopdoc (no page found), so this stays unextracted rather
      than guessed — a verification gap, not the "no consuming system yet" gap the
      other four share (it would've been bookkeeping-only either way, per the original
      scoping here).
12. **Random-destination list** — explicitly deferred, not attempted here. GECK's own
   documented semantics ("resolved once, then persisted across saves") can't be
   correctly implemented without real save/load
   (`enginedocs/nv_save_architecture.html`). At most, parse and store the candidate
   list now; leave resolution/persistence for when save architecture lands.

## Deliverables

- Animated (non-teleporting) doors play their real open/close animation on
  `activate()`, confirmed in real play against at least one real animated door.
- Door open/close/loop sounds play correctly.
- Quest Item/Sliding Door/Hidden/Minimal Use flags are extracted and stored even where
  the systems they'd gate don't exist yet — documented as inert, never silently
  dropped.
- Automatic Door works for at least one real automatic door in the game.
- Random-destination list explicitly deferred, with the reason recorded here, not
  rediscovered later.

## Acceptance criteria

- [ ] A real non-teleporting door visibly swings open on interact, in real play (not
      just a headless test) — headless-verified (toggle logic, animation keyframe
      values); not yet confirmed via `game.gd`'s actual interact raycast in a live
      Play session.
- [ ] Re-activating an already-open door produces the correct real behavior (closes,
      or whatever GetOpenState's real states dictate) — confirmed via
      `AutoClosingDoor`'s own real script (toggle-per-activation, not "play once");
      the visible in-play result of that toggle is still unconfirmed (same caveat as
      above).
- [x] `tests/test_door_activate.tscn` (teleport case) still passes unmodified.
- [ ] Open/close sounds audible in real play for at least one door that has them.
- [x] Full existing regression suite has no new failures.
