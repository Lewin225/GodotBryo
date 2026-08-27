extends Node
const GameDataConfigScript := preload("res://game_data_config.gd")
## One-off: check what this project's real NifReader/mesh_resolver pipeline
## sees for the Goodsprings NV_Nevadaflag.NIF -- it has real NiSkinInstance/
## NiSkinData/NiSkinPartition (bone skinning) AND NiGeomMorpherController/
## NiMorphData (vertex morphs) per a raw nifly block dump, neither of which
## this pipeline extracts at all (AGENTS.md: "Skeleton/skinning/animation
## data is intentionally not extracted"). Checking whether get_animation_
## sequences() still reports it as animated despite that gap, and what
## resolve_raw_geometry() actually produces.

func _ready() -> void:
	var config: Dictionary = GameDataConfigScript.resolve()
	var data_dir := String(config.get("data_dir", ""))
	var resolver := GamebryoMeshResolver.new(data_dir)
	var model := "clutter\\flags\\NV_Nevadaflag.NIF"
	var nif := resolver.load_nif(model)
	if nif == null:
		push_error("diag: load_nif failed")
		get_tree().quit(1)
		return
	print("submesh_count=%d" % nif.get_submesh_count())
	var sequences: Array = nif.get_animation_sequences()
	print("sequence_count=%d" % sequences.size())
	for seq in sequences:
		print("  seq name=%s cycle_type=%d track_count=%d" % [seq.get("name"), seq.get("cycle_type"), (seq.get("tracks", []) as Array).size()])
	var scene_nodes: Array = nif.get_scene_nodes()
	print("scene_node_count=%d" % scene_nodes.size())
	get_tree().quit(0)
