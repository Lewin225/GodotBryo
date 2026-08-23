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
		return 1 if a[0] == ctx.action_ref else 0)

	register("GetActionRef", func(_a, ctx: ScriptExecutionContext):
		return ctx.action_ref)

	register("Unlock", func(_a, _c):
		# Real, deliberate gap: no lock/key state exists on any Dynamic type
		# yet (DoorNode/ContainerNode have no `is_locked` field today).
		return 0)
