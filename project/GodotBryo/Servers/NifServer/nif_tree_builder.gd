@tool
extends RefCounted
class_name NifTreeBuilder

## Builds a Godot tree from a NifSource document.
##
## This is the main-thread half of NifServer (Plans/Completed Plans/NifServer/nif_server_v2.md
## sections 3 and 5), built directly on the nifly-backed NifSource rather than
## the legacy flattened loader -- which is what makes the section 3 node map
## possible at all: a node's block type is known, so a light becomes an
## OmniLight3D rather than yet another Node3D.
##
## Synchronous by design. Stage E adds the queue, budget and worker split; this
## exists so the tree can be looked at in the editor first.

const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")
const NifAnimationConverterScript := preload("res://GodotBryo/Servers/NifServer/nif_animation_converter.gd")
const NifObjectAnimatorScript := preload("res://GodotBryo/Servers/NifServer/nif_object_animator.gd")
## NiTimeController flags: bits 1-2 the cycle type (0 loop, 1 reverse, 2
## clamp, the encoding of a sequence's cycle type) and bit 3 active.
const FREE_CONTROLLER_TIMING_FLAGS := 0xE
const FREE_CONTROLLER_ACTIVE := 0x8
const NifBillboardNodeScript := preload("res://GodotBryo/Servers/NifServer/nif_billboard_node.gd")
# For cache_key() only, which is static -- the autoload instance is resolved
# separately because a static call cannot reach it.
const TextureServerScript := preload("res://GodotBryo/Servers/TextureServer/texture_server.gd")
const NifMaterialBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_material_builder.gd")

## nif_server_v2.md section 1: the result is already Y-up and Godot-forward, so
## no consumer applies an axis correction afterwards.
const ROOT_BASIS := Basis(Vector3.RIGHT, -PI / 2.0)

# BSDismemberBodyPartType names are format labels, not actor policy. They make
# the split tree inspectable while the raw integer remains the programmatic
# identity (including unknown values such as 65533 and 65535).
const DISMEMBER_PART_NAMES := {
	0: "BP_TORSO", 1: "BP_HEAD", 2: "BP_HEAD2", 3: "BP_LEFTARM", 4: "BP_LEFTARM2",
	5: "BP_RIGHTARM", 6: "BP_RIGHTARM2", 7: "BP_LEFTLEG", 8: "BP_LEFTLEG2",
	9: "BP_LEFTLEG3", 10: "BP_RIGHTLEG", 11: "BP_RIGHTLEG2", 12: "BP_RIGHTLEG3",
	13: "BP_BRAIN", 14: "BP_WEAPON",
	101: "BP_SECTIONCAP_HEAD", 102: "BP_SECTIONCAP_HEAD2", 103: "BP_SECTIONCAP_LEFTARM",
	104: "BP_SECTIONCAP_LEFTARM2", 105: "BP_SECTIONCAP_RIGHTARM", 106: "BP_SECTIONCAP_RIGHTARM2",
	107: "BP_SECTIONCAP_LEFTLEG", 108: "BP_SECTIONCAP_LEFTLEG2", 109: "BP_SECTIONCAP_LEFTLEG3",
	110: "BP_SECTIONCAP_RIGHTLEG", 111: "BP_SECTIONCAP_RIGHTLEG2", 112: "BP_SECTIONCAP_RIGHTLEG3",
	113: "BP_SECTIONCAP_BRAIN",
	201: "BP_TORSOCAP_HEAD", 202: "BP_TORSOCAP_HEAD2", 203: "BP_TORSOCAP_LEFTARM",
	204: "BP_TORSOCAP_LEFTARM2", 205: "BP_TORSOCAP_RIGHTARM", 206: "BP_TORSOCAP_RIGHTARM2",
	207: "BP_TORSOCAP_LEFTLEG", 208: "BP_TORSOCAP_LEFTLEG2", 209: "BP_TORSOCAP_LEFTLEG3",
	210: "BP_TORSOCAP_RIGHTLEG", 211: "BP_TORSOCAP_RIGHTLEG2", 212: "BP_TORSOCAP_RIGHTLEG3",
	213: "BP_TORSOCAP_BRAIN",
	1000: "BP_TORSOSECTION_HEAD", 2000: "BP_TORSOSECTION_HEAD2", 3000: "BP_TORSOSECTION_LEFTARM",
	4000: "BP_TORSOSECTION_LEFTARM2", 5000: "BP_TORSOSECTION_RIGHTARM", 6000: "BP_TORSOSECTION_RIGHTARM2",
	7000: "BP_TORSOSECTION_LEFTLEG", 8000: "BP_TORSOSECTION_LEFTLEG2", 9000: "BP_TORSOSECTION_LEFTLEG3",
	10000: "BP_TORSOSECTION_RIGHTLEG", 11000: "BP_TORSOSECTION_RIGHTLEG2", 12000: "BP_TORSOSECTION_RIGHTLEG3",
	13000: "BP_TORSOSECTION_BRAIN",
}


## Every (path, alpha_safe) pair this file's materials will ask for, deduped.
## Used by _resolve_textures(); each shape's list comes from
## NifMaterialBuilder.texture_refs(), which build() looks textures up through,
## so the warmed key and the looked-up key cannot drift apart.
static func _texture_refs(src: NifSource) -> Array:
	var refs: Array = []
	if src == null:
		return refs
	var seen := {}
	for nd in src.get_nodes():
		if not nd.has("positions"):
			continue
		for shape_ref in NifMaterialBuilderScript.texture_refs(nd):
			var key: String = TextureServerScript.cache_key(shape_ref["path"], shape_ref["alpha_safe"])
			if seen.has(key):
				continue
			seen[key] = true
			refs.append({"path": shape_ref["path"], "alpha_safe": shape_ref["alpha_safe"]})
	return refs


## Warms every texture, then awaits them all. Returns cache key -> ImageTexture.
##
## The warms go out first, as a batch, so they queue and decode concurrently;
## awaiting request() one at a time without that would serialise the whole set
## behind one decode each. A texture already resident costs nothing here --
## request() returns without touching the queue.
static func _resolve_textures(src: NifSource) -> Dictionary:
	var out := {}
	var server := _texture_server()
	if server == null:
		return out
	var refs := _texture_refs(src)
	for ref in refs:
		server.warm(ref["path"], ref["alpha_safe"])
	for ref in refs:
		var key: String = TextureServerScript.cache_key(ref["path"], ref["alpha_safe"])
		out[key] = await server.request(ref["path"], ref["alpha_safe"])
	return out


static func _texture_server() -> Node:
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	return (loop as SceneTree).root.get_node_or_null("TextureServer")


