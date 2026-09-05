#ifndef NIF_TYPES_H
#define NIF_TYPES_H

#include <array>
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

	// BSShaderNoLightingProperty's optional view-angle alpha falloff. Its
	// shaderFlags1 Use Falloff bit is the authoritative gate; when false the
	// four values are ignored even if present in the on-disk block.
	bool no_lighting_uses_falloff = false;
	float falloff_start_angle = 1.0f;
	float falloff_stop_angle = 0.0f;
	float falloff_start_opacity = 1.0f;
	float falloff_stop_opacity = 1.0f;

	// BSShaderProperty::IsDoubleSided() -- real per-shape shaderFlags2 bit
	// (niftools SLSF2_DOUBLE_SIDED, confirmed via nifly's own
	// BSShaderProperty::IsDoubleSided() implementation: shaderFlags2 &
	// (1<<4)). Bethesda's own signal that backface culling should be
	// disabled for this shape -- additive/glow "cookie" billboards
	// (effects/ambient/*.nif light-shaft planes) are the common real case,
	// though not every one of them actually ships this bit set (confirmed
	// via alpha_survey against IndFXLightRays01.nif's real data: flags2=0,
	// i.e. genuinely single-sided per Bethesda's own authored data -- this
	// field just makes the ones that DO ship it correctly double-sided,
	// where previously every shape was hard-culled to CULL_BACK regardless
	// of what the NIF actually specified).
	bool double_sided = false;

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

	// Index into Mesh::scene_nodes for this shape's own NiAVObject, or -1
	// if it's parented directly under the NIF's root (see SceneNode's own
	// doc comment). Only meaningful for Dynamic objects — Static content's
	// resolver never looks at this and keeps using the flattened transform
	// above unchanged.
	int32_t owning_node_index = -1;
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

	// Index into Mesh::scene_nodes for the NiAVObject collision was found
	// on (`av` in the extraction loop), or -1 if it's the NIF's root —
	// same convention as SubMesh::owning_node_index.
	int32_t owning_node_index = -1;
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

// One float-valued ControllerLink preserved alongside transform tracks. The
// link metadata is required because facial KF files may target a named
// property/controller rather than a Skeleton3D bone. The key values are
// authored float values; callers decide whether the target is a blend shape,
// material property, or another runtime value after inspecting the real link.
struct FloatAnimationTrack {
	std::string target_node_name;
	std::string property_type;
	std::string controller_type;
	std::vector<FloatKey> keys;
};

struct BoolKey {
	float time = 0.0f;
	bool value = false;
};

struct DirectAnimationController {
	std::string target_node_name;
	int32_t target_node_index = -1;
	std::string controller_type;
	std::string interpolator_type;
	float start_time = 0.0f;
	float stop_time = 0.0f;
	std::vector<AnimationTrack> transform_tracks;
	std::vector<BoolKey> visibility_keys;
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
	// NiControllerSequence.accumRootName. This is authored runtime metadata,
	// not a decoder instruction: the actor animation system decides whether
	// to accumulate or reset this node's translation.
	std::string accum_root_name;
	SequenceCycleType cycle_type = SequenceCycleType::kClamp;
	float start_time = 0.0f;
	float stop_time = 0.0f;
	std::vector<AnimationTrack> tracks;
	std::vector<FloatAnimationTrack> float_tracks;
};

// General (not animation-specific) preservation of the NIF's own node
// graph — additive infrastructure for Dynamic objects (see
// enginedocs/nv_class_hierarchy.md's Dynamic/Static split), so any future
// feature that needs to resolve a named NiNode/NiShape to a real placement
// in the scene can look it up, not just animation's target_node_name (the
// first consumer, but deliberately not the only reason this exists — a
// direct user request generalized this past animation).  Static content's
// resolver never touches this and keeps using SubMesh/CollisionShape's own
// flattened-to-root transform unchanged.
//
// One entry per non-root NiAVObject in the file (both NiNode and NiShape/
// leaf blocks alike, since a target name can legitimately name either) —
// the same population flatten_to_root()'s own parent-walk already
// traverses. The NIF's root block itself is deliberately excluded
// (parent_index == -1 for a node whose real parent IS the root), matching
// flatten_to_root's own root-transform-exclusion policy — see that
// function's doc comment in nif_loader.cpp for why (some Bethesda kit NIFs
// bake a stray nonzero rotation onto their root that must never apply).
struct SceneNode {
	std::string name;
	int32_t parent_index = -1; // index into Mesh::scene_nodes, or -1 if parented directly under the NIF's root

