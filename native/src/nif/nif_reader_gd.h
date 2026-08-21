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
	Transform3D get_transform(int index) const;

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

private:
	nif::Mesh mesh_;
	bool loaded_ = false;
	String last_error_;

	const nif::SubMesh *submesh(int index) const;
};

} // namespace godot

#endif // NIF_READER_GD_H