## `prefer_static` asks for section 10's flattened form: one wrapper Node3D with
## one MeshInstance3D per mesh, authored hierarchy removed, each mesh keeping its
## own surfaces, materials and collision. It is a PREFERENCE, not an override --
## a file with dynamic content comes back hierarchical, because flattening it
## would discard the behaviour that makes it work.
##
## The decision is never silent: the returned root always carries
## `nif_flattened`, and when the answer is false, `nif_not_flattened_because`
## names the content that prevented it.
static func build(src: NifSource, apply_root_basis: bool = true,
		prefer_static: bool = false, profile_main_thread_construction: bool = false) -> Node3D:
	if src == null:
		return null
	var textures: Dictionary = await _resolve_textures(src)
	return build_from_textures(src, textures, apply_root_basis, prefer_static,
		profile_main_thread_construction)


## NifServer starts this asynchronous half freely, then sends its result back
## through its own time-budgeted main-thread queue. Keeping the await separate
## prevents a large group of texture completions from resuming synchronous tree
## construction together in one idle frame.
static func resolve_textures(src: NifSource) -> Dictionary:
	if src == null:
		return {}
	return await _resolve_textures(src)


## The synchronous half of build(). Call only from NifServer's controlled
## drain, after resolve_textures() has completed.
static func build_from_textures(src: NifSource, textures: Dictionary,
		apply_root_basis: bool = true, prefer_static: bool = false,
		profile_main_thread_construction: bool = false) -> Node3D:
	if src == null:
		return null
	# Everything below is synchronous Node/Resource construction. Capture this
	# exact post-texture section so NifServer can identify the work that holds a
	# frame, rather than merely the time a request spent awaiting textures.
	var construction_started_usec := Time.get_ticks_usec()
	var construction_frame := Engine.get_process_frames()
	var nodes: Array = src.get_nodes()
	var root := Node3D.new()
	root.name = "NifRoot"
	if apply_root_basis:
		root.transform = Transform3D(ROOT_BASIS, Vector3.ZERO)

	var built: Array[Node3D] = []
	built.resize(nodes.size())
	# A PhysicsBody must itself receive the animation transform. Godot updates
	# an AnimatableBody3D's physics RID when its own transform changes, but not
	# when only an ancestor is animated. Promote animated collision owners
	# before tracks are bound so both the visual subtree and its body move from
	# the same transform track.
	var animated_collision_owners := _animated_collision_owners(src, nodes)
	# Separate from `built`: a bone is "placed" but has no Node3D, so a null
	# entry in `built` cannot be used to mean "not yet processed".
	var placed := {}

	# A file whose declared bones form a hierarchy inside it contains a real
	# skeleton, so it returns one. A file whose bone list is flat is a skin
	# referencing a rig held elsewhere, and returns unresolved named binds
	# instead (nif_server_v2.md section 9). Measured across the corpus: 185
	# files carry a hierarchy, 881 do not.
	var skeleton: Skeleton3D = null
	var bone_of_node := {}   # node index -> bone index
	# One BoneAttachment3D per bone, shared by child nodes and by collision.
	var attachments := {}
	if src.has_bone_hierarchy():
		skeleton = _build_skeleton(nodes, bone_of_node)
		if skeleton != null:
			root.add_child(skeleton)

	# Real NIFs emit a parent before its children; tolerate any order anyway.
	var remaining := range(nodes.size())
	var progressed := true
	while not remaining.is_empty() and progressed:
		progressed = false
		var still: Array = []
		for i in remaining:
			var nd: Dictionary = nodes[i]
			var parent_index := int(nd["parent_index"])
			if parent_index != -1 and not placed.has(parent_index):
				still.append(i)
				continue
			if bone_of_node.has(i):
				# Already a Skeleton3D bone; no Node3D duplicate for it.
				built[i] = null
				placed[i] = true
				progressed = true
				continue
			var node: Node3D = _make_node(nd, textures)
			if animated_collision_owners.has(i):
				node = AnimatableBody3D.new()
				# AnimationPlayer owns this body's pose. Physics must receive that
				# authored transform, not feed its previous physics pose back over it.
				(node as AnimatableBody3D).sync_to_physics = false
			var authored := String(nd["name"])
			node.name = NifNamesScript.escape(authored) if not authored.is_empty() else "%s%d" % [String(nd["block_type"]), i]
			node.set_meta(NifNamesScript.META_NIF_NAME, authored)
			node.set_meta("nif_block_type", String(nd["block_type"]))
			node.set_meta("nif_block_index", int(nd["block_index"]))
			# Keep an authored file root in the returned hierarchy so it remains
			# inspectable, but do not apply its local transform. Bethesda's NIF
			# instancing rule (and the legacy mesh resolver) treats REFR as the
			# placement boundary; applying a stray root rotation on top flips a
			# subset of real assets, including NVFencePickBurntCor02. The raw
			# value stays visible for debugging rather than disappearing with the
			# policy.
			if bool(nd.get("is_file_root", false)):
				node.set_meta("nif_file_root", true)
				node.set_meta("nif_suppressed_file_root_transform", nd["transform"])
				node.transform = Transform3D.IDENTITY
			else:
				node.transform = nd["transform"]
			_apply_extra_data(node, nd)
			# The physical body is the authored NIF node. Preserve any specialised
			# visual node (mesh, light, billboard, etc.) as an identity child, so
			# it inherits the body's animated transform rather than competing with
			# it for the authored node slot.
			if animated_collision_owners.has(i):
				var visual := _make_node(nd, textures)
				# A partitioned NiTriShape is a Node3D container whose children are
				# still visual geometry, so `get_class() != Node3D` alone is no
				# longer enough to distinguish an inert authored node from a visual.
				if visual.get_class() != "Node3D" or nd.has("positions"):
					visual.name = "Visual"
					node.add_child(visual)
			if parent_index == -1:
				root.add_child(node)
			elif bone_of_node.has(parent_index):
				# Parented to a bone: Godot reaches that through a
				# BoneAttachment3D rather than by parenting to the bone itself.
				_attachment_for(skeleton, int(bone_of_node[parent_index]), attachments).add_child(node)
			elif built[parent_index] != null:
				built[parent_index].add_child(node)
			else:
				root.add_child(node)
			built[i] = node
			placed[i] = true
			progressed = true
		remaining = still

	if skeleton != null:
		_bind_skins_to_skeleton(root, skeleton)
	# Animations first: which nodes move decides what kind of body their
	# collision hangs from, and collision now hangs off those nodes.
	var animated := _build_animations(src, root, nodes, built, skeleton, bone_of_node)
	# Ragdoll first: it claims its owning nodes so ordinary collision does not
	# also build a StaticBody3D for them.
	var ragdolled := _build_ragdoll(src, nodes, skeleton, bone_of_node)
	_build_collision(src, root, built, skeleton, bone_of_node, attachments, animated, ragdolled)

	if prefer_static:
		var blocker := _dynamic_content(root)
		root.set_meta("nif_flattened", blocker.is_empty())
		if blocker.is_empty():
			_flatten(root)
		else:
			root.set_meta("nif_not_flattened_because", blocker)
	if profile_main_thread_construction:
		root.set_meta("nif_main_thread_build_usec", Time.get_ticks_usec() - construction_started_usec)
		root.set_meta("nif_main_thread_build_frame", construction_frame)
	return root


