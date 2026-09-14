@tool
class_name EsmLeveledItemPreviewNode
extends EsmNode

## LVLI records are inventory definitions, not world-placeable objects. This
## node exists only to make browser/editor inspection use the normal reference
## physicalizer path without pretending the list has a mesh or collision.
func _on_reference_ready() -> void:
	if not reference is LeveledItemReference or not reference.base is LeveledItemBase:
		return
	if get_node_or_null("LeveledItemSummary") != null:
		return
	var list := reference.base as LeveledItemBase
	var label := Label3D.new()
	label.name = "LeveledItemSummary"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 64
	label.outline_size = 8
	label.modulate = Color(0.65, 0.85, 1.0, 1.0)
	label.text = "LVLI\n%s\n%d entries\nChance None: %d%%" % [
		list.editor_id if not list.editor_id.is_empty() else "0x%08X" % list.form_id,
		list.entries.size(), list.chance_none]
	add_generated_child(label)

func _should_request_nif() -> bool:
	return false

func is_world_placeable() -> bool:
	return false
