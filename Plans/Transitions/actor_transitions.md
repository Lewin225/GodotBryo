# Actor space transitions

How any actor, player or NPC, moves between spaces, and how the loaded world
follows the player. Replaces the door-transition ownership described in
`Plans/GameGd/game_gd_decomposition.md` §4 and "What Game should keep".

## Model

The loaded world follows the player's reference, as in Gamebryo: a door
teleport moves whoever activated it; for the player, that move is what causes
the load.

- An `ActorReference` is the truth for where an actor is. Nodes and physics
  bodies are projections of it.
- A physical node exists only while its reference's space is loaded.
- When a reference changes space:
  - an unpossessed actor's node is removed (checkin to `LOW_LEVEL`);
  - the possessed actor's space becomes the loaded space.
- The difference is decided by possession, never by the door or the caller.

Possession replaces Gamebryo's hard-coded player special case (the player's
`MoveTo` calling `TES::CenterOnCell`). The player is not a superclass of
actor: any actor can be possessed, which keeps NPC actors debuggable through
the same controller path and leaves room for co-op.

## Responsibilities

| Concern | Owner |
|---|---|
| Choosing what to activate | Controller: `PlayerController` via `InteractRay`, NPC package |
| Performing the activation | Actor: `ScriptServer.activate(target, self.reference)`; a `LOW_LEVEL` NPC's package calls it directly |
| Script dispatch, `Activate` semantics | `ScriptServer` |
| What activating a type means | `activate(ref, activator)` on the base type (`DoorBase`: teleport or swing) |
| Moving any reference | `ScriptServer.move_reference`, applied at one point per frame |
| Using terminals, furniture, containers | Actor state (`using` / `used_by`) via `ScriptServer.begin_use` / `end_use` |
| Loading the destination | Transition coordinator, reacting to the possessed actor's teleport |
| Showing UI | `PlayerController`, from its possessed actor's `using` state |

`game.gd` keeps no interaction, door or transition logic.

## Build order

Each stage ends at a test against the shipped data that prints
`ALL CHECKS PASSED`. A stage starts only after the previous gate passes.
`EsmServer` changes are their own stages (its README).

| Stage | Work | Gate |
|---|---|---|
| A | EsmServer location: `current_space_form_id` on `EsmReference`; `position` setter and `_refresh_cell`; grid index, `cell_at`, `reference_cell_changed`; exterior persistent references seeded into their grid cell | every placed exterior reference's cell is the grid cell under it; interiors unchanged; the signal fires only on a cell change |
| B | EsmServer doors: `DoorTeleportLink` replaces the `teleport_*` fields (callers `esm_door_node.gd`, NPC server portal seeding, `interact_ray.gd`); `is_locked` from XLOC presence | all XTELs populate a link; reciprocal pairs resolve; the 19 keyless level-0 doors are locked |
| C | `ScriptServer` autoload (`GodotBryo/Servers/ScriptServer/`) replacing the `ScriptEngine` scene node; `ScriptInstance` on `EsmReference`; per-dispatch contexts; block-parameter gating | existing script tests pass; `OnActivate Player` runs for the player only |
| D | Activation: `ScriptServer.activate`, default block, `Activate` rules, `EsmBase.activate` / `default_activate`, `DoorBase.activate`, `begin_use` / `end_use`, `lock` / `unlock`, `using` / `occupants` | a door activated with no node toggles `is_open`; a load door queues a move; key, level-255 and lockpick paths |
| E | Moves: per-frame queue and frame order, `reference_teleported`, `MoveTo` / `PositionCell` / `PositionWorld`; editor-id → reference lookup (EsmServer sub-stage) | `MoveTo` on an unloaded reference; moves in one frame collapse to the last |
| F | World reacts: `NavNpcSimulationServer` autoload indexing from `reference_cell_changed`; streamers physicalise/remove on cell change; nodes snap on same-space teleport | an NPC moved into a loaded cell appears; one moved out disappears |
| G | Player: `PlayerController` possession and `request_activate`; transition coordinator extracted from `game.gd`; frozen body; COC through the mover | in game: a door both ways, a same-space door, COC |

Door transitions work again at G.

## Activation

