extends Node

## Compares the mini sentry turret's mtidle.kf track targets with the bones
## and nodes of its skeleton NIF.

var _skeleton_tree: Node3D = null
var _library: AnimationLibrary = null
var _pending := 2


func _ready() -> void:
	NifServer.request("Creatures\\MiniSentryTurret\\Skeleton.nif", self, _on_tree, false)
	NifServer.request_kf("meshes/creatures/minisentryturret/mtidle.kf", self, _on_kf)
	while _pending > 0:
		await get_tree().process_frame
	var skeleton := _skeleton_tree.find_child("Skeleton3D", true, false) as Skeleton3D if _skeleton_tree != null else null
	print("skeleton3d: ", skeleton != null, " bones ", skeleton.get_bone_count() if skeleton else 0)
	var nodes := PackedStringArray()
	if _skeleton_tree != null:
		for node in _skeleton_tree.find_children("*", "Node3D", true, false):
			nodes.append(String(node.get_meta(NifNames.META_NIF_NAME, node.name)))
	print("nodes: ", nodes.slice(0, 30))
	if skeleton != null:
		var bones := PackedStringArray()
		for bone in skeleton.get_bone_count():
			bones.append(skeleton.get_bone_name(bone))
		print("bones: ", bones)
	if _library != null:
		for clip in _library.get_animation_list():
			var animation := _library.get_animation(clip)
			var targets := PackedStringArray()
			for track in animation.get_track_count():
				targets.append(String(animation.track_get_path(track)))
			print("clip ", clip, " tracks: ", targets.slice(0, 30))
	get_tree().quit()


func _on_tree(tree: Node3D) -> void:
	_skeleton_tree = tree
	if tree != null:
		add_child(tree)
	_pending -= 1


func _on_kf(library: AnimationLibrary) -> void:
	_library = library
	_pending -= 1
