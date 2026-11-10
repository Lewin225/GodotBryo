extends Node

## NifMaterialBuilder's material paths: Hair-flagged shapes are dispatched to
## PATH_HAIR, FaceGen-flagged ones to PATH_SKIN, Refraction-flagged ones to
## PATH_REFRACTION and every other shape to PATH_STANDARD, and an override registered
## through NifServer before the first build either adjusts the stock material
## or replaces it, while the `nif_*` metadata is stamped onto whatever it
## returns. Its own scene, because the overrides must be registered before
## anything in the process builds.

const NifTreeBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")
const NifMaterialContextScript := preload("res://GodotBryo/Servers/NifServer/nif_material_context.gd")
const NifMaterialBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_material_builder.gd")
const WATER_TANK := "meshes/architecture/goodsprings/NV_WaterTank.NIF"
# The tank's blended shape, flags1 0x82000101, flags2 0x1.
const REPLACED_SHAPE := "DieselTankNV:2"
const ADJUSTED_SHAPE := "DieselTankNV:0"
const BEARD := "meshes/characters/hair/beardchincurtain.nif"
const BEARD_SHAPE := "BeardChinCurtain:0"
const BEARD_HIGHLIGHT := "textures\\characters\\hair\\BeardLincoln_hl.dds"
# The Fat Man explosion's shock sphere, flags1 0x80018001: Refraction.
# Carries an NiStencilProperty, flags 0x4D80 (draw mode 3, both sides).
const BROOM := "meshes/animobjects/aobroom.nif"
const BROOM_SHAPE := "Broom"
const NUKE_EXPLOSION := "meshes/effects/explosionlarge01.nif"
const NUKE_SHOCK_SHAPE := "GeoSphere03:0"

var failures := 0
# shape name -> {diffuse_path, has_diffuse, path}, recorded by the override
var _seen := {}


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


## Replaces the blended tank shape with a ShaderMaterial and tints every other
## shape's stock material red.
func _override(context: NifMaterialContext) -> Material:
	var shape_name := String(context.node["name"])
	_seen[shape_name] = {
		"diffuse_path": context.texture_path(NifMaterialBuilderScript.ROLE_DIFFUSE),
		"has_diffuse": context.texture(NifMaterialBuilderScript.ROLE_DIFFUSE) != null,
		"path": context.path,
	}
	if shape_name == REPLACED_SHAPE:
		var shader := Shader.new()
		shader.code = "shader_type spatial;\nuniform sampler2D diffuse;\n"
		var replaced := ShaderMaterial.new()
		replaced.shader = shader
		replaced.set_shader_parameter("diffuse", context.texture(NifMaterialBuilderScript.ROLE_DIFFUSE))
		return replaced
	var adjusted := context.default_material() as StandardMaterial3D
	adjusted.albedo_color = Color.RED
	return adjusted


## Records what a hair shape's context holds and returns the stock material.
func _hair_override(context: NifMaterialContext) -> Material:
	_seen[String(context.node["name"])] = {
		"path": context.path,
		"highlight_path": context.texture_path(NifMaterialBuilderScript.ROLE_HAIR_HIGHLIGHT),
		"has_highlight": context.texture(NifMaterialBuilderScript.ROLE_HAIR_HIGHLIGHT) != null,
		"has_glow": context.texture_path(NifMaterialBuilderScript.ROLE_GLOW) != "",
	}
	return context.default_material()


func _shape(root: Node, authored_name: String) -> MeshInstance3D:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if String(node.get_meta("nif_name", "")) == authored_name:
			return node as MeshInstance3D
	return null


