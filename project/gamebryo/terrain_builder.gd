class_name GamebryoTerrainBuilder
extends RefCounted

## Builds one exterior CELL's terrain (phases/1/04-exterior-cell-terrain.md)
## from a LAND record's decoded heightmap: a StaticBody3D with one
## MeshInstance3D per BTXT quadrant (base texture only, no ATXT/VTXT
## blending — see esm::LandData's scope note) plus one HeightMapShape3D
## covering the whole grid.
##
## Unlike every other GamebryoReference, this is built directly in native
## Godot Y-up space — NOT the pre-rotation Bethesda Z-up convention (x, y,
## height) that REFR-placed objects use before the scene's outer -90 X
## rotation. That convention needs col/row to occupy the render mesh's
## local X/Y and height to occupy Z, but a HeightMapShape3D is natively
## X=width, Y=height, Z=depth — mapping one to the other means swapping two
## axes, which is a reflection (negative-determinant transform), and a
## first attempt at exactly that produced a CollisionShape3D balls fell
## straight through in testing (see phases/1/04-exterior-cell-terrain.md) —
## Godot/Jolt's heightmap collider doesn't support a reflected shape
## transform, only a proper rotation+scale. Building height along local Y
## from the start avoids ever needing that reflection, at the cost of the
## caller placing this node directly under the scene root (or any
## non-rotated parent) instead of the shared "world" node everything else
## uses — see the position-offset math in build()'s caller (test_terrain.gd
## / cell placement code) for the corresponding world-space translation.

const GRID_SIZE := 33 # esm::kLandGridSize
const QUAD_HALF := 16 # (GRID_SIZE - 1) / 2 -- each quadrant is 16x16 quads

## GECK wiki: adjacent VHGT samples are 128 Gamebryo units apart. Converted
## to meters at the true source would mean threading a second unit constant
## into esm_file.cpp for a value LandData doesn't otherwise need (heights
## are already scaled, but spacing is implicit grid structure, not a field) —
## so it's applied here instead, using the same 1/70 conversion documented in
## native/src/common/units.h.
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0
const VERTEX_SPACING := 128.0 * GAMEBRYO_UNITS_TO_METERS

## Returns a StaticBody3D positioned at the local origin, or null if the
## cell has no LAND record. `land` is the Dictionary from
## EsmReader.get_land_data(); `quadrant_textures` is an Array[Texture2D] of
## size 4 (fopdoc order: 0=BL, 1=BR, 2=TL, 3=TR), entries may be null.
##
## World placement: the returned node must be positioned at
## Vector3(cell_origin_x_m, 0, -cell_origin_y_m) — NOT under the rotated
## "world" node, and NOT the same (x, y, 0) offset used for REFR content's
## pre-rotation local space. cell_origin_{x,y}_m is the cell's XCLC grid
## coordinate * 4096 Gamebryo units, converted to meters.
static func build(land: Dictionary, quadrant_textures: Array) -> Node3D:
	if land.is_empty():
		return null
	var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
	if heights.size() != GRID_SIZE * GRID_SIZE:
		return null

	var root := StaticBody3D.new()
	root.name = "Terrain"

	# Quadrant row/col ranges, fopdoc order 0=BL 1=BR 2=TL 3=TR — row is the
	# grid's Bethesda-Y axis (0=south), col is Bethesda-X (0=west), matching
	# esm_types.h's LandData comment.
	var quadrant_ranges := [
		[0, QUAD_HALF, 0, QUAD_HALF], # BL: row 0..16, col 0..16
		[0, QUAD_HALF, QUAD_HALF, GRID_SIZE - 1], # BR: row 0..16, col 16..32
		[QUAD_HALF, GRID_SIZE - 1, 0, QUAD_HALF], # TL: row 16..32, col 0..16
		[QUAD_HALF, GRID_SIZE - 1, QUAD_HALF, GRID_SIZE - 1], # TR: row 16..32, col 16..32
	]

	for q in range(4):
		var range_def: Array = quadrant_ranges[q]
		var mesh := _build_quadrant_mesh(heights, range_def[0], range_def[1], range_def[2], range_def[3])
		var mi := MeshInstance3D.new()
		mi.name = "quadrant_%d" % q
		mi.mesh = mesh
		if q < quadrant_textures.size() and quadrant_textures[q] != null:
			var mat := StandardMaterial3D.new()
			mat.albedo_texture = quadrant_textures[q]
			mi.material_override = mat
		root.add_child(mi)

	root.add_child(_build_collision(heights))
	return root

static func _height_at(heights: PackedFloat32Array, row: int, col: int) -> float:
	return heights[row * GRID_SIZE + col]

