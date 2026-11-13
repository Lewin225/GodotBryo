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
## Shapes with the Hair flag go to PATH_HAIR, shapes with the FaceGen flag to
## PATH_SKIN, shapes with the Refraction flag to PATH_REFRACTION,
## BSShaderNoLightingProperty shapes to PATH_UNLIT, the remaining
## BSShaderPPLightingProperty shapes to PATH_LIT; every other shape goes to
## PATH_STANDARD.

# For cache_key() only, which is static.
const TextureServerScript := preload("res://GodotBryo/Servers/TextureServer/texture_server.gd")
const NifMaterialContextScript := preload("res://GodotBryo/Servers/NifServer/nif_material_context.gd")

## The StandardMaterial3D path for every shape no other path claims.
const PATH_STANDARD := &"standard"
## Shapes whose BSShaderPPLightingProperty sets the Hair flag. The GECK: "Enables
## hair shaders. Glowmaps are used as highlight textures." 159 shapes in the
## shipped corpus, all Shader Type 1 with a texture set, every one with an
## `_hl` texture in slot 2: 154 under meshes/characters/hair, 3 Fort head
## pikes and 2 skeleton clutter shapes.
const PATH_HAIR := &"hair"
## Shapes whose BSShaderPPLightingProperty sets the FaceGen flag: the skin.
## 332 shapes in the mesh archives (one per path): heads, hands, nude upper
## bodies and the skin parts of outfits, with a head, hand or upper-body
## diffuse, but for a few gore caps, a DLC02 body and some with no diffuse.
## Slot 2 is a `_sk` texture on 238 of them, none on the rest.
const PATH_SKIN := &"skin"
## Shapes whose BSShaderPPLightingProperty sets the Refraction flag: screen
## distortion meshes. 92 shapes in 83 NIFs, all BSShaderPPLightingProperty,
## none with an NiAlphaProperty, 87 writing depth, none with the Hair or
## FaceGen flag; 81 also set Fire Refraction. Explosion shock spheres
## (ExplosionLarge01's GeoSphere03, the Fat Man's), muzzle flash warps,
## shield and door fields. Their diffuse is FXWhite, FXPartTinyGlowy or a
## distortion normal map (FXNormalDistort_n). Its stock material draws
## nothing: refraction is not built, and the shape drawn as its texture is an
## opaque white or flat surface.
const PATH_REFRACTION := &"refraction"
## BSShaderNoLightingProperty shapes: 7,936 in the shipped corpus (effects,
## glows, light cards, AO fades). Built as a ShaderMaterial on the unlit NIF
## shader (shaders/nif_unlit.gdshaderinc), one generated variant per
## compile-time render state, with instance uniforms for per-instance alpha,
## colour, XEMI and UV.
const PATH_UNLIT := &"unlit"
## BSShaderPPLightingProperty shapes without the Hair, FaceGen or Refraction
## flag. Built as a ShaderMaterial on the lit NIF shader
## (shaders/nif_lit.gdshaderinc), one generated variant per compile-time render
## state, with the same instance uniforms as PATH_UNLIT.
const PATH_LIT := &"lit"
const PATHS: Array[StringName] = [PATH_STANDARD, PATH_HAIR, PATH_SKIN, PATH_REFRACTION, PATH_UNLIT, PATH_LIT]

const UNLIT_SHADER_BODY := "res://GodotBryo/Servers/NifServer/shaders/nif_unlit.gdshaderinc"
const LIT_SHADER_BODY := "res://GodotBryo/Servers/NifServer/shaders/nif_lit.gdshaderinc"

const ROLE_DIFFUSE := &"diffuse"
const ROLE_NORMAL := &"normal"
const ROLE_GLOW := &"glow"
## Slot 2 on a hair shape: the hair highlight texture, not a glow map.
const ROLE_HAIR_HIGHLIGHT := &"hair_highlight"
## Slot 2 on a skin shape: the `_sk` texture. HeadHuman_sk and HandMale_sk are
## one flat colour (21, 6, 5); what the skin shader does with it is not known.
const ROLE_SKIN_SK := &"skin_sk"