## Names in controller sequences are resolved exactly as animation binding
## resolves them below: authored block names win, and the object palette fills
## only gaps. This runs before the tree exists so animated collision owners can
## become the physics body that receives the transform track.
static func _animation_name_index(src: NifSource, nodes: Array) -> Dictionary:
	var index_of_name := {}
	var node_of_block := {}
	for i in nodes.size():
		var authored := String(nodes[i]["name"])
		node_of_block[int(nodes[i]["block_index"])] = i
		if not authored.is_empty() and not index_of_name.has(authored):
			index_of_name[authored] = i
	for palette in src.get_object_palettes():
		for entry in palette["entries"]:
			var alias := String(entry["name"])
			var block := int(entry["object_block_index"])
			if alias.is_empty() or block < 0 or index_of_name.has(alias):
				continue
			if node_of_block.has(block):
				index_of_name[alias] = node_of_block[block]
	return index_of_name


## A node is promoted only when it both owns a shape and has an emitted
## transform track. A transform controller with no keys is an authored static
## pose and needs no dynamic body.
static func _animated_collision_owners(src: NifSource, nodes: Array) -> Dictionary:
	var collision_owners := {}
	for shape in src.get_collision_shapes():
		collision_owners[int(shape["owning_node_index"])] = true
	if collision_owners.is_empty():
		return {}
	var index_of_name := _animation_name_index(src, nodes)
	var out := {}
	for sequence in src.get_sequences():
		for controlled in sequence["controlled_blocks"]:
			var interpolator: Dictionary = controlled["interpolator"]
			if not bool(interpolator["present"]) or String(interpolator["kind"]) != "transform":
				continue
			var has_transform_keys := not (interpolator["translation_keys"] as Array).is_empty() \
				or not (interpolator["rotation_keys"] as Array).is_empty() \
				or not (interpolator["scale_keys"] as Array).is_empty()
			if not has_transform_keys:
				continue
			var target := String(controlled["node_name"])
			if index_of_name.has(target):
				var node_index := int(index_of_name[target])
				if collision_owners.has(node_index):
					out[node_index] = true
	return out


## What in this tree stops it being flattened, or "" if nothing does.
##
## Each of these is behaviour that lives in the hierarchy: collapsing the
## hierarchy discards it. A caller that genuinely wants the geometry regardless
## can flatten the result itself -- that is its decision to make, with the
## consequence visible.
static func _dynamic_content(root: Node3D) -> String:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is AnimationPlayer:
			return "AnimationPlayer"
		if n is NifBillboardNode:
			return "NiBillboardNode"
		if n is PhysicalBoneSimulator3D:
			return "ragdoll"
		if n is GPUParticles3D:
			return "particles"
		if n is AnimatableBody3D:
			return "animated collision"
		if n is NifRigidBody:
			return "rigid body"
		if n is Skeleton3D:
			return "Skeleton3D"
		if n is MeshInstance3D and (n as MeshInstance3D).skin != null:
			return "skinned mesh"
	return ""


## Section 10: one wrapper, one MeshInstance3D per mesh, hierarchy removed.
## NOT a mesh merge -- each keeps its own surfaces and materials. Transforms are
## composed onto each leaf so geometry lands where it did, relative to the
## wrapper; nothing is baked to world space. Furniture markers (Marker3D) are
## leaves too: they are positions, not behaviour held in the hierarchy.
static func _flatten(root: Node3D) -> void:
	var leaves: Array = []
	var stack: Array = [{ "node": root, "xform": Transform3D.IDENTITY }]
	while not stack.is_empty():
		var entry: Dictionary = stack.pop_back()
		var node: Node = entry["node"]
		for c in node.get_children():
			var child_xform: Transform3D = entry["xform"]
			if c is Node3D:
				child_xform = child_xform * (c as Node3D).transform
			stack.append({ "node": c, "xform": child_xform })
		if node == root:
			continue
		if node is MeshInstance3D or node is CollisionShape3D or node is Marker3D:
			leaves.append({ "node": node, "xform": entry["xform"] })

	# Collision keeps one body, since the hierarchy that separated bodies per
	# owning node is exactly what is being removed.
	var body: StaticBody3D = null
	for leaf in leaves:
		var node: Node3D = leaf["node"]
		node.get_parent().remove_child(node)
		node.transform = leaf["xform"]
		if node is CollisionShape3D:
			if body == null:
				body = StaticBody3D.new()
				body.name = "Collision"
				root.add_child(body)
			body.add_child(node)
		else:
			root.add_child(node)

	# Everything the leaves used to hang from is now empty.
	for c in root.get_children():
		if c == body:
			continue
		if c is MeshInstance3D or c is Marker3D:
			continue
		c.free()


## Section 5.3: bhkBlendCollisionObject is the ragdoll discriminator -- 60 files,
## 56 of them named skeleton*.nif. Not the presence of a constraint: 164 files
## carry one without being a ragdoll.
##
## The bodies go under a PhysicalBoneSimulator3D, which is inert until
## physical_bones_start_simulation(), so an actor that never wants a ragdoll
## pays nothing behaviourally and calls nothing.
##
## Returns the set of node indices claimed, so _build_collision skips them.
static func _build_ragdoll(src: NifSource, nodes: Array, skeleton: Skeleton3D,
		bone_of_node: Dictionary) -> Dictionary:
	var claimed := {}
	if skeleton == null:
		# A ragdoll needs bones to hang off. A file declaring blend collision
		# without a hierarchy is a skin whose rig lives elsewhere, and its
		# collision stays ordinary rather than being invented into a ragdoll.
		return claimed
	var wanted := {}
	for i in nodes.size():
		if String(nodes[i]["collision_type"]) == "bhkBlendCollisionObject" and bone_of_node.has(i):
			wanted[i] = true
	if wanted.is_empty():
		return claimed

	var bodies: Array = src.get_collision_bodies()
	var shapes_by_owner := {}
	for cs in src.get_collision_shapes():
		var owner := int(cs["owning_node_index"])
		if not wanted.has(owner):
			continue
		if not shapes_by_owner.has(owner):
			shapes_by_owner[owner] = []
		(shapes_by_owner[owner] as Array).append(cs)

	var simulator := PhysicalBoneSimulator3D.new()
	simulator.name = "PhysicalBoneSimulator3D"
	skeleton.add_child(simulator)

	for i in wanted.keys():
		var bone := int(bone_of_node[i])
		var bone_name := skeleton.get_bone_name(bone)
		var phys := PhysicalBone3D.new()
		phys.name = "Physical_%s" % bone_name
		phys.bone_name = bone_name

		var body: Dictionary = {}
		for cs in shapes_by_owner.get(i, []):
			var bi := int(cs["body_index"])
			if bi >= 0 and bi < bodies.size():
				body = bodies[bi]
				break
		if not body.is_empty():
			phys.mass = maxf(float(body["mass"]), 0.001)
			phys.friction = float(body["friction"])
			phys.bounce = float(body["restitution"])
			phys.linear_damp = float(body["linear_damping"])
			phys.angular_damp = float(body["angular_damping"])
			_apply_ragdoll_joint(phys, body)

		simulator.add_child(phys)
		for cs in shapes_by_owner.get(i, []):
			var shape := _make_shape(cs)
			if shape == null:
				continue
			var col := CollisionShape3D.new()
			col.name = "%s_%d" % [String(cs["kind"]), int(cs["block_index"])]
			col.shape = shape
			phys.add_child(col)
		claimed[i] = true
	return claimed


