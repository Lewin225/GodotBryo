@tool
extends RefCounted
class_name NifAnimationConverter

## Converts NiControllerSequences into Godot Animations. Every controlled
## block -> track rule lives here, shared by KFs (NifAnimationBuilder) and a
## NIF's own sequences (NifTreeBuilder); each caller supplies a resolver that
## turns an authored target name into the node its track addresses.
##
## Godot track types carry what Godot applies itself: position, rotation and
## scale tracks for transforms, value tracks for properties (visibility, the
## NIF shaders' instance uniforms). What our own code acts on is metadata:
## text keys, face morph weights, priorities.

const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")

## A face morph weight: a link to skeleton.nif's HeadAnims:0 morpher, whose
## channels KF clips animate by morph name (the link's interpolator ID). The
## morpher's other targets in KFs (##dgRubberBand:0 on weapons, ##VomitSpray:0,
## ##Shock01:0) are not faces.
const FACE_MORPHER_CONTROLLER := "NiGeomMorpherController"
const FACE_MORPHER_NODE := "HeadAnims:0"
## A visibility track's path is its target's path with this property: a
## discrete bool value track, and its priority is recorded under that path.
const VISIBILITY_SUFFIX := ":visible"
## An alpha track's path is its target shape's path with this property: the
## NIF shaders' alpha multiplier, an instance uniform on the shape's
## MeshInstance3D (shaders/nif_*.gdshaderinc).
const ALPHA_SUFFIX := ":instance_shader_parameters/nif_alpha"
## An NiTextureTransformController link's operation (the last part of its
## controller ID, `<shaderMap>-<slot>-<operation>`) -> its track's property on
## the target shape: the NIF shaders' base-map UV transform instance uniforms.
## Census, every NIF and KF link: slot 0 and shaderMap 0 on all; in NIFs
## TT_TRANSLATE_U 704, TT_TRANSLATE_V 672, TT_SCALE_U 177, TT_SCALE_V 153,
## TT_ROTATE 105; in KFs 185, 227, 182, 185, 125.
## A material emissive colour track's path is its target shape's path with
## this property: NiMaterialColorController links on SELF_ILLUM, as Color keys.
## Census, every NIF and KF link: SELF_ILLUM 2,525 and SPEC 135; none target AMB
## or DIFF. SPEC links stay unhandled: the lit shader has no specular colour.
const EMISSIVE_SUFFIX := ":instance_shader_parameters/nif_emissive"
## The colour target of the NiMaterialColorController links built as
## EMISSIVE_SUFFIX tracks.
const EMISSIVE_TARGET := "SELF_ILLUM"
## A material emittance multiplier track's path is its target shape's path
## with this property: BSMaterialEmittanceMultController float links.
const EMIT_MULT_SUFFIX := ":instance_shader_parameters/nif_emit_mult"
const TEXTURE_TRANSFORM_SUFFIXES := {
	"TT_TRANSLATE_U": ":instance_shader_parameters/nif_uv_offset_u",
	"TT_TRANSLATE_V": ":instance_shader_parameters/nif_uv_offset_v",
	"TT_SCALE_U": ":instance_shader_parameters/nif_uv_scale_u",
	"TT_SCALE_V": ":instance_shader_parameters/nif_uv_scale_v",
	"TT_ROTATE": ":instance_shader_parameters/nif_uv_rotate",
}


