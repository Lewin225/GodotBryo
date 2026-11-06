extends Node3D

## Builds one CREA for each distinct skeleton and NIFZ parts combination and
## counts how many build, and how many of their parts end up in the body.

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
	print("distinct combinations %d" % by_combination.size())
	var built := 0
	var failed: Array[String] = []
	var short: Array[String] = []
	for key: String in by_combination:
		var base: CreatureBase = by_combination[key]
		var reference := EsmServer.create_reference_for_base(base.form_id)
		var controller := EsmReferencePhysicaliser.new().physicalise(reference, self) as NpcController
		var node := controller.actor
		var result := ["pending"]
		var clips := [-2]
		node.visual_load_completed.connect(func() -> void: result[0] = "built")
		node.visual_load_failed.connect(func(reason: String) -> void: result[0] = reason)
		node.animation_load_completed.connect(func(count: int) -> void: clips[0] = count)
		node.animation_load_failed.connect(func(reason: String) -> void: clips[0] = -1; print("ANIMFAIL %s: %s" % [base.editor_id, reason]))
		for frame in 900:
			await get_tree().process_frame
			if result[0] != "pending" and clips[0] != -2:
				break
		if result[0] == "built":
			var player := node.find_child(ActorAnimator.PLAYER_NODE_NAME, true, false) as AnimationPlayer
			var playing := ""
			if player != null and not player.current_animation.is_empty():
				playing = String(player.get_animation(player.current_animation).get_meta("nif_source_path", "")).get_file()
			print("ANIM %s clips %d playing %s" % [base.editor_id, clips[0], playing if not playing.is_empty() else "nothing"])
		if result[0] != "built":
			failed.append("%s: %s" % [base.editor_id, result[0]])
		else:
			built += 1
			var model := ActorBase.template_source(base, ActorBase.TEMPLATE_USE_MODEL_ANIMATION) as CreatureBase
			var paths := {}
			for mesh in node.find_children("*", "MeshInstance3D", true, false):
				paths[String(mesh.get_meta("gamebryo_model_path", "")).to_lower()] = true
			var missing := 0
			for path in model.model_list_paths:
				if not paths.has(path.to_lower()):
					missing += 1
					pass
			if missing > 0:
				short.append("%s: %d of %d parts have no mesh in the body" % [base.editor_id, missing, model.model_list_paths.size()])
		controller.queue_free()
	print("built %d, failed %d" % [built, failed.size()])
	for line in failed.slice(0, 15):
		print("  FAILED ", line)
	print("built with parts missing: %d" % short.size())
	for line in short.slice(0, 40):
		print("  ", line)
	get_tree().quit()
