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

## Default DOOR activation returns the same destination receipt as the legacy
## door path. Game owns the actual transition; a non-teleporting door toggles
## its authored open/closed animation locally.
func activate(_actor: Node = null) -> Dictionary:
	var door_reference := reference as DoorReference
	if door_reference == null:
		return {}
	var link := door_reference.teleport
	var server := EsmReference.get_esm_server()
	if link != null and server != null:
		var space := link.get_destination_space_form_id()
		if space != 0:
			return {
				"dest_cell_form_id": server.cell_at(space, link.position),
				"dest_position": link.position,
				"dest_rotation": link.rotation,
			}
	_toggle_swing()
	return {}

func _toggle_swing() -> void:
	var door_reference := reference as DoorReference
	if door_reference == null:
		return
	var player := get_nif_animation_player()
	if player != null and player.is_playing():
		return
	var opening := not door_reference.is_open
	var animation_name := "Open" if opening else "Close"
	if player != null and player.has_animation(animation_name):
		player.play(animation_name)
	door_reference.is_open = opening


## A paired LOD has no animated gate panel. When WorldStreamer promotes an
## already-open DOOR to its full NIF, the new tree starts at its authored
## closed pose unless the typed REFR state is applied here. Seek rather than
## play: streaming must reveal the live state immediately, not replay an open
## animation from closed after the full model happens to arrive.
func _on_nif_visual_ready(tree: Node3D) -> void:
	super._on_nif_visual_ready(tree)
	var door_reference := reference as DoorReference
	if door_reference == null or not door_reference.is_open:
		return
	var player := tree.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null or not player.has_animation("Open"):
		return
	player.play("Open")
	player.seek(player.get_animation("Open").length, true)
	# Preserve the final authored pose without a subsequent idle-frame advance.
	# A later activate() sees `is_open` and plays `Close` from this pose.
	player.pause()
