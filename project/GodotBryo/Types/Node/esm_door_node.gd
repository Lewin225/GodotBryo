@tool
@icon("res://GodotBryo/Types/Node/door.svg")
class_name EsmDoorNode
extends EsmNode

## New resource-backed door node for the EsmReferencePhysicaliser pipeline.
## This remains separate from the legacy project/gamebryo/DoorNode until the
## new physicalisation path is ready to replace that construction route.

## Editor test hook. This deliberately calls the same public activation
## pathway used by runtime interaction.
@export_tool_button("Activate Door") var activate_button: Callable = _editor_activate

func _editor_activate() -> void:
	activate()

func configure(door_reference: EsmReference) -> void:
	super.configure(door_reference)

func _reference_changed() -> void:
	super._reference_changed()

func build_visual(resolver: GamebryoMeshResolver) -> void:
	var door_reference := reference as DoorReference
	if door_reference == null or not door_reference.base is DoorBase:
		return
	var door_base := door_reference.base as DoorBase
	build_dynamic_visual(resolver, door_base.model_path)

## Default DOOR activation: toggle the authored open/closed animation. World
## transitions and script dispatch remain outside this physical node.
func activate(_actor: Node = null) -> Dictionary:
	if not reference is DoorReference:
		return {}
	_toggle_swing()
	return {}

func _toggle_swing() -> void:
	var door_reference := reference as DoorReference
	if door_reference == null:
		return
	var player := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player != null and player.is_playing():
		return
	var opening := not door_reference.is_open
	var animation_name := "Open" if opening else "Close"
	if player != null and player.has_animation(animation_name):
		player.play(animation_name)
	door_reference.is_open = opening
