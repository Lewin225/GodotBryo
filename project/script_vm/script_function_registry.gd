class_name ScriptFunctionRegistry
extends RefCounted

## String -> Callable(args: Array, ctx: ScriptExecutionContext) -> Variant,
## the exact same shape as GamebryoObjectRegistry._factories
## (project/gamebryo/object_registry.gd) -- runtime-populated, grown by
## calling register(), never a compiled-in switch. Seeded here with only
## the handful of real, ranked-by-usage functions
## (enginedocs/nv_script_interpreter_design.md's "Tier 1" list) that map
## onto systems this codebase actually has today -- inventory/quest/
## faction/AI-backed functions from that same list are real, deliberate
## gaps (see phases/5/00-script-interpreter-foundation.md), not oversights.
## call() on an unregistered name logs it once and returns 0/false, never a
## fabricated success -- matching the language's own real "silently stop,
## don't crash" behavior for a bad reference (design doc's Variables
## section) with the same non-crashing spirit for a missing function.

var _functions := {} # lowercased name -> Callable
var _warned_missing := {} # name -> true, so a hot GameMode loop doesn't spam the log every frame

## Set externally (ScriptEngine propagates its own esm whenever it's
## assigned) -- null-safe everywhere it's used below, since a registry can
## exist before an EsmReader is available (e.g. a bare unit test).
var esm: EsmReader = null
## Set by game.gd: this registry deliberately knows script semantics, not
## scene ownership or loader roots.  PlaceAtMe delegates the world mutation
## to the one runtime owner that has both.
var place_at_me_handler: Callable
var center_on_cell_handler: Callable

func _init() -> void:
	_register_defaults()

func register(name: String, fn: Callable) -> void:
	_functions[name.to_lower()] = fn

func is_registered(name: String) -> bool:
	return _functions.has(name.to_lower())

func call_function(name: String, args: Array, ctx: ScriptExecutionContext) -> Variant:
	var lower := name.to_lower()
	if _functions.has(lower):
		return _functions[lower].call(args, ctx)
	if not _warned_missing.has(lower):
		_warned_missing[lower] = true
		push_warning("ScriptFunctionRegistry: unimplemented script function '%s' -- evaluates to 0/false" % name)
	return 0

func _register_defaults() -> void:
	register("GetSecondsPassed", func(_a, _c): return 0.0) # real per-frame delta -- no caller-supplied delta reaches here yet; a real, deliberate gap until frame integration threads one through
	register("GameDaysPassed", func(_a, _c): return 0.0) # same gap: no game-clock system exists yet to source this from
	register("GetRandomPercent", func(_a, _c): return randi_range(0, 99))

	register("Enable", func(_a, ctx: ScriptExecutionContext):
		var node := ctx.calling_reference
		if node == null:
			return 0
		node.visible = true
		CellStreamBuilder.set_collision_disabled(node, false)
		return 1)

	register("Disable", func(_a, ctx: ScriptExecutionContext):
		var node := ctx.calling_reference
		if node == null:
			return 0
		node.visible = false
		CellStreamBuilder.set_collision_disabled(node, true)
		return 1)

	register("GetDisabled", func(_a, ctx: ScriptExecutionContext):
		var node := ctx.calling_reference
		if node == null:
			return 0
		return 0 if node.visible else 1)

	register("Activate", func(_a, ctx: ScriptExecutionContext):
		# Real signature is `Activate akActivator, abRunOnActivate` -- the
		# activator argument and the "also run this script's own OnActivate"
		# flag aren't consumed yet (this project's real activate() contract,
		# door_node.gd/game.gd's interact raycast, takes neither). Calling
		# the same activate() every other interactable already implements,
		# per the design doc's "close: function dispatch" call, not a
		# reimplementation.
		var node := ctx.calling_reference
		if node == null or not node.has_method("activate"):
			return 0
		node.activate()
		return 1)

	register("IsActionRef", func(a: Array, ctx: ScriptExecutionContext):
		if a.is_empty() or ctx.action_ref == null:
			return 0
		# safe_equal(), not a raw ==: a[0] is very often a "name" node's own
		# literal String (an unresolved editor-ID like "player" -- this
		# interpreter has no global editor-id -> Node registry to resolve it
		# through yet), and GDScript's own == throws for a String-vs-Object
		# comparison rather than just returning false (confirmed directly
		# this session) -- would otherwise crash the very first real
		# `IsActionRef player` this project's own real data uses.
		return 1 if ScriptExecutionContext.safe_equal(a[0], ctx.action_ref) else 0)

	register("GetActionRef", func(_a, ctx: ScriptExecutionContext):
		return ctx.action_ref)
		

	register("Unlock", func(_a, _c):
		# Real, deliberate gap: no lock/key state exists on any Dynamic type
		# yet (DoorNode/ContainerNode have no `is_locked` field today).
		return 0)

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

	var toggle_collision := func(_a: Array, ctx: ScriptExecutionContext):
		var target: Object = ctx.calling_reference
		if target == null:
			target = ctx.player_node
		if target != null and "noclip" in target:
			target.noclip = !target.noclip
			return 1 if target.noclip else 0
		return 0
	register("tcl", toggle_collision)
	register("TCL", toggle_collision)
	register("ToggleCollision", toggle_collision)

	register("ShowMessage", func(a: Array, _c):
		# Real argument shape confirmed against real data (GSBrokenSMGScript's
		# own `ShowMessage GSBrokenSMGMsg`): a bare MESG editor-ID name, not a
		# FormID -- resolved via get_message_by_editor_id(), which reads the
		# real MESG.FULL (title)/MESG.DESC (body) subrecords.
		#
		# No in-game message-box/menu UI exists in this project yet. Real,
		# per user direction: use the OS's own native alert dialog
		# (OS.alert()) as a stand-in -- genuinely shows the real message
		# text, just not through in-game UI. Two real consequences worth
		# being explicit about: OS.alert() is blocking/modal (freezes the
		# whole game loop, GameMode ticking included, until dismissed --
		# unlike the real engine's own non-blocking, frame-persistent
		# message box), and it returns void -- no button index at all, so a
		# MESG with real button choices (like GSBrokenSMGMsg's own two ITXT
		# entries) only ever shows as a single OK dialog. GetButtonPressed
		# stays genuinely unimplementable through this mechanism -- there's
		# no button result to report back, not a gap this function could
		# close even partially.
		if a.is_empty() or esm == null:
			return 0
		# str(), not String() -- GDScript's String() constructor is stricter
		# than it looks (confirmed directly, repeatedly, this session: it
		# throws for int/bool/other non-String Variants rather than
		# converting them). a[0] is normally already a String (a "name"
		# node's own literal), but a real script could pass a declared
		# local of any type here -- str() converts anything safely instead
		# of risking the same crash class again.
		var editor_id := str(a[0])
		var msg: Dictionary = esm.get_message_by_editor_id(editor_id)
		if msg.is_empty():
			push_warning("ScriptFunctionRegistry: ShowMessage -- no MESG found for editor ID '%s'" % editor_id)
			return 0
		var title: String = msg.get("title", "")
		OS.alert(String(msg.get("text", "")), title if title != "" else editor_id)
		return 1)