## NiStencilProperty draw mode 3, DRAW_BOTH (niftools StencilDrawMode).
const STENCIL_DRAW_BOTH := 3
## BSShaderFlags bit 18, Hair (nif.xml F3SF1).
const SHADER_FLAG1_HAIR := 1 << 18
## BSShaderFlags bit 10, FaceGen (nif.xml F3SF1).
const SHADER_FLAG1_FACEGEN := 1 << 10
## BSShaderFlags bit 15, Refraction (nif.xml F3SF1).
const SHADER_FLAG1_REFRACTION := 1 << 15
## BSShaderPPLightingProperty flags1 bit 0: Specular. 43,821 of the 53,840 lit
## shapes carry it.
const SHADER_FLAG1_SPECULAR := 1 << 0
## NiMaterialProperty's default glossiness, for a lit shape without one.
const DEFAULT_GLOSSINESS := 10.0
## The blocks the GECK lists the Hair flag for.
const HAIR_SHADER_BLOCKS: Array[String] = ["BSShaderPPLightingProperty", "Lighting30ShaderProperty"]

# Provisional StandardMaterial3D stand-in for additive XEMI light shafts.
# These distances and the alpha scale are visual tuning, not NIF fields.
const LIGHT_SHAFT_SOFT_CLIP_METERS := 1.0
const LIGHT_SHAFT_NEAR_FADE_METERS := 1.5
const LIGHT_SHAFT_ALPHA_SCALE := 0.2

# Shader body + render state key -> the generated Shader, shared by every
# material with that body and state.
static var _variant_shaders := {}
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
static func path_for(nd: Dictionary) -> StringName:
	if _is_hair(nd):
		return PATH_HAIR
	if _is_skin(nd):
		return PATH_SKIN
	if _is_refraction(nd):
		return PATH_REFRACTION
	if String(nd.get("shader_type", "")) == "BSShaderNoLightingProperty":
		return PATH_UNLIT
	if String(nd.get("shader_type", "")) == "BSShaderPPLightingProperty":
		return PATH_LIT
	return PATH_STANDARD


static func _is_hair(nd: Dictionary) -> bool:
	if not bool(nd.get("has_shader_flags", false)):
		return false
	if not HAIR_SHADER_BLOCKS.has(String(nd["shader_type"])):
		return false
	return (int(nd["shader_flags1"]) & SHADER_FLAG1_HAIR) != 0


static func _is_skin(nd: Dictionary) -> bool:
	if not bool(nd.get("has_shader_flags", false)):
		return false
	if String(nd["shader_type"]) != "BSShaderPPLightingProperty":
		return false
	return (int(nd["shader_flags1"]) & SHADER_FLAG1_FACEGEN) != 0


static func _is_refraction(nd: Dictionary) -> bool:
	if not bool(nd.get("has_shader_flags", false)):
		return false
	if String(nd["shader_type"]) != "BSShaderPPLightingProperty":
		return false
	return (int(nd["shader_flags1"]) & SHADER_FLAG1_REFRACTION) != 0


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
	match path_for(nd):
		PATH_HAIR:
			roles = [ROLE_DIFFUSE, ROLE_NORMAL, ROLE_HAIR_HIGHLIGHT]
		PATH_SKIN:
			roles = [ROLE_DIFFUSE, ROLE_NORMAL, ROLE_SKIN_SK]
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
	_stamp_metadata(material, nd, path, role_paths, used_slots)
	return material


static func _stock_builder(path: StringName) -> Callable:
	match path:
		PATH_STANDARD:
			return _build_standard
		PATH_HAIR:
			return _build_hair
		PATH_SKIN:
			return _build_skin
		PATH_REFRACTION:
			return _build_refraction
		PATH_UNLIT:
			return _build_unlit
		PATH_LIT:
			return _build_lit
	return _build_standard


## The raw file data every material carries, whichever path built it.
static func _stamp_metadata(material: Material, nd: Dictionary, path: StringName,
		role_paths: Dictionary, used_slots: Dictionary) -> void:
	material.set_meta("nif_material_path", path)
	# Whether the diffuse was fetched alpha-safe; a texture swap keeps it.
	material.set_meta("nif_alpha_safe", _alpha_safe(nd))
	# Role -> authored path, including roles the material does not render.
	material.set_meta("nif_texture_roles", role_paths)
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
	_apply_stencil(mat, nd)

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


## PATH_HAIR's stock material: PATH_STANDARD's, with no emission, because slot 2
## is the highlight rather than a glow map. StandardMaterial3D has no channel
## for the highlight, so it is not rendered; its path stays in
## `nif_texture_roles` and in the context. albedo_color is left white for the
## owner to tint with the hair colour, on its own copy of the material.
##
## Vertex colour is not used as albedo. Hair meshes carry vertex colours that
## are not a colour (a white-blond diffuse renders teal through them); what the
## hair shader uses them for is not known. They stay in the mesh's ARRAY_COLOR.
static func _build_hair(context: NifMaterialContext) -> Material:
	var mat := _build_standard(context) as StandardMaterial3D
	mat.vertex_color_use_as_albedo = false
	return mat