## One Animation from one NiControllerSequence. `resolver` takes an authored
## target name and returns {path: the track path's node part, shape: whether
## it is a shape's MeshInstance3D, bone: whether it is a Skeleton3D bone}, or
## an empty Dictionary when the name addresses nothing; such a link is listed
## in `nif_unhandled_controller_targets`. Each target that receives a transform
## track is appended to `moved`.
static func build_animation(sequence: Dictionary, resolver: Callable, moved: Array = []) -> Animation:
	var animation := Animation.new()
	var start := float(sequence.get("start_time", 0.0))
	var stop := float(sequence.get("stop_time", start))
	animation.length = maxf(stop - start, 0.001)
	match int(sequence.get("cycle_type", 2)):
		0: animation.loop_mode = Animation.LOOP_LINEAR
		1: animation.loop_mode = Animation.LOOP_PINGPONG
		_: animation.loop_mode = Animation.LOOP_NONE

	var unhandled: PackedStringArray = []
	var face_tracks := {}
	var track_priorities := {}
	var face_track_priorities := {}
	for controlled in sequence.get("controlled_blocks", []):
		var block := controlled as Dictionary
		var interpolator: Dictionary = block.get("interpolator", {})
		var target := String(block.get("node_name", ""))
		if not bool(interpolator.get("present", false)):
			continue
		if _is_face_track(block):
			_add_face_track(face_tracks, block, start)
			_add_priority(face_track_priorities, String(block["interpolator_id"]), block)
			continue
		if target.is_empty():
			unhandled.append("<unnamed>:%s" % String(interpolator.get("kind", "")))
			continue
		var resolved: Dictionary = resolver.call(target)
		var kind := String(interpolator.get("kind", ""))
		if resolved.is_empty():
			unhandled.append(target + ":" + kind)
			continue
		var path := String(resolved["path"])
		if _is_visibility_block(block) and not bool(resolved["bone"]):
			_add_visibility_track(animation, path, interpolator, start)
			_add_priority(track_priorities, path + VISIBILITY_SUFFIX, block)
			continue
		if _is_alpha_block(block) and bool(resolved["shape"]):
			if _add_float_track(animation, path + ALPHA_SUFFIX, interpolator, start):
				_add_priority(track_priorities, path + ALPHA_SUFFIX, block)
			continue
		if _texture_transform_suffix(block) != "" and bool(resolved["shape"]):
			var uv_path := path + _texture_transform_suffix(block)
			if _add_float_track(animation, uv_path, interpolator, start):
				_add_priority(track_priorities, uv_path, block)
			continue
		if _is_emissive_block(block) and bool(resolved["shape"]):
			if _add_color_track(animation, path + EMISSIVE_SUFFIX, interpolator, start):
				_add_priority(track_priorities, path + EMISSIVE_SUFFIX, block)
			continue
		if _is_emit_mult_block(block) and bool(resolved["shape"]):
			if _add_float_track(animation, path + EMIT_MULT_SUFFIX, interpolator, start):
				_add_priority(track_priorities, path + EMIT_MULT_SUFFIX, block)
			continue
		if kind != "transform":
			# Other property controllers (specular colour, other texture
			# slots, refraction, particles) are not built yet; the raw source
			# stays available through NifSource.
			unhandled.append(target + ":" + kind)
			continue
		if _add_transform_tracks(animation, path, interpolator, start) > 0:
			_add_priority(track_priorities, path, block)
			moved.append(target)

	animation.set_meta("nif_sequence_name", String(sequence.get("name", "")))
	animation.set_meta("nif_accum_root", String(sequence.get("accum_root_name", "")))
	animation.set_meta("nif_start_time", start)
	animation.set_meta("nif_text_keys", sequence.get("text_keys", []))
	animation.set_meta("nif_track_priorities", track_priorities)
	if not face_tracks.is_empty():
		animation.set_meta("nif_face_tracks", face_tracks)
		animation.set_meta("nif_face_track_priorities", face_track_priorities)
	if not unhandled.is_empty():
		animation.set_meta("nif_unhandled_controller_targets", unhandled)
	return animation


## Whether a controlled block drives a node's visibility: a bool interpolator
## on an NiVisController (1,677 of the corpus's 1,779 bool blocks; the rest
## drive particle emitters and stay unhandled).
static func _is_visibility_block(block: Dictionary) -> bool:
	var interpolator: Dictionary = block.get("interpolator", {})
	if String(interpolator.get("kind", "")) != "bool":
		return false
	return String(block.get("controller_type", "")) == "NiVisController"


## Adds a discrete value track `<target>:visible` from a bool interpolator's
## keys, or its static value as one key at 0 when it has none (1,243 of the
## corpus's bool blocks).
static func _add_visibility_track(animation: Animation, target: String,
		interpolator: Dictionary, start: float) -> void:
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath(target + VISIBILITY_SUFFIX))
	animation.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
	var keys: Array = interpolator.get("float_keys", [])
	if keys.is_empty():
		animation.track_insert_key(track, 0.0, float(interpolator.get("static_float", 1.0)) != 0.0)
		return
	for key in keys:
		animation.track_insert_key(track, maxf(float(key["time"]) - start, 0.0), float(key["value"]) != 0.0)


## Whether a controlled block animates a shape's material alpha: a float
## interpolator on an NiAlphaController. 1,182 links in the shipped
## corpus' NIFs, all float; 1,102 name a shape (1,010 unlit, 92 lit), the rest a name
## that is no shape.
static func _is_alpha_block(block: Dictionary) -> bool:
	var interpolator: Dictionary = block.get("interpolator", {})
	if String(interpolator.get("kind", "")) != "float":
		return false
	return String(block.get("controller_type", "")) == "NiAlphaController"


## Whether a controlled block animates a shape's emissive colour: a point3
## interpolator on an NiMaterialColorController whose target (the controller
## ID, on sequence links and free controllers alike) is SELF_ILLUM.
static func _is_emissive_block(block: Dictionary) -> bool:
	var interpolator: Dictionary = block.get("interpolator", {})
	if String(interpolator.get("kind", "")) != "point3":
		return false
	if String(block.get("controller_type", "")) != "NiMaterialColorController":
		return false
	return String(block.get("controller_id", "")) == EMISSIVE_TARGET


