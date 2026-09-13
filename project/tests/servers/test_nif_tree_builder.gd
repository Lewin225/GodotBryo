extends Node

## Builds real Godot trees from NifSource through NifTreeBuilder, asserts the
## section 3 node map holds, and writes a few scenes to disk for editor
## inspection.
##
## Preview scenes land in res://GodotBryo/Servers/NifServer/previews/ -- open
## any of them in the editor and walk the tree.

const NifTreeBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")
const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")
const PREVIEW_DIR := "res://GodotBryo/Servers/NifServer/previews"
const DOOR := "meshes/dungeons/vaultruined/doors/vdoorslidingvault22.nif"
const CONSOLE := "meshes/dungeons/vault/accessories/nvvwallconsole01.nif"
const TERMINAL := "meshes/terminals/terminaldesk01.nif"
const SIGN := "meshes/architecture/strip/newvegassign.nif"
const BILLBOARD := "meshes/effects/actorfirefx/fireball01.nif"

var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func _build(path: String) -> Node3D:
	var r: Dictionary = ArchiveServer.read(path)
	if not bool(r["found"]):
		return null
	var src := NifSource.new()
	if not src.load(PackedByteArray(r["data"])):
		return null
	return await NifTreeBuilderScript.build(src, true)


func _count(root: Node, type_name: String) -> int:
	var total := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.is_class(type_name):
			total += 1
		for c in n.get_children():
			stack.append(c)
	return total


func _find_first(root: Node, type_name: String) -> Node:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.is_class(type_name):
			return n
		for c in n.get_children():
			stack.append(c)
	return null


## Scans the catalog for a file containing a given block type. The node map is
## only meaningful if the rare types actually appear, so they are found rather
## than hard-coded.
func _find_file_with(block_type: String, limit: int = 6000) -> String:
	var scanned := 0
	for p in ArchiveServer.list_files_with_prefix("meshes/"):
		var sp := String(p)
		if not sp.ends_with(".nif"):
			continue
		scanned += 1
		if scanned > limit:
			break
		var r: Dictionary = ArchiveServer.read(sp)
		if not bool(r["found"]):
			continue
		var src := NifSource.new()
		if not src.load(PackedByteArray(r["data"])):
			continue
		for n in src.get_nodes():
			if String(n["block_type"]) == block_type:
				return sp
	return ""


func test_static_tree() -> void:
	print("--- static mesh tree ---")
	var root := await _build("meshes/architecture/barracks/barracks01.nif")
	check(root != null, "barracks01.nif built a tree")
	if root == null:
		return
	check(_count(root, "MeshInstance3D") == 10, "10 MeshInstance3D (got %d)" % _count(root, "MeshInstance3D"))
	check(_count(root, "StaticBody3D") == 1, "1 StaticBody3D")
	check(_count(root, "CollisionShape3D") == 1, "1 CollisionShape3D")

	var mi := _find_first(root, "MeshInstance3D") as MeshInstance3D
	check(mi.mesh != null and mi.mesh.get_surface_count() == 1, "mesh has one surface")
	var mat := mi.mesh.surface_get_material(0) as StandardMaterial3D
	check(mat != null, "surface carries a StandardMaterial3D")
	check(mat.albedo_texture != null, "diffuse texture resolved through TextureServer")
	check(mat.normal_texture != null, "normal map resolved")

	# Names must round-trip, and the authored name is always recoverable.
	var escaped_found := false
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.has_meta(NifNamesScript.META_NIF_NAME):
			var authored := String(n.get_meta(NifNamesScript.META_NIF_NAME))
			if authored != n.name:
				escaped_found = true
				check(NifNamesScript.unescape(String(n.name)) == authored,
					"'%s' round-trips from node name '%s'" % [authored, n.name]) if not escaped_found else null
		for c in n.get_children():
			stack.append(c)
	check(escaped_found, "at least one name needed escaping and round-trips")

	var cs := _find_first(root, "CollisionShape3D") as CollisionShape3D
	check(cs.shape is ConcavePolygonShape3D, "collision is a ConcavePolygonShape3D")
	check(String(cs.get_meta("nif_body_type", "")) == "bhkRigidBodyT", "collision records its body type")


