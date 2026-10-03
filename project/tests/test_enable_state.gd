extends Node3D

## Enable state: the Initially Disabled header flag (0x800), XESP enable
## parents (Opposite of Parent, two-deep chains), Enable / Disable /
## GetDisabled, a disabled actor's script not running, and an EsmNode hiding
## a disabled reference and turning its collision off.

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var script_server = get_node("/root/ScriptServer")
	var registry: ScriptFunctionRegistry = script_server.function_registry

	# TempRorschachTest01REF: header flags 0xC00, Initially Disabled.
	var card: EsmReference = esm_server.find_reference_by_editor_id("TempRorschachTest01REF")
	var card_ctx := ScriptExecutionContext.new(card)
	check(card.initially_disabled and card.disabled and card.is_disabled() and registry.call_function("GetDisabled", [], card_ctx) == 1,
			"TempRorschachTest01REF starts disabled (0x800); GetDisabled is 1 with it unloaded")

	# An EsmNode hides it and keeps its collision off, even when a streamer
	# turns the tile's collision on.
	var node: EsmNode = EsmReferencePhysicaliser.new().physicalise(card, self)
	var shape := CollisionShape3D.new()
	node.add_generated_child(shape)
	EsmNode.set_collision_disabled(self, false)
	check(not node.visible and shape.disabled, "its node is hidden and its collision stays off")
	script_server.run_debug_line("TempRorschachTest01REF.Enable 1")
	check(not card.is_disabled() and card.dirty and node.visible and not shape.disabled,
			"Enable 1 enables it, marks it dirty, and shows the node with collision")
	script_server.run_debug_line("TempRorschachTest01REF.Disable")
	check(card.is_disabled() and not node.visible and shape.disabled, "Disable hides it again")
	node.queue_free()

	# ACHR 000A46FC: Opposite of Parent, parent REFR 001438BE Initially Disabled.
	var child: EsmReference = esm_server.get_reference("authored:000A46FC")
	var parent: EsmReference = esm_server.get_reference("authored:001438BE")
	check(child.enable_parent_form_id == 0x001438BE and (child.enable_parent_flags & EsmReference.ENABLE_PARENT_OPPOSITE) != 0
			and not child.initially_disabled and parent.is_disabled() and not child.is_disabled(),
			"000A46FC follows disabled 001438BE inverted: it is enabled")
	var child_node: EsmNode = EsmReferencePhysicaliser.new().physicalise(child, self)
	parent.set_disabled(false)
	check(child.is_disabled() and not child_node.visible, "enabling the parent disables it and hides its node")
	child.set_disabled(false)
	check(child.is_disabled(), "Enable on the child does nothing: its parent decides")
	parent.set_disabled(true)
	check(not child.is_disabled() and child_node.visible, "disabling the parent again enables it")
	child_node.queue_free()

	# 000F3BD3 -> 000F3BD2 -> 000EE6C6 (Initially Disabled), no Opposite.
	var leaf: EsmReference = esm_server.get_reference("authored:000F3BD3")
	var root: EsmReference = esm_server.get_reference("authored:000EE6C6")
	var leaf_disabled := leaf.is_disabled()
	root.set_disabled(false)
	check(leaf_disabled and not leaf.is_disabled(), "a two-deep chain follows its root (disabled, then enabled)")
	root.set_disabled(true)

	# ACHR 000A41B4 (HVPasswordPaladinTalk): Initially Disabled, its script has
	# an OnLoad block, which does not run until it is enabled.
	var actor: EsmReference = esm_server.get_reference("authored:000A41B4")
	check(actor is ActorReference and actor.is_disabled() and not script_server.has_block_for(actor, "OnLoad"),
			"000A41B4 is a disabled actor; its OnLoad block does not run")
	actor.set_disabled(false)
	check(script_server.has_block_for(actor, "OnLoad"), "enabled, it does")
	actor.set_disabled(true)

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