## Whether a controlled block animates a shape's emittance multiplier: a float
## interpolator on a BSMaterialEmittanceMultController.
static func _is_emit_mult_block(block: Dictionary) -> bool:
	var interpolator: Dictionary = block.get("interpolator", {})
	if String(interpolator.get("kind", "")) != "float":
		return false
	return String(block.get("controller_type", "")) == "BSMaterialEmittanceMultController"


## Adds a Color value track at `path` from a point3 interpolator's keys (r, g,
## b; alpha 1), played linearly, or its static value as one key at 0 when it
## has none (12 SELF_ILLUM sequence links). Returns whether a track was added.
static func _add_color_track(animation: Animation, path: String,
		interpolator: Dictionary, start: float) -> bool:
	var keys: Array = interpolator.get("point3_keys", [])
	var has_static := bool(interpolator.get("has_static_point3", false))
	if keys.is_empty() and not has_static:
		return false
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath(path))
	animation.value_track_set_update_mode(track, Animation.UPDATE_CONTINUOUS)
	animation.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
	if keys.is_empty():
		var value: Vector3 = interpolator["static_point3"]
		animation.track_insert_key(track, 0.0, Color(value.x, value.y, value.z))
		return true
	for key in keys:
		var value: Vector3 = key["value"]
		animation.track_insert_key(track, maxf(float(key["time"]) - start, 0.0), Color(value.x, value.y, value.z))
	return true


## The track property suffix of an NiTextureTransformController float link on
## the base map (slot 0), or "" for any other link. Its operation is read from
## the controller ID, which KF links carry too: no KF link reaches its
## controller block.
static func _texture_transform_suffix(block: Dictionary) -> String:
	if String(block.get("controller_type", "")) != "NiTextureTransformController":
		return ""
	var interpolator: Dictionary = block.get("interpolator", {})
	if String(interpolator.get("kind", "")) != "float":
		return ""
	var parts := String(block.get("controller_id", "")).split("-")
	if parts.size() != 3 or parts[1] != "0":
		return ""
	return String(TEXTURE_TRANSFORM_SUFFIXES.get(parts[2], ""))


## Adds a value track at `path` from a float interpolator's keys, played
## linearly whatever their authored interpolation, or its static value as one
## key at 0 when it has none (85 of the NiAlphaController links). Returns
## whether a track was added: a link with neither keys nor a set static value
## adds none.
static func _add_float_track(animation: Animation, path: String,
		interpolator: Dictionary, start: float) -> bool:
	var keys: Array = interpolator.get("float_keys", [])
	var static_value := float(interpolator.get("static_float", 0.0))
	var has_static := bool(interpolator.get("has_static_float", false)) and _is_set(static_value)
	if keys.is_empty() and not has_static:
		return false
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath(path))
	animation.value_track_set_update_mode(track, Animation.UPDATE_CONTINUOUS)
	animation.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
	if keys.is_empty():
		animation.track_insert_key(track, 0.0, static_value)
		return true
	for key in keys:
		animation.track_insert_key(track, maxf(float(key["time"]) - start, 0.0), float(key["value"]))
	return true


## Records the link's priority byte under `key` (a track path or a morph
## name). A key met twice keeps its first priority; no transform target in the
## shipped KFs is linked twice in one sequence with different priorities.
static func _add_priority(priorities: Dictionary, key: String, block: Dictionary) -> void:
	if priorities.has(key):
		return
	priorities[key] = int(block.get("priority", 0))


## Whether an interpolator's static value is set: NIF writes an unset one as
## -FLT_MAX (still beyond 1e30 after the metre conversion).
static func _is_set(value: float) -> bool:
	return is_finite(value) and absf(value) < 1.0e30


static func _is_face_track(block: Dictionary) -> bool:
	if String(block.get("controller_type", "")) != FACE_MORPHER_CONTROLLER:
		return false
	if String(block.get("node_name", "")) != FACE_MORPHER_NODE:
		return false
	var interpolator: Dictionary = block.get("interpolator", {})
	return String(interpolator.get("kind", "")) == "float" \
			and not String(block.get("interpolator_id", "")).is_empty()


## Adds a morph weight track to `face_tracks`: morph name -> PackedFloat32Array
## of time, value pairs, times rebased as transform keys are. A link without
## keys holds its static value when it has one. A name met twice keeps its first track.
## Keys play linearly whatever their authored interpolation.
static func _add_face_track(face_tracks: Dictionary, block: Dictionary, start: float) -> void:
	var name := String(block["interpolator_id"])
	if face_tracks.has(name):
		return
	var interpolator: Dictionary = block["interpolator"]
	var pairs := PackedFloat32Array()
	for key: Dictionary in interpolator.get("float_keys", []):
		pairs.append(maxf(float(key["time"]) - start, 0.0))
		pairs.append(float(key["value"]))
	var static_value := float(interpolator.get("static_float", 0.0))
	# NIF writes an unset static value as -FLT_MAX.
	if pairs.is_empty() and bool(interpolator.get("has_static_float", false)) and absf(static_value) < 1.0e30:
		pairs.append(0.0)
		pairs.append(static_value)
	if not pairs.is_empty():
		face_tracks[name] = pairs


