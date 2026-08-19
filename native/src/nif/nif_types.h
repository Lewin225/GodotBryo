#ifndef NIF_TYPES_H
#define NIF_TYPES_H

#include <cstdint>
#include <string>
#include <vector>

namespace nif {

// One renderable piece of a NIF (one NiTriShape/NiTriStrips-equivalent
// block). Geometry is flattened to plain float/index arrays rather than
// exposing nifly types directly, so callers (Godot wrapper, glTF exporter)
// don't need to link against nifly themselves.
struct SubMesh {
	std::string name;

	std::vector<float> positions; // xyz, length == vertex_count * 3
	std::vector<float> normals; // xyz, length == vertex_count * 3, or empty if the shape has none
	std::vector<float> uvs; // uv, length == vertex_count * 2, or empty if the shape has none
	std::vector<uint32_t> indices; // triangle list, length == triangle_count * 3

	// Per-vertex RGBA, length == vertex_count * 4, or empty if the shape has
	// none (see phases/2/06-vertex-color-transparency.md). Bethesda uses
	// this for soft shadow/AO "blob" decals under furniture — a
	// texture-less shape whose alpha channel fades the shape's visibility
	// per-vertex — and, more generally, as a per-vertex tint multiplied
	// into the diffuse texture where one is present. Without this, a
	// texture-less alpha-blended shape has nothing to blend against and
	// renders as a solid, fully-opaque white blob instead of a soft fade.
	std::vector<float> colors;

	// Texture paths as stored in the NIF (BSA-relative, e.g.
	// "textures\architecture\ncr\...dds"), not yet resolved through the BSA
	// reader (0.1) — that's the integration task in 0.5. Empty if none.
	//
	// Slot indices follow BSShaderTextureSet's flat 13-slot array
	// (nifly's Shaders.hpp — nifly itself doesn't name the slots, this is
	// the community-documented FO3/NV convention used by nifskope/niftools:
	// 0=diffuse, 1=normal+gloss(alpha), 2=glow/emissive). Only the first
	// three are extracted (phases/2/01-material-pipeline.md) — slots 3+
	// (height/parallax, environment map/mask) are rare in base-game FO3/NV
	// content and not wired into rendering yet.
	std::string texture_path; // slot 0: diffuse/base
	std::string normal_texture_path; // slot 1: normal map (alpha channel is specular/gloss)
	std::string glow_texture_path; // slot 2: glow/emissive

	// True if this shape's NIF shader block is BSShaderNoLightingProperty
	// rather than the normal BSShaderPPLightingProperty (see
	// phases/2/06-vertex-color-transparency.md) — Bethesda's own signal
	// that a shape should render without scene lighting affecting it.
	// Confirmed against real data: soft shadow/AO "blob" decals under
	// furniture use this shader type, texture-less, with the shadow shape
	// carried entirely by per-vertex color/alpha — applying normal ambient/
	// directional lighting on top washes the intended dark gradient out to
	// a lit gray instead of a clean fade.
	bool no_lighting = false;

	// NiAlphaProperty, if present on this shape — controls whether the
	// render mesh should be alpha-blended/alpha-tested rather than treated
	// as fully opaque (foliage, fences, glass, hair). threshold is already
	// normalized to 0..1 (raw NIF value is a 0..255 byte).
	bool has_alpha_property = false;
	bool alpha_blend_enabled = false;
	bool alpha_test_enabled = false;
	float alpha_threshold = 0.5f;

	// Local transform relative to the NIF's root (or parent shape node),
	// for meshes composed of multiple sub-shapes. Rotation is row-major 3x3
	// (rotation[0..2] = row 0, etc.), matching nifly's MatTransform.
	float translation[3] = { 0.0f, 0.0f, 0.0f };
	float rotation[9] = { 1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f };
	float scale = 1.0f;
};

// One extracted bhk* collision shape (phases/1/02-collision-extraction.md).
// Kind determines which fields are populated; everything else stays at its
// default. Positions/dimensions/radii are already in meters
// (units::kHavokToMeters applied at extraction) — not Havok's own raw units.
enum class CollisionShapeKind {
	kNone,
	kTriangleMesh, // bhkPackedNiTriStripsShape -> Godot ConcavePolygonShape3D
	kBox, // bhkBoxShape -> BoxShape3D
	kSphere, // bhkSphereShape -> SphereShape3D
	kCapsule, // bhkCapsuleShape -> CapsuleShape3D
	kConvexHull, // bhkConvexVerticesShape -> ConvexPolygonShape3D
};

struct CollisionShape {
	CollisionShapeKind kind = CollisionShapeKind::kNone;
	std::string node_name; // which NiAVObject this came from — for association/debugging

	// Local transform relative to the NIF's root — same convention as
	// SubMesh's (row-major 3x3 rotation), from the collision-bearing
	// NiAVObject's own GetTransformToParent(). Does NOT additionally
	// compose the bhkRigidBody's own translation/rotation (usually
	// identity for static world geometry) — a known scope simplification,
	// see phases/1/02-collision-extraction.md.
	float translation[3] = { 0.0f, 0.0f, 0.0f };
	float rotation[9] = { 1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f };

	// kTriangleMesh / kConvexHull:
	std::vector<float> positions; // flat xyz, meters
	std::vector<uint32_t> indices; // triangle list, kTriangleMesh only

	// kBox:
	float half_extents[3] = { 0.0f, 0.0f, 0.0f };
	// kSphere:
	float radius = 0.0f;
	// kCapsule:
	float point_a[3] = { 0.0f, 0.0f, 0.0f };
	float point_b[3] = { 0.0f, 0.0f, 0.0f };
	float capsule_radius = 0.0f;
};

struct Mesh {
	std::vector<SubMesh> submeshes;
	std::vector<CollisionShape> collision_shapes;

	// True the moment ANY NiAVObject in the NIF has a non-empty collisionRef
	// — i.e. Havok collision was authored for this object at all — set
	// before attempting to resolve/parse what it points to. Deliberately
	// separate from collision_shapes.empty(): a NIF can have real collision
	// intent (collisionRef present) that this parser still can't extract
	// (bhkBlendCollisionObject/bhkNPCollisionObject, bhkListShape/
	// bhkConvexListShape — see nif_loader.cpp), in which case
	// collision_shapes is empty but has_collision_data is true. Callers need
	// this distinction to tell "no collision was ever intended" (window-
	// light volumetrics, markers) from "collision exists but we can't parse
	// this shape type yet" (a real parser gap, where a fallback collider is
	// still better than none).
	bool has_collision_data = false;

	// Human-readable NIF version string (e.g. "20.2.0.7 (FO3/NV)"), useful
	// for the "confirm which NIF version FNV ships" step without needing a
	// separate inspection tool.
	std::string nif_version;
};

} // namespace nif

#endif // NIF_TYPES_H
