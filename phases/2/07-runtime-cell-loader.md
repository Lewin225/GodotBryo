# 2.7 — Runtime Cell Loader (Door-Triggered, Interior/Exterior Unified)

Parent: [Phase 2](README.md)

## Goal

A real, gameplay-usable cell loader — not another `@tool` editor scene like
`interior_viewer.gd`/`exterior_viewer.gd`, which exist to inspect one hardcoded/
inspector-configured cell at a time in the editor. This is the runtime API a door
interaction (and, later, any other cell-transition trigger) actually calls: given a
destination, tear down the current cell, load the new one, and reposition the player —
interior and exterior handled through one entry point, not two separate code paths a
caller has to choose between.

Scoped deliberately narrower than full continuous world streaming (walking around and
having adjacent cells load/unload as you move — the larger, still-unscoped rest of
Phase 2's ROADMAP goal). This task is "load what a door transition needs," not
"stream the whole worldspace."

## Step 1 (do this first): `DOOR` destination parsing — currently doesn't exist at all

Confirmed before writing this doc, not assumed: `esm_file.cpp`'s `get_cell_references()`
(the REFR subrecord loop, ~line 279) reads `NAME`/`DATA`/`XSCL` and nothing else — no
`XTEL` handling. `DoorNode` (`project/gamebryo/door_node.gd`) has zero fields; its own
doc comment explicitly says "teleport/open state is interactive behavior, out of Phase
1's scope." This is the real blocker for everything else in this task — there is
currently no way to know which cell a door leads to, or where to place the player on
arrival.

- `XTEL` is a `REFR` subrecord (present on door `REFR`s that teleport, i.e. most
  exterior↔interior and interior↔interior doors — not present on doors that just swing
  open, e.g. a plain room door): destination `REFR` FormID (4 bytes), destination
  position (12 bytes), destination rotation (12 bytes), flags (4 bytes). Verify this
  layout against real `GSDocMitchellHouse`/Goodsprings door data before trusting it —
  same discipline as every other subrecord this project has parsed, don't assume the
  community-documented layout is exactly right without a real byte-level check.
- **The harder unsolved part**: `XTEL`'s destination is a `REFR` FormID (a specific
  door-marker placement on the other side), not a `CELL` FormID directly. There is
  currently no "find the `CELL` that contains REFR X" lookup anywhere in `EsmFile` —
  every existing lookup goes the other direction (`CELL` → its `REFR` children). Needs
  its own investigation: either walk up from the destination `REFR`'s file position to
  find its enclosing `CELL` (structurally, via the same parent-`GRUP` walking
  `get_child_records()` already does, just inverted), or build a `REFR FormID → parent
  CELL` index when the ESM is first opened (a one-time cost paid once per session, not
  per door). Pick based on what's actually observed once real data is in hand — don't
  guess the shape of this up front.
- Expose via `EsmReader`: something like `get_door_destination(refr_form_id) ->
  Dictionary` returning `{ "dest_cell_form_id": int, "dest_position": Vector3,
  "dest_rotation": Vector3 }` or empty if the door has no `XTEL` (a non-teleporting
  door — a real, valid case, not an error).

### Step 1 — done

`XTEL` layout confirmed byte-exact against real data (`GSDocMitchellDoor`,
`GSDocMitchellHouse`): 32 bytes — dest `REFR` FormID (4), dest position (12, same
Gamebryo-units-to-meters convention as `DATA`), dest rotation (12, radians), flags (4,
unused/unread) — exactly as the community-documented layout describes, verified rather
than assumed.