Activation is resource to resource, so `LOW_LEVEL` NPCs with no loaded node
can use doors. It is owned by `ScriptServer`:

```
ScriptServer.activate(target: EsmReference, activator: EsmReference)
  └─ run target's OnActivate block, or the default block
       └─ Activate  (inside the target's own block)
            └─ target.default_activate(activator)
                 └─ target.base.activate(target, activator)
                      └─ engine primitives (move_reference, ...)
```

### Script blocks

- A reference's block script is its base record's `SCRI`
  (`<type>_base.script_form_id`), reached through `reference.base`. No
  `FalloutNV.esm` REFR carries `SCRI` (0/314095).
- Blocks are separate entry points into one script. They share that script's
  locals, which are per reference (see "Script state").
- Block lookup is per block type. When the target's script has no
  `OnActivate` block, including when it has other blocks such as `GameMode`,
  or when the target has no script, the default block runs:

  ```
  Begin OnActivate
  	Activate
  End
  ```

- An authored `OnActivate` block replaces the default. The target's default
  behaviour then runs only if that block calls `Activate`.
- A block parameter filters by activator (`Begin OnActivate Player`). A block
  whose parameter does not match the activator counts as absent for that
  activation, so the default block runs. Verified in game: door
  `0008CD92` (`IndDoorSmAnim01`, script `OnActivate Player / Activate`),
  console `activate <Rex> 1` — Rex used the door (door sound, teleported), and
  his follow package brought him back through the same door.
- Parameterised `OnActivate` on DOOR bases in `FalloutNV.esm`: 6 scripts, 47
  load doors, including every `NVCGInvisibleCaveDoor` (19) and
  `IndDoorSmAnim01` (24). Under this rule all remain NPC-routable. Scripts
  that do restrict NPCs filter inside a bare block
  (`VMcCarranSilusDoorSCRIPT`: `if (IsActionREF LieutenantBoydREF || …)
  Activate`).

### Script state

A reference owns its script instance, as Gamebryo's `ExtraScript` does:

```gdscript
class_name ScriptInstance extends Resource
@export var script_form_id: int
@export var locals: Dictionary   # name -> int / float / reference instance id

# EsmReference
@export var script_instance: ScriptInstance   # null when the base has no script
```

- `ScriptInstance` is the persistent half: which script, and its locals. They
  persist whether or not the reference is loaded and are saved with it.
- `ScriptExecutionContext` is per dispatch only: calling reference, action
  ref, and the instance's locals. Built for one run and discarded.
- `ScriptServer` holds no per-reference state. It creates a reference's
  `ScriptInstance` lazily on first run or first write, seeding the declared
  locals (SCPT `SLSD`/`SCVR`) to 0.
- Cross-reference variables (`set MrJanitorREF.cleaning to 0`, a real patrol
  script) resolve the reference and write its `script_instance.locals`,
  loaded or not.
- `ref` locals are stored as instance ids, never resources: `.tres` stays
  acyclic and saves cleanly.
- Locals are keyed by name, as the interpreter resolves them. Compiled
  scripts address locals by `SLSD` index; saves may switch to index keys.

### Which scripts run

- `GameMode` (and `MenuMode`) blocks run only for references in loaded
  cells, as in Gamebryo, where object scripts stop when their cell is not
  loaded. Quest scripts are not reference scripts and are out of scope here.
- `ScriptServer` keeps the set of scripted references with a `GameMode` block
  in loaded cells, from the streamers' cell load/unload and
  `EsmServer.reference_cell_changed`. Membership is by cell, not by node:
  today's `_game_mode_nodes` misses any reference in a loaded cell without a
  node.
- Event blocks (`OnActivate`, `OnTrigger`, ...) run whenever their event
  happens, including on unloaded references: a `LOW_LEVEL` NPC activating a
  door in an unloaded cell runs the door's `OnActivate`.
- `OnLoad` stays tied to the reference's node being built.

### `Activate`

- Script `Activate [ActionRef] [RunOnActivateBlockFlag]` performs the target's
  built-in activation. With the flag 1 it runs the target's `OnActivate`
  block instead, as any other activation does. `Activate` inside a target's
  own `OnActivate` block therefore never re-enters it. Flag semantics are
  from the GECK wiki, unverified in game.