func test_override() -> void:
	print("--- material path overrides ---")
	check(not NifServer.set_material_path(&"water", _override), "an unknown material path is refused")
	check(NifServer.set_material_path(NifMaterialBuilderScript.PATH_STANDARD, _override),
		"an override for the standard path is accepted before any build")
	check(NifServer.set_material_path(NifMaterialBuilderScript.PATH_HAIR, _hair_override),
		"an override for the hair path is accepted before any build")

	var raw: Dictionary = ArchiveServer.read(WATER_TANK)
	var src := NifSource.new()
	if not bool(raw["found"]) or not src.load(PackedByteArray(raw["data"])):
		check(false, "read and parse the water tank")
		return
	var root: Node3D = await NifTreeBuilderScript.build(src)
	check(root != null, "the water tank builds")
	if root == null:
		return

	var replaced := _shape(root, REPLACED_SHAPE)
	var replaced_mat: Material = replaced.mesh.surface_get_material(0) if replaced != null else null
	check(replaced_mat is ShaderMaterial, "%s gets the override's ShaderMaterial" % REPLACED_SHAPE)
	if replaced_mat != null:
		check(replaced_mat.get_meta("nif_material_path", &"") == NifMaterialBuilderScript.PATH_STANDARD,
			"the ShaderMaterial carries nif_material_path")
		check(int(replaced_mat.get_meta("nif_shader_flags1", 0)) == 0x82000101
			and int(replaced_mat.get_meta("nif_shader_flags2", 0)) == 0x1,
			"the ShaderMaterial carries both raw shader flag words")
		check(replaced_mat.has_meta("nif_alpha_blend_func"), "the ShaderMaterial carries the alpha blend function")
		check(String(replaced_mat.get_meta("nif_shader_type", "")) == "BSShaderPPLightingProperty",
			"the ShaderMaterial carries the shader block type")
		var shader_mat := replaced_mat as ShaderMaterial
		check(shader_mat != null and shader_mat.get_shader_parameter("diffuse") != null,
			"the override received the resolved diffuse texture")
	var seen: Dictionary = _seen.get(REPLACED_SHAPE, {})
	var slots: PackedStringArray = []
	for nd in src.get_nodes():
		if String(nd["name"]) == REPLACED_SHAPE:
			slots = nd["texture_slots"]
	check(slots.size() > 0 and String(seen.get("diffuse_path", "")) == slots[0],
		"the context's diffuse path is the shape's slot 0")
	check(bool(seen.get("has_diffuse", false)), "the context's diffuse texture resolved")

	var adjusted := _shape(root, ADJUSTED_SHAPE)
	var adjusted_mat := adjusted.mesh.surface_get_material(0) as StandardMaterial3D if adjusted != null else null
	check(adjusted_mat != null and adjusted_mat.albedo_color == Color.RED,
		"%s gets the stock material, adjusted by the override" % ADJUSTED_SHAPE)
	if adjusted_mat != null:
		check(adjusted_mat.albedo_texture != null, "the adjusted stock material keeps its diffuse")
		check(adjusted_mat.get_meta("nif_material_path", &"") == NifMaterialBuilderScript.PATH_STANDARD,
			"the adjusted material carries nif_material_path")

	await _check_hair()

	var all_standard := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.mesh.get_surface_count() == 0:
			continue
		var mat := mi.mesh.surface_get_material(0)
		if mat == null or mat.get_meta("nif_material_path", &"") != NifMaterialBuilderScript.PATH_STANDARD:
			all_standard = false
	check(all_standard, "every water tank shape is dispatched to the standard path")
	root.free()

	check(not NifServer.set_material_path(NifMaterialBuilderScript.PATH_STANDARD, _override),
		"an override after the first build is refused")


func _check_hair() -> void:
	var raw: Dictionary = ArchiveServer.read(BEARD)
	var src := NifSource.new()
	if not bool(raw["found"]) or not src.load(PackedByteArray(raw["data"])):
		check(false, "read and parse %s" % BEARD)
		return
	var root: Node3D = await NifTreeBuilderScript.build(src)
	var beard := _shape(root, BEARD_SHAPE) if root != null else null
	check(beard != null, "%s builds with %s" % [BEARD, BEARD_SHAPE])
	if beard == null:
		return
	var seen: Dictionary = _seen.get(BEARD_SHAPE, {})
	check(seen.get("path", &"") == NifMaterialBuilderScript.PATH_HAIR, "the beard is dispatched to the hair path")
	check(String(seen.get("highlight_path", "")) == BEARD_HIGHLIGHT, "its context's hair highlight is slot 2")
	check(bool(seen.get("has_highlight", false)), "its hair highlight texture resolved")
	check(not bool(seen.get("has_glow", true)), "its context has no glow role")
	var mat := beard.mesh.surface_get_material(0) as StandardMaterial3D
	check(mat != null and not mat.emission_enabled, "the stock hair material has no emission")
	if mat != null:
		check(mat.albedo_texture != null and mat.normal_enabled, "it keeps its diffuse and normal map")
		check(mat.albedo_color == Color.WHITE, "its albedo colour is white, for the owner to tint")
		check(not mat.vertex_color_use_as_albedo, "it does not use vertex colour as albedo")
		check(beard.mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_COLOR,
			"the beard mesh keeps its vertex colours")
		var roles: Dictionary = mat.get_meta("nif_texture_roles", {})
		check(String(roles.get(NifMaterialBuilderScript.ROLE_HAIR_HIGHLIGHT, "")) == BEARD_HIGHLIGHT,
			"the material records the highlight path in nif_texture_roles")
		check(not mat.has_meta("nif_texture_slot_2"), "slot 2 is a role, not an unused slot")
	root.free()


