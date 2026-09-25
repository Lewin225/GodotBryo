class_name InteractRay
extends RayCast3D

signal target_changed(new_target: Object, new_collider: Object, interaction_type: StringName, action_text: String)

@export var reach_distance: float = 2.5
@export var player_body: CharacterBody3D
@export var use_emojis: bool = true

var current_target: Object = null
var current_collider: Object = null
var current_type: StringName = &"none"
var current_action: String = ""


func _ready() -> void:
	target_position = Vector3(0.0, 0.0, -reach_distance)
	collide_with_areas = false
	collide_with_bodies = true

	if not player_body:
		var parent := get_parent()
		if parent:
			player_body = parent.get_parent() as CharacterBody3D
	if player_body:
		add_exception(player_body)


func _process(_delta: float) -> void:
	_update_target()


func _update_target() -> void:
	var collider := get_collider()
	var target: Object = null
	var itype: StringName = &"none"
	var iaction: String = ""

	if collider != null:
		if is_instance_valid(player_body) and (collider == player_body or player_body.is_ancestor_of(collider as Node)):
			collider = null
		else:
			target = semantic_target(collider)
			if is_instance_valid(player_body) and (target == player_body or (target is Node and player_body.is_ancestor_of(target))):
				target = null
				collider = null
			else:
				itype = get_interaction_type(target)
				iaction = get_interaction_action(target)

	if target != current_target or collider != current_collider or iaction != current_action:
		current_target = target
		current_collider = collider
		current_type = itype
		current_action = iaction
		target_changed.emit(current_target, current_collider, current_type, current_action)


## Interactions happen on the semantic EsmNode, Not the collider
## Searches upwards from the collider till we reach one or nothing
static func semantic_target(target: Object) -> Object:
	if not target is Node:
		return target
	var node := target as Node
	while node != null:
		if node is EsmNode:
			return node
		node = node.get_parent()
	return target


func get_interact_info() -> Dictionary:
	# Used by the ui to show interaction hints. Should be removed once that debug feature is removed
	_update_target()
	if current_target == null:
		return {}
	return {
		"collider": current_collider,
		"target": current_target,
		"type": current_type,
		"action": current_action,
		"hit_position": get_collision_point(),
		"hit_normal": get_collision_normal()
	}


func get_interaction_type(target: Object) -> StringName:
	# Used by the ui to show interaction hints. Should be removed once that debug feature is removed
	if target == null:
		return &"none"
	if target is EsmItemNode:
		return &"item"
	if target is EsmDoorNode:
		return &"door"
	if target is EsmContainerNode:
		return &"container"
	if target is EsmTerminalNode:
		return &"terminal"
	if target is EsmTalkingActivatorNode:
		return &"talk"
	if target is EsmActivatorNode:
		return &"activator"
	if target is EsmFurnitureNode:
		return &"furniture"
	if target.has_method("pickup"):
		return &"item"
	if target.has_method("activate"):
		return &"activate"
	return &"none"

func get_interaction_action(target: Object) -> String:
	# Used by the ui to show interaction hints. Should be removed once that debug feature is removed
	if target == null:
		return ""
	if target is EsmItemNode or target.has_method("pickup"):
		return ("🖐️ " if use_emojis else "") + "Pick Up"
	if target is EsmDoorNode:
		var prefix: String = "🚪 " if use_emojis else ""
		var door_ref := (target as EsmDoorNode).reference as DoorReference
		return prefix + ("Close" if door_ref != null and door_ref.is_open else "Open")
	if target is EsmContainerNode:
		return ("📦 " if use_emojis else "") + "Search"
	if target is EsmTerminalNode:
		return ("💻 " if use_emojis else "") + "Access"
	if target is EsmTalkingActivatorNode:
		return ("💬 " if use_emojis else "") + "Talk"
	if target is EsmFurnitureNode:
		# FURN's authored marker_flags carry the real sit/sleep/lean distinction.
		# Until those bytes are decoded this stays one verb rather than guessing
		# from the node's name, which is what the v0 path did.
		return ("🪑 " if use_emojis else "") + "Use"
	if target is EsmActivatorNode:
		return ("⚡ " if use_emojis else "") + "Activate"
	if target.has_method("activate"):
		var prefix: String = "🔘 " if use_emojis else ""
		return prefix + ("Close" if ("is_open" in target and target.is_open) else "Open" if ("is_open" in target) else "Activate")
	return ""