## Builds one quadrant's mesh over vertex rows [row_start, row_end] and
## columns [col_start, col_end] (inclusive), sharing edge vertices with
## neighboring quadrants (each quadrant is a separate surface/material, so
## the shared edge is duplicated across two draw calls — normal for
## per-material terrain splatting). Native Y-up: (col*spacing, height,
## -row*spacing) — row increases toward -Z because that's the direction a
## REFR's Bethesda-Y position ends up at after the scene's own -90 X
## rotation (world Z = -bethesda_y), which this terrain must match
## spatially despite not going through that rotation itself.
static func _build_quadrant_mesh(heights: PackedFloat32Array, row_start: int, row_end: int, col_start: int, col_end: int) -> ArrayMesh:
	var rows := row_end - row_start + 1
	var cols := col_end - col_start + 1

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(rows * cols)
	uvs.resize(rows * cols)
	for r in range(rows):
		for c in range(cols):
			var row := row_start + r
			var col := col_start + c
			var i := r * cols + c
			verts[i] = Vector3(col * VERTEX_SPACING, _height_at(heights, row, col), -(row * VERTEX_SPACING))
			# Real bug, found via a direct user report that ground textures looked
			# "far too scaled up": UV used to be normalized 0..1 across the WHOLE
			# quadrant (~29m across), meaning one full texture tile stretched over
			# the entire quadrant with zero repeats -- unmistakably wrong once
			# actually looked at, just never flagged before. Real ground textures
			# should tile once per grid interval (VERTEX_SPACING, ~1.83m), giving
			# a real repeat count across the quadrant instead of one giant stretch.
			# Using the GLOBAL col/row (not local c/r) keeps UVs continuous across
			# quadrant boundaries within the same cell, matching what a real
			# splatted terrain looks like (no visible seam at the quadrant seam).
			uvs[i] = Vector2(float(col), float(row))

	var indices := PackedInt32Array()
	indices.resize((rows - 1) * (cols - 1) * 6)
	var idx := 0
	for r in range(rows - 1):
		for c in range(cols - 1):
			var v00 := r * cols + c
			var v10 := r * cols + (c + 1)
			var v01 := (r + 1) * cols + c
			var v11 := (r + 1) * cols + (c + 1)
			# Wound so the face normal points toward +Y (this convention's
			# up). Verified visually via the test scene (backface culling
			# made an earlier, oppositely-wound attempt invisible from
			# above — see phases/1/04-exterior-cell-terrain.md); not
			# derived from a spec, terrain has no documented winding
			# convention to cite.
			indices[idx] = v00; idx += 1
			indices[idx] = v01; idx += 1
			indices[idx] = v10; idx += 1
			indices[idx] = v10; idx += 1
			indices[idx] = v01; idx += 1
			indices[idx] = v11; idx += 1

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## First attempt used HeightMapShape3D — the natural fit for a heightmap —
## but real testing (a physics drop test, phases/1/04-exterior-cell-terrain.md)
## found it never collided at all, even in a minimal, unscaled, un-rotated
## 3x3 repro case with no terrain code involved. Not a transform bug on this
## project's end; switched to ConcavePolygonShape3D instead, the same shape
## type 1.2's collision extraction already uses successfully for every other
## mesh in the game. Built from the exact same vertex positions as the
## render mesh (no separate axis/scale mapping to get wrong) with
## backface_collision = true for the same reason 1.2 uses it on trimesh
## collision generally: real triangle winding was only verified for the
## render mesh, not independently for this synthetic terrain mesh.
static func _build_collision(heights: PackedFloat32Array) -> CollisionShape3D:
	var verts := PackedVector3Array()
	verts.resize((GRID_SIZE - 1) * (GRID_SIZE - 1) * 6)
	var idx := 0
	for row in range(GRID_SIZE - 1):
		for col in range(GRID_SIZE - 1):
			var v00 := Vector3(col * VERTEX_SPACING, _height_at(heights, row, col), -(row * VERTEX_SPACING))
			var v10 := Vector3((col + 1) * VERTEX_SPACING, _height_at(heights, row, col + 1), -(row * VERTEX_SPACING))
			var v01 := Vector3(col * VERTEX_SPACING, _height_at(heights, row + 1, col), -((row + 1) * VERTEX_SPACING))
			var v11 := Vector3((col + 1) * VERTEX_SPACING, _height_at(heights, row + 1, col + 1), -((row + 1) * VERTEX_SPACING))
			verts[idx] = v00; idx += 1
			verts[idx] = v01; idx += 1
			verts[idx] = v10; idx += 1
			verts[idx] = v10; idx += 1
			verts[idx] = v01; idx += 1
			verts[idx] = v11; idx += 1

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(verts)
	shape.backface_collision = true

	var col_shape := CollisionShape3D.new()
	col_shape.name = "terrain_collision"
	col_shape.shape = shape
	return col_shape
