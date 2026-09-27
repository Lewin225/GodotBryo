class_name ScriptFunctionRegistry
extends RefCounted

## Script function table: name -> Callable(args: Array, ctx:
## ScriptExecutionContext) -> Variant, grown at runtime through register().
## Calling an unregistered name logs once and returns 0.

var _functions := {} # lowercased name -> Callable
var _canonical_names: Array[String] = [] # Original registered names for autocomplete/reflection
var _warned_missing := {} # "name|SCPT" -> true: one warning per function per script, not every frame

## ESM reader for record lookups such as ShowMessage's MESG. Null until set.
var esm: EsmReader = null
## Script coordinates are Gamebryo units; references use metres
## (native/src/common/units.h is the authority for 70 units per metre).
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0
## The player's physics body, for commands that act on the body itself
## (ToggleCollision). Null when there is no player.
var player_node: Node = null
## Source of game time. Time functions return 0 while it is null.
var game_time_manager: GameTimeManager = null
## World-facing commands delegate to handlers registered by the scene that
## owns the loaders. PlaceAtMe receives (args, calling_reference).
var place_at_me_handler: Callable
## The ScriptServer that performs activation, locking and unlocking for the
## Activate, Lock and Unlock commands. Null in a bare registry.
var script_server: Object = null
var center_on_cell_handler: Callable
var show_message_handler: Callable
var get_button_pressed_handler: Callable

func _init() -> void:
	_register_defaults()

## Registers `fn` under a name, or an Array of names: the full name and its
## short aliases (`["GetActorValue", "GetAV"]`). Names are case-insensitive.
func register(names: Variant, fn: Callable) -> void:
	for name: String in (names if names is Array else [names]):
		_functions[name.to_lower()] = fn
		if not _canonical_names.has(name):
			_canonical_names.append(name)

func is_registered(name: String) -> bool:
	return _functions.has(name.to_lower())

func get_registered_function_names() -> Array[String]:
	return _canonical_names.duplicate()

func call_function(name: String, args: Array, ctx: ScriptExecutionContext) -> Variant:
	var lower := name.to_lower()
	if _functions.has(lower):
		return _functions[lower].call(args, ctx)
	# Once per function per script, so every script calling it is listed.
	var warn_key := "%s|%d" % [lower, ctx.instance.script_form_id if ctx != null and ctx.instance != null else 0]
	if not _warned_missing.has(warn_key):
		_warned_missing[warn_key] = true
		push_warning("ScriptFunctionRegistry: unimplemented script function '%s' in %s -- evaluates to 0/false"
				% [name, ctx.describe() if ctx != null else "an unknown script"])
	return 0

