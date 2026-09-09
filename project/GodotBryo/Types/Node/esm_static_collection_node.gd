@tool
@icon("res://GodotBryo/Types/Node/static_collection.svg")
class_name EsmStaticCollectionNode
extends EsmNode

## SCOL is an authored collection anchor. Its parts stay individual nodes for
## now, while this marker lets a future WorldStreamer opt into joining them.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_batch_candidate: bool = true

func build_collection(physicaliser: EsmReferencePhysicaliser) -> void:
	if reference == null or not reference.base is StaticCollectionBase:
		return
	var tree := Engine.get_main_loop()
	var root = tree.root if tree != null else null
	var server = root.get_node_or_null("EsmServer") if root != null else null
	if server == null or not server.is_ready():
		return
	var parts: Array = server.reader.get_scol_parts(reference.base_form_id)
	for index in parts.size():
		var child := physicaliser.physicalise_scol_part(parts[index], index)
		if child == null:
			continue
		child.name = "%s_Part%02d" % [child.name, index]
		add_child(child)
	_visual_built = true
