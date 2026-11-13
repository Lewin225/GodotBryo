extends Node

## NifSource.get_free_controllers(): controllers no NiControllerSequence link
## drives, on nodes and on their properties, each a controlled block with its
## own clock. The corpus count of free NiTextureTransformControllers matches
## the census (native/tools/manager_census, 1,098 in manager-less files and 7
## in files with a manager) in distinct controller blocks; a controller on a
## property several shapes share is exported once per shape. And Mr. House's
## penthouse screen exports its looping texture transforms with the
## sequence-link controller ID.

## Mr. House's penthouse screen: looping texture transforms of differing
## lengths, on the screen shape's NiTexturingProperty.
const SCREEN := "meshes/creatures/nvpenthouemaincomputer/nvdefaultscreen.nif"
## NiTimeController flags: bits 1-2 the cycle type (0 loop), bit 3 active.
const CYCLE_MASK := 0x6
const ACTIVE_BIT := 0x8
const TEXTURE_TRANSFORMS_IN_CORPUS := 1105
## The male skeleton: free transform controllers on its bones.
const SKELETON := "meshes/characters/_male/skeleton.nif"
## The hunting rifle: free controllers on its bolt, clip and trigger.
const RIFLE := "meshes/weapons/2handrifle/huntingrifle.nif"
const RIFLE_PARTS := ["##HRBolt", "##HRClip", "##HRTrigger"]
const NifTreeBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")
const NifObjectAnimatorScript := preload("res://GodotBryo/Servers/NifServer/nif_object_animator.gd")

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	_check_screen()
	await _check_screen_clips()
	await _check_skeleton_clips()
	await _check_rifle_parts_end_at_rest()
	_check_corpus()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_screen() -> void:
	print("--- %s ---" % SCREEN)
	var src := _load(SCREEN)
	if src == null:
		return
	var shapes := {}
	for nd in src.get_nodes():
		if nd.has("positions"):
			shapes[String(nd["name"])] = true
	var looping := []
	for fc in src.get_free_controllers():
		if String(fc["controller_type"]) != "NiTextureTransformController":
			continue
		if (int(fc["flags"]) & CYCLE_MASK) == 0 and (int(fc["flags"]) & ACTIVE_BIT) != 0:
			looping.append(fc)
	check(looping.size() >= 3, "it has looping, active texture transforms (%d)" % looping.size())
	var lengths := {}
	for fc in looping:
		var parts := String(fc["controller_id"]).split("-")
		check(parts.size() == 3 and parts[2].begins_with("TT_"),
			"controller ID %s is <shaderMap>-<slot>-<operation>" % fc["controller_id"])
		check(shapes.has(String(fc["node_name"])), "its target %s is a shape" % fc["node_name"])
		var interpolator: Dictionary = fc["interpolator"]
		check(bool(interpolator["present"]) and String(interpolator["kind"]) == "float",
			"it has a float interpolator")
		lengths[snappedf(float(fc["stop_time"]) - float(fc["start_time"]), 0.01)] = true
	check(lengths.size() > 1, "their loops differ in length (%s)" % str(lengths.keys()))


## The screen's tree carries its free controllers as FreeControllers clips in
## the AnimationPlayer library, one per timing, with UV tracks, to auto-play.
func _check_screen_clips() -> void:
	print("--- %s free-controller clips ---" % SCREEN)
	var root: Node3D = await NifTreeBuilderScript.build(_load(SCREEN))
	var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer if root != null else null
	check(player != null, "the screen's tree has an AnimationPlayer")
	if player == null:
		return
	var free_clips: Array = []
	for clip in player.get_animation_list():
		var animation := player.get_animation(clip)
		if bool(animation.get_meta("nif_free_controllers", false)):
			free_clips.append(animation)
	check(free_clips.size() > 1, "it has %d FreeControllers clips" % free_clips.size())
	var lengths := {}
	var uv_tracks := 0
	var autoplay := 0
	for animation: Animation in free_clips:
		lengths[snappedf(animation.length, 0.01)] = true
		if bool(animation.get_meta("nif_autoplay", false)):
			autoplay += 1
		for track in animation.get_track_count():
			if String(animation.track_get_path(track)).contains(":instance_shader_parameters/nif_uv_"):
				uv_tracks += 1
	check(lengths.size() > 1, "the clips differ in length (%s)" % str(lengths.keys()))
	check(uv_tracks > 0, "they carry base-map UV tracks (%d)" % uv_tracks)
	check(autoplay > 0, "%d of them auto-play" % autoplay)
	check(root.get_node_or_null(NifObjectAnimatorScript.NODE_NAME) != null,
		"the tree has a %s" % NifObjectAnimatorScript.NODE_NAME)
	# In the scene, the player runs the clips: some shape's base-map UV moves.
	add_child(root)
	var moved := false
	for i in 120:
		await get_tree().process_frame
		if _uv_moved(root):
			moved = true
			break
	check(moved, "playing, a shape's base-map UV uniforms move from their defaults")
	root.queue_free()