## Constraint -> joint. A bhkRagdollConstraint is a cone-twist; a limited hinge
## is a hinge. Anything else leaves the bone jointless rather than guessing.
static func _apply_ragdoll_joint(phys: PhysicalBone3D, body: Dictionary) -> void:
	var constraints: Array = body.get("constraints", [])
	for c in constraints:
		match String(c["kind"]):
			"ragdoll":
				phys.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
				# pivot_a is the joint in THIS body's frame and is zero across
				# the corpus -- the joint sits at the bone's own origin, which
				# is what Godot's joint_offset means. pivot_b is the same point
				# in the parent's frame and is kept rather than dropped.
				phys.joint_offset = Transform3D(Basis.IDENTITY, Vector3(c["pivot_a"]))
				phys.set_meta("nif_joint_pivot_parent", Vector3(c["pivot_b"]))
				phys.set_meta("nif_cone_max_angle", float(c["cone_max_angle"]))
				phys.set_meta("nif_twist_span", Vector2(float(c["twist_min_angle"]), float(c["twist_max_angle"])))
				return
			"hinge":
				phys.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
				phys.joint_offset = Transform3D(Basis.IDENTITY, Vector3(c["pivot_a"]))
				phys.set_meta("nif_joint_pivot_parent", Vector3(c["pivot_b"]))
				phys.set_meta("nif_hinge_span", Vector2(float(c["min_angle"]), float(c["max_angle"])))
				return
	phys.joint_type = PhysicalBone3D.JOINT_TYPE_NONE


## Returns the single BoneAttachment3D for a bone, creating it on first use.
static func _attachment_for(skeleton: Skeleton3D, bone: int, cache: Dictionary) -> BoneAttachment3D:
	if cache.has(bone):
		return cache[bone]
	var attachment := BoneAttachment3D.new()
	attachment.bone_name = skeleton.get_bone_name(bone)
	attachment.name = "%sAttachment" % attachment.bone_name
	skeleton.add_child(attachment)
	# The template is built out of the tree, where setting bone_name alone
	# leaves bone_idx at -1; every duplicate() of it then sets -1 and warns.
	# Setting the index under its skeleton stores the real one.
	attachment.bone_idx = bone
	cache[bone] = attachment
	return attachment


## Builds the Skeleton3D from the file's own declared bones, plus any ancestor
## needed to keep the chain intact. Bone names go through the same reversible
## escape as node names, so a skin's named binds resolve against them.
static func _build_skeleton(nodes: Array, bone_of_node: Dictionary) -> Skeleton3D:
	var wanted := {}
	for i in nodes.size():
		if not bool(nodes[i]["is_declared_bone"]):
			continue
		# Walk up so a declared bone's parents exist to hang it from.
		var walk := i
		while walk != -1 and not wanted.has(walk):
			wanted[walk] = true
			walk = int(nodes[walk]["parent_index"])
	if wanted.is_empty():
		return null

	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	var remaining: Array = wanted.keys()
	remaining.sort()
	var progressed := true
	while not remaining.is_empty() and progressed:
		progressed = false
		var still: Array = []
		for i in remaining:
			var parent_index := int(nodes[i]["parent_index"])
			if parent_index != -1 and wanted.has(parent_index) and not bone_of_node.has(parent_index):
				still.append(i)
				continue
			var authored := String(nodes[i]["name"])
			var bone := skeleton.add_bone(NifNamesScript.escape(authored) if not authored.is_empty() else "Bone%d" % i)
			# A declared file-root bone follows the same instancing policy as an
			# ordinary file-root Node3D. Retain its raw rest transform as skeleton
			# metadata because bones have no individual metadata channel.
			var raw_rest: Transform3D = nodes[i]["transform"]
			if bool(nodes[i].get("is_file_root", false)):
				skeleton.set_meta("nif_suppressed_file_root_bone_rest_%d" % i, raw_rest)
				raw_rest = Transform3D.IDENTITY
			skeleton.set_bone_rest(bone, raw_rest)
			if parent_index != -1 and bone_of_node.has(parent_index):
				skeleton.set_bone_parent(bone, int(bone_of_node[parent_index]))
			bone_of_node[i] = bone
			progressed = true
		remaining = still

	# Godot's per-bone POSE does not default to the rest transform: without
	# this every bone sits at the world origin and anything skinned to it
	# collapses into a tube.
	skeleton.reset_bone_poses()
	return skeleton


## Points a skinned mesh at the file's own skeleton when every bone it names is
## present there. A mesh naming a bone this file does not have is left unbound
## for the caller to resolve at assembly time.
static func _bind_skins_to_skeleton(root: Node3D, skeleton: Skeleton3D) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.append(c)
		if not (node is MeshInstance3D):
			continue
		var mi := node as MeshInstance3D
		if mi.skin == null:
			continue
		var all_present := true
		for b in mi.skin.get_bind_count():
			if skeleton.find_bone(String(mi.skin.get_bind_name(b))) == -1:
				all_present = false
				break
		if all_present and mi.skin.get_bind_count() > 0:
			mi.skeleton = mi.get_path_to(skeleton)


## Section 3's node map. Only four Godot classes carry behaviour; everything
## else is a Node3D with its block type recorded in metadata.
static func _make_node(nd: Dictionary, textures: Dictionary) -> Node3D:
	var block_type := String(nd["block_type"])
	match block_type:
		"NiBillboardNode":
			# Section 5.3 said material state, which is only equivalent when a
			# billboard node holds exactly one shape at its own origin. Across
			# meshes/effects/ 46 of 203 do not -- 35 hold several shapes that
			# would counter-rotate, 11 hold one offset by up to 4.75 m. So this
			# is a node that orients itself, as Gamebryo does.
			var billboard := NifBillboardNodeScript.new()
			billboard.billboard_mode = String(nd["billboard_mode"])
			return billboard
		"NiCamera":
			return Camera3D.new()
		"NiPointLight":
			var light := OmniLight3D.new()
			light.omni_range = 5.0
			return light
		"NiAmbientLight":
			# No per-object ambient light exists in Godot; carried as metadata.
			return Node3D.new()
		"NiParticleSystem", "BSStripParticleSystem":
			var particles := GPUParticles3D.new()
			particles.emitting = false
			return particles
	if nd.has("positions"):
		if _has_dismember_partitions(nd):
			return _make_dismember_partition_node(nd, textures)
		return _make_mesh_instance(nd, textures)
	return Node3D.new()


static func _has_dismember_partitions(nd: Dictionary) -> bool:
	if not nd.has("skin"):
		return false
	var skin: Dictionary = nd["skin"]
	return not (skin.get("dismember_partitions", []) as Array).is_empty()


