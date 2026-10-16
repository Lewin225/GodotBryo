@tool
extends RefCounted
class_name NifMaterialBuilder

## Builds one shape's material by dispatching it to a material path.
##
## path_for() picks the path from what the shape's NifSource node declares.
## Each path has a stock builder; a caller can replace it with set_material_path()
## before the first material is built, either adjusting the stock material or
## returning a different Material altogether. build() stamps the `nif_*`
## metadata onto whatever the path returns.
##
## Every shape currently goes to PATH_STANDARD.

# For cache_key() only, which is static.
const TextureServerScript := preload("res://GodotBryo/Servers/TextureServer/texture_server.gd")
const NifMaterialContextScript := preload("res://GodotBryo/Servers/NifServer/nif_material_context.gd")

## The StandardMaterial3D path every shape is dispatched to.
const PATH_STANDARD := &"standard"
const PATHS: Array[StringName] = [PATH_STANDARD]

const ROLE_DIFFUSE := &"diffuse"
const ROLE_NORMAL := &"normal"
const ROLE_GLOW := &"glow"

# Provisional StandardMaterial3D stand-in for additive XEMI light shafts.
# These distances and the alpha scale are visual tuning, not NIF fields.
const LIGHT_SHAFT_SOFT_CLIP_METERS := 1.0
const LIGHT_SHAFT_NEAR_FADE_METERS := 1.5
const LIGHT_SHAFT_ALPHA_SCALE := 0.2

static var _overrides := {}  # path -> Callable(NifMaterialContext) -> Material
static var _built_any := false


## Replaces a path's builder. `builder` takes a NifMaterialContext and returns a
## Material. Refused once any material has been built: NifServer caches
## delivered trees, so a later override would leave old and new materials mixed.
static func set_material_path(path: StringName, builder: Callable) -> bool:
	if not PATHS.has(path):
		push_error("NifMaterialBuilder: unknown material path '%s'" % path)
		return false
	if _built_any:
		push_error("NifMaterialBuilder: material path '%s' set after the first build" % path)
		return false
	if not builder.is_valid():
		push_error("NifMaterialBuilder: invalid builder for material path '%s'" % path)
		return false
	_overrides[path] = builder
	return true


## The material path for a shape's NifSource node.
static func path_for(_nd: Dictionary) -> StringName:
	return PATH_STANDARD


## The textures a shape's path uses: [{role, slot, path, alpha_safe}] in slot
## order, only for slots with an authored path. NifTreeBuilder warms exactly
## these, so the warmed and looked-up keys cannot drift apart.
static func texture_refs(nd: Dictionary) -> Array:
	var refs: Array = []
	var slots: PackedStringArray = nd.get("texture_slots", PackedStringArray())
	if slots.is_empty():
		return refs
	var alpha_safe := _alpha_safe(nd)
	var map: Array = _texture_slot_map(String(nd.get("texture_convention", "")))
	var roles: Array[StringName] = [ROLE_DIFFUSE, ROLE_NORMAL, ROLE_GLOW]
	for i in map.size():
		var slot: int = map[i]
		if slot < 0 or slot >= slots.size() or String(slots[slot]).is_empty():
			continue
		# Only the diffuse carries the shape's alpha-safe requirement; a
		# normal or glow map is never the DXT1 punch-through case.
		refs.append({
			"role": roles[i],
			"slot": slot,
			"path": String(slots[slot]),
			"alpha_safe": alpha_safe and roles[i] == ROLE_DIFFUSE,
		})
	return refs