	// LOCAL transform relative to the immediate parent (GetTransformToParent()
	// as authored) — deliberately NOT flattened to root, unlike SubMesh/
	// CollisionShape's own transform fields. Godot's own Node3D parent-child
	// composition reconstructs the flattened result at runtime; storing it
	// pre-flattened here would lose the ability for an intermediate node to
	// animate independently of its children (exactly the case an animated
	// hinge/elevator-car node needs). Rotation is row-major 3x3, same
	// convention as SubMesh's.
	float translation[3] = { 0.0f, 0.0f, 0.0f };
	float rotation[9] = { 1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f };
	float scale = 1.0f;
};

// A single spatial transform in the same convention as every other
// transform field in this file (row-major 3x3 rotation, translation already
// meters-converted) — kept as its own named struct (rather than reusing
// SceneNode's) since it isn't a scene-graph node, just a bind-pose or
// global<->skin transform.
struct SkinBoneTransform {
	float translation[3] = { 0.0f, 0.0f, 0.0f };
	float rotation[9] = { 1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f };
	float scale = 1.0f;
};

// Issue #46: real skeletal skinning data (BSDismemberSkinInstance/
// NiSkinInstance + NiSkinData + NiSkinPartition), one entry per skinned
// NiShape in the file. Confirmed real that BSDismemberSkinInstance (not
// plain NiSkinInstance) is what actual FNV humanoid/creature meshes use,
// and that NiSkinData+NiSkinPartition are always paired together in real
// content — see the issue's own research artifact. BSSkinInstance/
// BSSkinBoneData (Fallout 4's skinning format) confirmed NOT used in New
// Vegas and out of scope.
struct SkinData {
	// The owning NiShape's own name — same convention as SubMesh::name, and
	// how a caller should join this back to the SubMesh it skins (a shape
	// can have at most one skin instance, so this is a 1:1 join by name).
	std::string target_node_name;

	// Per-shape bone order (nifly::NifFile::GetShapeBoneList — resolved via
	// the skin instance's boneRefs to each bone NiNode's own name). NOT a
	// global index across the whole NIF — vertex_bone_indices below indexes
	// into THIS vector. A body's several skinned submeshes each carry their
	// own subset/order of a larger shared bone pool (confirmed real:
	// upperbody.nif's 6 BSDismemberSkinInstances all reference the same
	// 27-bone NiNode set, but nothing guarantees that in general) —
	// reconciling multiple SkinData entries against one shared Skeleton3D by
	// bone NAME, not by index, is later (Phase C) work, not this struct's.
	std::vector<std::string> bone_names;

	// NiSkinData.bones[].boneTransform (skin space -> bone space, i.e.
	// nifly's GetShapeTransformSkinToBone), one per bone_names entry.
	std::vector<SkinBoneTransform> bone_bind_transforms;

	// NiSkinData.skinTransform (global space -> skin space, i.e. nifly's
	// GetShapeTransformGlobalToSkin). Despite the name this is a normal
	// MatTransform like any bone's, not a 4x4 — same SkinBoneTransform shape
	// reused for both.
	SkinBoneTransform skin_to_global_transform;

	// Per-shape-vertex, parallel to the owning SubMesh's positions/normals/
	// uvs arrays (same vertex order/count). Each entry holds up to 4 bone
	// influences — confirmed real that no real FNV vertex needs more than 4
	// (native/tools/nif_skin_weights.cpp: 66 NiSkinPartition partitions
	// checked across human/Cazador/Brahmin/a real animated-flag mesh, all
	// numWeightsPerVertex == 4), matching Godot's own default ARRAY_BONES/
	// ARRAY_WEIGHTS width. Indices are into bone_names above, NOT a global
	// bone index. Unused slots (a vertex with fewer than 4 real influences —
	// the common case) are index 0 / weight 0.0, the same "unused slot"
	// convention Godot's own mesh arrays use.
	std::vector<std::array<uint16_t, 4>> vertex_bone_indices;
	std::vector<std::array<float, 4>> vertex_bone_weights;

	// BSDismemberSkinInstance::partitions[].partID, one per NiSkinPartition
	// partition — Bethesda's own dismemberment/gore-cap body-part tagging
	// (BSDismemberBodyPartType). Empty for a plain NiSkinInstance (no real
	// FNV humanoid/creature mesh observed to use one, but not assumed).
	// Captured here but not consumed by anything yet — dismemberment logic
	// and the ESM-side BPTD cross-reference are explicitly out of scope for
	// this issue.
	std::vector<uint16_t> partition_body_part_ids;
};

