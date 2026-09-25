# game.gd decomposition

`project/game.gd` is 725 lines and 29 functions. It is the scene root, the
transition coordinator, the debug HUD, the interaction dispatcher, an ESM
accessor and the inventory owner. This records what each disputed
responsibility currently does, whether it is still reachable, and where it
belongs.

Line numbers are from the state after the v0 disconnect (51 `gamebryo/` files
moved to `old/`).

---

## 1. Node discovery and player lookup

**Current.** `_ready()` (lines 111-124) assigns eleven members by hardcoded
`$Path`:

```gdscript
cell_streamer = $CellStreamerV2
world_streamer = $WorldStreamerV2
terrain_streamer = $TerrainStreamer
script_engine = $ScriptEngine
game_time_manager = $GameTimeManager
weather_manager = $WeatherManager
celestial_controller = $CelestialController
terminal_session = $TerminalSession
message_box = $MessageBox
_cell_label = $DebugHud/CellLabel
_look_at_label = $DebugHud/LookAtLabel
_sun = $Sun
_world_environment = $WorldEnvironment
```

Nothing is `@export`. A twelfth, `_interior_directional_light`, is built in code
(lines 129-134) specifically so the scene's `Sun` stays independently tunable.

The player is worse. `_get_character_body()` (699) does
`get_node_or_null(^"Character")` and caches it; nine call sites depend on it.
Everything downstream is duck-typed rather than typed: `"CAMERA" in player`,
`"interact_ray" in player`, `player.interact_ray is InteractRay`.

**Connected.** Yes, all of it.

**Should be.** `@export` every one of the eleven. A missing node then fails in
the editor with an empty slot rather than at runtime with a null deref, and
`game.tscn` becomes the single place the wiring is declared.

The player wants a typed contract, not a name lookup. It already has to expose
`CAMERA` and `interact_ray`; that is an interface. Either a `Player` class_name
with those as real typed members, or an exported `player: Player` on Game. The
string `"Character"` being the only thing binding Game to the player is the
weakest link in the file.

---

## 2. Serving an EsmReader

**Current.** Two accessors:

- `_await_typed_esm()` (165) — coroutine, waits for `EsmServer.esm_ready`, used
  once during `_ready()`.
- `_typed_esm_reader()` (173) — synchronous, re-resolves
  `/root/EsmServer` on **every call**, returns `server.reader`.

`_typed_esm_reader()` has six internal callers (330, 380, 388, 397, 546, 602)
and **three external ones**:

| caller | line |
|---|---|
| `teleport_debug_tab.gd` | 264 |
| `environment_debug_tab.gd` | 49, 52 |
| `lighting_debug_tab.gd` | 59, 75 |

**Connected.** Yes, and it has become a public API by accident — the debug tabs
call a leading-underscore method on Game to reach a global autoload they could
address directly.

**Should be.** Delete both. `EsmServer` is an autoload: callers write
`EsmServer.reader`, and the ones that need to wait `await EsmServer.esm_ready`.
Game holds `_shared_esm` (92) already for its own use; it does not also need to
be a lookup service. The three debug tabs should talk to `EsmServer` directly.

This is the cheapest of the five and removes a whole class of "reach into Game
for a global" coupling.

---

## 3. Debug HUD

**Current.** Game owns two labels and their update logic:

- `_cell_label` — written by `_update_cell_hud()` (598), driven from
  `_on_load_completed()` and from `_process()` while `WorldStreamer` is active.
  `_hud_cell_form_id` (53) caches the last drawn cell purely to avoid redundant
  ESM lookups every frame; `lighting_debug_tab` and `environment_debug_tab`
  both read that private field as their notion of "current cell".
- `_look_at_label` — toggled by the `toggle_stats` action in `_process()`
  (215-218), rendered by `_update_look_at_label()` (269), which runs a raycast
  **every frame while visible**.

**Connected.** Yes.

**Should be.** A `DebugHud` node that owns its own labels, input toggle and
refresh. It needs three inputs: the current cell FormID, the interact-ray
result, and the ESM reader. The first two are the only real coupling, and both
are things Game already computes for other reasons — so they become signals
Game emits, not fields the HUD reaches back for.

That also fixes the accidental `_hud_cell_form_id` API: "current cell" becomes
something published once, rather than a private cache two debug tabs read.