## PATH_SKIN's stock material: PATH_STANDARD's, with no emission, because slot
## 2 is the `_sk` texture rather than a glow map; its path stays in
## `nif_texture_roles`. An actor replaces it with its own skin material (the
## race's texture and the NPC's FaceGen tint, EsmActorNode._apply_skin).
static func _build_skin(context: NifMaterialContext) -> Material:
	return _build_standard(context)


## PATH_REFRACTION's stock material: draws nothing. A fully transparent,
## unshaded blend that writes no depth, so the distortion mesh neither shows
## nor hides what is behind it. Its textures stay in `nif_texture_roles` for a
## refraction override.
static func _build_refraction(_context: NifMaterialContext) -> Material:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.0)
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return mat


## PATH_UNLIT's stock material. The mapping rules are _build_standard()'s
## (shader depth flags, NiStencilProperty, NiAlphaProperty, the light-shaft
## fades); their result is carried over into the unlit shader variant for its
## compile-time state and into the variant's uniforms. Its render state is
## also stored as `nif_render_state` metadata (render_state()).
static func _build_unlit(context: NifMaterialContext) -> Material:
	var rules := _build_standard(context) as StandardMaterial3D
	var state := _shader_render_state(rules, context.node)
	var mat := ShaderMaterial.new()
	mat.shader = _variant_shader(UNLIT_SHADER_BODY, ["unshaded"], state)
	mat.set_shader_parameter("albedo_color", rules.albedo_color)
	mat.set_shader_parameter("texture_albedo", rules.albedo_texture)
	mat.set_shader_parameter("use_vertex_color", 1.0 if rules.vertex_color_use_as_albedo else 0.0)
	_set_alpha_cutoff(mat, state)
	if bool(state["proximity_fade"]):
		mat.set_shader_parameter("proximity_fade_distance", rules.proximity_fade_distance)
	if state["distance_fade_mode"] != BaseMaterial3D.DISTANCE_FADE_DISABLED:
		mat.set_shader_parameter("distance_fade_min", rules.distance_fade_min_distance)
		mat.set_shader_parameter("distance_fade_max", rules.distance_fade_max_distance)
	mat.set_meta("nif_render_state", state)
	return mat


## PATH_LIT's stock material. As PATH_UNLIT's: _build_standard()'s rules
## decide the render state, carried into the lit shader variant and its
## uniforms, with the normal map (normal_scale 1 when present, 0 when not) and
## the glow map as emission. Its render state is stored as `nif_render_state`.
static func _build_lit(context: NifMaterialContext) -> Material:
	var rules := _build_standard(context) as StandardMaterial3D
	var state := _shader_render_state(rules, context.node)
	var mat := ShaderMaterial.new()
	mat.shader = _variant_shader(LIT_SHADER_BODY, [], state)
	mat.set_shader_parameter("albedo_color", rules.albedo_color)
	mat.set_shader_parameter("texture_albedo", rules.albedo_texture)
	mat.set_shader_parameter("use_vertex_color", 1.0 if rules.vertex_color_use_as_albedo else 0.0)
	if rules.normal_enabled:
		mat.set_shader_parameter("texture_normal", rules.normal_texture)
		mat.set_shader_parameter("normal_scale", rules.normal_scale)
	if rules.emission_enabled:
		mat.set_shader_parameter("texture_emission", rules.emission_texture)
	_set_specular(mat, context.node)
	_set_alpha_cutoff(mat, state)
	mat.set_meta("nif_render_state", state)
	return mat


## The lit shader's specular uniforms: the Specular shader flag, and the
## roughness from NiMaterialProperty's glossiness (a Phong exponent; census of
## lit shapes with the flag: 10 on 19,488, 60 on 9,375, 70 on 4,156, 5 to 100
## in all) by the Blinn-Phong to GGX mapping sqrt(2 / (glossiness + 2)). The
## material's specular colour is not used: 39,845 of the 43,821 flagged shapes
## carry a black one, and no original lit shader takes a specular colour
## constant. A shape without an NiMaterialProperty uses glossiness 10.
static func _set_specular(mat: ShaderMaterial, nd: Dictionary) -> void:
	var flagged := bool(nd.get("has_shader_flags", false)) and (int(nd.get("shader_flags1", 0)) & SHADER_FLAG1_SPECULAR) != 0
	mat.set_shader_parameter("specular_enabled", 1.0 if flagged else 0.0)
	var glossiness := maxf(float(nd.get("material_glossiness", DEFAULT_GLOSSINESS)), 0.0)
	mat.set_shader_parameter("specular_roughness", sqrt(2.0 / (glossiness + 2.0)))


