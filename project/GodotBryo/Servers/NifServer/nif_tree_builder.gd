@tool
extends RefCounted
class_name NifTreeBuilder

## Builds a Godot tree from a NifSource document.
##
## This is the main-thread half of NifServer (Plans/NifServer/nif_server_v2.md
## sections 3 and 5), built directly on the nifly-backed NifSource rather than
## the legacy flattened loader -- which is what makes the section 3 node map
## possible at all: a node's block type is known, so a light becomes an
## OmniLight3D rather than yet another Node3D.
##
## Synchronous by design. Stage E adds the queue, budget and worker split; this
## exists so the tree can be looked at in the editor first.

const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")
# For cache_key() only, which is static -- the autoload instance is resolved
# separately because a static call cannot reach it.
const TextureServerScript := preload("res://GodotBryo/Servers/TextureServer/texture_server.gd")

## nif_server_v2.md section 1: the result is already Y-up and Godot-forward, so
## no consumer applies an axis correction afterwards.
const ROOT_BASIS := Basis(Vector3.RIGHT, -PI / 2.0)


## Every (path, alpha_safe) pair this file's materials will ask for, deduped.
## Used by _resolve_textures() so the warmed key and the looked-up key cannot
## drift apart.
static func _texture_refs(src: NifSource) -> Array:
	var refs: Array = []
	if src == null:
		return refs
	var seen := {}
	for nd in src.get_nodes():
		if not nd.has("positions"):
			continue
		var slots: PackedStringArray = nd["texture_slots"]
		if slots.is_empty():
			continue
		var alpha_safe := false
		if bool(nd.get("has_alpha_property", false)):
			alpha_safe = bool(nd["alpha_blend_enabled"]) or bool(nd["alpha_test_enabled"])
		var wanted: Array = _texture_slot_map(String(nd.get("texture_convention", "")))
		for i in wanted.size():
			var slot: int = wanted[i]
			if slot < 0 or slot >= slots.size() or String(slots[slot]).is_empty():
				continue
			# Only the diffuse carries the shape's alpha-safe requirement; a
			# normal or glow map is never the DXT1 punch-through case.
			var ref := {"path": String(slots[slot]), "alpha_safe": alpha_safe and i == 0}
			var key: String = TextureServerScript.cache_key(ref["path"], ref["alpha_safe"])
			if seen.has(key):
				continue
			seen[key] = true
			refs.append(ref)
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


## [diffuse, normal, glow] slot indices for a texture convention, -1 for a
## channel the convention does not carry. See _make_material.
static func _texture_slot_map(convention: String) -> Array:
	match convention:
		"texturing_property":
			return [0, 5, 4]
		"effect_shader":
			return [0, 1, -1]
	return [0, 1, 2]


static func build(src: NifSource, apply_root_basis: bool = true) -> Node3D:
	if src == null:
		return null
	# The only await in the whole builder. Textures are resolved up front so
	# every material below is built from an already-resident ImageTexture and
	# the node construction stays a straight synchronous pass.
	var textures: Dictionary = await _resolve_textures(src)
	var nodes: Array = src.get_nodes()
	var root := Node3D.new()
	root.name = "NifRoot"
	if apply_root_basis:
		root.transform = Transform3D(ROOT_BASIS, Vector3.ZERO)

	var built: Array[Node3D] = []
	built.resize(nodes.size())
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
			var node := _make_node(nd, textures)
			var authored := String(nd["name"])
			node.name = NifNamesScript.escape(authored) if not authored.is_empty() else "%s%d" % [String(nd["block_type"]), i]
			node.set_meta(NifNamesScript.META_NIF_NAME, authored)
			node.set_meta("nif_block_type", String(nd["block_type"]))
			node.set_meta("nif_block_index", int(nd["block_index"]))
			node.transform = nd["transform"]
			_apply_extra_data(node, nd)
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
	_build_collision(src, root, built, skeleton, bone_of_node, attachments, animated)
	return root


## Returns the single BoneAttachment3D for a bone, creating it on first use.
static func _attachment_for(skeleton: Skeleton3D, bone: int, cache: Dictionary) -> BoneAttachment3D:
	if cache.has(bone):
		return cache[bone]
	var attachment := BoneAttachment3D.new()
	attachment.bone_name = skeleton.get_bone_name(bone)
	attachment.name = "%sAttachment" % attachment.bone_name
	skeleton.add_child(attachment)
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
			skeleton.set_bone_rest(bone, nodes[i]["transform"])
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
		return _make_mesh_instance(nd, textures)
	return Node3D.new()