// Issue #47: one named morph/blend-shape target (NiMorphData's own
// per-shape morphs[] entry), extracted from a NiGeomMorpherController +
// NiMorphData pair. Real data (native/tools/nif_morph_dump.cpp, the real
// Goodsprings NV_Nevadaflag.NIF) confirms: with relative_targets == true
// (the only value seen in real FNV content so far, not assumed), index 0
// is always a literal copy of the base shape's own vertex positions
// (name == "Base", magnitude matching the raw geometry scale, not a small
// delta) — callers should skip index 0 as a buildable blend-shape target;
// indices 1..N are real small per-vertex offset deltas relative to that
// base. Carried through unfiltered here (native extraction doesn't drop
// index 0) so a caller can still inspect/validate it if needed.
struct MorphTarget {
	std::string name; // Morph::frameName, e.g. "NV_NCRFlag01BASE02" — may be empty for older content nifly's own Morph::Sync doesn't populate a frameName for
	std::vector<float> vertex_deltas; // flat xyz, length == vertex_count * 3, already meters-converted (see units.h) — vertex_count matches the owning SubMesh's own position count exactly, same shape as SkinData's per-vertex arrays
};

// One float-valued weight-animation curve driving a single MorphTarget's
// blend weight over time (0..1) — NiGeomMorpherController::interpWeights[i]
// -> NiFloatInterpolator -> NiFloatData, confirmed the real mechanism FNV
// content uses (NOT the older parallel interpolatorRefs[] array — that was
// empty in every real file sampled). `target_name` joins back to the
// MorphTarget with the same name in the same MorphData, exactly like
// AnimationTrack::target_node_name joins to a SceneNode — deliberately not
// assumed index-parallel with MorphData::targets, since interpWeights[i]
// pairing with morphs[i] by position is nifly's own internal storage detail,
// not a contract this project's own extraction should lean on further than
// necessary.
struct MorphWeightTrack {
	std::string target_name;
	std::vector<FloatKey> keys;
};

// One morph-capable NiShape's full morph setup: its target geometry deltas
// plus whatever weight-animation curves drive them. A NiGeomMorpherController
// is attached directly to its owning NiShape via that shape's own
// controllerRef (NOT via NiControllerManager/NiControllerSequence like
// AnimationSequence above) — confirmed real: the Nevada flag's two morph
// controllers each hang directly off their own NiTriShape, and that shape
// ALSO independently carries a NiTransformController for its own pivot-sway
// animation, wholly unrelated to this. This is therefore a genuinely
// separate animation clock from AnimationSequence's own start/stop/cycle
// time, sourced from the controller's own NiTimeController base fields, not
// assumed to share timing with anything else in the file.
struct MorphData {
	std::string target_node_name; // owning shape's own name — same join convention as SkinData::target_node_name (a shape has at most one morph controller in every real file sampled)
	bool relative_targets = true; // NiMorphData::relativeTargets
	std::vector<MorphTarget> targets; // includes index 0 (the base copy) — see MorphTarget's own doc comment
	std::vector<MorphWeightTrack> weight_tracks; // only entries with a real resolvable NiFloatInterpolator/NiFloatData — may be fewer than targets.size() if some are missing/unresolvable
	SequenceCycleType cycle_type = SequenceCycleType::kLoop;
	float start_time = 0.0f;
	float stop_time = 0.0f;
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

	// Controllers attached directly to NiAVObjects rather than owned by a
	// NiControllerManager/Sequence. Weapon NIFs use this form for local
	// components such as clips, slides, hammers, and shell nodes.
	std::vector<DirectAnimationController> direct_animation_controllers;

	// General node-graph preservation for Dynamic objects — see SceneNode's
	// own doc comment. Empty is a valid, common state (most Static content
	// never populates this at all; only the Dynamic-path resolver reads it).
	std::vector<SceneNode> scene_nodes;

	// Issue #46: real skeletal skinning — see SkinData's own doc comment.
	// Empty for the overwhelming majority of NIFs; only real skinned meshes
	// (humanoid/creature bodies) populate this.
	std::vector<SkinData> skin_data;

	// Issue #47: real vertex morph targets — see MorphData's own doc
	// comment. Empty for the overwhelming majority of NIFs; only real
	// morph-capable content (e.g. cloth-ripple flags) populates this.
	std::vector<MorphData> morph_data;
};

} // namespace nif

#endif // NIF_TYPES_H