static func _dismember_partition_name(part_id: int) -> String:
	return String(DISMEMBER_PART_NAMES.get(part_id, "Partition_%d" % part_id))


## A BSDismemberSkinInstance is attached to one NiTriShape, but its semantic
## partitions divide the shape's triangles. Retain the authored shape as this
## container and make each partition independently visible beneath it.
static func _make_dismember_partition_node(nd: Dictionary, textures: Dictionary) -> Node3D:
	var skin: Dictionary = nd["skin"]
	var partitions: Array = skin.get("dismember_partitions", [])
	var triangle_partitions: PackedInt32Array = skin.get("dismember_triangle_partitions", PackedInt32Array())
	var indices: PackedInt32Array = nd["indices"]
	@warning_ignore("integer_division")
	var triangle_count := indices.size() / 3
	if indices.size() % 3 != 0 or triangle_partitions.size() != triangle_count:
		push_warning("NifTreeBuilder: BSDismember partition map does not cover the source triangle list; keeping '%s' unsplit" % String(nd.get("name", "")))
		return _make_mesh_instance(nd, textures)
	for partition_index in triangle_partitions:
		if partition_index < 0 or partition_index >= partitions.size():
			push_warning("NifTreeBuilder: BSDismember partition map has an unassigned/invalid triangle; keeping '%s' unsplit" % String(nd.get("name", "")))
			return _make_mesh_instance(nd, textures)

	var grouped_indices: Array[PackedInt32Array] = []
	grouped_indices.resize(partitions.size())
	for partition_index in partitions.size():
		grouped_indices[partition_index] = PackedInt32Array()
	for triangle_index in triangle_count:
		var partition_index := triangle_partitions[triangle_index]
		var offset := triangle_index * 3
		grouped_indices[partition_index].append(indices[offset])
		grouped_indices[partition_index].append(indices[offset + 1])
		grouped_indices[partition_index].append(indices[offset + 2])

	var container := Node3D.new()
	var source_shape := String(nd.get("name", ""))
	for partition_index in partitions.size():
		var partition: Dictionary = partitions[partition_index]
		var part_id := int(partition.get("part_id", 0))
		var flags := int(partition.get("flags", 0))
		var mesh := _make_mesh_instance(nd, textures, grouped_indices[partition_index], true)
		mesh.name = _dismember_partition_name(part_id)
		mesh.set_meta("nif_dismember_part_id", part_id)
		mesh.set_meta("nif_dismember_partition_flags", flags)
		mesh.set_meta("nif_dismember_partition_index", partition_index)
		mesh.set_meta("nif_dismember_source_shape", source_shape)
		container.add_child(mesh)
	return container


static func _make_mesh_instance(nd: Dictionary, textures: Dictionary,
		indices_override: PackedInt32Array = PackedInt32Array(), has_indices_override := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var positions: PackedVector3Array = nd["positions"]
	var indices: PackedInt32Array = indices_override if has_indices_override else nd["indices"]
	if positions.is_empty() or indices.is_empty():
		return mi

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	var normals: PackedVector3Array = nd["normals"]
	if normals.size() == positions.size():
		arrays[Mesh.ARRAY_NORMAL] = normals
	var uvs: PackedVector2Array = nd["uvs"]
	if uvs.size() == positions.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	var colors: PackedColorArray = nd["colors"]
	if colors.size() == positions.size():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	if nd.has("skin"):
		var skin_desc: Dictionary = nd["skin"]
		var bi: PackedInt32Array = skin_desc["bone_indices"]
		var bw: PackedFloat32Array = skin_desc["bone_weights"]
		if bi.size() == positions.size() * 4 and bw.size() == bi.size():
			arrays[Mesh.ARRAY_BONES] = bi
			arrays[Mesh.ARRAY_WEIGHTS] = bw

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, NifMaterialBuilderScript.build(nd, arrays[Mesh.ARRAY_COLOR] != null, textures))
	mi.mesh = mesh
	# XEMI is placement data, so NifServer only identifies which authored
	# shapes consume it. The delivered tree's owner supplies the actual tint.
	mi.set_meta("nif_external_emittance",
		bool(nd.get("has_shader_flags", false)) and (int(nd.get("shader_flags1", 0)) & 0x20000000) != 0)

	if nd.has("skin"):
		# Named binds, skeleton deliberately unset: 86% of skinned NIFs carry a
		# flat bone list, so the rig belongs to the caller's assembly, not to
		# this file (nif_server_v2.md section 9).
		var skin := Skin.new()
		var names: PackedStringArray = (nd["skin"] as Dictionary)["bone_names"]
		var binds: Array = (nd["skin"] as Dictionary)["bind_transforms"]
		for i in names.size():
			# Escaped to match Skeleton3D bone names, which cannot contain ':'.
			skin.add_named_bind(NifNamesScript.escape(String(names[i])),
				binds[i] if i < binds.size() else Transform3D.IDENTITY)
		mi.skin = skin
		mi.set_meta("nif_skin_bones", names)
	return mi


static func _apply_extra_data(node: Node3D, nd: Dictionary) -> void:
	var furniture_index := 0
	# Every NiStringExtraData by its block name ("Prn", "UPB", ...): a node can
	# carry several, which the per-type metadata below keeps only the last of.
	var named_strings := {}
	for x in nd["extra_data"]:
		if String(x["block_type"]) == "NiStringExtraData" and x.has("string"):
			named_strings[String(x["name"])] = String(x["string"])
	if not named_strings.is_empty():
		node.set_meta("nif_string_extra_data", named_strings)
	for x in nd["extra_data"]:
		# BSFurnitureMarker: one Marker3D per position, in file order. The
		# orientation stays raw, as turning it into a rotation would pick a
		# sign convention the file does not state.
		for position: Dictionary in x.get("furniture_positions", []):
			var marker := Marker3D.new()
			marker.name = "FurnitureMarker%d" % furniture_index
			marker.position = Vector3(position["offset"])
			marker.set_meta("nif_furniture_orientation", int(position["orientation"]))
			marker.set_meta("nif_furniture_position_reference_1", int(position["position_reference_1"]))
			marker.set_meta("nif_furniture_position_reference_2", int(position["position_reference_2"]))
			node.add_child(marker)
			furniture_index += 1
		# "/" is a property-path separator in Godot and is rejected in a meta
		# name, so the block type is appended with an underscore instead.
		var key := "nif_extra_%s" % String(x["block_type"])
		if x.has("integer"):
			node.set_meta(key, int(x["integer"]))
		elif x.has("string"):
			node.set_meta(key, String(x["string"]))
		elif x.has("float"):
			node.set_meta(key, float(x["float"]))
		elif x.has("bounds_center"):
			node.set_meta(key, AABB(Vector3(x["bounds_center"]) - Vector3(x["bounds_half_extents"]),
				Vector3(x["bounds_half_extents"]) * 2.0))
		else:
			node.set_meta(key, String(x["name"]))