static func _make_mesh_instance(nd: Dictionary, textures: Dictionary) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var positions: PackedVector3Array = nd["positions"]
	var indices: PackedInt32Array = nd["indices"]
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
	mesh.surface_set_material(0, _make_material(nd, arrays[Mesh.ARRAY_COLOR] != null, textures))
	mi.mesh = mesh

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


## Vertex colour is not decoration in this content: Bethesda's unlit AO fades
## and glow overlays carry NO texture at all, so the per-vertex colour and its
## alpha are the only pixels the shape has. A StandardMaterial3D ignores
## ARRAY_COLOR unless `vertex_color_use_as_albedo` says otherwise, so without
## it those shapes render as solid opaque white quads.
static func _make_material(nd: Dictionary, has_vertex_colors: bool, textures: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.set_meta("nif_shader_type", String(nd["shader_type"]))

	if has_vertex_colors:
		mat.vertex_color_use_as_albedo = true

	# Alpha is resolved before the textures, because a blend- or test-enabled
	# shape needs its diffuse fetched through TextureServer's alpha-safe path.
	var blend_enabled := false
	var test_enabled := false
	if bool(nd.get("has_alpha_property", false)):
		blend_enabled = bool(nd["alpha_blend_enabled"])
		test_enabled = bool(nd["alpha_test_enabled"])
		_apply_alpha(mat, nd, blend_enabled, test_enabled)
	var alpha_safe := blend_enabled or test_enabled

	# Slot NUMBERS mean different things per convention, so the mapping is
	# picked from the block the slots came from rather than assumed. Reading a
	# NiTexturingProperty as if it were a BSShaderTextureSet is how a terminal
	# screen ends up with no albedo at all and renders solid white.
	var slots: PackedStringArray = nd["texture_slots"]
	var convention := String(nd.get("texture_convention", ""))
	mat.set_meta("nif_texture_convention", convention)
	# NiTexturingProperty is 0 base, 1 dark, 2 detail, 3 gloss, 4 glow, 5 bump,
	# 6-9 decal. Corpus-wide only `base` is ever occupied -- 4,701 of 4,701
	# shapes, with a single `dark` -- so the rest are mapped for correctness
	# rather than because anything ships them. BSEffectShaderProperty has no
	# glow slot at all.
	var map: Array = _texture_slot_map(convention)
	var diffuse_slot: int = map[0]
	var normal_slot: int = map[1]
	var glow_slot: int = map[2]

	if diffuse_slot < slots.size():
		mat.albedo_texture = _texture(textures, String(slots[diffuse_slot]), alpha_safe)
	if normal_slot >= 0 and normal_slot < slots.size():
		var normal := _texture(textures, String(slots[normal_slot]), false)
		if normal != null:
			mat.normal_enabled = true
			mat.normal_texture = normal
	if glow_slot >= 0 and glow_slot < slots.size():
		var glow := _texture(textures, String(slots[glow_slot]), false)
		if glow != null:
			mat.emission_enabled = true
			mat.emission_texture = glow
	# Everything else is read by the source but not rendered yet; recorded so
	# nothing is silently dropped.
	for i in slots.size():
		if i != diffuse_slot and i != normal_slot and i != glow_slot and String(slots[i]) != "":
			mat.set_meta("nif_texture_slot_%d" % i, String(slots[i]))

	# BSShaderNoLightingProperty is Bethesda's own signal that scene lighting
	# must not touch this shape. An AO fade's dark-to-transparent gradient
	# washes out to lit grey under ordinary shading, which is what NoLighting
	# exists to prevent.
	if String(nd["shader_type"]) == "BSShaderNoLightingProperty":
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


## NiAlphaProperty -> Godot transparency. Blend and test are separate bits and
## a shape can set either or both; blend takes precedence when both are on,
## since scissoring a blended gradient throws away the gradient.
static func _apply_alpha(mat: StandardMaterial3D, nd: Dictionary,
		blend_enabled: bool, test_enabled: bool) -> void:
	mat.set_meta("nif_alpha_blend_func", String(nd["alpha_blend_func"]))
	if blend_enabled:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# Light shafts and glow overlays ship src=SRC_ALPHA dst=ONE and are
		# genuinely additive; grime decals ship ZERO/SRC_COLOR and multiply.
		# Defaulting everything to mix loses both.
		match String(nd["alpha_blend_func"]):
			"add":
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			"multiply":
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_MUL
			_:
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	elif test_enabled:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		# Bethesda's alpha test is "keep if alpha > threshold"; Godot's scissor
		# discards below the threshold, so an authored 0 keeps everything and
		# the test becomes a no-op -- tree LOD billboards render as opaque
		# squares. 0.5 is Bethesda's own modal authored value (128/255).
		var threshold := float(nd["alpha_threshold"])
		mat.alpha_scissor_threshold = threshold if threshold > 0.0 else 0.5


## A lookup into what _resolve_textures() already awaited. No server call, no
## decode, no cache access -- by the time any material is built every texture
## this file needs is resident.
##
## `alpha_safe` selects TextureServer's DXT1 -> RGBA8 variant. Godot maps
## FORMAT_DXT1 to the BC1_RGB GPU format, which is opaque by spec, so BC1
## punch-through alpha is discarded by the sampler before any fragment shader
## runs -- alpha scissor then has nothing to cut and transparent texels render
## as the black they are encoded to. Not shader-fixable.
static func _texture(textures: Dictionary, path: String, alpha_safe: bool) -> ImageTexture:
	if path.is_empty():
		return null
	return textures.get(TextureServerScript.cache_key(path, alpha_safe))


static func _apply_extra_data(node: Node3D, nd: Dictionary) -> void:
	for x in nd["extra_data"]:
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
	if sequences.is_empty():
		return animated

	# Name -> node index. A block's own name wins; a NiDefaultAVObjectPalette
	# alias fills in only for names no block carries, which is the resolution
	# order section 8 established (280 of 26,022 entries disagree, and 97 of
	# those are the only way a live sequence finds its target).
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

	if library.get_animation_list().is_empty():
		if not unbound.is_empty():
			root.set_meta("nif_unbound_sequences", unbound)
		return animated

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	root.add_child(player)
	player.add_animation_library("", library)
	if not unbound.is_empty():
		player.set_meta("nif_unbound_sequences", unbound)
	return animated


## One Animation from one NiControllerSequence, or null when nothing in it
## resolves to a node in this file.
static func _make_animation(seq: Dictionary, index_of_name: Dictionary, root: Node3D,
		built: Array, skeleton: Skeleton3D, bone_of_node: Dictionary,
		animated: Dictionary) -> Animation:
	var anim := Animation.new()
	var start := float(seq["start_time"])
	var stop := float(seq["stop_time"])
	anim.length = maxf(stop - start, 0.001)
	match int(seq["cycle_type"]):
		0: anim.loop_mode = Animation.LOOP_LINEAR   # CYCLE_LOOP
		1: anim.loop_mode = Animation.LOOP_PINGPONG # CYCLE_REVERSE
		_: anim.loop_mode = Animation.LOOP_NONE     # CYCLE_CLAMP

	var tracks := 0
	for cb in seq["controlled_blocks"]:
		var ip: Dictionary = cb["interpolator"]
		if not bool(ip["present"]) or String(ip["kind"]) != "transform":
			# Float, bool, point3 and blend interpolators drive properties
			# rather than transforms; their addressing is the unsettled half
			# of section 7.3 and they are left to the caller for now.
			continue
		var target := String(cb["node_name"])
		if not index_of_name.has(target):
			continue
		var node_index := int(index_of_name[target])
		var base := _track_path(node_index, root, built, skeleton, bone_of_node)
		if base.is_empty():
			continue
		animated[node_index] = true
		tracks += _add_transform_tracks(anim, base, ip, start)

	if tracks == 0:
		return null
	# Sequence names, not text keys: NiTextKeyExtraData markers ("start",
	# "end", sound cues) are still outstanding, and are not these.
	anim.set_meta("nif_accum_root", String(seq["accum_root_name"]))
	anim.set_meta("nif_start_time", start)
	return anim


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


## Keys are authored in the node's own parent space and go in verbatim. Times
## are rebased to zero because Godot animations start there while a NIF
## sequence carries its own start time (recorded on the Animation as metadata).
static func _add_transform_tracks(anim: Animation, base: String, ip: Dictionary, start: float) -> int:
	var added := 0
	var resampled := bool(ip["resampled"])
	var pos_keys: Array = ip["translation_keys"]
	if not pos_keys.is_empty():
		var t := anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(t, NodePath(base))
		anim.track_set_interpolation_type(t, _track_interp(pos_keys, resampled))
		for k in pos_keys:
			anim.position_track_insert_key(t, maxf(float(k["time"]) - start, 0.0), Vector3(k["value"]))
		added += 1
	var rot_keys: Array = ip["rotation_keys"]
	if not rot_keys.is_empty():
		var t := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(t, NodePath(base))
		anim.track_set_interpolation_type(t, _track_interp(rot_keys, resampled))
		for k in rot_keys:
			anim.rotation_track_insert_key(t, maxf(float(k["time"]) - start, 0.0),
				(k["value"] as Quaternion).normalized())
		added += 1
	var scale_keys: Array = ip["scale_keys"]
	if not scale_keys.is_empty():
		var t := anim.add_track(Animation.TYPE_SCALE_3D)
		anim.track_set_path(t, NodePath(base))
		anim.track_set_interpolation_type(t, _track_interp(scale_keys, resampled))
		for k in scale_keys:
			var v := float(k["value"])
			anim.scale_track_insert_key(t, maxf(float(k["time"]) - start, 0.0), Vector3(v, v, v))
		added += 1
	return added


## Gamebryo interpolates PER KEY; Godot interpolates PER TRACK. The gap does
## not close, so this is a policy, not a mapping:
##
##   QUADRATIC / TBC  ->  CUBIC    the authored intent is "it stops softly".
##                                 Godot's cubic derives its curve from
##                                 neighbouring keys rather than the authored
##                                 tangents, which are not extracted -- close
##                                 enough for a designer's easing, and far
##                                 cheaper than baking a dense key run.
##   CONST            ->  LINEAR   DELIBERATE. A large share of the corpus is
##                                 authored stepped at the engine's ~30 Hz
##                                 update. That read as fine on a 360 and
##                                 reads as juddering on modern hardware;
##                                 smoothing it is an improvement, not a loss.
##   LINEAR / other   ->  LINEAR
##
## A mixed channel takes CUBIC only when eased keys are the MAJORITY. Cubic
## through keys authored linear invents overshoot at direction reversals,
## so the conservative side is the default one.
static func _track_interp(keys: Array, resampled: bool) -> int:
	if resampled:
		# Already sampled off a curve; the keys ARE the curve.
		return Animation.INTERPOLATION_LINEAR
	var eased := 0
	for k in keys:
		match String(k["interp"]):
			"quadratic", "tbc":
				eased += 1
	return Animation.INTERPOLATION_CUBIC if eased * 2 > keys.size() else Animation.INTERPOLATION_LINEAR


## Collision is built, never withheld (nif_server_v2.md section 5.3). Ragdoll
## bodies are tagged rather than turned into PhysicalBone3D here -- that needs
## a Skeleton3D pose driver, which belongs to the caller's assembly.
##
## A shape hangs off the node that OWNS it, not off the root. The owning node's
## transform is part of the shape's placement, and once a node is animated --
## a door panel, a lift platform -- collision parked at the root stays behind
## while the visual moves. An animated owner gets an AnimatableBody3D rather
## than a StaticBody3D, because a StaticBody3D that moves does not push
## anything it moves into.
static func _build_collision(src: NifSource, root: Node3D, built: Array,
		skeleton: Skeleton3D, bone_of_node: Dictionary, attachments: Dictionary,
		animated: Dictionary) -> void:
	var shapes: Array = src.get_collision_shapes()
	if shapes.is_empty():
		return
	var bodies: Array = src.get_collision_bodies()
	var body_of_owner := {}   # owning node index -> PhysicsBody3D
	for s in shapes:
		var shape := _make_shape(s)
		if shape == null:
			continue
		var owner_index := int(s["owning_node_index"])
		var parent := _collision_parent(owner_index, root, built, skeleton, bone_of_node, attachments)
		if parent == null:
			continue
		if not body_of_owner.has(owner_index):
			var b: PhysicsBody3D = AnimatableBody3D.new() if animated.has(owner_index) else StaticBody3D.new()
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
		container.add_child(cs)


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
			return tri
	return null