- The activator is the explicit `ActionRef` argument when given
  (`Activate player`), otherwise the current action ref.
- Activations from outside scripts (pawn, NPC package) run the target's
  `OnActivate` block, or the default block.

### Base-type activation

Activation behaviour lives on the base type, as in Gamebryo's base-form
`Activate`: the base record owns the script and every type-level fact, the
reference contributes only its own data (XTEL, XLOC, ownership). Base
resources are stateless and shared by every placement, so the reference is
passed in.

- `EsmBase.activate(ref, activator)` is a no-op; each base type with built-in
  activation overrides it. It decides what activating that type means and
  calls engine primitives to do it. It never implements a primitive itself,
  and `ScriptServer` holds no per-type table.
- `EsmReference.default_activate(activator)` calls
  `base.activate(self, activator)`. It is the dispatch point `Activate` uses,
  and the place a per-reference override can be added later. No reference
  overrides it now.

```gdscript
# DoorBase
func activate(ref: EsmReference, activator: EsmReference) -> void:
	var door := ref as DoorReference
	if door.is_locked:
		if door.lock_key != null and activator.has_item(door.lock_key):
			ScriptServer.unlock(door)
		elif door.lock_level == 255:
			return
		else:
			ScriptServer.begin_use(activator, door, -1)   # lockpicking
			return
	if door.teleport != null:
		ScriptServer.move_reference(activator, door.teleport.get_destination_space_form_id(),
			door.teleport.position, door.teleport.rotation)
	else:
		door.is_open = not door.is_open
```

### Locks

- `DoorReference.is_locked` is runtime state. XLOC initialises it: a door
  with XLOC is locked, at any level. Level 0 is Very Easy, not unlocked
  (verified: Prospector Saloon back door `0010901D`, XLOC level 0, no key,
  locked, lockpickable). `esm_server.gd` currently derives
  `is_locked = level > 0 or key`, which wrongly unlocks the 19 keyless
  level-0 doors (6 of them load doors).
- Lock levels 0/25/50/75/100 are Very Easy through Very Hard; 255 requires
  the key. `FalloutNV.esm`: 252 locked DOOR refs (65 load doors), 89 at 255,
  99 with a key, 54 at 100+ with no key (openable only by script).
- `ScriptServer.lock(ref, level)` / `unlock(ref)` are the primitives that
  change it. Script `Lock`/`Unlock` and package door flags call them.
- Package door flags (`PKDT`: lock/unlock doors at package start, end or
  location; 29 packages lock, 32 unlock) act once when triggered; they do not
  hold a state while the package runs. Inferred: Doctor Usanagi's clinic
  door `000ED1AA` is authored locked (level 50), her day packages carry
  "unlock doors at location", her sleep package has no door flag, and the
  door stays unlocked overnight. Bit assignments are from the community
  PKDT definition, not verified in this repo.
- Locked activation, for every activator:
  1. activator carries `lock_key`: unlock, then continue normally;
  2. level 255 without the key: fail;
  3. otherwise `begin_use(activator, door, -1)`: lockpicking is using the
     door. `PlayerController` shows the lockpick UI (success unlocks; either
     way it ends with `end_use`). An NPC controller or package ends the use
     immediately; the activation fails. NPCs do not pick locks.
- Owned locked doors show a red (crime) prompt to the player. Ownership stays
  on the reference for a future crime system.

A new type is one override on its base. A new kind of effect is one new
primitive on `ScriptServer`.

### Callers

| Caller | Call |
|---|---|
| `PlayerController` | picks a target from `InteractRay`, instructs its pawn: `pawn.request_activate(target_ref)` |
| Pawn (actor node) | `ScriptServer.activate(target_ref, self.reference)`; no reach check |
| `LOW_LEVEL` NPC package | `ScriptServer.activate(door_ref, npc_ref)` directly |
| Script `Activate` on another reference | `ScriptServer.activate(target, ctx.calling_reference)` |

Activation passes the `EsmReference` resource itself, never its id.
`EsmServer` hands out one instance per `instance_id`, so the resource is the
handle and `==` is identity. Ids are the form used for save games, worker-thread
messages and the console.

