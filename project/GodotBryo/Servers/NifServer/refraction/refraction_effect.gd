@tool
extends CompositorEffect
class_name RefractionEffect

## Offsets the finished frame by the refraction shapes' distortion buffer,
## after the transparent pass, so particles and smoke behind a shock sphere
## bend too: the original's ISREFRACT image-space pass. RefractionCapture
## draws the buffer and sets distortion_texture every frame.
##
## Two compute passes per view (COPY_SHADER, DISTORT_SHADER): the colour is
## copied, then each pixel a shape covers reads the copy at its UV plus the
## shape's offset. A pixel whose
## opaque depth is nearer than the shape's keeps its colour (the shape is
## behind a wall). ISREFRACT's Tint input is not read: where its value comes
## from is not found yet.

## The distortion buffer's RenderingDevice texture (RefractionCapture's
## viewport); an invalid RID draws nothing.
var distortion_texture := RID()

var _rd: RenderingDevice = null
var _copy_shader := RID()
var _copy_pipeline := RID()
var _distort_shader := RID()
var _distort_pipeline := RID()
var _sampler := RID()
## The colour copy, recreated when the colour buffer's size or format changes.
var _copy := RID()
var _copy_size := Vector2i.ZERO
var _copy_format := -1

## Copies the colour buffer into the copy texture.
const COPY_SHADER := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform readonly image2D color_image;
layout(rgba16f, set = 0, binding = 1) uniform writeonly image2D copy_image;

layout(push_constant, std430) uniform Params {
	vec2 size;
	vec2 pad;
} params;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (texel.x >= int(params.size.x) || texel.y >= int(params.size.y)) {
		return;
	}
	imageStore(copy_image, texel, imageLoad(color_image, texel));
}
"""

## Writes each covered pixel of the colour buffer from the copy at its UV plus
## the shape's offset, unless opaque geometry is nearer than the shape (Godot's
## reversed Z: a larger depth is nearer).
const DISTORT_SHADER := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform writeonly image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D copy_texture;
layout(set = 0, binding = 2) uniform sampler2D depth_texture;
layout(set = 0, binding = 3) uniform sampler2D distortion_texture;

layout(push_constant, std430) uniform Params {
	vec2 size;
	vec2 pad;
} params;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (texel.x >= int(params.size.x) || texel.y >= int(params.size.y)) {
		return;
	}
	vec2 uv = (vec2(texel) + 0.5) / params.size;
	vec4 distortion = texture(distortion_texture, uv);
	// Blue is the shape's depth; 0 is the cleared background, no shape.
	if (distortion.b <= 0.0) {
		return;
	}
	float scene_depth = texture(depth_texture, uv).r;
	if (scene_depth > distortion.b) {
		return;
	}
	vec2 source_uv = clamp(uv + (distortion.rg - 0.5), vec2(0.0), vec2(1.0));
	imageStore(color_image, texel, texture(copy_texture, source_uv));
}
"""


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	_free(_copy)
	_free(_sampler)
	_free(_copy_shader)
	_free(_distort_shader)


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	if not distortion_texture.is_valid():
		return
	if _rd == null and not _create():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var groups := Vector3i((size.x + 7) / 8, (size.y + 7) / 8, 1)
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		_ensure_copy(color, size)
		var params := PackedFloat32Array([size.x, size.y, 0.0, 0.0]).to_byte_array()
		var copy_set := UniformSetCacheRD.get_cache(_copy_shader, 0, [
			_image_uniform(0, color),
			_image_uniform(1, _copy),
		])
		var distort_set := UniformSetCacheRD.get_cache(_distort_shader, 0, [
			_image_uniform(0, color),
			_sampler_uniform(1, _copy),
			_sampler_uniform(2, depth),
			_sampler_uniform(3, distortion_texture),
		])
		_dispatch(_copy_pipeline, copy_set, params, groups)
		_dispatch(_distort_pipeline, distort_set, params, groups)


func _dispatch(pipeline: RID, uniform_set: RID, params: PackedByteArray, groups: Vector3i) -> void:
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_set_push_constant(list, params, params.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)
	_rd.compute_list_end()


func _create() -> bool:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return false
	_copy_shader = _compile(COPY_SHADER)
	_distort_shader = _compile(DISTORT_SHADER)
	if not _copy_shader.is_valid() or not _distort_shader.is_valid():
		_rd = null
		return false
	_copy_pipeline = _rd.compute_pipeline_create(_copy_shader)
	_distort_pipeline = _rd.compute_pipeline_create(_distort_shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)
	return true


func _compile(code: String) -> RID:
	var source := RDShaderSource.new()
	source.source_compute = code
	var spirv := _rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error("RefractionEffect: %s" % spirv.compile_error_compute)
		return RID()
	return _rd.shader_create_from_spirv(spirv)


## A copy texture of the colour buffer's size and format, sampled and stored.
func _ensure_copy(color: RID, size: Vector2i) -> void:
	var format := _rd.texture_get_format(color)
	if _copy.is_valid() and _copy_size == size and _copy_format == format.format:
		return
	_free(_copy)
	var copy_format := RDTextureFormat.new()
	copy_format.format = format.format
	copy_format.width = size.x
	copy_format.height = size.y
	copy_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_copy = _rd.texture_create(copy_format, RDTextureView.new())
	_copy_size = size
	_copy_format = format.format


func _image_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


func _sampler_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(_sampler)
	uniform.add_id(texture)
	return uniform


func _free(rid: RID) -> void:
	if rid.is_valid():
		_rd.free_rid(rid)
