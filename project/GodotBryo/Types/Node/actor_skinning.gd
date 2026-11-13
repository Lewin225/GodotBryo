@tool
class_name ActorSkinning
extends Node

## Binds skinned NIF parts to an actor's skeleton. A child of the actor node
## (esm_actor_node.tscn); the actor node calls it for body parts, skinned
## head parts and skinned equipment alike.

## Whether any mesh under `root` carries a skin with binds.
func tree_has_skin(root: Node3D) -> bool:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.skin != null and mesh.skin.get_bind_count() > 0:
			return true
	return false

# Gamebryo does not have the concept of skeletons in the way that Godot and other engines do.
# Gamebryo animations are simply targeted against NiNodes (Node3D) and skinned meshes target
# NiNodes like you would target a bone. NifServer detects possible skeletons and does the
# conversion for us, but it also returns the original NiNodes the skeleton was built from,
# which have no function for us, so this collapses the unneeded ones.
## Flattens a skinned part to its meshes: each keeps its accumulated transform
## and becomes a direct child of `root`; the NiNodes between are freed.
func compact_external_skin_part(root: Node3D) -> void:
	if root == null or not tree_has_skin(root):
		return
	var leaves: Array[Dictionary] = []
	var stack: Array[Dictionary] = [{"node": root, "transform": Transform3D.IDENTITY}]
	while not stack.is_empty():
		var entry: Dictionary = stack.pop_back()
		var node := entry["node"] as Node
		var accumulated: Transform3D = entry["transform"]
		for child in node.get_children():
			var child_transform := accumulated
			if child is Node3D:
				child_transform = accumulated * (child as Node3D).transform
			stack.append({"node": child, "transform": child_transform})
		if node != root and node is MeshInstance3D:
			leaves.append({"mesh": node, "transform": accumulated})
	if leaves.is_empty():
		return
	# Detach every leaf before freeing the source nodes. Do not use global
	# transforms here: NifRoot's R_x(-90) conversion remains on the wrapper and
	# must not be composed into a child a second time.
	for leaf in leaves:
		var mesh := leaf["mesh"] as MeshInstance3D
		mesh.get_parent().remove_child(mesh)
	# Only the Node3D hierarchy is collapsed. Plain Node children stay: the
	# part's AnimationPlayer (its clip library) and ObjectAnimator, whose
	# animator bound the same mesh instances when the part was staged (a
	# Securitron's screen face scrolls through it).
	for child in root.get_children():
		if child is Node3D:
			child.free()
	for leaf in leaves:
		var mesh := leaf["mesh"] as MeshInstance3D
		root.add_child(mesh)
		mesh.transform = leaf["transform"]
	root.set_meta("esm_humanoid_external_skin_compacted", true)
	root.set_meta("esm_humanoid_external_skin_mesh_count", leaves.size())

## NifServer supplies named Skin binds for flat external skins but deliberately
## leaves MeshInstance3D.skeleton empty. This resolves those names against the
## actor's shared skeleton without altering any bind pose. False when a bind
## names a bone the skeleton lacks, or no mesh is skinned.
func bind_external_skins(root: Node3D, skeleton: Skeleton3D) -> bool:
	var found_skin := false
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.skin == null or mesh.skin.get_bind_count() == 0:
			continue
		found_skin = true
		for bind_index in mesh.skin.get_bind_count():
			if skeleton.find_bone(String(mesh.skin.get_bind_name(bind_index))) == -1:
				return false
		mesh.skeleton = mesh.get_path_to(skeleton)
		# A partitioned BSDismember shape keeps the old MeshInstance3D's
		# authored local transform on its Node3D source container. External
		# skins are still positioned solely by their bind poses, so reset that
		# exact replacement for the old mesh-local transform too.
		var partition_source := mesh.get_parent() as Node3D
		if mesh.has_meta("nif_dismember_source_shape") and partition_source != null \
				and not bool(root.get_meta("esm_humanoid_external_skin_compacted", false)):
			partition_source.transform = Transform3D.IDENTITY
		# External body/equipment skins are positioned solely by their bind poses
		# against the shared skeleton. Retaining this NIF node's local transform
		# would compose it a second time.
		mesh.transform = Transform3D.IDENTITY
	return found_skin

## Builds the Skeleton3D for a skeleton NIF that NifServer returned as plain
## nodes because the file declares no bones (Mister Gutsy, eyebots): every NIF
## node under `tree` becomes a bone with its local transform as the rest, and
## what hangs from a node (collision, meshes) moves to a BoneAttachment3D on
## its bone. The bones are what this actor's parts skin and attach to. Null
## when `tree` has no NIF node.
func build_skeleton_from_nodes(tree: Node3D) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	var bone_nodes: Array[Node3D] = []
	var top_nodes: Array[Node3D] = []
	for child in tree.get_children():
		if _is_nif_node(child):
			top_nodes.append(child)
			_add_node_bones(skeleton, child, -1, bone_nodes)
	if skeleton.get_bone_count() == 0:
		skeleton.free()
		return null
	tree.add_child(skeleton)
	skeleton.reset_bone_poses()
	var attachments := {}
	for node in bone_nodes:
		var bone := int(node.get_meta("actor_skeleton_bone"))
		for child in node.get_children():
			if bone_nodes.has(child):
				continue
			child.reparent(_attachment_for(skeleton, bone, attachments), false)
	for node in top_nodes:
		node.free()
	return skeleton


