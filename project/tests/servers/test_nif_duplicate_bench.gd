extends Node

## Measurement, not a gate: warm NifTreeBuilder.build() against Node.duplicate()
## at 1, 10 and 100 instances, for outstanding_issues.md #11.
##
## The comparison is only meaningful warm. A cold build is dominated by archive
## read, NIF parse and texture decode -- work a built-tree cache also skips, so
## including it would measure the document cache rather than the thing in
## question. Every model here is therefore parsed and its textures made resident
## before the clock starts.

const COUNTS := [1, 10, 100]

## Chosen to span the shapes the builder produces rather than to be typical:
## a trivial prop, heavy architecture, a skinned body, and an animated door.
const MODELS := {
	"milkbottle01 (trivial prop)": "meshes/clutter/junk/milkbottle01.nif",
	"barracks01 (architecture)": "meshes/architecture/barracks/barracks01.nif",
	"upperbody (skin, no hierarchy)": "meshes/characters/_male/upperbody.nif",
	"stealthsuit_go (skin + Skeleton3D)": "meshes/nvdlc01/armor/stealthsuit/nvdlc01stealthsuit_go.nif",
	"vdoorslidingvault22 (animated)": "meshes/dungeons/vaultruined/doors/vdoorslidingvault22.nif",
}

const Builder := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")

var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func _load(path: String) -> NifSource:
	var r: Dictionary = ArchiveServer.read(path)
	if not bool(r["found"]):
		return null
	var src := NifSource.new()
	if not src.load(PackedByteArray(r["data"])):
		return null
	return src


## Every RID a tree holds that Godot's draw-list key is built from, plus the
## sub-resources a shared tree would be sharing.
func _resource_ids(root: Node) -> Dictionary:
	var out := {"mesh": [], "material": [], "shape": [], "anim": []}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				out["mesh"].append(mi.mesh.get_instance_id())
				for i in mi.mesh.get_surface_count():
					var m: Material = mi.mesh.surface_get_material(i)
					if m != null:
						out["material"].append(m.get_instance_id())
			for i in mi.get_surface_override_material_count():
				var m: Material = mi.get_surface_override_material(i)
				if m != null:
					out["material"].append(m.get_instance_id())
		elif n is CollisionShape3D:
			var cs := n as CollisionShape3D
			if cs.shape != null:
				out["shape"].append(cs.shape.get_instance_id())
		elif n is AnimationPlayer:
			var ap := n as AnimationPlayer
			for lib_name in ap.get_animation_library_list():
				var lib := ap.get_animation_library(lib_name)
				for a in lib.get_animation_list():
					out["anim"].append(lib.get_animation(a).get_instance_id())
	return out


func _count_nodes(root: Node) -> int:
	var n := 1
	for c in root.get_children():
		n += _count_nodes(c)
	return n