## Emits an AnimationPlayer for the sequences this file can actually play.
##
## A sequence addresses its targets by name (nif_server_v2.md section 8). When
## those names are nodes in THIS file -- doors, lifts, terminals, anything with
## its own NiControllerManager -- the clip is self-contained and is bound here.
## A KF addressing a rig assembled elsewhere resolves to nothing, and the
## sequence is recorded in metadata unbound rather than silently dropped: the
## caller retargets it against whatever it composed.
##
## Returns the set of node indices any track moves, as a Dictionary used as a
## set, because that decides what kind of body their collision needs.
static func _build_animations(src: NifSource, root: Node3D, nodes: Array, built: Array,
		skeleton: Skeleton3D, bone_of_node: Dictionary) -> Dictionary:
	var animated := {}
	var sequences: Array = src.get_sequences()
	var free_controllers: Array = src.get_free_controllers()
	if sequences.is_empty() and free_controllers.is_empty():
		return animated

	var index_of_name := _animation_name_index(src, nodes)

	var library := AnimationLibrary.new()
	var unbound := PackedStringArray()
	for seq in sequences:
		var anim := _make_animation(seq, index_of_name, root, built, skeleton, bone_of_node, animated)
		var seq_name := String(seq["name"])
		if seq_name.is_empty():
			seq_name = "Sequence%d" % int(seq["block_index"])
		if anim == null:
			unbound.append(seq_name)
			continue
		# ":" and "/" are illegal in an animation name, and authored sequence
		# names use neither -- but the same escape is applied for the same
		# reason it is applied to node names: so the mapping stays reversible.
		library.add_animation(NifNamesScript.escape(seq_name), anim)
	_add_free_controller_clips(library, free_controllers, index_of_name, root, built, skeleton,
		bone_of_node, animated)

	if library.get_animation_list().is_empty():
		if not unbound.is_empty():
			root.set_meta("nif_unbound_sequences", unbound)
		return animated

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	root.add_child(player)
	player.add_animation_library("", library)
	if NifObjectAnimatorScript.has_work(library):
		var object_animator: Node = NifObjectAnimatorScript.new()
		object_animator.name = NifObjectAnimatorScript.NODE_NAME
		root.add_child(object_animator)
	if not unbound.is_empty():
		player.set_meta("nif_unbound_sequences", unbound)
	return animated


## Adds a clip for each timing group of the file's free controllers
## (NifSource.get_free_controllers(): controllers no sequence drives, each on
## its own clock). Controllers whose start, stop, cycle type, frequency, phase
## and active bit all match share a clip, since they play on one clock; each
## other timing is its own clip, so every free controller is in the library
## whatever its length. Clips are named FreeControllers0.. in file order of
## their first controller, and carry `nif_free_controllers` (true),
## `nif_frequency`, `nif_phase`, `nif_active` and `nif_autoplay`: active and
## driving no declared bone (a rig's own free controllers are its pose, which
## the actor's animator owns). A clip that resolves nothing is left out.
static func _add_free_controller_clips(library: AnimationLibrary, free_controllers: Array,
		index_of_name: Dictionary, root: Node3D, built: Array, skeleton: Skeleton3D,
		bone_of_node: Dictionary, animated: Dictionary) -> void:
	var groups := {}
	var order: Array = []
	for fc in free_controllers:
		var key := "%f|%f|%d|%f|%f" % [float(fc["start_time"]), float(fc["stop_time"]),
			int(fc["flags"]) & FREE_CONTROLLER_TIMING_FLAGS, float(fc["frequency"]), float(fc["phase"])]
		if not groups.has(key):
			groups[key] = []
			order.append(key)
		(groups[key] as Array).append(fc)
	var clip_count := 0
	for key in order:
		var group: Array = groups[key]
		var first: Dictionary = group[0]
		var flags := int(first["flags"])
		var sequence := {
			"name": "FreeControllers%d" % clip_count,
			"start_time": float(first["start_time"]),
			"stop_time": float(first["stop_time"]),
			"cycle_type": (flags >> 1) & 0x3,
			"accum_root_name": "",
			"text_keys": [],
			"controlled_blocks": group,
		}
		var anim := _make_animation(sequence, index_of_name, root, built, skeleton, bone_of_node, animated)
		if anim == null:
			continue
		var drives_bone := false
		for fc in group:
			var target := String(fc["node_name"])
			if index_of_name.has(target) and bone_of_node.has(int(index_of_name[target])):
				drives_bone = true
		var active := (flags & FREE_CONTROLLER_ACTIVE) != 0
		anim.set_meta("nif_free_controllers", true)
		anim.set_meta("nif_frequency", float(first["frequency"]))
		anim.set_meta("nif_phase", float(first["phase"]))
		anim.set_meta("nif_active", active)
		anim.set_meta("nif_autoplay", active and not drives_bone)
		library.add_animation(String(sequence["name"]), anim)
		clip_count += 1


## One Animation from one NiControllerSequence, or null when nothing in it
## resolves to a node in this file. The block -> track rules are
## NifAnimationConverter's; this resolves the sequence's target names to the
## nodes built here, and records each node a transform track moves in
## `animated`.
static func _make_animation(seq: Dictionary, index_of_name: Dictionary, root: Node3D,
		built: Array, skeleton: Skeleton3D, bone_of_node: Dictionary,
		animated: Dictionary) -> Animation:
	var resolver := _tree_target.bind(index_of_name, root, built, skeleton, bone_of_node)
	var moved: Array = []
	var anim := NifAnimationConverterScript.build_animation(seq, resolver, moved)
	for target in moved:
		animated[int(index_of_name[target])] = true
	if anim.get_track_count() == 0:
		return null
	return anim


## A sequence target in this file: the built node's track path, whether it is
## a shape's MeshInstance3D, and whether it is a Skeleton3D bone; an empty
## Dictionary when the name is no node built here.
static func _tree_target(target: String, index_of_name: Dictionary, root: Node3D,
		built: Array, skeleton: Skeleton3D, bone_of_node: Dictionary) -> Dictionary:
	if not index_of_name.has(target):
		return {}
	var node_index := int(index_of_name[target])
	var path := _track_path(node_index, root, built, skeleton, bone_of_node)
	if path.is_empty():
		return {}
	var is_bone := bone_of_node.has(node_index)
	var is_shape := not is_bone and built[node_index] is MeshInstance3D
	return {"path": path, "shape": is_shape, "bone": is_bone}


## The NodePath an Animation track addresses a built node by. A bone is
## addressed as "Skeleton3D:BoneName", which is the only form Godot will apply
## to a Skeleton3D; an ordinary node by its own path.
static func _track_path(node_index: int, root: Node3D, built: Array,
		skeleton: Skeleton3D, bone_of_node: Dictionary) -> String:
	if bone_of_node.has(node_index):
		if skeleton == null:
			return ""
		return "%s:%s" % [root.get_path_to(skeleton), skeleton.get_bone_name(int(bone_of_node[node_index]))]
	if node_index < 0 or node_index >= built.size() or built[node_index] == null:
		return ""
	return String(root.get_path_to(built[node_index]))


