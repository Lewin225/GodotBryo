class_name GamebryoMeshResolver
extends RefCounted

## BSA-priority search + NIF/DDS resolution, shared by every object factory.
## Previously duplicated per-script across test_integration.gd, test_dds.gd,
## test_interior_cell.gd, cell_viewer.gd, and cell_viewer_editor.gd — worth
## extracting now that phases/1/01-object-type-registry.md's factories are
## real, reusable architecture rather than one-off test scripts. Same
## BSA-priority heuristic as native/tools/dump_object.cpp (Update.bsa, then
## DLC archives, then the base SArchiveList reversed) — see
## phases/0/results.md for why it's an approximation, not a load-order
## simulation.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

## Bethesda/Gamebryo world units are NOT meters (~70 units/m — see
## native/src/common/units.h for the sourced conversion and rationale). The
## conversion is applied at the true source, in the pure-C++ core
## (nif_loader.cpp's vertex/translation data, esm_file.cpp's REFR/SCOL
## position data) — NOT here. Every value this resolver hands back
## (positions, transforms) is already in meters by the time it reaches
## GDScript. Do not re-apply a scale on top of it.

var _bsa_readers := {}
var _bsa_order: Array[String] = []

func _init() -> void:
	_build_bsa_order()

func _build_bsa_order() -> void:
	var dir := DirAccess.open(DATA_DIR)
	var all_names: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.to_lower().ends_with(".bsa"):
			all_names.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	var remaining := all_names.duplicate()
	var ordered: Array[String] = []
	if remaining.has("Update.bsa"):
		ordered.append("Update.bsa")
		remaining.erase("Update.bsa")
	var dlc: Array[String] = []
	for n in remaining:
		if not n.begins_with("Fallout - "):
			dlc.append(n)
	dlc.sort()
	for n in dlc:
		ordered.append(n)
		remaining.erase(n)
	var base_order := ["Fallout - Misc.bsa", "Fallout - Sound.bsa", "Fallout - Voices1.bsa",
			"Fallout - Meshes.bsa", "Fallout - Textures2.bsa", "Fallout - Textures.bsa"]
	for n in base_order:
		if remaining.has(n):
			ordered.append(n)
			remaining.erase(n)
	remaining.sort()
	for n in remaining:
		ordered.append(n)
	_bsa_order = ordered

func _get_reader(bsa_name: String) -> BsaReader:
	if _bsa_readers.has(bsa_name):
		return _bsa_readers[bsa_name]
	var r := BsaReader.new()
	if not r.open(DATA_DIR + bsa_name):
		_bsa_readers[bsa_name] = null
		return null
	_bsa_readers[bsa_name] = r
	return r

## Returns { "bsa": String, "data": PackedByteArray } or {} if not found in
## any archive.
func resolve_bytes(rel_path: String) -> Dictionary:
	for bsa_name in _bsa_order:
		var r := _get_reader(bsa_name)
		if r == null:
			continue
		var data := r.extract(rel_path)
		if data.size() > 0:
			return { "bsa": bsa_name, "data": data }
	return {}

## Loads a NIF from its Data/Meshes/-relative path (as stored in a MODL
## subrecord — the "meshes\" prefix is added here, see
## phases/1/00-interior-cell-loader.md's MODL-path finding). Returns null if
## not found or unparseable.
func load_nif(model_path: String) -> NifReader:
	var found := resolve_bytes("meshes\\" + model_path)
	if found.is_empty():
		return null
	var nif := NifReader.new()
	if not nif.load(found["data"]):
		return null
	return nif

## Loads a texture from its Data/-relative path (as stored in a NIF's
## texture slot, already including "textures\"). Returns null if not found
## or undecodable.
func load_texture(tex_path: String) -> ImageTexture:
	if tex_path == "":
		return null
	var found := resolve_bytes(tex_path)
	if found.is_empty():
		return null
	var img := Image.new()
	if img.load_dds_from_buffer(found["data"]) != OK:
		return null
	return ImageTexture.create_from_image(img)

func build_submesh(nif: NifReader, index: int) -> ArrayMesh:
	var pos_flat := nif.get_positions(index)
	var norm_flat := nif.get_normals(index)
	var uv_flat := nif.get_uvs(index)
	var idx_flat := nif.get_indices(index)

	var verts := PackedVector3Array()
	verts.resize(pos_flat.size() / 3)
	for i in range(verts.size()):
		verts[i] = Vector3(pos_flat[i * 3], pos_flat[i * 3 + 1], pos_flat[i * 3 + 2])

	var normals := PackedVector3Array()
	if norm_flat.size() == pos_flat.size():
		normals.resize(norm_flat.size() / 3)
		for i in range(normals.size()):
			normals[i] = Vector3(norm_flat[i * 3], norm_flat[i * 3 + 1], norm_flat[i * 3 + 2])

	var uvs := PackedVector2Array()
	if uv_flat.size() == (pos_flat.size() / 3) * 2:
		uvs.resize(uv_flat.size() / 2)
		for i in range(uvs.size()):
			uvs[i] = Vector2(uv_flat[i * 2], uv_flat[i * 2 + 1])

	var indices := PackedInt32Array()
	indices.resize(idx_flat.size())
	for i in range(idx_flat.size()):
		indices[i] = idx_flat[i]

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	if normals.size() == verts.size():
		arrays[Mesh.ARRAY_NORMAL] = normals
	if uvs.size() == verts.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## Builds every MeshInstance3D child (one per NIF submesh, with resolved