## The render state for the NIF shaders: the StandardMaterial3D rules' state,
## except that a shape with both NiAlphaProperty bits is blended with its
## authored blend function and also alpha tested (`alpha_test`), as the file
## asks. StandardMaterial3D cannot do both, so its rules keep one
## (_apply_alpha()); the shaders discard at the authored threshold in the
## blended pass. The test function is GREATER on every dual-bit property
## (alpha_dual_bit.md); a threshold of 0 still rejects alpha 0, as there.
static func _shader_render_state(rules: StandardMaterial3D, nd: Dictionary) -> Dictionary:
	var state := _standard_render_state(rules)
	state["alpha_test"] = false
	if not bool(nd.get("has_alpha_property", false)):
		return state
	if not (bool(nd["alpha_blend_enabled"]) and bool(nd["alpha_test_enabled"])):
		return state
	state["transparency"] = BaseMaterial3D.TRANSPARENCY_ALPHA
	match String(nd["alpha_blend_func"]):
		"add":
			state["blend_mode"] = BaseMaterial3D.BLEND_MODE_ADD
		"multiply":
			state["blend_mode"] = BaseMaterial3D.BLEND_MODE_MUL
		_:
			state["blend_mode"] = BaseMaterial3D.BLEND_MODE_MIX
	state["alpha_test"] = true
	state["alpha_scissor_threshold"] = maxf(float(nd["alpha_threshold"]), 1.0 / 255.0)
	return state


## Sets the variant's alpha cutoff: the scissor threshold, or the alpha test
## threshold of a blended and tested shape.
static func _set_alpha_cutoff(mat: ShaderMaterial, state: Dictionary) -> void:
	var scissor: bool = state["transparency"] == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	if scissor or bool(state.get("alpha_test", false)):
		mat.set_shader_parameter("alpha_scissor_threshold", state["alpha_scissor_threshold"])


## A material's render state, whichever path built it: transparency,
## blend_mode, shading_mode, depth_draw_mode, depth_test_disabled, cull_mode,
## proximity_fade, distance_fade_mode (BaseMaterial3D's enums), and the values
## alpha_test (the NIF shaders only: blended and alpha tested), vertex_color,
## has_albedo_texture, has_normal_texture,
## has_emission_texture, albedo_color, alpha_scissor_threshold,
## proximity_fade_distance, distance_fade_max_distance. Empty for a material
## that is neither a StandardMaterial3D nor built by PATH_UNLIT.
static func render_state(material: Material) -> Dictionary:
	if material is StandardMaterial3D:
		return _standard_render_state(material as StandardMaterial3D)
	if material != null and material.has_meta("nif_render_state"):
		return material.get_meta("nif_render_state")
	return {}


static func _standard_render_state(mat: StandardMaterial3D) -> Dictionary:
	return {
		"transparency": mat.transparency,
		"blend_mode": mat.blend_mode,
		"shading_mode": mat.shading_mode,
		"depth_draw_mode": mat.depth_draw_mode,
		"depth_test_disabled": mat.get_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST),
		"cull_mode": mat.cull_mode,
		"proximity_fade": mat.proximity_fade_enabled,
		"distance_fade_mode": mat.distance_fade_mode,
		"vertex_color": mat.vertex_color_use_as_albedo,
		"has_albedo_texture": mat.albedo_texture != null,
		"has_normal_texture": mat.normal_enabled and mat.normal_texture != null,
		"has_emission_texture": mat.emission_enabled and mat.emission_texture != null,
		"albedo_color": mat.albedo_color,
		"alpha_scissor_threshold": mat.alpha_scissor_threshold,
		"proximity_fade_distance": mat.proximity_fade_distance,
		"distance_fade_max_distance": mat.distance_fade_max_distance,
	}


