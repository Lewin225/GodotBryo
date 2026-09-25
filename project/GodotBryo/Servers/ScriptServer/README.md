# ScriptServer

Runs GECK object scripts for references. Autoloaded singleton `ScriptServer`.

A reference's script is its base record's `SCRI` (`<type>_base.script_form_id`).
Its persistent state is the reference's `ScriptInstance` (`EsmReference.script_instance`):
the SCPT FormID and the locals, saved with the reference. Nothing per-reference is
kept in this server except which references are loaded.

---

## Contract

```gdscript
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

**Blocks.** Event blocks (`OnActivate`, `OnTriggerEnter`, ...) run whenever
`dispatch_event()` is called, whether or not the reference is loaded. `GameMode` and
`MenuMode` run every frame only for references marked loaded with
`set_reference_loaded()`, which also runs `OnLoad`. A block with a parameter
(`Begin OnActivate Player`) runs only when the parameter names the dispatch's action
reference; a block without one always runs.

**Contexts.** `ScriptExecutionContext` is built per dispatch: calling reference, action
reference, the player's reference, and the calling reference's `ScriptInstance`. Script
values are int, float or `EsmReference`; a `ref` local is stored in the instance as
`{"ref": instance_id}` and read back as the reference.

**Names.** `player` resolves to `player_reference`. Other reference names in source stay
as text; functions that take editor IDs (ShowMessage's MESG) resolve them themselves.

**Nodes.** Commands that act on a loaded object (`Enable`, `Disable`, `GetDisabled`,
`Activate`) find it with `EsmNode.node_for(reference)` and do nothing when the reference
is not physicalised.

**Handlers.** World-facing commands delegate to callables on `function_registry` set by
the scene that owns the loaders: `place_at_me_handler(args, calling_reference)`,
`center_on_cell_handler(args)`, plus `game_time_manager` for time functions.

---

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