## Every Hair-flagged shape in the corpus, and only those, goes to the hair
## path; every FaceGen-flagged one to the skin path; every Refraction-flagged
## one to the refraction path.
func test_path_census() -> void:
	print("--- hair, skin and refraction path census ---")
	var refraction := 0
	var stencil := 0
	var stencil_both := 0
	var refraction_alpha := 0
	var hair := 0
	var highlights := 0
	var skin := 0
	var skin_sk := 0
	for p in ArchiveServer.list_files_with_prefix("meshes/"):
		var sp := String(p)
		if not sp.ends_with(".nif"):
			continue
		var raw: Dictionary = ArchiveServer.read(sp)
		var src := NifSource.new()
		if not bool(raw["found"]) or not src.load(PackedByteArray(raw["data"])):
			continue
		for nd in src.get_nodes():
			if not nd.has("positions"):
				continue
			var path := NifMaterialBuilderScript.path_for(nd)
			if bool(nd.get("has_stencil_property", false)):
				stencil += 1
				if int(nd["stencil_draw_mode"]) == NifMaterialBuilderScript.STENCIL_DRAW_BOTH:
					stencil_both += 1
			var slots: PackedStringArray = nd["texture_slots"]
			var slot_2 := String(slots[2]).to_lower() if slots.size() > 2 else ""
			if path == NifMaterialBuilderScript.PATH_REFRACTION:
				refraction += 1
				if bool(nd.get("has_alpha_property", false)):
					refraction_alpha += 1
			if path == NifMaterialBuilderScript.PATH_SKIN:
				skin += 1
				if slot_2.ends_with("_sk.dds"):
					skin_sk += 1
			if path != NifMaterialBuilderScript.PATH_HAIR:
				continue
			hair += 1
			if slot_2.ends_with("_hl.dds"):
				highlights += 1
	check(hair == 159, "159 shapes go to the hair path (got %d)" % hair)
	check(highlights == hair, "every one has an _hl texture in slot 2 (got %d)" % highlights)
	check(skin == 332, "332 shapes go to the skin path (got %d)" % skin)
	check(stencil == 2017, "2,017 shapes carry an NiStencilProperty (got %d)" % stencil)
	check(stencil_both == stencil, "every one draws both sides (got %d)" % stencil_both)
	check(refraction == 92, "92 shapes go to the refraction path (got %d)" % refraction)
	check(refraction_alpha == 0, "none of them has an NiAlphaProperty (got %d)" % refraction_alpha)
	check(skin_sk == 238, "238 of them have an _sk texture in slot 2 (got %d)" % skin_sk)


## The shock sphere's stock material draws nothing: fully transparent,
## unshaded, no depth write.
func test_refraction_material() -> void:
	print("--- refraction stock material ---")
	var raw: Dictionary = ArchiveServer.read(NUKE_EXPLOSION)
	var src := NifSource.new()
	if not bool(raw["found"]) or not src.load(PackedByteArray(raw["data"])):
		check(false, "read %s" % NUKE_EXPLOSION)
		return
	var shape: Dictionary = {}
	for nd in src.get_nodes():
		if String(nd["name"]) == NUKE_SHOCK_SHAPE:
			shape = nd
			break
	check(not shape.is_empty(), "%s has %s" % [NUKE_EXPLOSION, NUKE_SHOCK_SHAPE])
	if shape.is_empty():
		return
	check(NifMaterialBuilderScript.path_for(shape) == NifMaterialBuilderScript.PATH_REFRACTION,
		"%s goes to the refraction path" % NUKE_SHOCK_SHAPE)
	var mat := NifMaterialBuilderScript._build_refraction(null) as StandardMaterial3D
	check(mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and is_zero_approx(mat.albedo_color.a),
		"its stock material is fully transparent")
	check(mat.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED, "and writes no depth")


## A two-sided shape is not culled; a shape with no NiStencilProperty keeps
## the back-face cull.
func test_stencil_cull() -> void:
	print("--- NiStencilProperty draw mode ---")
	var raw: Dictionary = ArchiveServer.read(BROOM)
	var src := NifSource.new()
	if not bool(raw["found"]) or not src.load(PackedByteArray(raw["data"])):
		check(false, "read %s" % BROOM)
		return
	var two_sided: Dictionary = {}
	var one_sided: Dictionary = {}
	for nd in src.get_nodes():
		if not nd.has("positions"):
			continue
		if String(nd["name"]) == BROOM_SHAPE:
			two_sided = nd
		elif not bool(nd.get("has_stencil_property", false)):
			one_sided = nd
	check(not two_sided.is_empty() and bool(two_sided["has_stencil_property"]),
		"%s has an NiStencilProperty" % BROOM_SHAPE)
	if not two_sided.is_empty():
		var mat := NifMaterialBuilderScript._build_standard(NifMaterialContextScript.new(
			NifMaterialBuilderScript.PATH_STANDARD, two_sided, false, {}, {},
			NifMaterialBuilderScript._build_standard)) as StandardMaterial3D
		check(mat.cull_mode == BaseMaterial3D.CULL_DISABLED, "%s draws both sides" % BROOM_SHAPE)
	if not one_sided.is_empty():
		var mat := NifMaterialBuilderScript._build_standard(NifMaterialContextScript.new(
			NifMaterialBuilderScript.PATH_STANDARD, one_sided, false, {}, {},
			NifMaterialBuilderScript._build_standard)) as StandardMaterial3D
		check(mat.cull_mode == BaseMaterial3D.CULL_BACK, "%s keeps the back-face cull" % String(one_sided["name"]))


func _ready() -> void:
	check(ArchiveServer.is_ready(), "ArchiveServer available")
	test_path_census()
	test_refraction_material()
	test_stencil_cull()
	await test_override()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