## The shader variant of `body` for a render state, generated once per body
## and compile-time combination and shared. `base_modes` are the body's own
## render modes (unshaded for the unlit body).
static func _variant_shader(body: String, base_modes: PackedStringArray, state: Dictionary) -> Shader:
	var modes: PackedStringArray = base_modes.duplicate()
	var defines: PackedStringArray = []
	match int(state["transparency"]):
		BaseMaterial3D.TRANSPARENCY_ALPHA:
			defines.append("NIF_ALPHA")
			match int(state["blend_mode"]):
				BaseMaterial3D.BLEND_MODE_ADD:
					modes.append("blend_add")
				BaseMaterial3D.BLEND_MODE_MUL:
					modes.append("blend_mul")
				_:
					modes.append("blend_mix")
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			defines.append("NIF_ALPHA")
			defines.append("NIF_SCISSOR")
	match int(state["depth_draw_mode"]):
		BaseMaterial3D.DEPTH_DRAW_ALWAYS:
			modes.append("depth_draw_always")
		BaseMaterial3D.DEPTH_DRAW_DISABLED:
			modes.append("depth_draw_never")
		_:
			modes.append("depth_draw_opaque")
	if bool(state["depth_test_disabled"]):
		modes.append("depth_test_disabled")
	match int(state["cull_mode"]):
		BaseMaterial3D.CULL_DISABLED:
			modes.append("cull_disabled")
		BaseMaterial3D.CULL_FRONT:
			modes.append("cull_front")
		_:
			modes.append("cull_back")
	if bool(state.get("alpha_test", false)):
		defines.append("NIF_ALPHA_TEST")
	if bool(state["proximity_fade"]):
		defines.append("NIF_PROXIMITY_FADE")
	if int(state["distance_fade_mode"]) != BaseMaterial3D.DISTANCE_FADE_DISABLED:
		defines.append("NIF_DISTANCE_FADE")
	var key := body + " | " + ", ".join(modes) + " | " + " ".join(defines)
	if _variant_shaders.has(key):
		return _variant_shaders[key]
	var code := "shader_type spatial;\nrender_mode %s;\n" % ", ".join(modes)
	for define in defines:
		code += "#define %s\n" % define
	code += "#include \"%s\"\n" % body
	var shader := Shader.new()
	shader.code = code
	_variant_shaders[key] = shader
	return shader


## The number of shader variants of `body` generated so far.
static func variant_count(body: String) -> int:
	var count := 0
	for key in _variant_shaders:
		if String(key).begins_with(body + " | "):
			count += 1
	return count


## FO3/FNV BSShaderProperty flags (xEdit wbBSShaderFlags/2). Only the two depth
## bits have a direct BaseMaterial3D mapping here. Disabling depth testing also
## disables writes in Godot, even if the authored write bit happens to be set.
static func _apply_shader_depth(mat: StandardMaterial3D, flags1: int, flags2: int) -> void:
	var depth_test := (flags1 & 0x80000000) != 0
	var depth_write := (flags2 & 0x1) != 0
	if not depth_test:
		mat.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS if depth_write else BaseMaterial3D.DEPTH_DRAW_DISABLED


## NiStencilProperty's draw mode -> cull. 2,017 shapes carry one, all draw
## mode 3 (DRAW_BOTH): two-sided, so no culling (foliage, light cards, effect
## planes). Modes 0 to 2 (CCW_OR_BOTH, CCW, CW) appear on no shipped shape
## and keep the default back-face cull; which Godot face CW and CCW name
## after the tree builder's winding conversion is not checked.
static func _apply_stencil(mat: StandardMaterial3D, nd: Dictionary) -> void:
	if not bool(nd.get("has_stencil_property", false)):
		return
	if int(nd["stencil_draw_mode"]) == STENCIL_DRAW_BOTH:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED


## NiAlphaProperty -> Godot transparency. Blend and test are separate bits and
## a shape can set either or both. StandardMaterial3D cannot combine authored
## blending with authored alpha testing, so a dual-bit shape keeps one by its
## blend function. An additive or multiply shape blends, as a blend-only one
## does: those blends are order independent, and their test thresholds (1 to 3
## of 255 on the effect cards) discard nothing visible. A mix shape uses alpha
## scissor at the authored cutoff, so its depth write keeps overlapping cards
## sorted; this drops its authored edge blending.
static func _apply_alpha(mat: StandardMaterial3D, nd: Dictionary,
		blend_enabled: bool, test_enabled: bool) -> void:
	var blend_func := String(nd["alpha_blend_func"])
	var order_independent := blend_func == "add" or blend_func == "multiply"
	if blend_enabled and test_enabled and not order_independent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		# NiAlphaProperty's GREATER 0 still rejects fully transparent pixels.
		# Godot's cutoff of 0 rejects none, so use the smallest 8-bit step.
		mat.alpha_scissor_threshold = maxf(float(nd["alpha_threshold"]), 1.0 / 255.0)
	elif blend_enabled:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# Light shafts, glow overlays and muzzle flashes ship src=SRC_ALPHA
		# dst=ONE and are genuinely additive; grime decals ship ZERO/SRC_COLOR
		# and multiply. Defaulting everything to mix loses both.
		match blend_func:
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