func test_node_map() -> void:
	print("--- section 3 node map: block type drives the Godot class ---")
	var light_file := _find_file_with("NiPointLight")
	check(not light_file.is_empty(), "found a NIF with a NiPointLight (%s)" % light_file)
	if not light_file.is_empty():
		var root := await _build(light_file)
		check(_count(root, "OmniLight3D") > 0, "NiPointLight became an OmniLight3D (%d)" % _count(root, "OmniLight3D"))

	var cam_file := _find_file_with("NiCamera")
	check(not cam_file.is_empty(), "found a NIF with a NiCamera (%s)" % cam_file)
	if not cam_file.is_empty():
		var root := await _build(cam_file)
		check(_count(root, "Camera3D") > 0, "NiCamera became a Camera3D (%d)" % _count(root, "Camera3D"))

	var psys_file := _find_file_with("NiParticleSystem")
	check(not psys_file.is_empty(), "found a NIF with a NiParticleSystem (%s)" % psys_file)
	if not psys_file.is_empty():
		var root := await _build(psys_file)
		check(_count(root, "GPUParticles3D") > 0, "NiParticleSystem became a GPUParticles3D (%d)" % _count(root, "GPUParticles3D"))


func test_skinned_tree() -> void:
	print("--- skinned tree: named binds, skeleton unset ---")
	var root := await _build("meshes/characters/_male/upperbody.nif")
	check(root != null, "upperbody.nif built a tree")
	if root == null:
		return
	var skinned := 0
	var unset := 0
	var named := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).skin != null:
			skinned += 1
			var mi := n as MeshInstance3D
			if mi.skeleton == NodePath("") or mi.skeleton.is_empty():
				unset += 1
			if mi.skin.get_bind_count() > 0 and String(mi.skin.get_bind_name(0)) != "":
				named += 1
		for c in n.get_children():
			stack.append(c)
	check(skinned == 6, "6 skinned MeshInstance3D (got %d)" % skinned)
	check(unset == skinned, "every skin leaves `skeleton` unset (%d of %d)" % [unset, skinned])
	check(named == skinned, "every skin uses named binds (%d of %d)" % [named, skinned])


## A file whose declared bones form a hierarchy inside it contains a skeleton,
## so it returns one. A file whose bone list is flat is a skin awaiting a rig
## held elsewhere, and must not invent one.
func test_skeleton_emission() -> void:
	print("--- skeleton emission follows the file's own content ---")

	var skel := await _build("meshes/characters/_male/skeleton.nif")
	check(skel != null, "skeleton.nif built")
	if skel != null:
		var sk := _find_first(skel, "Skeleton3D") as Skeleton3D
		check(sk != null, "skeleton.nif returns a Skeleton3D")
		if sk != null:
			check(sk.get_bone_count() == 65, "65 bones (got %d)" % sk.get_bone_count())
			check(sk.find_bone("Bip01") != -1, "'Bip01' is a bone")
			check(sk.get_bone_parent(sk.find_bone("Bip01 NonAccum")) == sk.find_bone("Bip01"),
				"'Bip01 NonAccum' is parented to 'Bip01' -- a real hierarchy, not a flat list")
			# HeadAnims:0 is a NiTriShape parented to a bone; Godot reaches
			# that through a BoneAttachment3D.
			check(_count(skel, "BoneAttachment3D") > 0,
				"%d BoneAttachment3D for non-bone children of bones" % _count(skel, "BoneAttachment3D"))
			check(_count(skel, "MeshInstance3D") == 1, "the HeadAnims mesh survives (got %d)" % _count(skel, "MeshInstance3D"))

	# Self-contained skinned file: a ground object carries its own rig, so its
	# skin binds in place rather than being left for the caller.
	var go := await _build("meshes/armor/raiderarmor01/m/go.nif")
	check(go != null, "go.nif built")
	if go != null:
		var gsk := _find_first(go, "Skeleton3D") as Skeleton3D
		check(gsk != null, "ground object returns a Skeleton3D")
		var bound := 0
		var stack: Array = [go]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is MeshInstance3D and (n as MeshInstance3D).skin != null:
				if not (n as MeshInstance3D).skeleton.is_empty():
					bound += 1
			for c in n.get_children():
				stack.append(c)
		check(bound > 0, "%d skinned mesh bound to the file's own skeleton" % bound)

	# Flat bone list: the rig lives in another file, so none is invented.
	var body := await _build("meshes/characters/_male/upperbody.nif")
	if body != null:
		check(_find_first(body, "Skeleton3D") == null,
			"upperbody.nif returns NO Skeleton3D -- its bone list is flat")


