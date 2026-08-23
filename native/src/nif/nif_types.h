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

	// phases/2/01-material-pipeline.md's known gap, closed: NiAlphaProperty's
	// src/dst blend-function bits (flags bits 1-4 / 5-8), decoded to one of
	// Godot's own composite-mode buckets rather than passed through raw —
	// only meaningful when alpha_blend_enabled (never for alpha_test, which
	// is a discard, not a blend). Sourced against real data, not assumed:
	// sampled every blend-enabled shape across ~2,000 real FO3/NV NIFs (see
	// alpha_survey tool + phases/2/xx write-up) and found exactly three
	// combinations in use, no others —
	//   src=SRC_ALPHA dst=INV_SRC_ALPHA (734/796): ordinary alpha blend
	//   src=SRC_ALPHA dst=ONE, or src=ONE dst=ONE (40/796): additive — the
	//     light-shaft/glow-effect convention (IndFXLightRays* etc)
	//   src=ZERO dst=SRC_COLOR (22/796): multiply
	// An unrecognized combination (none seen in the sample, but nothing rules
	// one out in unsampled content) falls back to kMix — the same "always
	// mix" behavior this project used before this field existed, not a new
	// failure mode.
	enum class BlendFunc {
		kMix,
		kAdd,
		kMultiply,
	};
	BlendFunc alpha_blend_func = BlendFunc::kMix;

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

// phases/3/00-door-completion.md, Part A: how one keyframe's value should
// be interpolated toward the NEXT keyframe. Mirrors niftools' own NiKeyType
// enum (LINEAR_KEY/QUADRATIC_KEY/TBC_KEY/CONST_KEY/NO_INTERP), sourced
// against a real census of every animated NIF in FalloutNV.esm + DLC
// (native/tools/anim_survey.cpp) rather than assumed: kQuadratic is the
// MAJORITY case for real rotation/scale data (12,691 quadratic vs 1,703
// linear rotation keys; 9,761 vs 74 for scale), not an edge case a
// linear-only reader could safely ignore. kTbc is real but rare. XYZ
// per-axis rotation keys (a separate representation from quaternion keys,
// selected by NiTransformData::rotationType — see AnimationTrack below)
// use this same enum for each axis independently.
enum class KeyInterpolation {
	kNone,      // NO_INTERP -- effectively a single static value, no curve
	kLinear,
	kQuadratic, // Hermite -- forward/backward tangents are meaningful
	kTbc,       // Kochanek-Bartels -- tension/bias/continuity are meaningful
	kConstant,  // CONST_KEY -- holds `value` until the next key, no blending
};

// One float-valued keyframe (scale, or one axis of a per-axis rotation
// track). forward/backward/tension/bias/continuity are only meaningful
// when `interp` is kQuadratic/kTbc respectively — carried regardless so a
// future evaluator doesn't need to re-read the source NIF to get them.
struct FloatKey {
	float time = 0.0f;
	float value = 0.0f;
	float forward = 0.0f;
	float backward = 0.0f;
	float tension = 0.0f;
	float bias = 0.0f;
	float continuity = 0.0f;
	KeyInterpolation interp = KeyInterpolation::kNone;
};

// One translation keyframe. `value`/`forward`/`backward` are already in
// meters (units::kGamebryoUnitsToMeters applied at extraction, same as
// every other position value this codebase hands back — see units.h) —
// not raw Gamebryo units.
struct Vector3Key {
	float time = 0.0f;
	float value[3] = { 0.0f, 0.0f, 0.0f };
	float forward[3] = { 0.0f, 0.0f, 0.0f };
	float backward[3] = { 0.0f, 0.0f, 0.0f };
	float tension = 0.0f;
	float bias = 0.0f;
	float continuity = 0.0f;
	KeyInterpolation interp = KeyInterpolation::kNone;
};

// One quaternion-rotation keyframe (x, y, z, w). Real data (571 non-empty
// cases in the same census) shows quaternion keys are always authored as
// kNone/kLinear in practice — never quadratic/TBC — but `interp` is still
// carried rather than assumed, since nifly's own key template supports all
// four for any value type and this project's own discipline is to not
// assume from a sample.
struct QuatKey {
	float time = 0.0f;
	float value[4] = { 0.0f, 0.0f, 0.0f, 1.0f };
	KeyInterpolation interp = KeyInterpolation::kNone;
};

