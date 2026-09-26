@tool
@icon("res://GodotBryo/Types/Node/door.svg")
class_name EsmDoorNode
extends EsmNode

## Editor preview: toggles the door's open state and plays it.
@export_tool_button("Activate Door") var activate_button: Callable = _editor_activate

func _editor_activate() -> void:
	var door_reference := reference as DoorReference
	if door_reference == null:
		return
	door_reference.is_open = not door_reference.is_open
	on_activated(null)

## The open state the node last showed; activations that leave is_open
## unchanged (a locked door, a teleport) play nothing.
var _shown_open := false

## Plays Open or Close when the reference's is_open changed since it was last
## shown. A teleporting door has no open state to show.
func on_activated(_activator: EsmReference) -> void:
	var door_reference := reference as DoorReference
	if door_reference == null or door_reference.teleport != null or door_reference.is_open == _shown_open:
		return
	_shown_open = door_reference.is_open
	var player := get_nif_animation_player()
	var animation_name := "Open" if door_reference.is_open else "Close"
	if player != null and player.has_animation(animation_name):
		player.play(animation_name)


## A paired LOD has no animated gate panel. When WorldStreamer promotes an
## already-open DOOR to its full NIF, the new tree starts at its authored
## closed pose unless the typed REFR state is applied here. Seek rather than
## play: streaming must reveal the live state immediately, not replay an open
## animation from closed after the full model happens to arrive.
func _on_nif_visual_ready(tree: Node3D) -> void:
	super._on_nif_visual_ready(tree)
	var door_reference := reference as DoorReference
	_shown_open = door_reference != null and door_reference.is_open
	if door_reference == null or not door_reference.is_open:
		return
	var player := tree.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null or not player.has_animation("Open"):
		return
	player.play("Open")
	player.seek(player.get_animation("Open").length, true)
	# Preserve the final authored pose without a subsequent idle-frame advance.
	# A later activation that closes the door plays `Close` from this pose.
	player.pause()