func test_metadata() -> void:
	print("--- metadata carries what Godot has no construct for ---")
	var root := await _build("meshes/architecture/barracks/barracks01.nif")
	if root == null:
		return
	var with_block_type := 0
	var extras := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.has_meta("nif_block_type"):
			with_block_type += 1
		for k in n.get_meta_list():
			if String(k).begins_with("nif_extra_"):
				extras += 1
		for c in n.get_children():
			stack.append(c)
	check(with_block_type > 0, "%d nodes record their NIF block type" % with_block_type)
	check(extras > 0, "%d extra-data entries carried as metadata" % extras)


func test_animation() -> void:
	print("--- animated door: AnimationPlayer + collision placement ---")
	var root := await _build(DOOR)
	if root == null:
		check(false, "vdoorslidingvault22.nif built a tree")
		return
	check(true, "vdoorslidingvault22.nif built a tree")

	var player := _find_first(root, "AnimationPlayer") as AnimationPlayer
	check(player != null, "door returns an AnimationPlayer")
	if player == null:
		root.queue_free()
		return
	var clips := player.get_animation_list()
	check(clips.has("Open") and clips.has("Close"),
		"both authored sequences bound (got %s)" % [clips])

	var open := player.get_animation("Open")
	check(open != null and open.get_track_count() > 0, "'Open' carries tracks")
	if open != null:
		# The NIF says 0.00..1.33 s; Godot lengths start at zero.
		check(absf(open.length - 1.3333) < 0.01, "'Open' is %.4f s" % open.length)
		var moved := {}
		for t in open.get_track_count():
			var path := open.track_get_path(t)
			var target := root.get_node_or_null(NodePath(path))
			check(target != null, "track %d resolves to a node in the tree (%s)" % [t, path])
			if target != null:
				moved[target.name] = true
			# Keys are meters. A door panel travels under a meter, not tens.
			if open.track_get_type(t) == Animation.TYPE_POSITION_3D:
				for k in open.track_get_key_count(t):
					var v: Vector3 = open.track_get_key_value(t, k)
					check(v.length() < 10.0, "position key %d is in meters (%.3f m)" % [k, v.length()])
					break
		check(moved.size() == 2, "'Open' moves both panels (got %d)" % moved.size())
		# Gamebryo interpolates per key, Godot per track, so the mapping is a
		# policy. The door is authored linear on translation and rotation and
		# QUADRATIC on scale, which is exactly the split that policy makes.
		var by_type := {}
		for t in open.get_track_count():
			var kind := open.track_get_type(t)
			var mode := open.track_get_interpolation_type(t)
			by_type[kind] = by_type.get(kind, {})
			by_type[kind][mode] = int((by_type[kind] as Dictionary).get(mode, 0)) + 1
		var pos_modes: Dictionary = by_type.get(Animation.TYPE_POSITION_3D, {})
		var scale_modes: Dictionary = by_type.get(Animation.TYPE_SCALE_3D, {})
		check(pos_modes.get(Animation.INTERPOLATION_LINEAR, 0) == 2 and pos_modes.size() == 1,
			"linear-authored translation stays LINEAR (%s)" % [pos_modes])
		check(scale_modes.get(Animation.INTERPOLATION_CUBIC, 0) == 2 and scale_modes.size() == 1,
			"quadratic-authored scale becomes CUBIC (%s)" % [scale_modes])

	# The point of the restructure: an animated panel's collision travels with
	# it, so the body has to be a DESCENDANT of the panel, not a root sibling.
	var bodies := 0
	var under_animated := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.append(c)
		if not (node is PhysicsBody3D):
			continue
		bodies += 1
		var parent := node.get_parent()
		if parent != null and parent != root:
			under_animated += 1
			check(node is AnimatableBody3D or not _is_animated(player, root, parent),
				"%s under animated %s is an AnimatableBody3D" % [node.get_class(), parent.name])
	check(bodies > 0, "door has collision (%d bodies)" % bodies)
	check(under_animated > 0, "%d of %d bodies hang off their owning node, not the root" % [under_animated, bodies])
	root.queue_free()


