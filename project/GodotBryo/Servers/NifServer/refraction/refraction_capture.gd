extends Node
class_name RefractionCapture

## Draws the refraction shapes' distortion buffer and installs RefractionEffect,
## which offsets the finished frame by it. The original draws its refraction
## shapes into a buffer of their own (pixel shaders taking only NormalMap and
## PSRefractionPower) and an image-space pass, ISREFRACT, distorts the frame;
## this is that split in Godot.
##
## A SubViewport shares the main viewport's World3D. Its camera copies the
## main viewport's active camera every frame (transform, projection, near and
## far, so depths match) and sees only LAYER_MASK, where NifTreeBuilder puts
## refraction shapes; nif_refraction.gdshader writes their offsets and depth
## there and discards under any other camera. The viewport renders only while
## a refraction shape is in the tree (GROUP), at RESOLUTION_SCALE of the main
## viewport.
##
## A scene without this node draws no refraction: the shapes discard.

const RefractionEffectScript := preload("res://GodotBryo/Servers/NifServer/refraction/refraction_effect.gd")

## The visual layer refraction shapes are on, 1-based as in the editor.
const LAYER := 20
## The distortion camera's cull mask: LAYER alone. nif_refraction.gdshader
## compares CAMERA_VISIBLE_LAYERS with this value.
const LAYER_MASK := 1 << (LAYER - 1)
## The group NifTreeBuilder adds refraction shapes to.
const GROUP := &"nif_refraction"
## The distortion buffer's background, as stored: no offset, no shape.
const NEUTRAL := Color(0.5, 0.5, 0.0)
## The distortion buffer's size against the main viewport's.
const RESOLUTION_SCALE := 0.5

## The WorldEnvironment whose compositor gets RefractionEffect.
@export var world_environment: WorldEnvironment

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _effect: CompositorEffect = null


func _ready() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "DistortionViewport"
	_viewport.use_hdr_2d = true
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_viewport.use_taa = false
	_viewport.positional_shadow_atlas_size = 0
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.name = "DistortionCamera"
	_camera.cull_mask = LAYER_MASK
	_camera.environment = _distortion_environment()
	# The WorldEnvironment's compositor runs on every viewport of its world,
	# this one included: RefractionEffect would distort the buffer by itself,
	# compounding the offsets and moving the depths. A camera's own compositor
	# replaces the world's, so an empty one keeps the buffer as the shapes
	# wrote it.
	_camera.compositor = Compositor.new()
	# The WorldEnvironment's camera attributes apply to every camera without
	# its own: game.tscn's auto exposure scaled the buffer's offsets and
	# depths, and its far depth of field (from 26 m) blurred them. Plain
	# attributes (exposure 1, no auto exposure, no blur) keep them as written.
	_camera.attributes = CameraAttributesPractical.new()
	_viewport.add_child(_camera)
	_effect = RefractionEffectScript.new()
	if world_environment != null:
		if world_environment.compositor == null:
			world_environment.compositor = Compositor.new()
		var effects := world_environment.compositor.compositor_effects
		effects.append(_effect)
		world_environment.compositor.compositor_effects = effects


func _exit_tree() -> void:
	if world_environment == null or world_environment.compositor == null or _effect == null:
		return
	var effects := world_environment.compositor.compositor_effects
	effects.erase(_effect)
	world_environment.compositor.compositor_effects = effects


func _process(_delta: float) -> void:
	var main := get_viewport().get_camera_3d()
	var active := main != null and get_tree().get_node_count_in_group(GROUP) > 0
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	_effect.enabled = active
	if not active:
		return
	var size := Vector2(get_viewport().get_visible_rect().size) * RESOLUTION_SCALE
	_viewport.size = Vector2i(maxi(int(size.x), 1), maxi(int(size.y), 1))
	_camera.global_transform = main.global_transform
	_camera.projection = main.projection
	_camera.keep_aspect = main.keep_aspect
	_camera.fov = main.fov
	_camera.size = main.size
	_camera.frustum_offset = main.frustum_offset
	_camera.h_offset = main.h_offset
	_camera.v_offset = main.v_offset
	_camera.near = main.near
	_camera.far = main.far
	_effect.distortion_texture = RenderingServer.texture_get_rd_texture(_viewport.get_texture().get_rid())


## The distortion camera's environment: a background of no offset (0.5 red
## and green) and no shape (blue 0: a shape's depth is above 0, Godot's
## reversed Z putting the far plane at 0), and a linear tonemap at exposure 1,
## so the shader's output reaches the buffer as written. The buffer is read
## with linear filtering at a different size, so a pixel on a shape's edge
## mixes the shape with the background: a neutral background leaves it a
## smaller offset of the shape's own, where black (an offset of -0.5) pulled
## it half the screen.
static func _distortion_environment() -> Environment:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	# The background colour is taken as sRGB and stored linear (0.5 became
	# 0.214): encoded here, it is stored as NEUTRAL.
	environment.background_color = NEUTRAL.linear_to_srgb()
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.tonemap_exposure = 1.0
	return environment