The harder part (REFR → containing CELL) resolved as a **positional-bisection walk**
(`EsmFile::find_owner_of()`/`find_cell_containing_ref()`): every `GRUP` header carries
its own byte size, so the walk only ever descends into whichever nested group's byte
range actually contains the target record — no content scanning, cheap regardless of
worldspace size or how many sibling cells exist at each level. Combined into `EsmFile::resolve_refr_xtel(refr_form_id)` /
`EsmReader.resolve_refr_xtel()` — deliberately named for what it actually does (resolve
any REFR's `XTEL`, not DOOR-specific; nothing here checks `base_type`) rather than
`get_door_destination`, after confirming that name was misleadingly narrow —
`get_door_destination()` still exists as a thin same-signature wrapper, since that's the
name a door-interaction call site actually reaches for. Either way, a caller only needs
the REFR's own FormID (no need to already know its home cell).

**Verified against real data three ways, not just unit-tested**: (1) confirmed
`GSDocMitchellDoor`'s destination position/rotation match the raw `XTEL` bytes
byte-for-byte; (2) an initial sanity assumption ("the destination should be near
Goodsprings grid cell (-17,0)") turned out to be wrong, not a bug — traced down by
independently confirming, via the already-proven `get_cell_references()` path (fully
separate code from the new resolution logic), that the resolved destination cell
genuinely does contain the exact destination REFR as a direct child; (3) the
non-teleporting-door case (`NVCraftsmanHomeDoor`, a plain door placed *inside*
`GSDocMitchellHouse` with no `XTEL`) correctly returns empty/`has_destination=false`,
not a crash or a false positive.

**Wired into `DoorNode`** (not looked up lazily): `GamebryoObjectRegistry._build_door()`
calls `DoorNode.resolve_destination(esm)` once at build time, right after the node's
own `form_id` is set — matching how `LightNode` already resolves its `LightData` once
at build time rather than re-querying. `DoorNode` now exposes `has_destination`,
`dest_cell_form_id`, `dest_position`, `dest_rotation` as real fields.

Full existing test suite re-run and passing.

## Step 2: Unified load/unload entry point

One GDScript class/autoload (not yet named — decide during implementation) exposing
something like `load_cell(cell_form_id: int) -> void`, internally dispatching to
interior (`get_cell_references()` only) or exterior (`get_land_data()` + terrain +
references) based on whether the cell has a parent `WRLD` — reusing
`GamebryoObjectRegistry`/`GamebryoMeshResolver`/`GamebryoTerrainBuilder` exactly as
they exist today, not reimplementing cell-building logic a third time.

- **Cache lifetime split, stated explicitly so it doesn't get scoped wrong**: the
  `GamebryoMeshResolver` (mesh/texture/material caches, Phase 2.0) persists for the
  whole session, across every cell transition — that's the entire point of it. Only
  the previous cell's *node subtree* gets torn down per transition.
- **Teardown must free immediately, not with `queue_free()`.** Directly reuses a bug
  already found and fixed once this session in `exterior_viewer.gd`:
  `queue_free()`'s deferred removal lets a same-named replacement node collide and get
  silently renamed by Godot. A loader that's triggered repeatedly during real gameplay
  (not once via an editor button) needs the same `remove_child()` + `free()` pattern
  from the start, not to rediscover the same bug.
- **Re-entrancy guard**: same generation-counter/cancellation pattern from
  `exterior_viewer.gd`'s streaming fix (phases/2/02). A player mashing "activate" on a
  door mid-load must not race two loads against each other.
- **Exterior scope decision** (a real judgment call, not a default to assume): load
  just the destination cell, or the destination plus a small neighborhood (reusing
  `exterior_viewer.gd`'s grid-range loading) to avoid a visible terrain edge right at
  the door? Recommend: destination cell only for this task, small neighborhood as a
  deliberate, separately-flagged follow-up — keeps this task's scope to "what a door
  transition needs," continuous adjacent-cell streaming is its own later task per this
  README's "Why these three, and why now" framing.

### Step 2 — done

Built as `project/cell_loader.gd` (`class_name CellLoader`), a real runtime class rather
than another `@tool` inspection scene — `load_cell(cell_form_id: int)`. Dispatch between
interior/exterior turned out not to need an explicit branch at all: every cell is
checked via `get_land_data()`, which already returns `{}` gracefully for an interior
cell (or an exterior cell that genuinely has none, same as Phase 1's own scope note) —
terrain is only built when it returns real data. `get_cell_references()` is identical
either way. Confirmed one real gap along the way and fixed it: there was no way to
recover an exterior cell's own `XCLC` grid coordinate from just its FormID (only the
reverse direction existed) — needed to position terrain correctly when loading by
FormID alone rather than iterating a known grid range like `exterior_viewer.gd` does.
Added `EsmFile::get_exterior_cell_grid()` / `EsmReader.get_exterior_cell_grid()`,
verified against real data in both directions (Goodsprings' grid cell round-trips to
`(-17, 0)`; an interior cell correctly returns empty).

**Double-buffered swap**, per discussion: a hidden, physically-inert `LoadingCell` is
built and streamed in (same frame-budgeted batching as `exterior_viewer.gd`) while
`CurrentCell` stays fully live and solid the whole time — collision is disabled
(`CollisionShape3D.disabled = true`) on every node as it's added to `LoadingCell`, then
flipped back on in one pass at swap time, so nothing the player could clip into is ever
live before the swap. The old `CurrentCell` is freed and only *then* is `LoadingCell`
renamed — hit the exact node-name-collision bug already fixed once this session in
`exterior_viewer.gd`, but in the opposite order this time (renaming before freeing the
old same-named node, so Godot silently renamed the new one instead) — caught by a real
test (`get_node("CurrentCell")` resolving to something other than the just-loaded
root), not by inspection.

**No retention pool** (per discussion — 2.0's caching already makes a cold rebuild of a
recently-visited cell cheap; a small LRU pool of recently-left cells is a legitimate
later optimization if real measurements say backtracking still isn't fast enough, not
built in now).

**Player repositioning is deliberately not this class's job** — it has no notion of a
player node at all. A caller (the eventual door-interaction handler) already holds the
landing transform from `DoorNode.dest_position`/`dest_rotation` before ever calling
`load_cell()`, and repositions its own player node on `load_completed` — keeps this
class decoupled from a player controller that doesn't exist in this codebase yet (being
built separately).

**Verified**: `test_cell_loader.gd` — interior load, swap to exterior (confirming the
old root is actually freed, not just hidden, and terrain/objects build correctly),
swap to a second interior, and a mid-load cancellation (confirming the previous
`CurrentCell` is completely untouched and `load_completed` never fires for a cancelled
load). A separate physics test confirms collision is genuinely re-enabled after swap,
not just visually correct — a ball dropped onto post-swap terrain settles at the
expected height. Full existing test suite re-run and passing.

### Revised after real use: `CellLoader` is now `@tool`, a real scene node, and caches xrefs

While actually wiring this into a real gameplay scene (`game.tscn`, with a real
character controller dropped in), three gaps surfaced:

1. **`CellLoader` was being spawned via `CellLoader.new()` in code** rather than
   existing as a real node authored in the `.tscn`. Fixed: `game.tscn` now declares
   `CellLoader` directly (`$CellLoader`), the same way `Sun`/`WorldEnvironment` already
   are — no code-side instantiation.
2. **No way to inspect/use it without pressing Play.** Fixed: `CellLoader` is now
   `@tool`, with an exported `cell_editor_id` and a "Load Cell" inspector button —
   the same interactive pattern `interior_viewer.gd`/`exterior_viewer.gd` already
   established, but on the one class real gameplay also uses, not a third parallel
   tool. Editor-built nodes get proper ownership (`_own_recursive()`, same as those two
   scripts) so they show up correctly in the Scene dock; a no-op at runtime.
3. **No way to query what's actually in the cell being loaded.** The REFR placement
   data was being consumed once (to build nodes) and thrown away. Fixed: `CellLoader`
   now caches the current/loading cell's full REFR list as soon as it's fetched — 
   queryable via `get_current_refs()`/`find_ref_by_editor_id()`/`find_ref_by_form_id()`
   — available as soon as `load_started` fires, not only after `load_completed`. Lets a
   caller (e.g. a spawn-point lookup) find a specific marker REFR directly instead of
   re-deriving the same data from `EsmReader` itself.

Verified: the existing `test_cell_loader.gd` (code-instantiated) still passes unchanged
— `@tool` didn't break runtime use. `game.tscn`'s scene-declared `CellLoader` loads
correctly end-to-end. The editor-load path (`cell_editor_id` + `_editor_load_cell()`)
and xref queries (`get_current_refs().size()`, `find_ref_by_editor_id()`) verified
directly — 434 refs cached for `GSDocMitchellHouse`, `GSDocMitchellDoor` found and
correctly typed. Full test suite re-run and passing.

## Step 3: Signals

- `load_started(cell_form_id: int)`
- `load_progress(fraction: float)` — the natural place to expose 2.2's frame-budgeted
  streaming progress once that lands; until then, can fire `0.0`→`1.0` around a single
  synchronous or coroutine-based load.
- `load_completed(cell_form_id: int, success: bool)` — "success" must mean collision is
  in place too, not just first-frame-visible geometry, so a caller can safely move the
  player without them falling through ungenerated collision.

## Step 4: Player repositioning + minimal trigger

- Reposition the player node atomically with the cell swap — using `XTEL`'s
  destination position/rotation from Step 1 — ideally between `load_started` and
  `load_completed` so nothing renders the player standing in the old (about to be
  freed) cell at the new position for a stray frame.
- **No interaction/input system exists anywhere in the project yet.** Full raycast/
  "activate" input handling is real player-controller work (ROADMAP Phase 3
  territory) — out of scope here. A minimal programmatic trigger (e.g. a script-callable
  `trigger_door(door_refr_form_id: int)`, or a `Area3D`-based proximity+key-press stub)
  is enough to prove the loader end-to-end without building the real interaction
  system prematurely. Confirm this scope with the user before over-building it.

### Step 4 — door trigger done; player repositioning deliberately deferred (player controller being built separately)

`DoorNode.activate() -> Dictionary` — a plain callable function, not a signal, matching
the same decoupling `resolve_destination()` already established (`DoorNode` has no idea
`CellLoader` or a player exists). Returns
`{ "dest_cell_form_id", "dest_position", "dest_rotation" }`, or `{}` for a
non-teleporting door (a real, valid case — confirmed with `NVCraftsmanHomeDoor`, not a
contrived one).

**"Pickup-able by a raycast" needed zero extra plumbing** — confirmed with a real
`PhysicsDirectSpaceState3D.intersect_ray()` test, not assumed: `DoorNode` is already a
real `StaticBody3D` (via `GamebryoReference`) with real collision shapes
(`populate_collision_children()`, already called during `_build_door()`), so a normal
world-space raycast toward a cell-loader-built door's own position already returns that
exact `DoorNode` instance as `collider` — Godot's default collision layer/mask (1/1)
just works, nothing was disabled or needed adjusting. A caller's own interaction code
just needs `if hit.collider is DoorNode: var dest = hit.collider.activate()`.

Verified end-to-end with `test_door_activate.gd` against a real, loader-built
`GSDocMitchellDoor`: raycast hit identity, `activate()`'s returned data matches the
door's own resolved fields, and the non-teleporting-door empty-result case. Full
existing test suite re-run and passing.

Player repositioning itself is out of this task's scope, per direction — a player
controller is being built separately and will own connecting `activate()`'s returned
destination to `CellLoader.load_cell()` and its own transform on `load_completed`.

## Deliverables

- `XTEL` parsing in `EsmFile`/`EsmReader`, verified against real door data.
- REFR→parent-CELL resolution (shape TBD, per Step 1's investigation).
- A unified runtime cell loader (interior + exterior, one entry point).
- `load_started`/`load_progress`/`load_completed` signals.
- A minimal door-trigger stub sufficient to demonstrate an end-to-end transition.

## Acceptance criteria

- [x] `XTEL` destination data confirmed against real byte-level door data, not assumed
      from documentation alone.
- [x] Given a door's REFR FormID, the loader resolves the correct destination cell and
      landing transform.
- [x] Loading a new cell tears down the previous cell and loads the new one, interior
      or exterior, through the same call (`CellLoader.load_cell()`) — verified
      interior→exterior→interior, old root confirmed actually freed each time, not
      just hidden.
- [x] Repeated/rapid triggering doesn't race two loads against each other —
      `cancel_load()` verified mid-stream, previous `CurrentCell` completely untouched.
- [x] `load_completed(success=true)` only fires once the destination cell's collision
      is actually in place — verified with a real physics drop test after a swap, not
      just visual inspection.
- [x] A door is pickup-able by a raycast and callable by function, with zero extra
      collision-layer plumbing needed — `DoorNode.activate()`, verified end-to-end
      against a real loader-built door.
- [ ] A real interactive test with an actual player controller: trigger a door
      transition and confirm the player lands correctly, doesn't fall through the
      floor, and the previous cell's nodes are actually gone. Needs a player controller,
      being built separately — this task's own scope (loader + door trigger) is
      otherwise complete.
