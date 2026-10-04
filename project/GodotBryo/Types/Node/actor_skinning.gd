@tool
class_name ActorSkinning
extends Node

## Binds skinned NIF parts to an actor's skeleton. A child of the actor node
## (esm_humanoid_actor.tscn); the actor node calls it for body parts, skinned
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
	for child in root.get_children():
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