## Collision is built, never withheld (nif_server_v2.md section 5.3). Ragdoll
## bodies are tagged rather than turned into PhysicalBone3D here -- that needs
## a Skeleton3D pose driver, which belongs to the caller's assembly.
##
## A shape hangs off the node that OWNS it, not off the root. The owning node's
## transform is part of the shape's placement, and once a node is animated --
## a door panel, a lift platform -- collision parked at the root stays behind
## while the visual moves. An animated owner gets an AnimatableBody3D rather
## than a StaticBody3D, because a StaticBody3D that moves does not push
## anything it moves into. A body whose motion system moves (MOVING_MOTION_SYSTEMS)
## on an owner that is not animated is a NifRigidBody, which moves its owner;
## every other body is a StaticBody3D. A caller that must not move, such as a
## STAT, freezes its NifRigidBodys.
static func _build_collision(src: NifSource, root: Node3D, built: Array,
		skeleton: Skeleton3D, bone_of_node: Dictionary, attachments: Dictionary,
		animated: Dictionary, ragdolled: Dictionary) -> void:
	var shapes: Array = src.get_collision_shapes()
	if shapes.is_empty():
		return
	var bodies: Array = src.get_collision_bodies()
	var body_of_owner := {}   # owning node index -> PhysicsBody3D
	var body_node_by_block := {}   # bhkRigidBody block index -> PhysicsBody3D
	for s in shapes:
		var shape := _make_shape(s)
		if shape == null:
			continue
		var owner_index := int(s["owning_node_index"])
		if ragdolled.has(owner_index):
			continue # already a PhysicalBone3D's shape
		var parent := _collision_parent(owner_index, root, built, skeleton, bone_of_node, attachments)
		if parent == null:
			continue
		if not body_of_owner.has(owner_index):
			# Promoted owners are already the dynamic body receiving animation
			# tracks directly. Do not nest another body beneath it: inherited
			# transforms look right in the editor but leave its physics RID behind.
			if parent is PhysicsBody3D:
				body_of_owner[owner_index] = parent
			else:
				var body_data := _body_data(bodies, int(s["body_index"]))
				var b: PhysicsBody3D
				if animated.has(owner_index):
					b = AnimatableBody3D.new()
				elif _is_moving(body_data):
					b = _make_rigid_body(body_data)
				else:
					b = StaticBody3D.new()
				b.name = "Collision"
				parent.add_child(b)
				body_of_owner[owner_index] = b
		var container: PhysicsBody3D = body_of_owner[owner_index]

		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.name = "%s_%d" % [String(s["kind"]), int(s["block_index"])]
		if owner_index >= 0 and owner_index < built.size() and built[owner_index] != null:
			cs.set_meta("nif_owning_node", built[owner_index].name)
		elif bone_of_node.has(owner_index) and skeleton != null:
			cs.set_meta("nif_owning_node", skeleton.get_bone_name(int(bone_of_node[owner_index])))
		var bi := int(s["body_index"])
		if bi >= 0 and bi < bodies.size():
			var b: Dictionary = bodies[bi]
			cs.set_meta("nif_body_type", String(b["block_type"]))
			cs.set_meta("nif_body_mass", float(b["mass"]))
			# bhkRigidBodyT means "the body carries its own transform"; plain
			# bhkRigidBody means the fields are there but inert. Both halves
			# of that transform matter -- taking the translation alone leaves
			# a rotated collider sitting square to its own mesh.
			if String(b["block_type"]) == "bhkRigidBodyT":
				cs.transform = Transform3D(Basis(b["rotation"] as Quaternion),
					Vector3(b["translation"]))
			body_node_by_block[int(b["block_index"])] = container
		container.add_child(cs)
	_build_joints(root, bodies, body_node_by_block)


## Constraint -> joint, for constraints between two bodies _build_collision
## built (ragdoll bones have their own path, _apply_ragdoll_joint). A hinge is a
## HingeJoint3D turning about the axle, limited when the constraint is a
## limited hinge: Havok measures its angle between the perpendicular axes
## axleInA1 and axleInB1, Godot from the pose at creation, so the limits are
## shifted by the authored angle. A ragdoll constraint is a ConeTwistJoint3D
## twisting about its twist axis, its swing span the cone angle and its twist
## span the larger twist limit; the plane limits have no Godot equivalent and
## stay in metadata. Other constraint types (prismatic, stiff spring,
## breakable) get no joint; their block types are listed in the root's
## `nif_unjoined_constraints`.
static func _build_joints(root: Node3D, bodies: Array, body_node_by_block: Dictionary) -> void:
	var unjoined: Array[String] = []
	for body_data: Dictionary in bodies:
		for c: Dictionary in body_data.get("constraints", []):
			var a := body_node_by_block.get(int(c.get("entity_a_block", -1))) as PhysicsBody3D
			var b := body_node_by_block.get(int(c.get("entity_b_block", -1))) as PhysicsBody3D
			if a == null or b == null or a == b:
				continue
			var joint := _make_joint(c, a, b, _body_frame(bodies, int(c["entity_a_block"])), _body_frame(bodies, int(c["entity_b_block"])))
			if joint == null:
				unjoined.append(String(c.get("block_type", "")))
				continue
			joint.name = "%s_%d" % [String(c.get("block_type", "Joint")), int(c.get("block_index", 0))]
			a.add_child(joint)
			joint.node_a = joint.get_path_to(a)
			joint.node_b = joint.get_path_to(b)
	if not unjoined.is_empty():
		root.set_meta("nif_unjoined_constraints", unjoined)


## A body's own frame relative to its node: bhkRigidBodyT's transform, or
## identity for a plain bhkRigidBody, whose fields are inert.
static func _body_frame(bodies: Array, block_index: int) -> Transform3D:
	for body_data: Dictionary in bodies:
		if int(body_data["block_index"]) != block_index:
			continue
		if String(body_data["block_type"]) == "bhkRigidBodyT":
			return Transform3D(Basis(body_data["rotation"] as Quaternion), Vector3(body_data["translation"]))
	return Transform3D.IDENTITY


