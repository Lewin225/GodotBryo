#ifndef NIF_READER_GD_H
#define NIF_READER_GD_H

#include "nif_types.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace godot {

// Thin Godot-facing wrapper around nif::load_mesh() (native/src/nif/nif_loader.{h,cpp},
// itself a thin wrapper over the vendored nifly library). Real parsing logic
// lives outside Godot entirely, per the pattern established by BsaReader
// (0.1) and EsmReader (0.2).
class NifReader : public RefCounted {
	GDCLASS(NifReader, RefCounted)

protected:
	static void _bind_methods();

public:
	bool load(const PackedByteArray &bytes);
	String get_last_error() const { return last_error_; }
	String get_nif_version() const;

	int get_submesh_count() const;
	String get_submesh_name(int index) const;
	PackedFloat32Array get_positions(int index) const;
	PackedFloat32Array get_normals(int index) const;
	PackedFloat32Array get_uvs(int index) const;
	// Per-vertex RGBA, or empty if the shape has none — see
	// phases/2/06-vertex-color-transparency.md.
	PackedColorArray get_colors(int index) const;
	PackedInt32Array get_indices(int index) const;
	String get_texture_path(int index) const;
	// phases/2/01-material-pipeline.md: additional BSShaderTextureSet slots
	// beyond slot 0 (diffuse) — see nif_types.h's SubMesh comment for the
	// slot-index convention. Empty string if the shape has none.
	String get_normal_texture_path(int index) const;
	String get_glow_texture_path(int index) const;
	// { "has_alpha_property": bool, "blend_enabled": bool, "test_enabled":
	// bool, "threshold": float (0..1), "blend_func": int } — from the
	// shape's NiAlphaProperty, or has_alpha_property=false if it has none
	// (treat as fully opaque). "blend_func" (only meaningful when
	// blend_enabled) is nif::SubMesh::BlendFunc as a plain int: 0=mix
	// (ordinary alpha blend), 1=add (additive, e.g. light-shaft/glow
	// effects), 2=multiply — see nif_types.h for the real-data sourcing.
	Dictionary get_alpha_info(int index) const;
	// True if the shape's NIF shader is BSShaderNoLightingProperty (see
	// phases/2/06-vertex-color-transparency.md) — Bethesda's own signal
	// that scene lighting should not affect this shape.
	bool is_unlit(int index) const;
	Dictionary get_no_lighting_falloff(int index) const;
	bool is_double_sided(int index) const;
	Transform3D get_transform(int index) const;
	// Index into get_scene_nodes() for this shape's own node, or -1 if
	// parented directly under the NIF's root — see nif_types.h's
	// SubMesh::owning_node_index doc comment. Only meaningful for
	// Dynamic-path resolution.
	int get_submesh_owning_node_index(int index) const;

	// Writes a self-contained .gltf for the currently loaded mesh (see
	// gltf_export.h) — the smoke-test deliverable for this task.
	bool export_gltf(const String &path) const;

	// Every extracted bhk* collision shape (phases/1/02-collision-extraction.md),
	// as an Array of Dictionary: { "kind": String ("triangle_mesh"/"box"/
	// "sphere"/"capsule"/"convex_hull"), "name": String, "transform":
	// Transform3D, and kind-specific fields — "positions"/"indices"
	// (triangle_mesh), "positions" (convex_hull), "half_extents" (box, a
	// Vector3), "radius" (sphere), "point_a"/"point_b"/"capsule_radius"
	// (capsule). All distances already in meters.
	Array get_collision_shapes() const;
	// True if any NiAVObject in the NIF has Havok collision authored at all
	// (a non-empty collisionRef), independent of whether get_collision_shapes()
	// could actually extract it — see nif_types.h's Mesh::has_collision_data.
	bool has_collision_data() const { return mesh_.has_collision_data; }

