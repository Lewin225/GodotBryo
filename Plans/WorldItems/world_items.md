# World items

Placed items become physics objects the player can pick up into an inventory and drop back into
the world. Covers MISC, ALCH, AMMO, KEYM, WEAP, ARMO, BOOK, CCRD and CMNY references.

## Status

Steps 1 to 7 are built on the `world-items` branch; step 8 was run once (results above) without
switching the project. The player controller has no drop request yet (no inventory UI to send
it from).

## Starting state

- `EsmReferencePhysicaliser._make_node()` sends all nine item reference types to `EsmItemNode`
  (`GodotBryo/Types/Node/esm_item_node.gd`). The node is the NIF tree only: `nif_tree_builder.gd`
  builds the item's collision as a `StaticBody3D`, so items are static props.
- Each item type has its own reference resource (`MiscReference`, `AlchemyReference`, ...).
- `InventoryItem` is either a stack (a base and a count) or one `item_reference`. Nothing sets
  `item_reference` outside tests.
- `physics/3d/physics_engine` is unset in `project.godot` (`DEFAULT`, Godot Physics). In v0,
  small items such as keys fell through floors, and loose items were kept physics-paused.
- `ScriptServer.activate()` runs the target's `OnActivate` block when it has one, otherwise
  `default_activate()`: the reference's `default_activate()`, then its node's `on_activated()`.
- `EsmReference.set_location(space, position)` sets `current_space_form_id` and `position` and
  recomputes `current_cell_form_id`; a cell change emits the reference's `cell_changed` and
  `EsmServer.reference_cell_changed`, which the streamers follow.
  `_refresh_cell()` returns early for space 0, so a reference set to space 0 keeps its old cell
  and emits nothing.

## Census

`native/tools/item_physics_census`, every placed REFR of an item base in FalloutNV.esm (26068)
and its world model (ARMO's MOD2, every other type's MODL):

- By type: MISC 20469, ALCH 4214, WEAP 691, AMMO 385, ARMO 239, BOOK 52, KEYM 18. No placed
  CCRD or CMNY.
- 26045 have a `bhkRigidBody`. 13 have no model (brass knuckles and other hand-to-hand weapons,
  RexBite, a surgical mask, V22MantisEgg); 10 have a model with no rigid body (microphones,
  `25mmGrndLnchrUnique`, `boxinggoldlt`, `DisplacerGloveRigid`).
- REFR record flag 0x20000000 ("Don't Havok Settle"): set on none.
- Rigid bodies per model: 1 on 25786 references; 2, 4 or 6 on 259; 0 on 23.
- Motion system: 4 on 25884 bodies, 2 on 864, 7 on 19, 6 on 3. Quality type: 3 on 26748, 1 on
  19, 2 on 3. Collision response: 1 on all.
- Collision filter layer: 4 on 17440 bodies, 10 on 8612, 5 on 589, 6 on 64, 7 on 44, 1 on 18,
  2 on 3.
- Shapes: `bhkConvexVerticesShape` 19621, `bhkBoxShape` 6489, `bhkCapsuleShape` 458, a MOPP over
  a list of transformed boxes and convex shapes 146, a list of convex shapes 48, a MOPP over
  packed triangle strips 8.
- Mass: 0.1 to 98; 84 bodies have mass 0. Friction 0.5 on 25721 bodies (0.1 to 5 on the rest).
  Restitution 0.4 on 25817 (0.2 to 0.9 on the rest). Linear damping 0.1 and angular damping 0
  on 26751; 1.0 and 1.0 on 19.

- Deactivator type: 2 (spatial) on 26753 bodies, 1 (never) on 17. Solver deactivation: 2 (low)
  on 26751, 1 (off) on 19. Mass 0 is only on fixed or keyframed bodies (17 MISC fixed, 3 MISC
  keyframed, 2 KEYM fixed).

`native/tools/nif_physics_by_type`, distinct models per base record type: the body's motion
system and quality say whether a model moves, not the collision object (every collidable model
has a `bhkCollisionObject`, flags 0x01, or 0x29 on keyframed bodies). 7/1 (fixed) is 4845 of
5492 STAT models with collision and every FURN; 6/2 (keyframed) is doors and animated
containers and activators; 4, 2 or 8 with quality 3 (moving) is almost every item model. 34 of
263 MISC models and 4 of 7 KEYM models are fixed; about 260 STAT, 99 MSTT, 23 ACTI and 7 CONT
models are moving.

