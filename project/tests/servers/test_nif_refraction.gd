extends Node3D

## Refraction (RefractionCapture, RefractionEffect, nif_refraction.gdshader),
## drawn with the real renderer (run without --headless). An orthographic
## camera looks at a blended backdrop whose red is its screen U; a refraction
## quad in the middle, its normal map pointing +X at strength 0.1, offsets
## the frame by +0.1 in U. Checked: the distortion buffer holds the encoded
## offset and the quad's depth (0 where uncovered); a covered pixel shows the backdrop from 0.1 of the
## screen to its right (the backdrop is transparent, so the transparent pass
## is bent); a pixel behind an opaque wall in front of the quad is the wall;
## an uncovered pixel is the backdrop as drawn.

const NifMaterialBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_material_builder.gd")
const RefractionCaptureScript := preload("res://GodotBryo/Servers/NifServer/refraction/refraction_capture.gd")
const STRENGTH := 0.1
const SETTLE_FRAMES := 20
## Red levels in the 8-bit frame differ by at least this much between U and
## U + STRENGTH over the backdrop's range.
const COLOR_TOLERANCE := 0.03

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	# game.tscn's camera attributes: auto exposure and a far depth of field.
	# They must not reach the distortion buffer.
	var attributes := CameraAttributesPractical.new()
	attributes.auto_exposure_enabled = true
	attributes.auto_exposure_scale = 0.2
	attributes.auto_exposure_min_sensitivity = 200.0
	attributes.auto_exposure_max_sensitivity = 400.0
	attributes.dof_blur_far_enabled = true
	attributes.dof_blur_far_distance = 1.0
	attributes.dof_blur_far_transition = 1.0
	environment.camera_attributes = attributes
	add_child(environment)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position = Vector3(0, 0, 5)
	add_child(camera)
	camera.make_current()
	add_child(_quad(Vector3(0, 0, -1), Vector2(20, 20), _backdrop_material()))
	# Below the screen's centre (world y -0.75 to -0.25, screen V 0.625 to
	# 0.875), so a buffer read upside down would distort the mirrored band.
	var refraction := _quad(Vector3(0, -0.5, 0), Vector2(1, 0.5), _refraction_material())
	refraction.layers |= RefractionCaptureScript.LAYER_MASK
	refraction.add_to_group(RefractionCaptureScript.GROUP)
	refraction.set_instance_shader_parameter("nif_refraction_strength", STRENGTH)
	add_child(refraction)
	# The wall covers the quad's left half, in front of it.
	add_child(_quad(Vector3(-0.25, -0.5, 1), Vector2(0.5, 0.5), _wall_material()))
	var capture := RefractionCaptureScript.new()
	capture.world_environment = environment
	add_child(capture)
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	_check_distortion_buffer(capture)
	_check_frame()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_distortion_buffer(capture: Node) -> void:
	print("--- distortion buffer ---")
	var viewport := capture.get_node("DistortionViewport") as SubViewport
	var image := viewport.get_texture().get_image()
	var below := image.get_pixel(int(image.get_width() * 0.55), int(image.get_height() * 0.75))
	check(below.b > 0.0, "the quad covers the buffer's centre (depth %.3f)" % below.b)
	check(absf(below.r - (0.5 + STRENGTH)) < 0.01, "its red is 0.5 + the offset (%.3f)" % below.r)
	check(absf(below.g - 0.5) < 0.01, "its green is 0.5 (%.3f)" % below.g)
	var camera := capture.get_node("DistortionViewport/DistortionCamera") as Camera3D
	check(camera.compositor != null and camera.compositor.compositor_effects.is_empty(),
		"the distortion camera has its own empty compositor, so RefractionEffect does not run on the buffer")
	var outside := image.get_pixel(2, 2)
	check(outside.b <= 0.0, "a corner is uncovered (depth %.3f)" % outside.b)
	check(absf(outside.r - 0.5) < 0.01 and absf(outside.g - 0.5) < 0.01,
		"and holds no offset, so a shape's filtered edge is not pulled (%.3f, %.3f)" % [outside.r, outside.g])


func _check_frame() -> void:
	print("--- frame ---")
	var image := get_viewport().get_texture().get_image()
	var covered := _pixel(image, 0.55, 0.75)
	var source := _pixel(image, 0.55 + STRENGTH, 0.95)
	var plain := _pixel(image, 0.55, 0.95)
	# The band mirrored about the centre is not covered: it keeps its colour.
	var mirrored := _pixel(image, 0.55, 0.25)
	check(absf(mirrored.r - plain.r) < COLOR_TOLERANCE,
		"the mirrored band is undistorted (%.3f, plain %.3f)" % [mirrored.r, plain.r])
	check(absf(covered.r - source.r) < COLOR_TOLERANCE,
		"a covered pixel shows the backdrop at U + %.1f (%.3f, there %.3f)" % [STRENGTH, covered.r, source.r])
	check(absf(covered.r - plain.r) > COLOR_TOLERANCE,
		"and not the backdrop at its own U (%.3f)" % plain.r)
	var walled := _pixel(image, 0.45, 0.75)
	# The main frame is auto-exposed, so the wall's blue is not exactly 1.
	check(walled.b > 0.5 and walled.r < 0.05, "a pixel behind the wall is the wall (%s)" % walled)


func _pixel(image: Image, u: float, v: float) -> Color:
	return image.get_pixel(int(u * (image.get_width() - 1)), int(v * (image.get_height() - 1)))


func _quad(position: Vector3, size: Vector2, material: Material) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = position
	instance.material_override = material
	return instance


## Blended, so it draws in the transparent pass; red is its screen U.
func _backdrop_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never;
void fragment() {
	ALBEDO = vec3(SCREEN_UV.x, 0.0, 0.0);
	ALPHA = 1.0;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func _wall_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0, 0, 1)
	return material


## The refraction shader with a normal map whose xy is (1, 0.5): an offset of
## +strength in U.
func _refraction_material() -> ShaderMaterial:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 0.5, 1.0, 1.0))
	var material := ShaderMaterial.new()
	material.shader = NifMaterialBuilderScript.REFRACTION_SHADER
	material.set_shader_parameter("texture_normal", ImageTexture.create_from_image(image))
	return material