Node-level `activate()` becomes presentation only: the target's loaded node,
if any, is notified to play its animation. Every effect of activation happens
on references; activation never returns an outcome.

### Using a reference

Activating a terminal, furniture or container means the actor is using it.
That is actor state, not a UI event:

- `ActorReference.using: EsmReference` and `using_marker: int`, one slot. An
  actor never uses two references at once. `using_marker` is the furniture
  marker index, `-1` for any other type.
- FURN tracks occupancy per marker: `FurnitureReference.occupants`, one
  `ActorReference` or null per `MNAM`-active marker. One FURN reference is
  used by as many actors as it has free active markers; activation picks a
  free one and does nothing when none is free. Marker selection (nearest,
  first free) is decided when furniture use is implemented.
- Terminals and containers are single-user: `used_by: ActorReference`.
  Activation does nothing when `used_by` is another actor.
- `ScriptServer.begin_use(actor, target, marker)` / `end_use(actor)` are the
  primitives that set both sides together. Nothing writes these fields
  directly.
- `activate` on terminal, furniture and container base types calls
  `begin_use(activator, ref, marker)`.
- The player controller shows the UI for its possessed actor's `using`
  target. For any other actor, the same state exists and nothing is shown.
- Use ends by changing the actor's state: the player closing the UI calls
  `end_use(possessed)`; for NPCs, the package ends it. The UI never tears
  itself down independently.
- The target's own state (terminal page, locked or hacked) stays on the
  target reference; the UI reads it from there.
- Idle markers whose idle is a sit-and-type animation are not use. The actor
  uses neither a terminal nor furniture; it plays an idle.

Evidence (`FalloutNV.esm`, `furniture_marker_census.py`,
`terminal_use_census.py`):

- Furniture markers are FURN data. 227/234 FURN bases use a NIF with
  `BSFurnitureMarker` blocks; 45 have 2–6 active `MNAM` markers. Non-FURN
  bases reusing a furniture mesh (52 STAT, 2 ACTI, 1 MSTT) never use its
  markers. No TERM, CONT or DOOR model has markers.
- No NPC uses a terminal in the authored data: 0/4166 packages target a TERM
  reference or base (specific-reference and object-ID targets, location
  targets), and no script calls `Activate` on a terminal reference. NPC
  "terminal use" is authored as FURN (`UseClosedWallTerminalMarker`,
  `Computer*Chair*L/R`) or IDLM (`DefaultStandingTerminalMarker`) placed at the
  terminal: 95/219 placed terminals have one within 150 units. Unverified:
  object-type package targets were not decoded, and the IDLE search was by
  name. A community answer is pending.
- Terminals are therefore used only by possessed actors in practice;
  `used_by` matters for co-op.

This replaces `EsmTerminalNode.activate()`'s `{"terminal", "menu_items"}`
return value and `game.gd`'s two terminal branches.

### REFR embedded scripts

REFRs carry embedded patrol result scripts (`XPRD`/`XPPA`/`INAM` +
`SCHR`/`SCTX`/`SCRO`; 1343 in `FalloutNV.esm`, 106 with source text, on STAT,
IDLM and FURN markers). They have no blocks and are not part of activation.
They belong to the package system, which runs them on the arriving NPC.
`ScriptServer` needs to run a bare statement list with a given subject for
them and for dialogue result scripts.

## Moving references

One primitive moves any reference:

```
ScriptServer.move_reference(ref, space_form_id, position, rotation)
```

- Queues the move. Several moves of one reference in a frame collapse to the
  last. Queued moves are applied at one fixed point in the frame order:

  1. Body → reference sync, skipping frozen bodies.
  2. Script execution.
  3. Apply queued moves.
  4. Freeze the possessed body if its reference was moved.