`native/tools/nif_motion_census`, all 20542 NIFs: 1480 carry a moving body (2435 bodies at
motion 4, 130 at 2, 2 at 8), all owned by a `bhkCollisionObject`; 28 of them also carry a fixed
or keyframed body. Every ragdoll bone (`bhkBlendCollisionObject`, 1103) is keyframed.

`native/tools/havok_settle_census`, every master: REFR flag 0x20000000 ("Don't Havok Settle") is
on 124 REFRs in FalloutNV.esm, 40 in HonestHearts.esm, 9 in LonesomeRoad.esm and 17 in
DeadMoney.esm. Every flagged base is a STAT whose model's bodies are fixed (motion system 7), or
one of 35 HonestHearts MSTTs with no rigid body. It is never on a reference whose model has a
moving body, so it changes nothing in the shipped data and is not read.

`native/tools/nif_constraint_census`: 163 models carry a constraint on a moving body (see
NifServer's README, Joints). `clutter\school\globe01.nif` (Globe00) is a frame and a globe, two
moving bodies on a `bhkHingeConstraint`; without the joint the globe falls out of its frame.

## Doc Mitchell's house (`tests/test_world_item_physics`)

153 items with moving bodies. Every item has its support's collision directly under it; many
are authored touching it or a few millimetres inside it.

| | Godot Physics | Jolt |
|---|---|---|
| Awake 15 s after load | 52 | 1 |
| References dirtied by settling | 23 | 11 |
| Picking up a bottom item wakes the one above | no | yes; it falls 0.015 m and sleeps |

- On Godot Physics most awake items fall through the room's triangle-mesh floor and shelves
  (Plunger, SurgicalTubing at y -700 m) and the book stacks jitter at 0.01 to 0.09 m/s without
  sleeping. On Jolt only the Plunger, authored exactly at the floor, falls through.
- On Jolt the dirtied references are items leaning against walls (Crutch, HatPrewarHat,
  BoxDetergent) and medicine shelf items that slide or tip more than 0.1 m before resting.
- Freeing the node an item rests on does not wake the item on either engine, so pickup wakes
  its neighbours itself.
- Releasing bodies before the cell's NIFs arrive drops items through shelves whose collision
  is not built yet; bodies start frozen until nothing under their cell or tile root waits on a
  NIF.

## Decisions

- **One item node for every item type.** `EsmItemNode` stays a `Node3D` at the placement.
  NifServer builds what the NIF asks for: a body whose motion system moves (1, 2, 4, 8) is a
  `NifRigidBody` under the node that owns the collision, moving that node, so the meshes follow
  it. A STAT that carries one freezes it (`EsmStaticNode`). Per-type behaviour (reading a book, a stack
  count on ammo or caps) is data on the reference resources and a handler at activation, not
  node subclasses.
- **The reference is the item's identity and is never removed.** Pickup frees the node and puts
  the same reference in the activator's inventory as an `InventoryItem` with that
  `item_reference`. Drop places the same reference in the world again, and the streamer builds a
  new node for it.
- **Two location fields.** A reference is either placed or held, never both:
  - `current_space_form_id` + `position` (with the derived `current_cell_form_id`): where a
    placed reference is. 0 when held.
  - `holder_instance_id`: the `instance_id` of the actor or container reference whose inventory
    holds it (`FalloutNV.esm:00101C9E` style for a placed holder, a runtime id for a runtime
    one). Empty when placed.

  One field holding either kind would mix a WRLD/CELL FormID with a reference `instance_id`,
  leave `position` meaningful for only one kind, and make every reader of
  `current_space_form_id` (streamers, `TransitionCoordinator`, `cell_at`, saves, GetInCell,
  GetDistance) tell the two apart. With two fields those readers see space 0 for a held item and
  skip it. Setting one clears the other, and an assert checks that only one is set.
- **Location is queryable.** Quest markers point at items in containers. An item's world
  location is its own when placed and its holder's when held:

  ```gdscript
  func world_location() -> EsmReference:
  	var holder := get_holder()
  	if holder != null:
  		return holder.world_location()
  	return self
  ```

  Holders are actors and containers, which are placed, so the walk ends one level up.
- **Pickup and drop are actor features.** NPCs pick items up too, so both live on the actor side
  (`ActorReference` or a server acting on it), not in `PlayerController`. Activating an item
  calls the actor's pickup. The player controller drops by sending a drop request with the item's
  reference, which is unique.
- **Godot Physics first, then Jolt.** The physics items are built and tested on the current
  engine, then the project switches to Jolt and the two are compared on performance and
  stability, small items falling through floors included.
- **Moves use the existing notification.** Drop is `set_location()` to the dropping actor's
  space and position, the path an NPC moved to the player takes. Pickup sets the space to 0
  through the same path, so `_refresh_cell()` must set `current_cell_form_id` to 0 and emit
  `reference_cell_changed` when a reference goes to space 0; the streamer then frees its node.

## Build order

1. **Census.** Over every placed item reference in FalloutNV.esm and its NIF: the `bhkRigidBody`
   motion type, layer, mass, friction and restitution; shape kinds (single, list, compound,
   nested); items with no collision; and the REFR "Don't Havok Settle" flag. Settles whether
   placed items start asleep at their authored placement or settle under gravity.
2. **Space 0 notification.** `_refresh_cell()` clears the cell and emits on space 0. Test: a
   loaded reference set to space 0 loses its node.
3. **Holder field.** `holder_instance_id` on `EsmReference`, `get_holder()`, `world_location()`,
   saved and loaded with the reference. Test: round-trip through save and load.
4. **Physics item node.** The tree builder builds the item's `bhk*` shapes under the item's own
   `RigidBody3D` with the census's mass and material values. A body writes its transform back
   to the reference when it falls asleep, not every frame.
5. **Sleeping and dirty threshold.** Sleep is aggressive but leaves items time to settle:
   short time-before-sleep and raised linear and angular sleep thresholds, tuned in a dense
   cell (Doc Mitchell's house, a store shelf) until items settle in place and the active body
   count drops to zero soon after load. A body's write-back marks its reference dirty only when
   it has moved past a threshold from its authored placement (distance and angle), or when the
   player, an actor or a script moved it; settling alone never does.
   - Stacked and touching items (the stacked books in Doc Mitchell's house) sleep while in
     contact with each other: sleep goes by velocity, never by having no contacts, and a stack
     that jitters is fixed by the thresholds, not by keeping it awake.
   - Removing an item wakes its neighbours. Whether a sleeping body wakes when what it rests on
     is freed is checked on Godot Physics and Jolt; where it does not, pickup queries the item's
     bounds, grown slightly, and wakes every item body it overlaps before freeing the node. Item
     bodies do not use contact monitoring for this.

   Tests: loading a dense cell and waiting for every body to sleep leaves no item reference
   dirty, the book stack included; picking up the bottom book wakes the books above it, which
   fall and sleep again.
   Built: bodies start frozen until their surroundings' NIFs arrive, then are released asleep at
   their placement (nothing settles on load; see Doc Mitchell's house, HatPrewarHat), the node follows its body
   to rest, and the reference is written past 0.1 m or 25 degrees from its stored placement.
   Sleep thresholds are Godot's defaults; tuning them waits on the engine choice.
6. **Pickup.** An actor's pickup moves an item reference into its inventory: space 0, holder
   set, an `InventoryItem` with `item_reference`. The item references' `default_activate()`
   calls the activator's pickup; scripted items run `OnActivate` first, as
   `ScriptServer.activate()` already does.
7. **Drop.** An actor's drop takes the item reference, removes its entry and places it at the
   actor through `set_location()`. The player controller sends the drop request by reference.
8. **Jolt comparison.** Switch `physics/3d/physics_engine` to Jolt and compare against Godot
   Physics: frame time with many loose items loaded, and items resting on floors and shelves
   without falling through or jittering. Keys and other small items are the stability case.

## Open

- Whether the game simulates placed items on load. HatPrewarHat (`00105C6F`) hangs on
  SubHatstandDirty01 (`00105C70`), whose only collision is a capsule pole: simulated, it falls
  1.43 m. In the game it stays on the stand, does not move when touched, and is thrown off when
  punched, so it intersects the stand. Bodies are released asleep; whether anything then floats
  that the game shows resting is to be checked in play.

- The dirty threshold's values, and whether "moved by something" is tracked (an impulse or grab
  sets a flag on the node) or the threshold alone is enough. An item that settles differently
  on each load stays below the threshold unless it falls off something.

- Dropping from a stack (AddItem, container contents, leveled lists), which has no reference:
  the dropped unit needs an id when dropped, a runtime reference. Gamebryo also drops several
  units of a stack as one reference carrying a count, so a dropped stack may be one reference
  with a count (holding units of the same quality) rather than one reference per unit.
- Stacks: picking up a placed reference gives one entry per reference. Whether identical
  references merge for display waits on an inventory UI. Authored container entries stay stacks
  (`Plans/Completed Plans/Saving/save_load.md`, Open).
- Bodies outside the full-detail streaming radius and in paused exteriors: frozen, and when a
  moved item's cell unloads its last transform is already on the reference.
- Cell reset and cleanup of dropped items (save plan, Open).