## Keys are already converted to Godot coordinates by NifSource. Times are
## rebased because Godot animation resources begin at zero while a sequence
## records its own source start time as metadata. A channel without keys whose
## interpolator has a set static value becomes a one-key track holding it: the
## link pins that channel for the sequence. A static scale of 1 adds no track,
## as a missing scale track leaves the bone at scale 1.
static func _add_transform_tracks(animation: Animation, target: String,
		interpolator: Dictionary, start: float) -> int:
	var added := 0
	var resampled := bool(interpolator.get("resampled", false))
	var has_static := bool(interpolator.get("has_static_transform", false))
	var position_keys: Array = interpolator.get("translation_keys", [])
	var static_position: Vector3 = interpolator.get("translation", Vector3.ZERO)
	if position_keys.is_empty() and has_static and _is_set(static_position.x):
		var track := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(track, NodePath(target))
		animation.position_track_insert_key(track, 0.0, static_position)
		added += 1
	if not position_keys.is_empty():
		var track := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(track, NodePath(target))
		animation.track_set_interpolation_type(track, _track_interpolation(position_keys, resampled))
		for key in position_keys:
			animation.position_track_insert_key(track, maxf(float(key["time"]) - start, 0.0),
				Vector3(key["value"]))
		added += 1
	var rotation_keys: Array = interpolator.get("rotation_keys", [])
	var static_rotation: Quaternion = interpolator.get("rotation", Quaternion.IDENTITY)
	if rotation_keys.is_empty() and has_static and _is_set(static_rotation.w):
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath(target))
		animation.rotation_track_insert_key(track, 0.0, static_rotation.normalized())
		added += 1
	if not rotation_keys.is_empty():
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath(target))
		animation.track_set_interpolation_type(track, _track_interpolation(rotation_keys, resampled))
		for key in rotation_keys:
			animation.rotation_track_insert_key(track, maxf(float(key["time"]) - start, 0.0),
				(key["value"] as Quaternion).normalized())
		added += 1
	var scale_keys: Array = interpolator.get("scale_keys", [])
	var static_scale := float(interpolator.get("scale", 1.0))
	if scale_keys.is_empty() and has_static and _is_set(static_scale) and not is_equal_approx(static_scale, 1.0):
		var track := animation.add_track(Animation.TYPE_SCALE_3D)
		animation.track_set_path(track, NodePath(target))
		animation.scale_track_insert_key(track, 0.0, Vector3(static_scale, static_scale, static_scale))
		added += 1
	if not scale_keys.is_empty():
		var track := animation.add_track(Animation.TYPE_SCALE_3D)
		animation.track_set_path(track, NodePath(target))
		animation.track_set_interpolation_type(track, _track_interpolation(scale_keys, resampled))
		for key in scale_keys:
			var value := float(key["value"])
			animation.scale_track_insert_key(track, maxf(float(key["time"]) - start, 0.0),
				Vector3(value, value, value))
		added += 1
	return added


## Gamebryo interpolates PER KEY; Godot interpolates PER TRACK. The gap does
## not close, so this is a policy, not a mapping:
##
##   QUADRATIC / TBC  ->  CUBIC    the authored intent is "it stops softly".
##                                 Godot's cubic derives its curve from
##                                 neighbouring keys rather than the authored
##                                 tangents, which are not extracted -- close
##                                 enough for a designer's easing, and far
##                                 cheaper than baking a dense key run.
##   CONST            ->  LINEAR   DELIBERATE. A large share of the corpus is
##                                 authored stepped at the engine's ~30 Hz
##                                 update. That read as fine on a 360 and
##                                 reads as juddering on modern hardware;
##                                 smoothing it is an improvement, not a loss.
##   LINEAR / other   ->  LINEAR
##
## A mixed channel takes CUBIC only when eased keys are the MAJORITY. Cubic
## through keys authored linear invents overshoot at direction reversals,
## so the conservative side is the default one.
static func _track_interpolation(keys: Array, resampled: bool) -> int:
	if resampled:
		return Animation.INTERPOLATION_LINEAR
	var eased := 0
	for key in keys:
		match String(key.get("interp", "")):
			"quadratic", "tbc": eased += 1
	return Animation.INTERPOLATION_CUBIC if eased * 2 > keys.size() else Animation.INTERPOLATION_LINEAR
