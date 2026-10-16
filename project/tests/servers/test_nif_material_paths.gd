extends Node

## NifMaterialBuilder's material paths: every shape is dispatched to
## PATH_STANDARD, and an override registered through NifServer before the
## first build either adjusts the stock material or replaces it, while the
## `nif_*` metadata is stamped onto whatever it returns. Its own scene, because
## the override must be registered before anything in the process builds.

const NifTreeBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")
const NifMaterialBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_material_builder.gd")
const WATER_TANK := "meshes/architecture/goodsprings/NV_WaterTank.NIF"
# The tank's blended shape, flags1 0x82000101, flags2 0x1.
const REPLACED_SHAPE := "DieselTankNV:2"
const ADJUSTED_SHAPE := "DieselTankNV:0"

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

	var all_standard := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.mesh.get_surface_count() == 0:
			continue
		var mat := mi.mesh.surface_get_material(0)
		if mat == null or mat.get_meta("nif_material_path", &"") != NifMaterialBuilderScript.PATH_STANDARD:
			all_standard = false
	check(all_standard, "every shape is dispatched to the standard path")
	root.free()

	check(not NifServer.set_material_path(NifMaterialBuilderScript.PATH_STANDARD, _override),
		"an override after the first build is refused")


func _ready() -> void:
	check(ArchiveServer.is_ready(), "ArchiveServer available")
	await test_override()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