## The shape's material from its path's builder, with the `nif_*` metadata.
## `textures` is cache key -> ImageTexture, already resolved by NifTreeBuilder.
static func build(nd: Dictionary, has_vertex_colors: bool, textures: Dictionary) -> Material:
	_built_any = true
	var path := path_for(nd)
	var role_textures := {}
	var role_paths := {}
	var used_slots := {}
	for ref in texture_refs(nd):
		var key: String = TextureServerScript.cache_key(ref["path"], ref["alpha_safe"])
		role_textures[ref["role"]] = textures.get(key)
		role_paths[ref["role"]] = ref["path"]
		used_slots[ref["slot"]] = true
	var context := NifMaterialContextScript.new(path, nd, has_vertex_colors,
		role_textures, role_paths, _stock_builder(path))
	var material: Material = null
	if _overrides.has(path):
		material = (_overrides[path] as Callable).call(context)
		if material == null:
			push_error("NifMaterialBuilder: override for '%s' returned null; using the stock material" % path)
	if material == null:
		material = context.default_material()
	_stamp_metadata(material, nd, path, used_slots)
	return material


static func _stock_builder(path: StringName) -> Callable:
	match path:
		PATH_STANDARD:
			return _build_standard
	return _build_standard


## The raw file data every material carries, whichever path built it.
static func _stamp_metadata(material: Material, nd: Dictionary, path: StringName, used_slots: Dictionary) -> void:
	material.set_meta("nif_material_path", path)
	material.set_meta("nif_shader_type", String(nd["shader_type"]))
	material.set_meta("nif_texture_convention", String(nd.get("texture_convention", "")))
	if bool(nd.get("has_shader_flags", false)):
		material.set_meta("nif_shader_flags1", int(nd["shader_flags1"]))
		material.set_meta("nif_shader_flags2", int(nd["shader_flags2"]))
	if bool(nd.get("has_alpha_property", false)):
		material.set_meta("nif_alpha_blend_func", String(nd["alpha_blend_func"]))
	# Slots the path does not use are recorded so nothing is silently dropped.
	var slots: PackedStringArray = nd.get("texture_slots", PackedStringArray())
	for i in slots.size():
		if not used_slots.has(i) and String(slots[i]) != "":
			material.set_meta("nif_texture_slot_%d" % i, String(slots[i]))


## A blend- or test-enabled shape needs its diffuse fetched through
## TextureServer's alpha-safe path.
##
## `alpha_safe` selects TextureServer's DXT1 -> RGBA8 variant. Godot maps
## FORMAT_DXT1 to the BC1_RGB GPU format, which is opaque by spec, so BC1
## punch-through alpha is discarded by the sampler before any fragment shader
## runs -- alpha scissor then has nothing to cut and transparent texels render
## as the black they are encoded to. Not shader-fixable.
static func _alpha_safe(nd: Dictionary) -> bool:
	if not bool(nd.get("has_alpha_property", false)):
		return false
	return bool(nd["alpha_blend_enabled"]) or bool(nd["alpha_test_enabled"])


## [diffuse, normal, glow] slot indices for a texture convention, -1 for a
## channel the convention does not carry.
##
## Slot NUMBERS mean different things per convention, so the mapping is picked
## from the block the slots came from rather than assumed. Reading a
## NiTexturingProperty as if it were a BSShaderTextureSet is how a terminal
## screen ends up with no albedo at all and renders solid white.
## NiTexturingProperty is 0 base, 1 dark, 2 detail, 3 gloss, 4 glow, 5 bump,
## 6-9 decal. Corpus-wide only `base` is ever occupied -- 4,701 of 4,701
## shapes, with a single `dark` -- so the rest are mapped for correctness
## rather than because anything ships them. BSEffectShaderProperty has no glow
## slot at all.
static func _texture_slot_map(convention: String) -> Array:
	match convention:
		"texturing_property":
			return [0, 5, 4]
		"effect_shader":
			return [0, 1, -1]
	return [0, 1, 2]