func _uv_moved(root: Node) -> bool:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var offset_u := _uniform(mesh, "nif_uv_offset_u", 0.0)
		var offset_v := _uniform(mesh, "nif_uv_offset_v", 0.0)
		var scale_u := _uniform(mesh, "nif_uv_scale_u", 1.0)
		var rotate := _uniform(mesh, "nif_uv_rotate", 0.0)
		var moved_offset := not is_zero_approx(offset_u) or not is_zero_approx(offset_v)
		if moved_offset or not is_equal_approx(scale_u, 1.0) or not is_zero_approx(rotate):
			return true
	return false


## An instance uniform's value, or `default` when the shape's material has none
## (a StandardMaterial3D shape) or it was never set.
func _uniform(mesh: MeshInstance3D, uniform: String, default: float) -> float:
	var value: Variant = mesh.get_instance_shader_parameter(uniform)
	return float(value) if value != null else default


## The hunting rifle's free controllers run its bolt, clip and trigger from a
## displaced pose (-0.033 s) to their rest pose (0 s). Played out, each part
## ends exactly at its NIF rest transform.
func _check_rifle_parts_end_at_rest() -> void:
	print("--- %s parts after their free controllers ---" % RIFLE)
	var src := _load(RIFLE)
	var rest := {}
	for nd in src.get_nodes():
		if RIFLE_PARTS.has(String(nd["name"])):
			rest[String(nd["name"])] = nd["transform"]
	var root: Node3D = await NifTreeBuilderScript.build(src)
	add_child(root)
	for i in 30:
		await get_tree().process_frame
	for part in RIFLE_PARTS:
		var node := root.find_child(NifNames.escape(part), true, false) as Node3D
		var expected: Transform3D = rest.get(part, Transform3D.IDENTITY)
		check(node != null and node.transform.is_equal_approx(expected),
			"%s ends at its rest transform (%s, got %s)" % [part, expected.origin, node.transform.origin if node != null else "none"])
	root.queue_free()


## A rig's free controllers drive its bones: in the library, never auto-played.
func _check_skeleton_clips() -> void:
	print("--- %s free-controller clips ---" % SKELETON)
	var root: Node3D = await NifTreeBuilderScript.build(_load(SKELETON))
	var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer if root != null else null
	var free_clips := 0
	var autoplay := 0
	if player != null:
		for clip in player.get_animation_list():
			var animation := player.get_animation(clip)
			if not bool(animation.get_meta("nif_free_controllers", false)):
				continue
			free_clips += 1
			if bool(animation.get_meta("nif_autoplay", false)):
				autoplay += 1
	check(free_clips > 0, "the skeleton's free controllers are in the library (%d clips)" % free_clips)
	check(autoplay == 0, "none of them auto-plays (got %d)" % autoplay)
	check(root == null or root.get_node_or_null(NifObjectAnimatorScript.NODE_NAME) == null,
		"the skeleton has no %s" % NifObjectAnimatorScript.NODE_NAME)
	if root != null:
		root.free()


func _check_corpus() -> void:
	print("--- free NiTextureTransformControllers in every NIF ---")
	var count := 0
	var entries := 0
	for p in ArchiveServer.list_files_with_prefix("meshes/"):
		var sp := String(p)
		if not sp.ends_with(".nif"):
			continue
		var src := _load(sp)
		if src == null:
			continue
		var blocks := {}
		for fc in src.get_free_controllers():
			if String(fc["controller_type"]) == "NiTextureTransformController":
				blocks[int(fc["block_index"])] = true
				entries += 1
		count += blocks.size()
	check(count == TEXTURE_TRANSFORMS_IN_CORPUS,
		"%d free texture transform blocks (got %d)" % [TEXTURE_TRANSFORMS_IN_CORPUS, count])
	# A property shared by several shapes exports its controller once per shape:
	# each shape's own uniform is animated.
	print("  INFO %d entries: %d controllers on a property shared by more than one shape" % [entries, entries - count])


func _load(path: String) -> NifSource:
	var raw: Dictionary = ArchiveServer.read(path)
	if not bool(raw["found"]):
		return null
	var src := NifSource.new()
	if not src.load(PackedByteArray(raw["data"])):
		return null
	return src
