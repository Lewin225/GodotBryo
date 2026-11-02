extends Node

## Census of every CREA's NIFZ parts against its skeleton: per distinct
## (skeleton, part) pair, whether the part is skinned, whether every bind names
## a skeleton bone, and for an unskinned part its top node names.

var _trees := {}
var _pending := 0


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var pairs := {}
	var creatures := 0
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "CREA":
			continue
		var base := EsmServer.get_base(int(row["form_id"])) as CreatureBase
		if base == null:
			continue
		var model := ActorBase.template_source(base, ActorBase.TEMPLATE_USE_MODEL_ANIMATION) as CreatureBase
		if model == null or model.model_list_paths.is_empty():
			continue
		creatures += 1
		for part in model.model_list_paths:
			pairs["%s|%s" % [model.model_path, part]] = true
	var paths := {}
	for pair: String in pairs:
		for path in pair.split("|"):
			paths[path.to_lower()] = path
	print("creatures with parts %d, distinct pairs %d, distinct NIFs %d" % [creatures, pairs.size(), paths.size()])
	for key: String in paths:
		_pending += 1
		NifServer.request(paths[key], self, _on_tree.bind(key), false)
	while _pending > 0:
		await get_tree().process_frame
	var counts := {}
	var examples := {}
	for pair: String in pairs:
		var halves := pair.split("|")
		var verdict := _verdict(halves[0].to_lower(), halves[1].to_lower())
		counts[verdict] = int(counts.get(verdict, 0)) + 1
		if not examples.has(verdict):
			examples[verdict] = []
		if examples[verdict].size() < 6:
			examples[verdict].append(halves[1])
	for verdict in counts:
		print("%5d  %s  e.g. %s" % [counts[verdict], verdict, examples[verdict]])
	get_tree().quit()


func _on_tree(tree: Node3D, key: String) -> void:
	if tree != null:
		var holder := Node3D.new()
		add_child(holder)
		holder.add_child(tree)
	_trees[key] = tree
	_pending -= 1


func _verdict(skeleton_key: String, part_key: String) -> String:
	var skeleton_tree: Node3D = _trees.get(skeleton_key)
	var part: Node3D = _trees.get(part_key)
	if skeleton_tree == null:
		return "skeleton missing"
	if part == null:
		return "part missing"
	var skeleton := skeleton_tree.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null:
		var prn_node := ""
		for node in [part] + part.find_children("*", "Node3D", true, false):
			var strings: Dictionary = node.get_meta("nif_string_extra_data", {})
			if strings.has("Prn"):
				prn_node = String(strings["Prn"])
				break
		var skinned_any := false
		for child in part.find_children("*", "MeshInstance3D", true, false):
			if (child as MeshInstance3D).skin != null:
				skinned_any = true
		return "no Skeleton3D; part skinned %s, Prn %s, Prn node in skeleton tree %s" % [skinned_any, "set" if not prn_node.is_empty() else "none", _find_named(skeleton_tree, prn_node) != null]
	var skinned := 0
	var unbound := {}
	for child in part.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.skin == null or mesh.skin.get_bind_count() == 0:
			continue
		skinned += 1
		for bind_index in mesh.skin.get_bind_count():
			var bone := String(mesh.skin.get_bind_name(bind_index))
			if skeleton.find_bone(bone) == -1:
				unbound[bone] = true
	var meshes := part.find_children("*", "MeshInstance3D", true, false).size()
	if skinned == 0:
		var names := PackedStringArray()
		for child in part.get_children():
			names.append(String(child.get_meta(NifNames.META_NIF_NAME, child.name)))
		var in_skeleton := false
		for node in part.find_children("*", "Node3D", true, false):
			if skeleton.find_bone(String(node.get_meta(NifNames.META_NIF_NAME, node.name))) != -1:
				in_skeleton = true
		var prn := ""
		for node in [part] + part.find_children("*", "Node3D", true, false):
			var strings: Dictionary = node.get_meta("nif_string_extra_data", {})
			if strings.has("Prn"):
				prn = String(strings["Prn"])
				break
		if prn.is_empty():
			return "unskinned (%s), no Prn" % ["meshes" if meshes > 0 else "no meshes"]
		var bone_found := skeleton.find_bone(NifNames.escape(prn)) != -1 or skeleton.find_bone(prn) != -1
		if not bone_found:
			var node_found := _find_named(skeleton_tree, prn) != null
			return "unskinned, Prn '%s' names no bone; a skeleton node: %s" % [prn, node_found]
		return "unskinned (%s), Prn names a skeleton bone" % ["meshes" if meshes > 0 else "no meshes"]
	if skinned < meshes:
		return "partly skinned, binds %s" % ("all found" if unbound.is_empty() else "missing")
	if not unbound.is_empty():
		var in_part := 0
		for bone: String in unbound:
			if _find_named(part, NifNames.unescape(bone)) != null:
				in_part += 1
		return "skinned, binds missing (%s); %d of %d are nodes in the part itself" % [", ".join(unbound.keys().slice(0, 3)), in_part, unbound.size()]
	return "skinned, all binds found"


func _find_named(root: Node, nif_name: String) -> Node:
	if nif_name.is_empty():
		return null
	for node in [root] + root.find_children("*", "", true, false):
		if String(node.get_meta(NifNames.META_NIF_NAME, "")) == nif_name:
			return node
	return null