## True when any track in any clip addresses `node`.
func _is_animated(player: AnimationPlayer, root: Node3D, node: Node) -> bool:
	var wanted := root.get_path_to(node)
	for name in player.get_animation_list():
		var anim := player.get_animation(name)
		for t in anim.get_track_count():
			if anim.track_get_path(t) == wanted:
				return true
	return false


func test_vertex_colour_and_alpha() -> void:
	print("--- vertex colour + NiAlphaProperty ---")
	var root := await _build(CONSOLE)
	if root == null:
		check(false, "nvvwallconsole01.nif built a tree")
		return
	check(true, "nvvwallconsole01.nif built a tree")

	var by_name := {}
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.append(c)
		if node is MeshInstance3D:
			by_name[node.name] = (node as MeshInstance3D).mesh.surface_get_material(0)
	check(by_name.size() == 3, "3 shapes (got %d)" % by_name.size())

	# Every shape in this file carries vertex colours, and Godot ignores
	# ARRAY_COLOR unless the material opts in.
	var vcol := 0
	for m in by_name.values():
		if (m as StandardMaterial3D).vertex_color_use_as_albedo:
			vcol += 1
	check(vcol == 3, "all 3 materials use vertex colour as albedo (got %d)" % vcol)

	# Block 16 is the case this exists for: an unlit, texture-less, blended
	# AO fade whose only pixels are per-vertex colour and alpha. Rendered
	# without either flag it is a solid opaque white quad.
	var fade: StandardMaterial3D = null
	for name in by_name.keys():
		var m: StandardMaterial3D = by_name[name]
		if m.albedo_texture == null:
			fade = m
			break
	check(fade != null, "found the texture-less shape")
	if fade == null:
		root.queue_free()
		return
	check(fade.vertex_color_use_as_albedo, "texture-less shape reads vertex colour")
	check(fade.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA,
		"blend-enabled shape is TRANSPARENCY_ALPHA (got %d)" % fade.transparency)
	check(fade.blend_mode == BaseMaterial3D.BLEND_MODE_MIX,
		"src=SRC_ALPHA dst=INV_SRC_ALPHA maps to MIX (got %d)" % fade.blend_mode)
	check(fade.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
		"BSShaderNoLightingProperty is unshaded (got %d)" % fade.shading_mode)
	root.queue_free()


func test_texture_conventions() -> void:
	print("--- NiTexturingProperty texture slots ---")
	var src := NifSource.new()
	var r: Dictionary = ArchiveServer.read(TERMINAL)
	if not bool(r["found"]) or not src.load(PackedByteArray(r["data"])):
		check(false, "loaded terminaldesk01.nif")
		return

	# A shape's slots carry different meanings per source block, so the source
	# reports WHICH block they came from rather than merging the conventions.
	var conventions := {}
	for n in src.get_nodes():
		if not n.has("positions"):
			continue
		conventions[String(n["texture_convention"])] = String((n["texture_slots"] as PackedStringArray)[0])
	check(conventions.has("shader_set"), "the desk body uses a BSShaderTextureSet")
	check(conventions.has("texturing_property"),
		"the screen uses a NiTexturingProperty (got %s)" % [conventions.keys()])
	check(String(conventions.get("texturing_property", "")).to_lower().contains("terminalscreen"),
		"its base slot resolves to the screen texture (%s)" % conventions.get("texturing_property", ""))

	# The failure this guards: reading NiTexturingProperty through the shader
	# set gate leaves the screen with no albedo at all -- a solid white quad.
	var root := await _build(TERMINAL)
	if root == null:
		check(false, "terminaldesk01.nif built a tree")
		return
	var textured := 0
	var shapes := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.append(c)
		if not (node is MeshInstance3D):
			continue
		shapes += 1
		var m: StandardMaterial3D = (node as MeshInstance3D).mesh.surface_get_material(0)
		if m.albedo_texture != null:
			textured += 1
	check(shapes == 2, "2 shapes (got %d)" % shapes)
	check(textured == 2, "both shapes resolved an albedo texture (got %d)" % textured)
	root.queue_free()


