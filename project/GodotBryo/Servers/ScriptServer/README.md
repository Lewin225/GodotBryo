# ScriptServer

Runs GECK object scripts for references. Autoloaded singleton `ScriptServer`.

A reference's script is its base record's `SCRI` (`<type>_base.script_form_id`).
Its persistent state is the reference's `ScriptInstance` (`EsmReference.script_instance`):
the SCPT FormID and the locals, saved with the reference. Nothing per-reference is
kept in this server except which references are loaded.

---

## Contract

```gdscript
ScriptServer.activate(target, activator)                 # OnActivate block, or built-in
ScriptServer.default_activate(target, activator)         # built-in only, then node presents
ScriptServer.move_reference(reference, space_form_id, position, rotation)   # queued
ScriptServer.get_pending_move(reference) -> Dictionary
ScriptServer.apply_pending_moves()                       # also run every frame
ScriptServer.begin_use(actor, target, marker := -1) -> bool
ScriptServer.end_use(actor)
ScriptServer.lock(reference, level := -1)             # doors and terminals
ScriptServer.unlock(reference)
ScriptServer.run_result_script(source, subject, action_ref := null) -> Variant
ScriptServer.dispatch_event(reference, block_type, action_ref := null) -> Variant
ScriptServer.has_block_for(reference, block_type, action_ref := null) -> bool
ScriptServer.get_script_instance(reference) -> ScriptInstance   # created on first use
ScriptServer.set_reference_loaded(reference, loaded: bool)
ScriptServer.is_reference_loaded(reference) -> bool
ScriptServer.run_debug_line(line, target: EsmReference = null) -> Dictionary
ScriptServer.get_debug_instances() -> Array
ScriptServer.get_debug_usage() -> Dictionary

ScriptServer.player_reference: EsmReference   # what `player` resolves to
ScriptServer.player_node: Node                # the player's body, for ToggleCollision
ScriptServer.message_box: MessageBox          # ShowMessage / GetButtonPressed
ScriptServer.function_registry: ScriptFunctionRegistry
```

**Moves.** `move_reference()` queues; a later move of the same reference replaces the
queued one. Each frame `_process()` runs loaded references' `GameMode` blocks, then
applies the queue: space, position and rotation are set together (one cell refresh) and
the reference's `teleported(old_space, new_space)` and
`reference_teleported(reference, old_space, new_space)` are emitted. `process_priority`
is 100, so this runs after default-priority `_process()`; physics bodies sync their
references in `_physics_process()`, earlier in the frame. Script `MoveTo Target [x y z]`
(offset in Gamebryo units, Target's rotation), `PositionCell x y z zRot CellID` and
`PositionWorld x y z zRot WorldspaceID` (Gamebryo units, degrees) all queue through
`move_reference()`.

**Blocks.** Event blocks (`OnActivate`, `OnTriggerEnter`, ...) run whenever
`dispatch_event()` is called, whether or not the reference is loaded. `GameMode` and
`MenuMode` run every frame only for references marked loaded with
`set_reference_loaded()`, which also runs `OnLoad` (once per load).
`CellStreamerV2` marks its current CELL's references loaded; `WorldStreamerV2`
marks those of resident tiles at full detail, and unloads them when a tile drops to
LOD, is removed, or is paused for an interior visit. References moving between
CELLs are unloaded by the streamer they left and loaded (deferred to the end of the
frame) by the one they entered. A block with a parameter
(`Begin OnActivate Player`) runs only when the parameter names the dispatch's action
reference; a block without one always runs.

**Activation.** `activate()` runs the target's `OnActivate` block that accepts the
activator; with none, it performs the built-in activation, as if the block were
`Begin OnActivate / Activate / End`. The built-in activation is
`EsmReference.default_activate()`, which calls the base type's `activate(ref,
activator)`: doors unlock with their key, start lockpicking, move the activator
through XTEL or toggle open; terminals, containers and furniture start being used.
The target's loaded node then plays it (`EsmNode.on_activated()`). Script `Activate`
performs the built-in activation, or runs `OnActivate` when its second argument is 1;
its activator is the first argument, or the dispatch's action reference.

**Result scripts.** `run_result_script()` runs a bare statement list with no
Begin/End (terminal menu items; later dialogue and packages). `subject` is the implicit
reference of its calls, `action_ref` the activator. It has its own locals, declared in
its source and fresh on every run.

**Locks.** A door with XLOC, or a terminal whose base is not flagged unlocked, starts
locked. Activating one with its key (door) or password note (terminal) unlocks it;
level 255 (door) or 5 (terminal) without it does nothing; otherwise the activator starts
using it — lockpicking or hacking.

**Use.** `begin_use()` / `end_use()` set `ActorReference.using` / `using_marker` and
the target's side together: `used_by` for single-user references, one
`FurnitureReference.occupants` slot per active MNAM marker for furniture.
`ActorReference.using_changed` reports both. Use state is runtime only.

**Contexts.** `ScriptExecutionContext` is built per dispatch: calling reference, action
reference, the player's reference, and the calling reference's `ScriptInstance`. Script
values are int, float or `EsmReference`; a `ref` local is stored in the instance as
`{"ref": instance_id}` and read back as the reference.

**Names.** `player` resolves to `player_reference`; any other name that is a placed
reference's editor ID resolves to that reference (`EsmServer.find_reference_by_editor_id`),
loaded or not. Other names stay as text for functions that take editor IDs of other record
types (ShowMessage's MESG). `SomeREF.var` reads and writes a variable of that reference's
own `ScriptInstance`.

**Nodes.** Commands that act on a loaded object (`Enable`, `Disable`, `GetDisabled`)
find it with `EsmNode.node_for(reference)` and do nothing when the reference
is not physicalised.

**Handlers.** World-facing commands delegate to callables on `function_registry` set by
the scene that owns the loaders: `place_at_me_handler(args, calling_reference)`,
`center_on_cell_handler(args)`, plus `game_time_manager` for time functions.

---

## Unverified behaviour

What the code assumes where the original game's behaviour has not been checked in play.
Each is a reason to test before building on it.

| Assumption | Code | Source | How to check |
|---|---|---|---|
| `Activate`'s `RunOnActivateBlockFlag` defaults to 0 = built-in activation; 1 runs the target's `OnActivate` | registry `Activate` | GECK wiki, recalled | scripted door + console `SomeDoorREF.Activate player` with and without `1` |
| Code after `player.MoveTo` to another CELL still runs that frame | `move_reference` never interrupts the caller | GECK wiki recalls the rest of the script stops | a script that sets a variable after `player.MoveTo` |
| `GetPos` right after `MoveTo` in the same script returns the old position | moves are queued and applied after `GameMode` | follows from deferred moves | `GetPos` is not implemented yet |
| Owners (NPC or faction) do not pass their own locked doors without the key | `DoorBase.activate` | conservative default; `Lock`'s `AsOwner` parameter (GECK wiki) may decide it | an owner NPC following through a door locked with `lock 50 0` and `lock 50 1` |

## Files

| File | Role |
|---|---|
| `script_server.gd` | the autoload |
| `script_lexer.gd`, `script_parser.gd` | SCTX source → AST |
| `script_interpreter.gd` | tree-walking interpreter, one per parsed SCPT, cached |
| `script_function_registry.gd` | script function table |
| `script_execution_context.gd` | per-dispatch state |

## Tests

`tests/test_script_lexer`, `test_script_parser`, `test_script_interpreter`,
`test_script_showmessage`, `test_script_esm`, `test_debug_tabs`, run against the shipped
ESM:

```
cd project
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/test_script_interpreter.tscn
```