## Adds `node` and the NIF nodes under it as bones of `skeleton`, under
## `parent_bone` (-1 for a root), recording each in `bone_nodes`.
func _add_node_bones(skeleton: Skeleton3D, node: Node3D, parent_bone: int, bone_nodes: Array[Node3D]) -> void:
	var bone := skeleton.add_bone(_unique_bone_name(skeleton, NifNames.escape(String(node.get_meta(NifNames.META_NIF_NAME)))))
	skeleton.set_bone_rest(bone, node.transform)
	if parent_bone != -1:
		skeleton.set_bone_parent(bone, parent_bone)
	node.set_meta("actor_skeleton_bone", bone)
	bone_nodes.append(node)
	for child in node.get_children():
		if _is_nif_node(child):
			_add_node_bones(skeleton, child, bone, bone_nodes)


## Whether `node` is a plain NIF node (NiNode and its kin) rather than a mesh,
## collision body or other typed node.
func _is_nif_node(node: Node) -> bool:
	return node.get_class() == "Node3D" and node.has_meta(NifNames.META_NIF_NAME) \
			and String(node.get_meta("nif_block_type", "")).ends_with("Node")


func _unique_bone_name(skeleton: Skeleton3D, wanted: String) -> String:
	var name := wanted if not wanted.is_empty() else "Bone"
	var suffix := 1
	while skeleton.find_bone(name) != -1:
		name = "%s#%d" % [wanted, suffix]
		suffix += 1
	return name


func _attachment_for(skeleton: Skeleton3D, bone: int, cache: Dictionary) -> BoneAttachment3D:
	if cache.has(bone):
		return cache[bone]
	var attachment := BoneAttachment3D.new()
	attachment.bone_name = skeleton.get_bone_name(bone)
	attachment.name = "%sAttachment" % attachment.bone_name
	skeleton.add_child(attachment)
	attachment.bone_idx = bone
	cache[bone] = attachment
	return attachment


## Makes the skeleton NIF's node `nif_name`, which hangs from a bone through
## a BoneAttachment3D, a bone of its own under that bone (a part's Prn can
## name such a node: the sentry bot's Bip01 L Finger1, the robobrain's
## DomeRoot). Returns its bone, or -1 when the tree has no such node under a
## bone.
func add_skeleton_node_bone(skeleton_tree: Node3D, skeleton: Skeleton3D, nif_name: String) -> int:
	var existing := skeleton.find_bone(NifNames.escape(nif_name))
	if existing != -1:
		return existing
	var node := _find_nif_node(skeleton_tree, nif_name)
	if node == null:
		return -1
	var rest := node.transform
	var parent := node.get_parent()
	while parent != null and not parent is BoneAttachment3D:
		if parent == skeleton_tree or not parent is Node3D:
			return -1
		rest = (parent as Node3D).transform * rest
		parent = parent.get_parent()
	if parent == null:
		return -1
	return _add_bone(skeleton, NifNames.escape(nif_name), (parent as BoneAttachment3D).bone_idx, rest)


## Adds the bones a skinned part's binds name that `skeleton` lacks but the
## part carries as nodes of its own (the brahmin lamp's pole, the Cazador's
## wings): each under the bone of its nearest ancestor the skeleton has, at
## its transform relative to that ancestor. Call before
## compact_external_skin_part, which frees those nodes.
func add_part_bones(part_tree: Node3D, skeleton: Skeleton3D) -> void:
	for child in part_tree.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.skin == null:
			continue
		for bind_index in mesh.skin.get_bind_count():
			var bone_name := String(mesh.skin.get_bind_name(bind_index))
			if skeleton.find_bone(bone_name) != -1:
				continue
			var node := _find_nif_node(part_tree, NifNames.unescape(bone_name))
			if node != null:
				_ensure_part_bone(part_tree, skeleton, node)


func _ensure_part_bone(part_tree: Node3D, skeleton: Skeleton3D, node: Node3D) -> int:
	var bone_name := NifNames.escape(String(node.get_meta(NifNames.META_NIF_NAME)))
	var existing := skeleton.find_bone(bone_name)
	if existing != -1:
		return existing
	var parent := node.get_parent() as Node3D
	if parent == null or parent == part_tree or not parent.has_meta(NifNames.META_NIF_NAME):
		return -1
	var parent_bone := _ensure_part_bone(part_tree, skeleton, parent)
	if parent_bone == -1:
		return -1
	return _add_bone(skeleton, bone_name, parent_bone, node.transform)


func _add_bone(skeleton: Skeleton3D, bone_name: String, parent_bone: int, rest: Transform3D) -> int:
	var bone := skeleton.add_bone(bone_name)
	skeleton.set_bone_parent(bone, parent_bone)
	skeleton.set_bone_rest(bone, rest)
	# A new bone's pose is not its rest until set (see reset_bone_poses).
	skeleton.reset_bone_pose(bone)
	return bone


func _find_nif_node(root: Node, nif_name: String) -> Node3D:
	if nif_name.is_empty():
		return null
	for node in root.find_children("*", "Node3D", true, false):
		if String(node.get_meta(NifNames.META_NIF_NAME, "")) == nif_name:
			return node
	return null