	// phases/3/00-door-completion.md, Part A: rigid single-node transform
	// animation (NiControllerManager/NiControllerSequence) — see
	// nif_types.h's own AnimationSequence/AnimationTrack doc comments for
	// the real-data census that scoped this. Every Array of Dictionary,
	// mirroring the source struct fields directly:
	//   sequence: { "name": String, "cycle_type": int (0=loop/1=reverse/
	//     2=clamp), "start_time": float, "stop_time": float,
	//     "tracks": Array of track }
	//   track: { "target_node_name": String, "has_quaternion_keys": bool,
	//     "quaternion_keys": Array of quat_key, "has_axis_keys": bool,
	//     "x_rotation_keys"/"y_rotation_keys"/"z_rotation_keys": Array of
	//     float_key (radians), "translation_keys": Array of vec3_key
	//     (meters), "scale_keys": Array of float_key (relative multiplier) }
	//   float_key: { "time": float, "value": float, "forward": float,
	//     "backward": float, "tension": float, "bias": float,
	//     "continuity": float, "interp": int } — interp is
	//     nif::KeyInterpolation as a plain int (0=none/1=linear/
	//     2=quadratic/3=tbc/4=constant); forward/backward only meaningful
	//     when interp==2, tension/bias/continuity only when interp==3.
	//   vec3_key: same shape as float_key but "value"/"forward"/"backward"
	//     are Vector3.
	//   quat_key: { "time": float, "value": Quaternion, "interp": int }
	Array get_animation_sequences() const;

	// phases/3/00-door-completion.md follow-up: general node-graph
	// preservation (nif_types.h's SceneNode doc comment) — every non-root
	// NiAVObject in the file, for resolving a named node (animation
	// target_node_name, or any future lookup) to a real placement. Array of
	// Dictionary: { "name": String, "parent_index": int (-1 if parented
	// directly under the NIF's root), "transform": Transform3D (LOCAL to
	// the immediate parent — NOT flattened to root, unlike get_transform()) }.
	Array get_scene_nodes() const;

	// Issue #46: real skeletal skinning data (BSDismemberSkinInstance/
	// NiSkinInstance + NiSkinData + NiSkinPartition) — see nif_types.h's
	// SkinData doc comment. One Dictionary per skinned NiShape:
	//   { "target_node_name": String — the owning shape's own name, joins
	//       to get_submesh_name() (1:1, a shape has at most one skin
	//       instance),
	//     "bone_names": PackedStringArray — per-shape bone order; indices
	//       below are into THIS array, not global across the NIF,
	//     "bone_bind_transforms": Array of Transform3D, parallel to
	//       bone_names (skin space -> bone space),
	//     "skin_to_global_transform": Transform3D (global space -> skin
	//       space),
	//     "bone_indices": PackedInt32Array, length vertex_count * 4 — same
	//       flattened convention Godot's own ArrayMesh ARRAY_BONES expects,
	//     "bone_weights": PackedFloat32Array, length vertex_count * 4 — same
	//       convention as ARRAY_WEIGHTS; unused slots (fewer than 4 real
	//       influences) are index 0 / weight 0.0,
	//     "partition_body_part_ids": PackedInt32Array — BSDismemberSkinInstance
	//       body-part tags, one per NiSkinPartition partition; empty for a
	//       plain NiSkinInstance }
	Array get_skin_data() const;

	// Issue #47: real vertex morph targets (NiGeomMorpherController +
	// NiMorphData, plus their NiFloatInterpolator/NiFloatData weight-
	// animation curves) — see nif_types.h's own MorphData doc comment. One
	// Dictionary per morph-capable NiShape:
	//   { "target_node_name": String — the owning shape's own name, joins
	//       to get_submesh_name() (1:1, a shape has at most one morph
	//       controller in every real file sampled),
	//     "relative_targets": bool — NiMorphData::relativeTargets; true in
	//       every real file sampled so far,
	//     "cycle_type": int (0=loop/1=reverse/2=clamp, same convention as
	//       get_animation_sequences()'s own "cycle_type"),
	//     "start_time": float, "stop_time": float — this controller's OWN
	//       clock, independent of get_animation_sequences()'s,
	//     "targets": Array of { "name": String, "vertex_deltas":
	//       PackedFloat32Array, flat xyz, length vertex_count*3 } — includes
	//       index 0 (the base shape's own copy, see nif_types.h's
	//       MorphTarget doc comment for why a caller should skip building a
	//       blend shape from it),
	//     "weight_tracks": Array of { "target_name": String — joins to
	//       "targets"[i]["name"], "keys": Array of float_key (same shape as
	//       get_animation_sequences()'s own float_key) } }
	Array get_morph_data() const;

private:
	nif::Mesh mesh_;
	bool loaded_ = false;
	String last_error_;

	const nif::SubMesh *submesh(int index) const;
};

} // namespace godot

#endif // NIF_READER_GD_H