## Prints how a tree's skinned meshes bind, for the template and its copy alike.
func _report_skin(label: String, which: String, root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var nn: Node = stack.pop_back()
		for c in nn.get_children():
			stack.push_back(c)
		if nn is MeshInstance3D and (nn as MeshInstance3D).skin != null:
			var mi := nn as MeshInstance3D
			var target: Node = mi.get_node_or_null(mi.skeleton)
			print("  skin[%s] %-10s path='%s' -> %s  skin_id=%d  in_tree=%s" % [
				label.split(" ")[0], which, str(mi.skeleton),
				("null" if target == null else target.get_class()),
				mi.skin.get_instance_id(), str(mi.is_inside_tree())])
			return


## A tree carrying its own Skeleton3D binds skins through a NodePath. That path
## is relative, so a copy must resolve it to the copy's OWN skeleton and never
## to the template's -- the failure #11 flags as unverified.
func _check_skeleton_rebind(label: String, template: Node, copy: Node) -> void:
	var t_skel := _find(template, "Skeleton3D")
	if t_skel == null:
		return
	var c_skel := _find(copy, "Skeleton3D")
	check(c_skel != null and c_skel != t_skel, "%s: copy has its own Skeleton3D" % label)
	var bound := 0
	var stack: Array[Node] = [copy]
	while not stack.is_empty():
		var nn: Node = stack.pop_back()
		for c in nn.get_children():
			stack.push_back(c)
		if nn is MeshInstance3D:
			var mi := nn as MeshInstance3D
			if mi.skin == null or String(mi.skeleton) == "":
				continue
			var target: Node = mi.get_node_or_null(mi.skeleton)
			check(target == c_skel,
				"%s: skinned copy resolves to the COPY's skeleton, not the template's" % label)
			check(mi.skin == (_find_skin(template)),
				"%s: Skin resource is shared with the template" % label)
			bound += 1
	check(bound > 0, "%s: at least one skin is bound through a NodePath (%d)" % [label, bound])


## duplicate() copies a BoneAttachment3D before the copy's Skeleton3D has its
## bones, and Godot logs "Bone index -1 out of range" while it does. The
## question is whether the copy is correct once parented, which is how a cached
## tree would actually be used -- bone_idx resolves on entering the tree, so
## both template and copy read -1 until then and comparing them detached proves
## nothing.
func _check_bone_attachments(label: String, template: Node, copy: Node) -> void:
	if _attachments(template).is_empty():
		return
	add_child(template)
	add_child(copy)
	var t_list := _attachments(template)
	var c_list := _attachments(copy)
	check(c_list.size() == t_list.size(),
		"%s: copy has the same %d BoneAttachment3D(s)" % [label, t_list.size()])
	var bad := 0
	var unresolved := 0
	for i in mini(t_list.size(), c_list.size()):
		var t: BoneAttachment3D = t_list[i]
		var c: BoneAttachment3D = c_list[i]
		if c.bone_idx < 0:
			unresolved += 1
		if c.bone_name != t.bone_name or c.bone_idx != t.bone_idx:
			bad += 1
			if bad <= 3:
				print("     attachment '%s': template bone='%s' idx=%d | copy bone='%s' idx=%d" % [
					t.name, t.bone_name, t.bone_idx, c.bone_name, c.bone_idx])
	check(bad == 0, "%s: parented copy's BoneAttachment3Ds match the template (%d differ)" % [label, bad])
	if unresolved > 0:
		print("     NOTE %d of %d attachments still resolve to bone -1 once parented, on BOTH trees"
			% [unresolved, c_list.size()])
	remove_child(template)
	remove_child(copy)


func _attachments(root: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is BoneAttachment3D:
			out.append(n)
		for c in n.get_children():
			stack.push_back(c)
	out.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
	return out


func _find(root: Node, klass: String) -> Node:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.is_class(klass):
			return n
		for c in n.get_children():
			stack.push_back(c)
	return null


func _find_skin(root: Node) -> Skin:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).skin != null:
			return (n as MeshInstance3D).skin
		for c in n.get_children():
			stack.push_back(c)
	return null


func _ready() -> void:
	await get_tree().process_frame
	print("--- NifServer #11: warm build() vs duplicate() ---")
	print("Godot %s | %s" % [Engine.get_version_info()["string"], OS.get_name()])

	for label in MODELS:
		var path: String = MODELS[label]
		var src := _load(path)
		if src == null:
			check(false, "load %s" % path)
			continue

		# Warm: parse is done, and this first build makes every texture resident
		# so no later build can pay a decode.
		var template: Node3D = await Builder.build(src)
		if template == null:
			check(false, "build %s" % path)
			continue
		var node_count := _count_nodes(template)

		print("\n%s" % label)
		print("  %d nodes" % node_count)
		print("  %-6s %12s %12s %10s" % ["N", "build ms", "dup ms", "speedup"])

		for n in COUNTS:
			# --- build path
			var made: Array[Node3D] = []
			var t0 := Time.get_ticks_usec()
			for i in n:
				made.append(await Builder.build(src))
			var build_us := Time.get_ticks_usec() - t0
			for x in made:
				x.free()

			# --- duplicate path
			var dups: Array[Node] = []
			t0 = Time.get_ticks_usec()
			for i in n:
				dups.append(template.duplicate())
			var dup_us := Time.get_ticks_usec() - t0
			for x in dups:
				x.free()

			print("  %-6d %12.3f %12.3f %9.2fx" % [
				n, build_us / 1000.0, dup_us / 1000.0,
				(float(build_us) / float(dup_us)) if dup_us > 0 else 0.0])

		# --- the claim the whole approach rests on: duplicate() shares
		# resources by reference rather than copying them.
		var fresh: Node3D = await Builder.build(src)
		var copy: Node = template.duplicate()
		var t_ids := _resource_ids(template)
		var d_ids := _resource_ids(copy)
		var f_ids := _resource_ids(fresh)
		for kind in t_ids:
			var t_list: Array = t_ids[kind]
			if t_list.is_empty():
				continue
			var shared: bool = d_ids[kind] == t_list
			var distinct := true
			for id in f_ids[kind]:
				if t_list.has(id):
					distinct = false
			check(shared, "%s: duplicate() shares all %d %s resource(s)" % [label, t_list.size(), kind])
			check(distinct, "%s: a fresh build()'s %s resources are all distinct" % [label, kind])
		# Skinned trees: MeshInstance3D.skeleton is a NodePath that has to
		# re-resolve inside the copy, which #11 flags as unverified. The
		# template is the control -- if it does not resolve either, the
		# NodePath is not a duplication problem.
		_report_skin(label, "template", template)
		_report_skin(label, "duplicate", copy)
		_check_skeleton_rebind(label, template, copy)
		_check_bone_attachments(label, template, copy)
		copy.free()
		fresh.free()
		template.free()

	print("\n=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