// One ControllerLink -> NiTransformInterpolator -> NiTransformData, fully
// extracted. `target_node_name` is this NIF's own scene-graph node name
// the track drives (ControllerLink::nodeName — confirmed a direct string
// in FNV-version NIFs via real data, not an offset into a NiStringPalette;
// that alternate encoding only applies to NIF versions older than this
// game ships, per ControllerLink::Sync's own version gating in
// nifly/include/Animation.hpp). Deliberately NOT correlated to a specific
// SubMesh here — a target node is commonly a wrapping NiNode with several
// child shapes under it, not a single shape itself, so that correlation is
// left to whoever wires real playback (phases/3/00-door-completion.md's
// own Part A steps 3-4), not assumed at parse time.
//
// Rotation is stored in whichever representation the source NIF actually
// used — has_quaternion_keys and has_axis_keys are independent, not
// mutually exclusive by construction (real data confirms both occur, never
// checked to be exclusive), though in practice every real sample checked
// so far uses exactly one or neither (a translation/scale-only track, e.g.
// a real elevator car: pure translation, no rotation at all).
struct AnimationTrack {
	std::string target_node_name;

	bool has_quaternion_keys = false;
	std::vector<QuatKey> quaternion_keys;

	bool has_axis_keys = false;
	std::vector<FloatKey> x_rotation_keys; // radians -- standard NIF convention, same as every other rotation value in this codebase
	std::vector<FloatKey> y_rotation_keys;
	std::vector<FloatKey> z_rotation_keys;

	std::vector<Vector3Key> translation_keys; // meters
	std::vector<FloatKey> scale_keys;         // relative multiplier, no unit conversion (same convention as REFR XSCL/SCOL part scale — see units.h)
};

// Mirrors niftools' CycleType enum. Real doors/cabinets use kClamp (play
// once, hold the end pose) — confirmed via the same census, not assumed.
enum class SequenceCycleType {
	kLoop,
	kReverse,
	kClamp,
};

// One named animation clip (NiControllerSequence) — e.g. a door's "Open"/
// "Close", an elevator's "Forward"/"Backward". May drive many target nodes
// at once: a real complex mechanism's single sequence commonly animates
// dozens of nodes together (confirmed directly — a real silo elevator
// shaft's "Forward" sequence alone has 20+ tracked nodes), not just one.
struct AnimationSequence {
	std::string name;
	SequenceCycleType cycle_type = SequenceCycleType::kClamp;
	float start_time = 0.0f;
	float stop_time = 0.0f;
	std::vector<AnimationTrack> tracks;
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

	// phases/3/00-door-completion.md, Part A step 1-2: rigid single-node
	// transform animation (NiControllerManager/NiControllerSequence), NOT
	// skeletal (no NiSkinInstance/bone weighting read here — that's later,
	// harder Phase 3 work, deliberately deferred). Scoped against a real
	// census across every animated NIF in FalloutNV.esm + DLC (1,153 files,
	// 31,012 controlled links, native/tools/anim_survey.cpp), not just
	// door content — doors alone would have under-scoped this badly: they
	// happen to use only linear/XYZ-axis rotation with no translation or
	// scale, while the real population is dominated by QUADRATIC (Hermite)
	// interpolation for rotation (12,691 quadratic vs 1,703 linear) and
	// scale (9,761 vs 74), and both quaternion-keyed (571 real cases) and
	// per-axis rotation representations appear. Deliberately excludes
	// NiFloatInterpolator/NiBoolInterpolator/NiBoolTimelineInterpolator/
	// NiPoint3Interpolator targets (confirmed via the same census to be
	// particle-system/visibility/color animation, a different concern from
	// object pose) and NiBSplineCompTransformInterpolator (confirmed zero
	// occurrences in real FNV content, not assumed absent).
	std::vector<AnimationSequence> animation_sequences;
};

} // namespace nif

#endif // NIF_TYPES_H