func _register_defaults() -> void:
	# Real seconds since the calling script last ran.
	register("GetSecondsPassed", func(_a, ctx: ScriptExecutionContext):
		return ctx.seconds_passed)
	register("GameDaysPassed", func(_a, _c):
		if game_time_manager != null:
			return game_time_manager.game_days_passed
		return 0.0)
	register("GetCurrentTime", func(_a, _c):
		if game_time_manager != null:
			return game_time_manager.game_hour
		return 0.0)
	register("GetRandomPercent", func(_a, _c): return randi_range(0, 99))

	register("Enable", func(_a, ctx: ScriptExecutionContext):
		var node := EsmNode.node_for(ctx.calling_reference)
		if node == null:
			return 0
		node.visible = true
		EsmNode.set_collision_disabled(node, false)
		return 1)

	register("Disable", func(_a, ctx: ScriptExecutionContext):
		var node := EsmNode.node_for(ctx.calling_reference)
		if node == null:
			return 0
		node.visible = false
		EsmNode.set_collision_disabled(node, true)
		return 1)

	register("GetDisabled", func(_a, ctx: ScriptExecutionContext):
		var node := EsmNode.node_for(ctx.calling_reference)
		if node == null:
			return 0
		return 0 if node.visible else 1)

	# `[Ref.]Activate [ActionRef] [RunOnActivateBlockFlag]`. The activator is
	# ActionRef when given, else this dispatch's action reference. With the
	# flag 1 the target's OnActivate block runs as for any activation;
	# otherwise the built-in activation runs directly, so `Activate` inside a
	# target's own OnActivate block does not re-enter it.
	register("Activate", func(a: Array, ctx: ScriptExecutionContext):
		var target := ctx.calling_reference
		if target == null or script_server == null:
			return 0
		var activator: EsmReference = a[0] if a.size() > 0 and a[0] is EsmReference else ctx.action_ref
		var run_block := a.size() > 1 and ScriptExecutionContext.is_truthy(a[1])
		if run_block:
			script_server.activate(target, activator)
		else:
			script_server.default_activate(target, activator)
		return 1)

	# `[Ref.]MoveTo Target [x y z]`: moves the calling reference to Target's
	# space and position plus the offset (Gamebryo units), taking Target's
	# rotation.
	register("MoveTo", func(a: Array, ctx: ScriptExecutionContext):
		var target: Variant = a[0] if a.size() > 0 else null
		if ctx.calling_reference == null or not target is EsmReference or script_server == null:
			return 0
		var offset := Vector3(_number(a, 1), _number(a, 2), _number(a, 3)) * GAMEBRYO_UNITS_TO_METERS
		var marker := target as EsmReference
		script_server.move_reference(ctx.calling_reference, marker.current_space_form_id, marker.position + offset, marker.rotation)
		return 1)

	# `[Ref.]PositionCell x y z zRot CellID`: Gamebryo units, degrees; the
	# CELL by editor ID. Keeps the reference's x/y rotation.
	register("PositionCell", func(a: Array, ctx: ScriptExecutionContext):
		if ctx.calling_reference == null or a.size() < 5 or script_server == null or esm == null:
			return 0
		var cell := int(esm.find_cell_by_editor_id(str(a[4])).get("form_id", 0))
		var esm_server := EsmReference.get_esm_server()
		if cell == 0 or esm_server == null:
			return 0
		_position(ctx.calling_reference, esm_server.get_space_form_id_for_cell(cell), a)
		return 1)

	# `[Ref.]PositionWorld x y z zRot WorldspaceID`: as PositionCell, in a
	# worldspace named by editor ID.
	register("PositionWorld", func(a: Array, ctx: ScriptExecutionContext):
		if ctx.calling_reference == null or a.size() < 5 or script_server == null or esm == null:
			return 0
		var worldspace := int(esm.find_worldspace_by_editor_id(str(a[4])).get("form_id", 0))
		if worldspace == 0:
			return 0
		_position(ctx.calling_reference, worldspace, a)
		return 1)

	# `[Ref.]Lock [Level]` / `[Ref.]Unlock` on the calling reference.
	register("Lock", func(a: Array, ctx: ScriptExecutionContext):
		if ctx.calling_reference == null or script_server == null:
			return 0
		script_server.lock(ctx.calling_reference, int(a[0]) if a.size() > 0 and (a[0] is int or a[0] is float) else -1)
		return 1)

	register("IsActionRef", func(a: Array, ctx: ScriptExecutionContext):
		if a.is_empty() or ctx.action_ref == null:
			return 0
		# a[0] is a reference, or the text of a name that did not resolve.
		return 1 if ScriptExecutionContext.safe_equal(a[0], ctx.action_ref) else 0)

	register("GetActionRef", func(_a, ctx: ScriptExecutionContext):
		return ctx.action_ref)

	register("GetSelf", func(_a, ctx: ScriptExecutionContext):
		return ctx.calling_reference)

	# Quests, named by editor ID: `GetStage Quest`, `GetStageDone Quest Stage`,
	# `SetStage Quest Stage`, `StartQuest Quest`, `StopQuest Quest`,
	# `GetQuestRunning Quest`, `GetQuestCompleted Quest`,
	# `SetQuestDelay Quest Seconds`.
	register("GetStage", func(a: Array, _c):
		var quests := _quest_server()
		return quests.get_stage(_quest(a, 0)) if quests != null else 0)
	register("GetStageDone", func(a: Array, _c):
		var quests := _quest_server()
		return 1 if quests != null and quests.is_stage_done(_quest(a, 0), int(_number(a, 1))) else 0)
	register("SetStage", func(a: Array, _c):
		var quests := _quest_server()
		var quest := _quest(a, 0)
		if quests == null or quest == null:
			return 0
		quests.set_stage(quest, int(_number(a, 1)))
		return 1)
	register("StartQuest", func(a: Array, _c):
		var quests := _quest_server()
		if quests == null or _quest(a, 0) == null:
			return 0
		quests.start_quest(_quest(a, 0))
		return 1)
	register("StopQuest", func(a: Array, _c):
		var quests := _quest_server()
		if quests == null or _quest(a, 0) == null:
			return 0
		quests.stop_quest(_quest(a, 0))
		return 1)
	register("GetQuestRunning", func(a: Array, _c):
		var quests := _quest_server()
		return 1 if quests != null and quests.is_running(_quest(a, 0)) else 0)
	register("GetQuestCompleted", func(a: Array, _c):
		var quests := _quest_server()
		return 1 if quests != null and quests.is_completed(_quest(a, 0)) else 0)
	register("SetQuestDelay", func(a: Array, _c):
		var quests := _quest_server()
		if quests == null or _quest(a, 0) == null:
			return 0
		quests.set_script_delay(_quest(a, 0), _number(a, 1))
		return 1)

	# Quest objectives, by QOBJ index: `SetObjectiveDisplayed Quest Index Flag`,
	# `SetObjectiveCompleted Quest Index Flag` (Flag 1 sets, 0 clears),
	# `GetObjectiveDisplayed Quest Index`, `GetObjectiveCompleted Quest Index`.
	register("GetObjectiveDisplayed", func(a: Array, _c):
		return _read_objective(a, "is_objective_displayed"))
	register("GetObjectiveCompleted", func(a: Array, _c):
		return _read_objective(a, "is_objective_completed"))
	register("SetObjectiveDisplayed", func(a: Array, _c):
		return _change_objective(a, "set_objective_displayed", "SetObjectiveDisplayed"))
	register("SetObjectiveCompleted", func(a: Array, _c):
		return _change_objective(a, "set_objective_completed", "SetObjectiveCompleted"))

	# Actor values of the calling actor, named by script name (`GetAV Health`).
	register(["GetActorValue", "GetAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _read_actor_value(a, ctx, "get_current"))
	register(["GetBaseActorValue", "GetBaseAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _read_actor_value(a, ctx, "get_base"))
	register(["GetPermanentActorValue", "GetPermAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _read_actor_value(a, ctx, "get_permanent"))
	register(["SetActorValue", "SetAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _change_actor_value(a, ctx, "set_base"))
	register(["ModActorValue", "ModAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _change_actor_value(a, ctx, "modify"))
	register(["ForceActorValue", "ForceAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _change_actor_value(a, ctx, "force"))
	register(["DamageActorValue", "DamageAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _change_actor_value(a, ctx, "damage_value"))
	register(["RestoreActorValue", "RestoreAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _change_actor_value(a, ctx, "restore_value"))
	register("GetHealthPercentage", func(_a, ctx: ScriptExecutionContext):
		var values := _actor_values(ctx)
		return values.health_percentage() if values != null else 0.0)
	register("GetLevel", func(_a, ctx: ScriptExecutionContext):
		var values := _actor_values(ctx)
		return values.get_level() if values != null else 0)
		

	register("Unlock", func(_a, ctx: ScriptExecutionContext):
		if ctx.calling_reference == null or script_server == null:
			return 0
		script_server.unlock(ctx.calling_reference)
		return 1)

	register("PlaceAtMe", func(a: Array, ctx: ScriptExecutionContext):
		if a.is_empty() or not place_at_me_handler.is_valid():
			push_warning("ScriptFunctionRegistry: PlaceAtMe unavailable -- no world placement handler")
			return 0
		return place_at_me_handler.call(a, ctx.calling_reference))

	var center_on_cell := func(a: Array, _ctx: ScriptExecutionContext):
		if a.is_empty() or not center_on_cell_handler.is_valid():
			push_warning("ScriptFunctionRegistry: CenterOnCell unavailable -- no cell-transition handler")
			return 0
		return center_on_cell_handler.call(a)
	register(["CenterOnCell", "COC"], center_on_cell)

	# Toggles noclip on the calling reference's node, or on the player's body
	# when there is no calling reference.
	var toggle_collision := func(_a: Array, ctx: ScriptExecutionContext):
		var target: Object = EsmNode.node_for(ctx.calling_reference) if ctx.calling_reference != null else player_node
		if target != null and "noclip" in target:
			target.noclip = !target.noclip
			return 1 if target.noclip else 0
		return 0
	register(["ToggleCollision", "TCL"], toggle_collision)

	register("ShowMessage", func(a: Array, ctx: ScriptExecutionContext):
		# Real argument shape: either an EditorID string (e.g. GSBrokenSMGMsg)
		# or a FormID -- resolved via get_message_by_editor_id() or get_message_by_form_id().
		if a.is_empty() or esm == null:
			return 0
		var identifier := str(a[0])
		var msg: Dictionary = {}
		if a[0] is int or a[0] is float:
			msg = esm.get_message_by_form_id(int(a[0]))
		elif identifier.is_valid_int():
			msg = esm.get_message_by_form_id(int(identifier))
		if msg.is_empty():
			msg = esm.get_message_by_editor_id(identifier)
		if msg.is_empty():
			push_warning("ScriptFunctionRegistry: ShowMessage -- no MESG found for '%s'" % identifier)
			return 0
		if show_message_handler.is_valid():
			return show_message_handler.call(msg, ctx)
		return 1)

	register("GetButtonPressed", func(_a: Array, ctx: ScriptExecutionContext):
		# Returns the 0-based button index pressed by the player, or -1 if no button
		# was pressed yet. Reading this value consumes it back to -1 per Gamebryo semantics.
		if get_button_pressed_handler.is_valid():
			return get_button_pressed_handler.call(ctx)
		return -1)

## Numeric argument `index`, or 0 when absent or not a number.
static func _number(args: Array, index: int) -> float:
	if index < args.size() and (args[index] is int or args[index] is float):
		return float(args[index])
	return 0.0

## Queues PositionCell/PositionWorld's move: x y z in Gamebryo units, zRot in
## degrees.
func _position(ref: EsmReference, space_form_id: int, args: Array) -> void:
	var position := Vector3(_number(args, 0), _number(args, 1), _number(args, 2)) * GAMEBRYO_UNITS_TO_METERS
	var rotation := Vector3(ref.rotation.x, ref.rotation.y, deg_to_rad(_number(args, 3)))
	script_server.move_reference(ref, space_form_id, position, rotation)

## The calling reference's actor values, or null when it is not an actor.
static func _actor_values(ctx: ScriptExecutionContext) -> ActorValues:
	return ctx.calling_reference.get_actor_values() if ctx.calling_reference != null else null

## `method` (get_current, get_base, get_permanent) of the actor value named by
## the first argument, on the calling actor; 0 for a non-actor.
static func _read_actor_value(args: Array, ctx: ScriptExecutionContext, method: String) -> float:
	var values := _actor_values(ctx)
	var code := _actor_value_code(args, 0)
	return values.call(method, code) if values != null and code >= 0 else 0.0

## Applies `method` (set_base, modify, force, damage_value, restore_value)
## with the second argument to the actor value named by the first. 1 when
## applied, 0 for a non-actor or an unknown actor value.
static func _change_actor_value(args: Array, ctx: ScriptExecutionContext, method: String) -> int:
	var values := _actor_values(ctx)
	var code := _actor_value_code(args, 0)
	if values == null or code < 0:
		return 0
	values.call(method, code, _number(args, 1))
	return 1

## The actor value code an argument names, or -1.
static func _actor_value_code(args: Array, index: int) -> int:
	if index >= args.size():
		return -1
	var code := ActorValue.from_name(str(args[index]))
	if code < 0:
		push_warning("ScriptFunctionRegistry: unknown actor value '%s'" % str(args[index]))
	return code

## The QUST named by argument `index` (its editor ID), or null.
static func _quest(args: Array, index: int) -> EsmBase:
	var esm_server := EsmReference.get_esm_server()
	if index >= args.size() or esm_server == null or not esm_server.is_ready():
		return null
	return esm_server.find_quest_by_editor_id(str(args[index]))

## 1 when QuestServer's `method` (is_objective_displayed,
## is_objective_completed) is true for the quest and objective index named by
## the first two arguments, else 0.
static func _read_objective(args: Array, method: String) -> int:
	var quests := _quest_server()
	var quest := _quest(args, 0)
	if quests == null or quest == null or not _is_number(args, 1):
		return 0
	return 1 if quests.call(method, quest, int(_number(args, 1))) else 0

## Applies QuestServer's `method` (set_objective_displayed,
## set_objective_completed) to the quest and objective index named by the
## first two arguments: the third argument sets when nonzero, clears when 0.
## Without a third argument nothing changes. 1 when applied, else 0.
static func _change_objective(args: Array, method: String, name: String) -> int:
	var quests := _quest_server()
	var quest := _quest(args, 0)
	if quests == null or quest == null or not _is_number(args, 1):
		return 0
	if not _is_number(args, 2):
		push_warning("ScriptFunctionRegistry: %s %s %s without a flag changes nothing"
				% [name, quest.editor_id, str(args[1])])
		return 0
	return 1 if quests.call(method, quest, int(_number(args, 1)), _number(args, 2) != 0.0) else 0

## Whether argument `index` exists and is a number.
static func _is_number(args: Array, index: int) -> bool:
	return index < args.size() and (args[index] is int or args[index] is float)

## The QuestServer autoload, or null where it does not exist.
static func _quest_server() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("QuestServer") if tree != null else null