## PATH_STANDARD's stock material.
##
## Vertex colour is not decoration in this content: Bethesda's unlit AO fades
## and glow overlays carry NO texture at all, so the per-vertex colour and its
## alpha are the only pixels the shape has. A StandardMaterial3D ignores
## ARRAY_COLOR unless `vertex_color_use_as_albedo` says otherwise, so without
## it those shapes render as solid opaque white quads.
static func _build_standard(context: NifMaterialContext) -> Material:
	var nd := context.node
	var mat := StandardMaterial3D.new()
	if bool(nd.get("has_shader_flags", false)):
		_apply_shader_depth(mat, int(nd["shader_flags1"]), int(nd["shader_flags2"]))

	if context.has_vertex_colors:
		mat.vertex_color_use_as_albedo = true

	var blend_enabled := false
	var test_enabled := false
	if bool(nd.get("has_alpha_property", false)):
		blend_enabled = bool(nd["alpha_blend_enabled"])
		test_enabled = bool(nd["alpha_test_enabled"])
		_apply_alpha(mat, nd, blend_enabled, test_enabled)

	mat.albedo_texture = context.texture(ROLE_DIFFUSE)
	var normal := context.texture(ROLE_NORMAL)
	if normal != null:
		mat.normal_enabled = true
		mat.normal_texture = normal
	var glow := context.texture(ROLE_GLOW)
	if glow != null:
		mat.emission_enabled = true
		mat.emission_texture = glow

	# BSShaderNoLightingProperty is Bethesda's own signal that scene lighting
	# must not touch this shape. An AO fade's dark-to-transparent gradient
	# washes out to lit grey under ordinary shading, which is what NoLighting
	# exists to prevent.
	if String(nd["shader_type"]) == "BSShaderNoLightingProperty":
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# The light-ray/beam shapes use additive NoLighting plus external
		# emittance. Do not apply this to every unlit shape: the boarded-window
		# glow plane has no alpha blend, and the beam's editor marker has no XEMI.
		if bool(nd.get("has_shader_flags", false)) \
				and (int(nd.get("shader_flags1", 0)) & 0x20000000) != 0 \
				and blend_enabled and String(nd.get("alpha_blend_func", "")) == "add":
			mat.proximity_fade_enabled = true
			mat.proximity_fade_distance = LIGHT_SHAFT_SOFT_CLIP_METERS
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
			mat.distance_fade_min_distance = 0.0
			mat.distance_fade_max_distance = LIGHT_SHAFT_NEAR_FADE_METERS
			var shaft_color := mat.albedo_color
			shaft_color.a *= LIGHT_SHAFT_ALPHA_SCALE
			mat.albedo_color = shaft_color
	return mat


## FO3/FNV BSShaderProperty flags (xEdit wbBSShaderFlags/2). Only the two depth
## bits have a direct BaseMaterial3D mapping here. Disabling depth testing also
## disables writes in Godot, even if the authored write bit happens to be set.
static func _apply_shader_depth(mat: StandardMaterial3D, flags1: int, flags2: int) -> void:
	var depth_test := (flags1 & 0x80000000) != 0
	var depth_write := (flags2 & 0x1) != 0
	if not depth_test:
		mat.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS if depth_write else BaseMaterial3D.DEPTH_DRAW_DISABLED


## NiAlphaProperty -> Godot transparency. Blend and test are separate bits and
## a shape can set either or both. StandardMaterial3D cannot combine authored
## blending with authored alpha testing; try alpha scissor for the dual-bit
## case, using the authored cutoff so discarded pixels cannot occlude each
## other when depth writing is enabled. This drops the authored edge blending.
static func _apply_alpha(mat: StandardMaterial3D, nd: Dictionary,
		blend_enabled: bool, test_enabled: bool) -> void:
	if blend_enabled and test_enabled:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		# NiAlphaProperty's GREATER 0 still rejects fully transparent pixels.
		# Godot's cutoff of 0 rejects none, so use the smallest 8-bit step.
		mat.alpha_scissor_threshold = maxf(float(nd["alpha_threshold"]), 1.0 / 255.0)
	elif blend_enabled:
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
