class_name ScriptFunctionRegistry
extends RefCounted

## Script function table: name -> Callable(args: Array, ctx:
## ScriptExecutionContext) -> Variant, grown at runtime through register().
## Calling an unregistered name logs once and returns 0.

var _functions := {} # lowercased name -> Callable
var _canonical_names: Array[String] = [] # Original registered names for autocomplete/reflection
var _warned_missing := {} # name -> true, so a hot GameMode loop doesn't spam the log every frame

## ESM reader for record lookups such as ShowMessage's MESG. Null until set.
var esm: EsmReader = null
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

func register(name: String, fn: Callable) -> void:
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
	if not _warned_missing.has(lower):
		_warned_missing[lower] = true
		push_warning("ScriptFunctionRegistry: unimplemented script function '%s' -- evaluates to 0/false" % name)
	return 0

func _register_defaults() -> void:
	register("GetSecondsPassed", func(_a, _c):
		if game_time_manager != null:
			return game_time_manager.consume_seconds_passed()
		return 0.0)
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
	register("CenterOnCell", center_on_cell)
	register("COC", center_on_cell)

	# Toggles noclip on the calling reference's node, or on the player's body
	# when there is no calling reference.
	var toggle_collision := func(_a: Array, ctx: ScriptExecutionContext):
		var target: Object = EsmNode.node_for(ctx.calling_reference) if ctx.calling_reference != null else player_node
		if target != null and "noclip" in target:
			target.noclip = !target.noclip
			return 1 if target.noclip else 0
		return 0
	register("tcl", toggle_collision)
	register("TCL", toggle_collision)
	register("ToggleCollision", toggle_collision)

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