## The joint for constraint `c` between `a` and `b`, as a child of `a` at
## pivot_a, or null for a type with no joint. `frame_a` and `frame_b` place
## each body's constraint frame relative to its node.
static func _make_joint(c: Dictionary, a: PhysicsBody3D, b: PhysicsBody3D, frame_a: Transform3D, frame_b: Transform3D) -> Joint3D:
	var kind := String(c.get("kind", ""))
	var pivot := Vector3(c["pivot_a"])
	var axis := (frame_a.basis * Vector3(c["axis_a"])).normalized()
	var perpendicular := (frame_a.basis * Vector3(c["plane_a"])).normalized()
	if axis == Vector3.ZERO:
		return null
	if kind == "hinge":
		var hinge := HingeJoint3D.new()
		# HingeJoint3D turns about its local Z.
		hinge.transform = Transform3D(_basis_with_axis(axis, perpendicular, 2), frame_a * pivot)
		if bool(c.get("limited", false)):
			var authored := _authored_hinge_angle(c, a, b, frame_a, frame_b, axis)
			hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
			hinge.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, float(c["min_angle"]) - authored)
			hinge.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, float(c["max_angle"]) - authored)
		hinge.set_meta("nif_hinge_limits", Vector2(float(c["min_angle"]), float(c["max_angle"])))
		return hinge
	if kind == "ragdoll":
		var cone := ConeTwistJoint3D.new()
		# ConeTwistJoint3D twists about its local X.
		cone.transform = Transform3D(_basis_with_axis(axis, perpendicular, 0), frame_a * pivot)
		cone.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, float(c["cone_max_angle"]))
		cone.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, maxf(absf(float(c["twist_min_angle"])), absf(float(c["twist_max_angle"]))))
		cone.set_meta("nif_plane_limits", Vector2(float(c["plane_min_angle"]), float(c["plane_max_angle"])))
		return cone
	return null


## An orthonormal basis whose axis `index` (0 X, 1 Y, 2 Z) is `axis`, with the
## next axis as close to `perpendicular` as `axis` allows.
static func _basis_with_axis(axis: Vector3, perpendicular: Vector3, index: int) -> Basis:
	var next := perpendicular - axis * perpendicular.dot(axis)
	if next.length() < 0.0001:
		next = axis.cross(Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT)
	next = next.normalized()
	var third := axis.cross(next)
	var columns := [axis, next, third]
	var x: Vector3 = columns[(3 - index) % 3]
	var y: Vector3 = columns[(4 - index) % 3]
	var z: Vector3 = columns[(5 - index) % 3]
	return Basis(x, y, z)


## The limited hinge's angle in the authored pose: from body A's perpendicular
## axis to body B's, about the axle, in A's node frame.
static func _authored_hinge_angle(c: Dictionary, a: Node3D, b: Node3D, frame_a: Transform3D, frame_b: Transform3D, axis: Vector3) -> float:
	var a_to_b := _relative(a, b)
	var perp_a := (frame_a.basis * Vector3(c["plane_a"])).normalized()
	var perp_b := (a_to_b.basis * frame_b.basis * Vector3(c["plane_b"])).normalized()
	return perp_a.signed_angle_to(perp_b, axis)


## `b`'s transform in `a`'s frame, through their common ancestors.
static func _relative(a: Node3D, b: Node3D) -> Transform3D:
	return _to_root(a).affine_inverse() * _to_root(b)


static func _to_root(node: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current is Node3D:
		result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


## Motion systems that move under simulation: 1 dynamic, 2 sphere inertia,
## 4 box inertia, 8 thin box. 6 is keyframed and 7 fixed; 3 and 5, the
## stabilized systems, do not exist in the game's Havok and behave as fixed.
const MOVING_MOTION_SYSTEMS := [1, 2, 4, 8]
## bhkRigidBody deactivator type 1: the body never comes to rest.
const DEACTIVATOR_NEVER := 1
## The share of a bhkRigidBody's restitution a NifRigidBody bounces with. At the
## authored values (0.4 on most items) Jolt bounces dropped items far more
## than the game does, where restitution is only partly applied.
const RESTITUTION_SCALE := 0.25


## The rigid body a shape belongs to, or an empty Dictionary.
static func _body_data(bodies: Array, body_index: int) -> Dictionary:
	if body_index < 0 or body_index >= bodies.size():
		return {}
	return bodies[body_index]


## Whether the body's motion system moves under simulation.
static func _is_moving(body_data: Dictionary) -> bool:
	return MOVING_MOTION_SYSTEMS.has(int(body_data.get("motion_system", 0)))


## A NifRigidBody with the bhkRigidBody's mass, friction, restitution (scaled by
## RESTITUTION_SCALE), damping
## and deactivation; it moves its parent with it. Mass 0
## means infinite mass, which no moving body in the corpus has; it is built as
## 1 kg.
static func _make_rigid_body(body_data: Dictionary) -> NifRigidBody:
	var body := NifRigidBody.new()
	var mass := float(body_data.get("mass", 0.0))
	body.mass = mass if mass > 0.0 else 1.0
	var material := PhysicsMaterial.new()
	material.friction = float(body_data.get("friction", 0.5))
	material.bounce = float(body_data.get("restitution", 0.0)) * RESTITUTION_SCALE
	body.physics_material_override = material
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = float(body_data.get("linear_damping", 0.0))
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = float(body_data.get("angular_damping", 0.0))
	body.can_sleep = int(body_data.get("deactivator_type", 0)) != DEACTIVATOR_NEVER
	body.motion_system = int(body_data.get("motion_system", 0))
	body.quality_type = int(body_data.get("quality_type", 0))
	body.solver_deactivation = int(body_data.get("solver_deactivation", 0))
	body.layer = int(body_data.get("layer", 0))
	return body


## Where a shape's body belongs: under its owning node, under that bone's
## BoneAttachment3D, or at the root when the owner is the root or unresolvable.
static func _collision_parent(owner_index: int, root: Node3D, built: Array,
		skeleton: Skeleton3D, bone_of_node: Dictionary, attachments: Dictionary) -> Node3D:
	if bone_of_node.has(owner_index):
		return _attachment_for(skeleton, int(bone_of_node[owner_index]), attachments) if skeleton != null else root
	if owner_index >= 0 and owner_index < built.size() and built[owner_index] != null:
		return built[owner_index]
	return root


static func _make_shape(s: Dictionary) -> Shape3D:
	match String(s["kind"]):
		"box":
			var b := BoxShape3D.new()
			b.size = Vector3(s["half_extents"]) * 2.0
			return b
		"sphere":
			var sp := SphereShape3D.new()
			sp.radius = maxf(float(s["radius"]), 0.001)
			return sp
		"capsule":
			var c := CapsuleShape3D.new()
			c.radius = maxf(float(s["capsule_radius"]), 0.001)
			c.height = maxf(Vector3(s["point_a"]).distance_to(Vector3(s["point_b"])), 0.001) + c.radius * 2.0
			return c
		"convex_hull":
			var pts: PackedVector3Array = s["positions"]
			if pts.is_empty():
				return null
			var ch := ConvexPolygonShape3D.new()
			ch.points = pts
			return ch
		"triangle_mesh":
			var verts: PackedVector3Array = s["positions"]
			var idx: PackedInt32Array = s["indices"]
			if verts.is_empty() or idx.is_empty():
				return null
			var faces := PackedVector3Array()
			faces.resize(idx.size())
			for i in idx.size():
				faces[i] = verts[idx[i]]
			var tri := ConcavePolygonShape3D.new()
			tri.set_faces(faces)
			# Havok accepts collision from either side of a triangle.  Shipped NIF
			# collision is consequently not consistently wound: many meshes have
			# alternating faces flipped.  Keep the authored topology intact and
			# let Godot test both sides, rather than doubling every triangle.
			tri.backface_collision = true
			return tri
	return null