- Applying a move sets the reference's space, position and rotation in one
  step (`_set_location`), so the cell is refreshed once (see "Reference
  location").
- Nothing validates the destination: doors, `MoveTo` and `PositionWorld` can
  all put a reference outside the generated world if the data or script says
  so. Every base-game and DLC XTEL landing has a grid CELL
  (`xtel_census.py`).
- Applying a move emits `reference_teleported(ref, old_space, new_space)`.
  The player controller listens for its possessed actor. Ordinary movement
  does not emit it.
- `position`/`rotation` are in the ESM convention already produced by the
  native parser: metres, Gamebryo Z-up axes, radians. Conversion to Godot
  axes happens only when a body is placed. No other unit conversion.

### Reference location

Every reference stores a space, a position and a cell. The cell is always
valid, interior or exterior, and is derived from the other two; no caller
writes it.

```gdscript
# EsmReference
var current_space_form_id: int
var current_cell_form_id: int          # written only by _refresh_cell
signal cell_changed(old_cell: int, new_cell: int)
var position: Vector3:
	set(value):
		position = value
		_refresh_cell()
```

- `_refresh_cell()` asks `EsmServer.cell_at(space, position)`. Only when the
  cell changes, it emits the reference's own `cell_changed` and reports to
  `EsmServer.reference_cell_changed(ref, old_cell, new_cell)`, the one global
  signal for every reference type. It compares the grid coordinate
  first and does a lookup only when that changes.
- `EsmServer.cell_at(space, position)`: an interior cell returns itself; a
  worldspace returns the grid cell at `floor(position / cell_size)`, or the
  worldspace's persistent cell when no grid CELL exists there. The
  interior/exterior difference exists only here.
- `cell_size` is 4096 Gamebryo units expressed in the same unit as
  `position` (metres, `units::kGamebryoUnitsToMeters`), not 4096.
- `cell_at` is backed by an in-memory `(worldspace, x, y) → cell` dictionary
  built once from the ESM (30096 exterior grid cells in `FalloutNV.esm`).
  Runtime code never calls the native `find_exterior_cell` /
  `get_cell_editor_id` / `get_exterior_cell_grid`: each walks or parses the ESM
  on disk per call, which is what made the old per-frame cell HUD expensive
  (`game.gd` `_hud_cell_form_id` exists to avoid it).
- Seeding assigns position through the same setter, so exterior persistent
  actors start in the grid cell under them, not the worldspace persistent
  cell (`esm_server.gd` currently records the persistent cell).
- `NavNpcSimulationServer` maintains `actors_by_cell_form_id` from
  `EsmServer.reference_cell_changed`. It writes a simulated actor's position only when that actor
  ticks; physicalised actors (normally under 30) write it on body sync.
- Measured cost (Godot 4.7.1, 1000 references written once per frame): plain
  field 0.051 µs/write; setter while walking 0.124 µs/write; setter crossing a
  cell and emitting on every write 0.444 µs/write.
- Exterior cells carry no data that needs them in `FalloutNV.esm`: 0/30096
  grid cells have `XOWN` or `XEZN`, all 773 `GetInCell` conditions and all 166
  package "in cell" locations name interiors. The stored cell exists so every
  reader gets one without branching.

### Entering and leaving the loaded area

One rule covers walking and teleporting, for every reference type:

- Streamers own which cells are loaded and listen to
  `EsmServer.reference_cell_changed`:
  - a reference without a physical node whose new cell is loaded is
    physicalised (actors: checkout from `NavNpcSimulationServer`);
  - a physicalised reference whose new cell is not loaded loses its node
    (actors: checkin).
- A physical node listens to its own reference's teleport. A teleport within
  the same loaded space snaps the node or body to the new transform (NPCs,
  and markers or items moved by `MoveTo`). A teleport out of the loaded area
  is already handled by the streamer rule.
- The possessed actor is the exception by construction: its cell changing to
  an unloaded one makes the transition coordinator load it, instead of the
  streamer removing its node.

Callers differ only in how they compute the destination transform:

| Caller | Transform |
|---|---|
| `DoorBase.activate` | `DoorTeleportLink`: destination space + landing transform |
| Script `MoveTo marker, x, y, z` | marker reference → its space + position + offset; rotation: the target's heading |
| Script `PositionCell` / `PositionWorld` | arguments |
| `CenterOnCell` / `COC` | cell's COC marker |
| Teleport debug tab, later fast travel | explicit |

`MoveTo` rotation, observed in game: a dropped item moved with `MoveTo player`
takes the player's heading; an NPC showed no visible change, either keeping
its heading or re-facing through AI before the frame rendered. `MoveTo`
applies the target's heading; actor AI may turn the actor afterwards.

A door teleport is not `MoveTo <destination door>`: that lands on the door's
origin and ignores the authored landing rotation.

## Player controller and transitions

`PlayerController` holds `possessed: ActorReference` and listens for
`reference_teleported` on it.

- Different space: request a load of the new space.
- Same space: reposition the body; streaming follows.

Both cases are required: 44 base-game XTEL doors teleport within one space.

A transition coordinator takes over `game.gd`'s `_do_exterior_transition`,
`_on_load_completed`, `_can_release_exterior_transition` and the
interior/exterior environment swap. It converges state rather than handling
one-shot events: desired space = possessed actor's space; if the loaded space
differs, load it. A teleport applied during a pending load retargets it,
guarded by the existing transition generation counter.

`CenterOnCell`'s separate `center_on_cell_handler` path is removed; COC moves
the possessed reference and the coordinator does the rest.

During a transition:

- The possessed body is frozen from the applied move until it is placed from
  the reference at the destination. A frozen body is skipped by body →
  reference sync, so it cannot write its old-space position back under the
  new cell. The move is applied after that frame's sync, so no sync runs
  between the move and the freeze.
- The simulation clock (`NavNpcSimulationServer`, game time) is paused until
  the transition is released, matching Gamebryo's load screen.

## Door teleport data

### XTEL, per exhaustive census

Every REFR in `FalloutNV.esm`, `DeadMoney.esm`, `HonestHearts.esm`,
`OldWorldBlues.esm`, `LonesomeRoad.esm`. Reproduce with `xtel_census.py`
in this folder.

| Property | Result |
|---|---|
| Layout | 32 bytes, 100%: destination REFR FormID u32, landing position 3×f32, landing rotation 3×f32, flags u32 |
| Flags | bit 0 = no alarm. 0 on all 1108 base-game XTELs; set on 2 DeadMoney and 3 LonesomeRoad |
| Holder / destination type | 100% DOOR → DOOR, base game and all four DLC (DLC resolved against `FalloutNV.esm`) |
| Destination has own XTEL | 100% |
| Reciprocal (B's XTEL points back to A) | base game 1106/1108; DLC 100% |
| Landing vs destination door origin | median ≈85 raw units; 9 exactly 0; max 34180 |
| Exterior destinations | 491/491 destination doors filed in the worldspace persistent cell |
| Same source and destination space | 44 base game |
| Destinations with >1 incoming link | 2 base game (below) |
| Destination REFR in another plugin | 1 (DeadMoney → `FalloutNV.esm`) |

Doors with more than one incoming link:

| Destination | From | Landing (raw) | Rot Z |
|---|---|---|---|
| `0xCAFA5` | `0xCAEB5` | (31966.3, 3266.6, 1586.0) | 2.183 |
| `0xCAFA5` | `0xCED40` | (23776.0, −29504.0, 6995.0) | 2.212 |
| `0x827BA` | `0x17388C` | (4684.4, 1154.7, −288.0) | −1.571 |
| `0x827BA` | `0x87A6B` | (4683.5, 1153.1, −288.0) | −1.571 |

Links are followed exactly as authored. One-way links are valid data, and
authoring errors in the ESM are reproduced, not corrected:

- REPCONN: exterior `REPCONMainDoor` (`0x87A6B`) leads into RocketLabMid
  `0x827BA`, which leads back to `NVInvisibleDoor` `0x17388C`, ≈130 units from
  the main door.
- Boone's Room, Novac: two enabled interior doors ≈48 units apart
  (`0xCAEB5`, `0xCED40`) both lead to exterior `0xCAFA5`, which leads back
  only to `0xCED40`. `0xCAEB5`'s landing is ≈34000 units from `0xCAFA5`.

The landing transform belongs to the link, not the destination door:
`0xCAFA5` has two incoming landings ≈34000 units apart. GECK draws A's
teleport marker next to B, but the data is stored in A's XTEL.

### `DoorTeleportLink`

```gdscript
class_name DoorTeleportLink extends Resource
@export var destination_id: String   # XTEL destination REFR, "authored:%08X"
@export var position: Vector3        # landing, metres, Gamebryo Z-up
@export var rotation: Vector3        # landing, radians
@export var no_alarm: bool           # XTEL flags bit 0

## Resolved destination door. Lazy and editor-only.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "DoorReference", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY)
var destination: DoorReference:
	get:
		return EsmServer.get_reference(destination_id) as DoorReference if not destination_id.is_empty() else null
```

`DoorReference.teleport: DoorTeleportLink`, null when the REFR has no XTEL.

- The destination is resolved lazily. `_reference_from_placement` caches a
  reference only after building it (`esm_server.gd`), so eager resolution of
  a reciprocal pair recurses without end.
- The resolved destination is never stored, following the `lock_key`
  precedent: `.tres` stays acyclic and no `RefCounted` cycle forms.
- Resolution goes through `EsmServer`, not a single file, because a
  destination can live in another plugin.
- Destination space is derived, not stored, by
  `DoorTeleportLink.get_destination_space_form_id()`: the destination door's
  space. The cell follows from space and landing position through
  `cell_at`. The cell containing the destination REFR is always the
  worldspace persistent cell for exterior destinations (491/491), never the
  grid cell, so it is never used.

Removed from `DoorReference`: `has_teleport_destination`,
`teleport_destination_refr_form_id`, `teleport_destination_cell_form_id`
(wrong for every exterior destination), `teleport_position`,
`teleport_rotation`, `teleport_no_alarm`.

`NpcPortal` is the same edge; it wraps or is replaced by `DoorTeleportLink`.

## Script VM changes

- `ScriptExecutionContext.calling_reference` and `action_ref` become
  `EsmReference`, with the node looked up only when one is loaded. `MoveTo`
  and `Activate` must work on references with no node.
- Script state moves from `ScriptServer._contexts[node]` to
  `EsmReference.script_instance`; `ScriptExecutionContext` becomes per
  dispatch.
- `Activate` follows the calling rules under "Activation" and honours
  `abRunOnActivate`.
- Block parameters gate execution (`script_interpreter.gd` currently runs
  every same-named block regardless of parameter).
- Register `MoveTo`, `PositionCell`, `PositionWorld` over `move_reference`.
- A global editor-id → reference lookup, owned by `EsmServer`, including
  persistent references in unloaded cells. Needed by `MoveTo SomeMarkerREF`,
  `SomeREF.Enable`, `set SomeREF.var to x` and `IsActionRef SomeREF`. Names
  resolve through this index, not the compiled script's `SCRO` list, so
  console input and hand-written scripts resolve the same way as authored
  ones. The same index gives FormID → reference without reading the filing
  CELL's other references (today `get_reference()` reads a whole persistent
  CELL, 4468 references for WastelandNV, to build one).

## Player body persistence

`PlayerController` is functionally a singleton. It and its pawn's body and
visualisation persist across transitions; they are not torn down or rebuilt.
The body is frozen from the teleport until it is placed from the reference at
the destination (see "During a transition").

## Followers

Companions are not teleported with the player. Their follow package targets
the player's reference and reaches it through normal cross-space routing
(`NavNpcSimulationServer.route_across_spaces`, door portals), arriving after
the player.

## Rejected alternative

A Gamebryo-style world owner (`WorldServer.center_on`) called directly from a
player-aware `move_reference`, with no possession. One explicit call site and
a single stack trace per load, but it makes the player a hard-coded exception
in the core primitive. Rejected in favour of possession (see "Model").

## Open

- Verify against the original game: after `player.MoveTo` to another cell,
  does the rest of the calling script stop for that frame (recalled from the
  GECK wiki, unverified)? If so, `ScriptServer` stops the calling block when a
  move of the possessed reference is queued.
- Verify: does `GetPos` immediately after `MoveTo` in the same script return
  the old position? Deferred moves produce that behaviour.
- Owner passage through locked doors: do owners (NPC or faction) pass their
  own locked doors, and does `Lock`'s `AsOwner` parameter (recalled from the
  GECK wiki) decide it? 21 owned locked load doors in `FalloutNV.esm`. Until
  verified, NPCs never pass a locked door without its key; a package that
  unlocks the door is their route through. Console tests at `000ED1AA` gave no
  clean result.