## texture) under `parent`. Shared by every GamebryoVisual-shaped factory.
func populate_mesh_children(parent: Node3D, nif: NifReader) -> void:
	for i in range(nif.get_submesh_count()):
		var mesh := build_submesh(nif, i)
		var mi := MeshInstance3D.new()
		mi.name = "sub%d" % i
		mi.mesh = mesh
		mi.transform = nif.get_transform(i)
		var tex := load_texture(nif.get_texture_path(i))
		if tex != null:
			var mat := StandardMaterial3D.new()
			mat.albedo_texture = tex
			mi.material_override = mat
		parent.add_child(mi)

## Builds a CollisionShape3D child per extracted bhk* shape (phases/1/02-
## collision-extraction.md), or one bounding-box fallback collider (from the
## render mesh's own AABB) if the NIF has no collision data at all — per
## the phase doc's explicit requirement that meshless-collision objects
## still get *something* walkable rather than no collision.
func populate_collision_children(parent: Node3D, nif: NifReader) -> void:
	var shapes: Array = nif.get_collision_shapes()
	if shapes.is_empty():
		_add_fallback_collision(parent, nif)
		return
	for s in shapes:
		var col := CollisionShape3D.new()
		col.name = "collision_%s" % String(s.get("name", ""))
		var kind: String = s.get("kind", "")

		match kind:
			"triangle_mesh":
				var shape := ConcavePolygonShape3D.new()
				shape.set_faces(_expand_triangles(s.get("positions", PackedFloat32Array()), s.get("indices", PackedInt32Array())))
				# Godot's ConcavePolygonShape3D is one-sided by default
				# (backface_collision = false). Havok's own triangle winding
				# (a separate data source from the render mesh, which needed
				# its own winding fix — see nif_loader.cpp) was never
				# independently verified; rather than guess at a second
				# unverified winding convention, make trimesh collision
				# solid from both sides. Confirmed necessary: a physics test
				# ball fell straight through a real floor's triangle-mesh
				# collision before this was added.
				shape.backface_collision = true
				col.shape = shape
				col.transform = s.get("transform", Transform3D.IDENTITY)
			"convex_hull":
				var shape := ConvexPolygonShape3D.new()
				shape.points = _flat_to_vector3(s.get("positions", PackedFloat32Array()))
				col.shape = shape
				col.transform = s.get("transform", Transform3D.IDENTITY)
			"box":
				var shape := BoxShape3D.new()
				var he: Vector3 = s.get("half_extents", Vector3.ONE)
				shape.size = he * 2.0
				col.shape = shape
				col.transform = s.get("transform", Transform3D.IDENTITY)
			"sphere":
				var shape := SphereShape3D.new()
				shape.radius = max(float(s.get("radius", 0.1)), 0.01)
				col.shape = shape
				col.transform = s.get("transform", Transform3D.IDENTITY)
			"capsule":
				var shape := CapsuleShape3D.new()
				var a: Vector3 = s.get("point_a", Vector3.ZERO)
				var b: Vector3 = s.get("point_b", Vector3.ZERO)
				shape.radius = max(float(s.get("capsule_radius", 0.1)), 0.01)
				shape.height = max(a.distance_to(b) + shape.radius * 2.0, shape.radius * 2.0)
				# CapsuleShape3D is aligned along local Y by convention — build
				# a basis whose Y axis points from a to b, positioned at the
				# midpoint, then compose with the shape's own base transform.
				var base_transform: Transform3D = s.get("transform", Transform3D.IDENTITY)
				var mid := (a + b) * 0.5
				var dir := b - a
				var cap_basis := _basis_aligned_to_y(dir) if dir.length() > 0.0001 else Basis.IDENTITY
				col.transform = base_transform * Transform3D(cap_basis, mid)
				col.shape = shape
			_:
				continue
		parent.add_child(col)

func _expand_triangles(positions: PackedFloat32Array, indices: PackedInt32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(indices.size())
	for i in range(indices.size()):
		var idx := indices[i]
		out[i] = Vector3(positions[idx * 3], positions[idx * 3 + 1], positions[idx * 3 + 2])
	return out

func _flat_to_vector3(positions: PackedFloat32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(positions.size() / 3)
	for i in range(out.size()):
		out[i] = Vector3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
	return out

func _basis_aligned_to_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var reference := Vector3.RIGHT if absf(y.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x := reference.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)

func _add_fallback_collision(parent: Node3D, nif: NifReader) -> void:
	var combined := AABB()
	var have := false
	for i in range(nif.get_submesh_count()):
		var pos_flat := nif.get_positions(i)
		if pos_flat.size() < 3:
			continue
		var local_aabb := AABB()
		local_aabb.position = Vector3(pos_flat[0], pos_flat[1], pos_flat[2])
		for v in range(pos_flat.size() / 3):
			local_aabb = local_aabb.expand(Vector3(pos_flat[v * 3], pos_flat[v * 3 + 1], pos_flat[v * 3 + 2]))
		var world_aabb: AABB = nif.get_transform(i) * local_aabb
		combined = world_aabb if not have else combined.merge(world_aabb)
		have = true
	if not have:
		return

	var col := CollisionShape3D.new()
	col.name = "collision_fallback_bbox"
	var shape := BoxShape3D.new()
	shape.size = combined.size.max(Vector3.ONE * 0.05) # avoid a degenerate zero-thickness box
	col.shape = shape
	col.position = combined.get_center()
	parent.add_child(col)

## Bethesda REFR.DATA rotation: X/Y/Z Euler radians composed as Rz*Ry*Rx,
## with the angles NEGATED before building each axis rotation — see
## phases/1/00-interior-cell-loader.md for how this was found (OpenMW
## source cross-check, after a visibly-wrong first attempt).
static func refr_basis(rot: Vector3) -> Basis:
	var bx := Basis(Vector3(1, 0, 0), -rot.x)
	var by := Basis(Vector3(0, 1, 0), -rot.y)
	var bz := Basis(Vector3(0, 0, 1), -rot.z)
	return bz * by * bx
