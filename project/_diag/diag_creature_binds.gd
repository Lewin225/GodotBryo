extends Node3D

## For one CREA per distinct skeleton and parts combination: for each skinned
## mesh, the bones whose rest pose disagrees with the mesh's bind pose. At rest
## every bind's skeleton global rest times its bind pose is the same transform;
## a bind whose product sits far from the mesh's most common one is reported.

const TOLERANCE_METRES := 0.01

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var by_combination := {}
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "CREA":
			continue
		var base := EsmServer.get_base(int(row["form_id"])) as CreatureBase
		var model := ActorBase.template_source(base, ActorBase.TEMPLATE_USE_MODEL_ANIMATION) as CreatureBase
		if model == null or model.model_list_paths.is_empty():
			continue
		var key := model.model_path.to_lower() + "|" + "|".join(model.model_list_paths).to_lower()
		if not by_combination.has(key):
			by_combination[key] = base
	var bad_bones := {}
	var creatures_with_bad := 0
	for key: String in by_combination:
		var base: CreatureBase = by_combination[key]
		var reference := EsmServer.create_reference_for_base(base.form_id)
		var controller := EsmReferencePhysicaliser.new().physicalise(reference, self) as NpcController
		var node := controller.actor
		var result := ["pending"]
		node.visual_load_completed.connect(func() -> void: result[0] = "built")
		node.visual_load_failed.connect(func(reason: String) -> void: result[0] = reason)
		for frame in 900:
			await get_tree().process_frame
			if result[0] != "pending":
				break
		if result[0] == "built":
			var lines := _check(node)
			if not lines.is_empty():
				creatures_with_bad += 1
				print("== %s (%s)" % [base.editor_id, key.get_slice("|", 0)])
				for line in lines:
					print("  ", line)
					var bone := line.get_slice(" ", 0)
					bad_bones[bone] = int(bad_bones.get(bone, 0)) + 1
		controller.queue_free()
	print("combinations %d, with mismatched binds %d" % [by_combination.size(), creatures_with_bad])
	var names := bad_bones.keys()
	names.sort_custom(func(a, b): return bad_bones[a] > bad_bones[b])
	for name in names.slice(0, 30):
		print("%4d  %s" % [bad_bones[name], name])
	get_tree().quit()


func _check(node: Node) -> PackedStringArray:
	var lines := PackedStringArray()
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.skin == null:
			continue
		var skeleton := mesh.get_node_or_null(mesh.skeleton) as Skeleton3D
		if skeleton == null:
			continue
		var products: Array[Transform3D] = []
		var names := PackedStringArray()
		for bind in mesh.skin.get_bind_count():
			var bone := mesh.skin.get_bind_bone(bind)
			var bone_name := String(mesh.skin.get_bind_name(bind))
			if bone < 0:
				bone = skeleton.find_bone(bone_name)
			if bone < 0:
				lines.append("%s missing in %s" % [bone_name.replace(" ", "_"), mesh.name])
				continue
			products.append(skeleton.get_bone_global_rest(bone) * mesh.skin.get_bind_pose(bind))
			names.append(skeleton.get_bone_name(bone))
		var reference := _most_common(products)
		for index in products.size():
			var offset := products[index].origin.distance_to(reference.origin)
			if offset > TOLERANCE_METRES:
				lines.append("%s off %.3f m in %s (%s)" % [names[index].replace(" ", "_"), offset, mesh.name, String(mesh.get_meta("gamebryo_model_path", "")).get_file()])
	return lines


func _most_common(products: Array[Transform3D]) -> Transform3D:
	var best := Transform3D.IDENTITY
	var best_count := -1
	for candidate in products:
		var count := 0
		for other in products:
			if other.origin.distance_to(candidate.origin) <= TOLERANCE_METRES:
				count += 1
		if count > best_count:
			best_count = count
			best = candidate
	return best
