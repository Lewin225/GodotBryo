extends Node
const GameDataConfigScript := preload("res://game_data_config.gd")
## One-off: verify issue #44's fix (animated STAT routes to a real Node with
## a playing AnimationPlayer instead of DirectGeometryBatch/RID). Resolves
## the real Goodsprings saloon sign REFR through GamebryoObjectRegistry.build()
## and checks the result.

func _ready() -> void:
	var config: Dictionary = GameDataConfigScript.resolve()
	var data_dir := String(config.get("data_dir", ""))
	var esm := EsmReader.new()
	if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		push_error("diag: could not open ESM")
		get_tree().quit(1)
		return
	var resolver := GamebryoMeshResolver.new(data_dir)
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	var cell: Dictionary = esm.find_exterior_cell(int(wrld["form_id"]), -17, 0)
	var refs: Array = esm.get_cell_references(int(cell["form_id"]))

	var sign_ref: Dictionary = {}
	for r in refs:
		if String(r.get("editor_id", "")) == "NVGSSaloonSign2":
			sign_ref = r
			break

	if sign_ref.is_empty():
		push_error("diag: NVGSSaloonSign2 REFR not found in (-17,0)")
		get_tree().quit(1)
		return

	print("found REFR base_type=%s edid=%s model=%s" % [sign_ref.get("base_type"), sign_ref.get("editor_id"), sign_ref.get("model")])
	var node := registry.build(sign_ref)
	if node == null:
		push_error("diag: FAIL build() returned null")
		get_tree().quit(1)
		return

	print("built node class=%s name=%s" % [node.get_class(), node.name])
	var player := node.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player == null:
		push_error("diag: FAIL no AnimationPlayer child")
		get_tree().quit(1)
		return

	print("AnimationPlayer found. has_animation(SpecialIdle)=%s is_playing=%s current=%s" % [
		player.has_animation("SpecialIdle"), player.is_playing(), player.current_animation])

	if player.has_animation("SpecialIdle") and player.is_playing() and player.current_animation == "SpecialIdle":
		print("PASS (interior build() path): animated static autoplays SpecialIdle")
	else:
		push_error("diag: FAIL SpecialIdle not autoplaying as expected (interior path)")
		get_tree().quit(1)
		return

	# Exterior/WorldStreamer path: resolve_placement() (worker-safe) + a REAL
	# DirectGeometryBatch passed to construct_from_resolved() -- confirms the
	# new "animated" flag actually keeps this out of the batch, not just that
	# the interior path (which never touches DirectGeometryBatch at all) works.
	var ctx := GamebryoResolveContext.new(data_dir)
	var resolved := registry.resolve_placement(sign_ref, ctx)
	if resolved.get("kind", "") != "visual" or not resolved.get("animated", false):
		push_error("diag: FAIL resolve_placement() did not flag animated=true (kind=%s)" % resolved.get("kind", ""))
		get_tree().quit(1)
		return
	var batch := DirectGeometryBatch.new()
	var ext_node := registry.construct_from_resolved(resolved, batch)
	if ext_node == null:
		push_error("diag: FAIL construct_from_resolved() fell through to DirectGeometryBatch instead of returning a real node")
		get_tree().quit(1)
		return
	var ext_player := ext_node.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if ext_player != null and ext_player.is_playing() and ext_player.current_animation == "SpecialIdle":
		print("PASS (exterior resolve+construct path): animated static kept out of DirectGeometryBatch, autoplays SpecialIdle")
		get_tree().quit(0)
	else:
		push_error("diag: FAIL exterior path node has no playing SpecialIdle AnimationPlayer")
		get_tree().quit(1)