## Transform of `node` expressed in `root`'s frame. Deliberately walks local
## `.transform` rather than using global_transform: the tree is built off-tree,
## and global_transform requires is_inside_tree().
func _local_to(node: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


func test_collision_alignment() -> void:
	print("--- bhkRigidBodyT carries rotation, not just translation ---")
	var root := await _build(SIGN)
	if root == null:
		check(false, "newvegassign.nif built a tree")
		return
	var mesh_aabb := AABB()
	var col_aabb := AABB()
	var first_m := true
	var first_c := true
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.append(c)
		if node is MeshInstance3D:
			var a := _local_to(node, root) * (node as MeshInstance3D).mesh.get_aabb()
			mesh_aabb = a if first_m else mesh_aabb.merge(a)
			first_m = false
		elif node is CollisionShape3D:
			var sh: Shape3D = (node as CollisionShape3D).shape
			var pts := PackedVector3Array()
			if sh is ConcavePolygonShape3D:
				pts = (sh as ConcavePolygonShape3D).get_faces()
			elif sh is ConvexPolygonShape3D:
				pts = (sh as ConvexPolygonShape3D).points
			if pts.is_empty():
				continue
			var x := _local_to(node, root)
			var a := AABB(x * pts[0], Vector3.ZERO)
			for p in pts:
				a = a.expand(x * p)
			col_aabb = a if first_c else col_aabb.merge(a)
			first_c = false
	check(not first_m and not first_c, "the sign has both geometry and collision")
	if first_m or first_c:
		root.queue_free()
		return

	# The body's transform is a +90 degree rotation about X. Dropping it swaps
	# the collider's Y and Z extents against a 9 m tall sign, which this
	# catches: the size delta goes from ~0.3 m to ~10 m.
	var centre_delta := (mesh_aabb.get_center() - col_aabb.get_center()).length()
	var size_delta := (mesh_aabb.size - col_aabb.size).length()
	check(centre_delta < 0.5,
		"collision centre is within 0.5 m of the mesh (%.3f m)" % centre_delta)
	check(size_delta < 1.0,
		"collision extents match the mesh within 1 m (%.3f m)" % size_delta)
	# A simplified hull sits inside its render mesh, never outside it.
	check(col_aabb.size.length() <= mesh_aabb.size.length(),
		"the collision hull is no larger than the mesh")
	root.queue_free()


func test_ragdoll() -> void:
	print("--- E4 / section 5.3: bhkBlendCollisionObject becomes a ragdoll ---")
	var root := await _build("meshes/characters/_male/skeleton.nif")
	if root == null:
		check(false, "skeleton.nif built")
		return
	var sim: PhysicalBoneSimulator3D = null
	var bones: Array = []
	var shaped := 0
	var joints := {}
	var other_bodies := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is PhysicalBoneSimulator3D:
			sim = n
		elif n is PhysicalBone3D:
			bones.append(n)
			joints[n.joint_type] = int(joints.get(n.joint_type, 0)) + 1
			for c in n.get_children():
				if c is CollisionShape3D:
					shaped += 1
					break
		elif n is StaticBody3D or n is AnimatableBody3D:
			other_bodies += 1

	check(sim != null, "a PhysicalBoneSimulator3D is emitted")
	# The whole point of the simulator: an actor that never wants a ragdoll
	# pays nothing behaviourally and calls nothing.
	check(sim != null and not sim.is_simulating_physics(), "and it is inert until started")
	check(bones.size() == 18, "18 PhysicalBone3D, one per blend collision object (got %d)" % bones.size())
	check(shaped == bones.size(), "every bone carries a CollisionShape3D (%d of %d)" % [shaped, bones.size()])
	check(other_bodies == 0, "ordinary collision did not also build bodies for them (%d)" % other_bodies)

	# bhkMalleableConstraint wraps a ConstraintData whose own type selects the
	# live descriptor. Read as opaque it loses 14 of the rig's 17 joints.
	var cone: int = joints.get(PhysicalBone3D.JOINT_TYPE_CONE, 0)
	var hinge: int = joints.get(PhysicalBone3D.JOINT_TYPE_HINGE, 0)
	check(cone == 9, "9 ragdoll constraints became cone joints (got %d)" % cone)
	check(hinge == 8, "8 limited hinges became hinge joints (got %d)" % hinge)
	root.queue_free()


func test_billboard() -> void:
	print("--- E4 / section 5.3: NiBillboardNode becomes a self-orienting node ---")
	var src := NifSource.new()
	var r: Dictionary = ArchiveServer.read(BILLBOARD)
	if not bool(r["found"]) or not src.load(PackedByteArray(r["data"])):
		check(false, "loaded %s" % BILLBOARD)
		return
	var declared := 0
	for n in src.get_nodes():
		if not String(n["billboard_mode"]).is_empty():
			declared += 1
	check(declared > 0, "%d NiBillboardNode declared" % declared)

	var root := await _build(BILLBOARD)
	if root == null:
		return
	var billboards: Array = []
	var material_billboarded := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is NifBillboardNode:
			billboards.append(n)
		if not (n is MeshInstance3D):
			continue
		var mesh: Mesh = (n as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i) as BaseMaterial3D
			if mat != null and mat.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED:
				material_billboarded += 1

	check(billboards.size() == declared,
		"every NiBillboardNode became a NifBillboardNode (%d of %d)" % [billboards.size(), declared])
	# Gamebryo billboards the NODE and children follow rigidly. Doing it on the
	# material instead spins each mesh about its own origin, which breaks any
	# billboard holding several shapes or one shape offset from the node --
	# 46 of 203 in meshes/effects/. So the material must be left alone.
	check(material_billboarded == 0,
		"no material-level billboard is applied on top (%d)" % material_billboarded)
	if not billboards.is_empty():
		check(String((billboards[0] as NifBillboardNode).billboard_mode) == "bs_rotate_about_up",
			"the authored mode reaches the node (%s)" % (billboards[0] as NifBillboardNode).billboard_mode)
	root.queue_free()


func _set_owner_recursive(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		_set_owner_recursive(c, owner)


func write_previews() -> void:
	print("--- writing preview scenes ---")
	DirAccess.make_dir_recursive_absolute(PREVIEW_DIR)
	var cases := {
		"barracks01": "meshes/architecture/barracks/barracks01.nif",
		"upperbody_skinned": "meshes/characters/_male/upperbody.nif",
		"skeleton_ragdoll": "meshes/characters/_male/skeleton.nif",
		"milkbottle": "meshes/clutter/junk/milkbottle01.nif",
		"sliding_door_animated": DOOR,
		"wall_console_vertex_colour": CONSOLE,
		"terminal_desk_screen": TERMINAL,
		"newvegas_sign_collision": SIGN,
	}
	for name in cases.keys():
		var root := await _build(String(cases[name]))
		if root == null:
			check(false, "built preview for %s" % name)
			continue
		root.name = name
		_set_owner_recursive(root, root)
		var packed := PackedScene.new()
		var err := packed.pack(root)
		if err != OK:
			check(false, "packed %s (err %d)" % [name, err])
			continue
		var path := "%s/%s.tscn" % [PREVIEW_DIR, name]
		check(ResourceSaver.save(packed, path) == OK, "wrote %s" % path)
		root.queue_free()


func _ready() -> void:
	check(ArchiveServer.is_ready(), "ArchiveServer available")
	await test_static_tree()
	await test_node_map()
	await test_skinned_tree()
	await test_skeleton_emission()
	await test_metadata()
	await test_animation()
	await test_vertex_colour_and_alpha()
	await test_texture_conventions()
	await test_collision_alignment()
	await test_ragdoll()
	await test_billboard()
	await write_previews()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
