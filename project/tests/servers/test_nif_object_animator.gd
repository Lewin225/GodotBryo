extends Node

## NifObjectAnimator: a NIF object's animation group plays in KfAnimator slot
## 0. The spinning windmill (a STAT, no script) plays its only sequence,
## SpecialIdle, by default; the Freeside sign (Lucky38LightScript's PlayGroup
## Left / Right) plays Left when asked; an unknown group is refused. PlayGroup
## and IsAnimPlaying record and read the group on the calling reference, and
## the sign script's IsAnimPlaying condition parses with its argument.

const NifTreeBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")
const NifObjectAnimatorScript := preload("res://GodotBryo/Servers/NifServer/nif_object_animator.gd")
## WindmillSpinningNV's model: one sequence, SpecialIdle, looping 7 s.
const WINDMILL := "meshes/architecture/ncr/spinningwindmill.nif"
## NVFreesideSignLargeLights's model: Left and Right.
const SIGN := "meshes/architecture/freeside/nv_freesidesign-large_lights.nif"

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	await _check_windmill()
	await _check_sign()
	_check_script_functions()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_windmill() -> void:
	print("--- %s ---" % WINDMILL)
	var root := await _build(WINDMILL)
	if root == null:
		return
	add_child(root)
	var animator := root.get_node_or_null(NifObjectAnimatorScript.NODE_NAME)
	check(animator != null, "the windmill has an ObjectAnimator")
	if animator == null:
		root.queue_free()
		return
	check(animator.get_group() == "SpecialIdle", "it plays its default group SpecialIdle (got %s)" % animator.get_group())
	var start: Dictionary = animator.get_animator().get_start(NifObjectAnimatorScript.GROUP_SLOT)
	check(String(start.get("path", "")) == "SpecialIdle", "SpecialIdle plays in slot 0 (%s)" % start.get("path", "none"))
	var before := _poses(root)
	for i in 30:
		await get_tree().process_frame
	check(_poses(root) != before, "a node of the windmill moves while it plays")
	root.queue_free()


func _check_sign() -> void:
	print("--- %s ---" % SIGN)
	var root := await _build(SIGN)
	if root == null:
		return
	add_child(root)
	var animator := root.get_node_or_null(NifObjectAnimatorScript.NODE_NAME)
	check(animator != null, "the sign has an ObjectAnimator")
	if animator == null:
		root.queue_free()
		return
	check(animator.get_group() == "", "it has no default group (got %s)" % animator.get_group())
	check(not animator.play_group("Forward"), "a group it has no clip for is refused")
	check(animator.play_group("left"), "Left plays, named in any case")
	var start: Dictionary = animator.get_animator().get_start(NifObjectAnimatorScript.GROUP_SLOT)
	check(String(start.get("path", "")) == "Left", "Left plays in slot 0 (%s)" % start.get("path", "none"))
	root.queue_free()


func _check_script_functions() -> void:
	print("--- PlayGroup, IsAnimPlaying ---")
	var reference := EsmReference.new()
	var played := []
	reference.anim_group_played.connect(func(group: String) -> void: played.append(group))
	var ctx := ScriptExecutionContext.new(reference)
	var registry: ScriptFunctionRegistry = ScriptServer.function_registry
	check(int(registry.call_function("IsAnimPlaying", [], ctx)) == 0, "no group played: IsAnimPlaying is 0")
	check(int(registry.call_function("PlayGroup", ["Left", 0], ctx)) == 1, "PlayGroup Left 0 runs")
	check(reference.anim_group == "Left", "the reference records Left")
	check(played == ["Left"], "and announces it (%s)" % str(played))
	check(int(registry.call_function("IsAnimPlaying", ["left"], ctx)) == 1, "IsAnimPlaying left is 1")
	check(int(registry.call_function("IsAnimPlaying", ["Right"], ctx)) == 0, "IsAnimPlaying Right is 0")
	# Lucky38LightScript's guard: IsAnimPlaying takes its group as an argument,
	# so the condition is (IsAnimPlaying Left) != 1, not a bare name.
	var source := "Scn Test\nBegin GameMode\nIf (IsAnimPlaying Left != 1)\nPlayGroup Left 0\nEndif\nEnd\n"
	var program := ScriptParser.new(ScriptLexer.new(source).tokenize()).parse()
	var branch: Dictionary = program["blocks"][0]["stmts"][0]["branches"][0]
	var cond: Dictionary = branch["cond"]
	var left: Dictionary = cond.get("left", {})
	check(String(cond.get("kind", "")) == "binop" and String(left.get("name", "")) == "IsAnimPlaying"
		and (left.get("args", []) as Array).size() == 1,
		"If (IsAnimPlaying Left != 1) parses as (IsAnimPlaying Left) != 1")
	check((branch["stmts"] as Array).size() == 1, "its body is only PlayGroup Left 0")


## Every Node3D's transform under `root`, in order.
func _poses(root: Node) -> Array:
	var out: Array = []
	for node in root.find_children("*", "Node3D", true, false):
		out.append((node as Node3D).transform)
	return out


func _build(path: String) -> Node3D:
	var raw: Dictionary = ArchiveServer.read(path)
	var src := NifSource.new()
	if not bool(raw["found"]) or not src.load(PackedByteArray(raw["data"])):
		check(false, "read %s" % path)
		return null
	return await NifTreeBuilderScript.build(src)
