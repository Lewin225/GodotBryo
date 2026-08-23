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

1. **Confirm scope against real data before writing a parser.** Sample how many real
   `DOOR` placements across `FalloutNV.esm` + DLC actually use an "Animated" model
   variant vs. a plain one, and confirm the exact NIF block chain nifly exposes for
   them (`NiControllerManager` → `NiControllerSequence` → `NiTransformInterpolator` →
   `NiTransformData`) against a real sample — don't assume the chain shape from the
   block names alone.
2. **Native parsing** (`nif_loader.cpp`): extract keyframe time + transform samples
   for the single animated node a door's swing uses. Explicitly no
   `NiSkinInstance`/bone-hierarchy support needed here — that's the harder, later part
   of Phase 3, deliberately deferred.
3. **Playback mechanism, decided not assumed:** compare a lightweight custom
   interpolator (manual per-frame `Transform3D` lerp/slerp between keyframes) against
   reusing Godot's `AnimationPlayer`/`AnimationLibrary` for this single-node case
   before picking one — a full `AnimationPlayer` pipeline may or may not be worth
   standing up this early versus when real skeletal animation lands later in this
   phase.
4. **Wire `activate()`:** a non-teleporting door with animation data plays its open
   animation instead of returning `{}`. Determine the real open/closed/opening/closing
   state mapping (GECK's `GetOpenState` — confirm the actual value-to-state mapping
   against real data, referenced but not fully specified in
   `enginedocs/GeckWiki/scripting/txt/Scripting for Beginners - GECK.txt`'s own
   `GetOpenState == 3 ; Closed` example) so re-activating a door mid-swing or already
   open does the right thing, matching the real `AutoClosingDoor` example script's own
   behavior rather than guessing.
5. **Regression:** `tests/test_door_activate.tscn` (the teleport case) must pass
   unmodified — teleport and animated-swing are two different code paths that only
   share the `activate()` entry point and the `GamebryoCollisionBody`/`owner_ref`
   resolution already built for it.

### Part B — GECK feature parity (lower priority, not blocking)

6. **Open/Close/Loop sounds:** extract the real sound-reference subrecords from a
   `DOOR` record (verify the actual subrecord tags against real bytes — don't assume
   from memory), play via `AudioStreamPlayer3D` on activate()/animation-complete.
7. **Flags** — extract the record's flag bitfield and wire what can actually do
   something today, while explicitly documenting (not silently dropping) what can't
   yet:
   - **Quest Item** — bookkeeping only for now; no despawn-prevention system exists.
   - **Sliding Door** — no navmesh system exists yet, so "skip navmesh obstacle
     generation" is a no-op today; store the flag, don't implement the behavior yet.
   - **Hidden** — no local-map UI exists yet; same caveat.
   - **Automatic Door** — real and implementable now: auto-teleport within
     `fAutoDoorActivateDistance` (a real `GMST`), needs a proximity check somewhere in
     the interact/streaming loop.
   - **Minimal Use** — needs AI/pathing (NPC shortcut suppression) to exist first; not
     implementable yet.
8. **Random-destination list** — explicitly deferred, not attempted here. GECK's own
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
      just a headless test).
- [ ] Re-activating an already-open door produces the correct real behavior (closes,
      or whatever GetOpenState's real states dictate) — confirmed against real data,
      not guessed.
- [ ] `tests/test_door_activate.tscn` (teleport case) still passes unmodified.
- [ ] Open/close sounds audible in real play for at least one door that has them.
- [ ] Full existing regression suite has no new failures.