---

## 4. Player interaction

**Current.** Three functions:

- `_interact_raycast()` (238) — delegates to `player.interact_ray.get_interact_info()`
  when the player has one, otherwise runs its own `intersect_ray` fallback.
- `_try_interact()` (366) — dispatches on the result.
- `_update_look_at_label()` — reuses the same raycast for the HUD.

`_try_interact()` currently branches:

1. `target is EsmTerminalNode` → `terminal_session.open_session(...)`
2. no `activate()` method → `script_engine.dispatch_event(target, "OnActivate", ...)`
3. otherwise `target.activate(player)` and interpret the returned `Dictionary`:
   - `outcome["terminal"]` → open a terminal session
   - `outcome["dest_cell_form_id"]` → run a door transition
   - empty → no-op
   - anything else → `push_warning` "unsupported outcome"

**Connected.** Yes.

**Should be.** The `EsmNode.activate()` contract already exists — every typed
node has it, and `EsmDoorNode`/`EsmTerminalNode` already return structured
outcomes. What is wrong is that Game re-implements type dispatch *on top of* it:

- Branch 1 exists only because `EsmTerminalNode.activate()` returns
  `{"terminal": self, "menu_items": ...}` and Game handles that case twice —
  once by type before calling activate, once by inspecting the outcome
  afterwards. Branch 1 is redundant with branch 3's `outcome["terminal"]` path.
- The fallback raycast in `_interact_raycast()` duplicates `InteractRay` for a
  player that does not have one. Since the player always has one now, that
  branch is dead weight keeping a second implementation alive.

> Superseded for doors and transitions by `Plans/Transitions/actor_transitions.md`.

The activation contract itself is the right shape and does not need replacing.
What moves out is the *dispatch*: a node returns an outcome, and a handler
(terminal session, door transition) consumes it. Game should own the door
transition — it genuinely coordinates streamers — and nothing else.

On the proposed `activate(esmreference)` signature: the current one is
`activate(actor: Node = null)`, and an `EsmNode` already holds its own
`reference`. Passing the reference in would be passing a node its own field.
The parameter that varies is *who* activated it, which is what `actor` is.

---

## 5. `_find_esm_node_ancestor()`

**Current.** Lines 290-299. Walks up from any `Object` to the first `EsmNode`
ancestor. Three call sites, all inside Game: 258 (`_interact_raycast`), 279 and
281 (`_update_look_at_label`).

**This is a duplicate.** `InteractRay.semantic_target()`
(`player/interact_ray.gd`) is the same walk, is `static`, and is already the
canonical version — `test_esm_server.gd:393` asserts its behaviour.

The two differ only in failure mode: `semantic_target()` returns the original
object when no `EsmNode` is found, `_find_esm_node_ancestor()` returns null.
Game's line 258 wants the "null" form; 279-281 call it twice to emulate a
fallback that `semantic_target()` gives for free.

**Should be.** Delete it and call `InteractRay.semantic_target()`. If a
null-returning variant is genuinely wanted, it belongs next to
`semantic_target()` as a second static, not as a private copy in Game.

---

## What Game should keep

> Superseded for doors and transitions by `Plans/Transitions/actor_transitions.md`.

Door/worldspace transitions (`_do_exterior_transition`,
`_can_release_exterior_transition`, `_convert_*_spawn_transform`,
`_find_coc_spawn_transform`, `reposition_player`) and the interior/exterior
environment swap (`_set_exterior_environment`, `_apply_cell_lighting`,
`_apply_xcll_directional_light`).

These genuinely coordinate across CellStreamerV2, WorldStreamerV2,
TerrainStreamer and the player, which is what a scene root is for. Everything in
sections 1-5 is either a service Game should not be, a duplicate, or UI.

## Suggested order

1. **`_typed_esm_reader()` removal** — mechanical, three external callers,
   no behaviour change.
2. **`_find_esm_node_ancestor()` removal** — mechanical, three internal callers.
3. **`@export` the node references** — mechanical, touches `game.tscn`.
4. **Extract `DebugHud`** — needs the current-cell signal first.
5. **Interaction dispatch** — largest, and the one with real design questions.

1-3 are independent of each other and of 4-5.
