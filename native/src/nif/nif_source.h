#ifndef NIF_SOURCE_H
#define NIF_SOURCE_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace nifsrc {

// Stage D of Plans/Completed Plans/server_stack_build_order.md: a reader over nifly's own
// object model, which is what every measurement in nif_server_v2.md was taken
// from. Deliberately separate from nif_loader.{h,cpp}, the legacy pre-digested
// summary -- that one stays untouched and keeps serving its existing callers.
//
// The distinguishing property is that nothing here is flattened or
// interpreted: a node keeps its block type, so a consumer can tell a
// NiPointLight from a NiCamera from a NiTriShape.

// Text-key marker on an animation ("start", "end", a sound cue, ...).
struct TextKey {
	float time = 0.0f;
	std::string value;
};

// One BSFurnitureMarker position in the User Version <= 11 form every FNV NIF
// uses (516 positions over 233 furniture NIFs; native/tools/furniture_census).
struct FurniturePosition {
	float offset[3] = { 0.0f, 0.0f, 0.0f }; // metres (units.h), in the owning node's space
	uint16_t orientation = 0; // thousandths of a radian
	uint8_t position_reference_1 = 0; // the furniture marker ID idle conditions test
	uint8_t position_reference_2 = 0; // equal to position_reference_1 on all 516
};

struct ExtraData {
	uint32_t block_index = 0;
	std::string block_type;
	std::string name; // NiExtraData::name, often empty

	// Decoded payload, by kind. Untouched fields stay at their defaults.
	bool has_integer = false;
	uint32_t integer_value = 0; // NiIntegerExtraData, BSXFlags
	bool has_float = false;
	float float_value = 0.0f; // NiFloatExtraData
	bool has_string = false;
	std::string string_value; // NiStringExtraData
	bool has_bounds = false;
	float bounds_center[3] = { 0.0f, 0.0f, 0.0f }; // BSBound
	float bounds_half_extents[3] = { 0.0f, 0.0f, 0.0f };
	std::vector<TextKey> text_keys; // NiTextKeyExtraData
	std::vector<FurniturePosition> furniture_positions; // BSFurnitureMarker
};

// One BSDismemberSkinInstance partition record. Its index is the value used by
// SkinData::dismember_triangle_partitions, so the pair preserves the authored
// triangle-to-body-part association rather than flattening it to shape-wide
// metadata.
struct DismemberPartition {
	uint16_t part_id = 0;
	uint16_t flags = 0;
};

// Per-vertex skin influence. Bone indices are into SkinData::bone_names, not
// into any skeleton: 86% of skinned NIFs carry a flat bone LIST rather than a
// hierarchy, so the rig belongs to whatever the caller binds this to
// (nif_server_v2.md 9). Resolution is by name, at bind time.
struct SkinData {
	std::vector<std::string> bone_names;
	std::vector<float> bind_transforms; // 16 floats per bone, row-major, meters
	std::vector<int32_t> bone_indices; // 4 per vertex
	std::vector<float> bone_weights; // 4 per vertex, parallel to the above

	// Empty for an ordinary NiSkinInstance. For BSDismemberSkinInstance, these
	// ordered records and the parallel per-shape-triangle index preserve the
	// exact exported runtime partitioning. A triangle index of -1 is authored
	// as unassigned and is retained for the caller to handle explicitly.
	std::vector<DismemberPartition> dismember_partitions;
	std::vector<int32_t> dismember_triangle_partitions;
};

// Triangle geometry for one shape. Positions are METERS: the conversion is
// applied here at the source, matching units.h's convention that every
// position this codebase returns is already in meters.
struct Geometry {
	std::vector<float> positions; // 3 per vertex
	std::vector<float> normals; // 3 per vertex, empty when absent
	std::vector<float> uvs; // 2 per vertex, empty when absent
	std::vector<float> colors; // 4 per vertex, empty when absent
	std::vector<uint32_t> indices; // 3 per triangle
	bool has_skin = false;
	SkinData skin;
};

// One resolved collision shape. Positions are METERS, converted with the
// Havok scale (kHavokToMeters), which is a THIRD unit system distinct from
// both raw Gamebryo units and meters -- see units.h for how that factor was
// established numerically rather than from a single secondary source.
struct CollisionShape {
	uint32_t block_index = 0;
	std::string block_type;
	int32_t owning_node_index = -1;
	int32_t body_index = -1; // index into Document::collision_bodies

	std::string kind; // box | sphere | capsule | convex_hull | triangle_mesh
	float half_extents[3] = { 0.0f, 0.0f, 0.0f }; // box
	float radius = 0.0f; // sphere
	float point_a[3] = { 0.0f, 0.0f, 0.0f }; // capsule
	float point_b[3] = { 0.0f, 0.0f, 0.0f };
	float capsule_radius = 0.0f;
	std::vector<float> positions; // convex hull / triangle mesh, 3 per vertex
	std::vector<uint32_t> indices; // triangle mesh, 3 per triangle

	// Accumulated transform of every bhkTransformShape / bhkConvexTransformShape
	// wrapping this shape. Those wrappers exist only to offset the shape they
	// hold, so discarding them puts the collider in the wrong place --
	// 47 files use the first, 34 the second.
	//
	// Row-major 4x4, translation at indices 3, 7, 11, already in METERS
	// (kHavokToMeters). Identity, and has_transform false, when there are no
	// wrappers -- which is the 11,134-file ordinary case.
	bool has_transform = false;
	float transform[16] = {
		1.0f, 0.0f, 0.0f, 0.0f,
		0.0f, 1.0f, 0.0f, 0.0f,
		0.0f, 0.0f, 1.0f, 0.0f,
		0.0f, 0.0f, 0.0f, 1.0f
	};
};

// One constraint on a rigid body. Presence is NOT a ragdoll signal -- 164
// files carry one without a bhkBlendCollisionObject -- but on a body that IS
// part of a ragdoll it is what gives the joint its type and limits.
//
// Pivots are METERS (kHavokToMeters); axes and angles are unitless. `a` is the
// frame on this body, `b` the frame on the body it is jointed to.
struct CollisionConstraint {
	uint32_t block_index = 0;
	std::string block_type; // bhkRagdollConstraint | bhkLimitedHingeConstraint | ...
	std::string kind; // ragdoll | hinge | unsupported
	// Set when the real descriptor came out of a bhkMalleableConstraint
	// wrapper, which holds a ConstraintData whose own type selects it.
	std::string wrapped_by;

	float pivot_a[3] = { 0.0f, 0.0f, 0.0f };
	float pivot_b[3] = { 0.0f, 0.0f, 0.0f };
	// ragdoll: twist + plane. hinge: axle + perpendicular.
	float axis_a[3] = { 0.0f, 0.0f, 0.0f };
	float axis_b[3] = { 0.0f, 0.0f, 0.0f };
	float plane_a[3] = { 0.0f, 0.0f, 0.0f };
	float plane_b[3] = { 0.0f, 0.0f, 0.0f };

	float cone_max_angle = 0.0f; // ragdoll only
	float plane_min_angle = 0.0f;
	float plane_max_angle = 0.0f;
	float twist_min_angle = 0.0f;
	float twist_max_angle = 0.0f;
	float min_angle = 0.0f; // hinge only
	float max_angle = 0.0f;
	float max_friction = 0.0f;
};

// One rigid body. bhkRigidBodyT carries its own transform; bhkRigidBody does
// not. The collision OBJECT's block type (SceneNode::collision_type) is what
// distinguishes a ragdoll from ordinary collision, not anything here.
struct CollisionBody {
	uint32_t block_index = 0;
	std::string block_type; // bhkRigidBody | bhkRigidBodyT
	int32_t owning_node_index = -1;
	float mass = 0.0f;
	float friction = 0.0f;
	float restitution = 0.0f;
	float linear_damping = 0.0f;
	float angular_damping = 0.0f;
	// bhkRigidBodyT's transform, both halves. Reading the translation without
	// the rotation leaves a rotated collider sitting square to its mesh.
	float translation[3] = { 0.0f, 0.0f, 0.0f }; // meters, bhkRigidBodyT only
	float rotation[4] = { 0.0f, 0.0f, 0.0f, 1.0f }; // XYZW, bhkRigidBodyT only

	std::vector<CollisionConstraint> constraints;
};

// One morph frame: a named set of per-vertex deltas against the base mesh.
struct MorphFrame {
	std::string name;
	std::vector<float> deltas; // 3 per vertex, meters
};

struct SceneNode {
	std::string name; // authored, verbatim
	std::string block_type; // e.g. "NiNode", "NiCamera", "BSFadeNode"
	int32_t parent_index = -1; // index into nodes, or -1 for a root
	uint32_t block_index = 0; // index into the NIF's own block table
	// The unparented file root is retained for inspection. Its raw transform
	// is real file data, but NIF instancing deliberately suppresses it (the
	// established legacy rule; see NifTreeBuilder) rather than applying it on
	// top of a REFR placement. This remains separate from parent_index so a
	// consumer can make that policy visible instead of making the root vanish.
	bool is_file_root = false;

	// Collision object attached to this node, if any. The BLOCK TYPE is the
	// discriminator nif_server_v2.md 5.3 turns on:
	//
	//   bhkCollisionObject       ordinary collision -- 11,134 files
	//   bhkSPCollisionObject     phantoms (triggers, water, traps) -- 40 files
	//   bhkBlendCollisionObject  ragdoll -- 60 files, 56 named skeleton*.nif
	//
	// Presence of a constraint is NOT the discriminator: 164 files carry one
	// without being a ragdoll, bhkLimitedHingeConstraint alone appearing in
	// 190 files of which 90 are meshes/armor.
	// True when the file explicitly names this node as a bone -- via a skin's
	// NiSkinInstance::boneRefs, or via NiBoneLODController::boneArrays (which
	// skeleton.nif uses: 62 bones across 8 LOD groups). Bones are authored
	// data, not an inference from naming.
	bool is_declared_bone = false;

	// NiBillboardNode's mode. Godot expresses this as material state rather
	// than a node type (nif_server_v2.md 5.3), so it is reported here and
	// applied to descendant materials. Empty when the node is not a billboard.
	//   always_face_camera | rotate_about_up | rigid_face_camera
	//   always_face_center | rigid_face_center | bs_rotate_about_up
	std::string billboard_mode;

	std::string collision_type; // empty when the node has no collision object
	int32_t collision_block_index = -1;
	// NiCollisionObject::targetRef -- the NiAVObject the collision object
	// declares itself attached to, which is NOT necessarily the node whose
	// collisionRef reached it. -1 when unset.
	int32_t collision_target_block_index = -1;

	// BSShaderTextureSet slots for a shape node, empty for everything else.
	// Always 6 entries when present: every one of the 56,789 texture sets in
	// the shipped corpus declares exactly 6 (13 is Skyrim SE only). An entry
	// is the authored path or empty.
	//
	//   0 diffuse          99.96% occupied      3 height/parallax   0.90%
	//   1 normal + gloss   99.61%               4 environment map  11.69%
	//   2 glow/emissive     7.50%               5 environment mask 10.14%
	//
	// All six are read unconditionally: an occupied slot is the fact, no
	// shader flag needs to agree first. The legacy loader reads only 0-2.
	std::vector<std::string> texture_slots;
	int32_t texture_set_block_index = -1; // the shared BSShaderTextureSet, or -1

	// Which block the slots came from, because the slot NUMBERS mean
	// different things per convention and flattening them would silently
	// mis-assign textures:
	//
	//   ""                     no textures on this shape
	//   "shader_set"           BSShaderTextureSet, 6 slots:
	//                            0 diffuse  1 normal  2 glow
	//                            3 height   4 env     5 env mask
	//   "texturing_property"   NiTexturingProperty, up to 10 slots:
	//                            0 base   1 dark   2 detail  3 gloss
	//                            4 glow   5 bump   6-9 decal
	//   "effect_shader"        BSEffectShaderProperty:
	//                            0 source 1 normal 3 greyscale
	//                            4 env    5 env mask
	//
	// Slot 2 is glow under the first convention and DETAIL under the second,
	// which is the trap: a terminal screen's texture lives on a
	// NiTexturingProperty with no texture set at all, and reading it as if it
	// were a shader set returns nothing -- the screen renders solid white.
	std::string texture_convention;
	std::string shader_type; // shader property block type, empty when none
	// Raw BSShaderProperty flags. Keep both words intact: the FO3/FNV bit names
	// are documented, but translating every bit into Godot behaviour is separate.
	bool has_shader_flags = false;
	uint32_t shader_flags1 = 0;
	uint32_t shader_flags2 = 0;

	// NiProperty blocks this node references, by BLOCK INDEX -- the identity
	// nif_server_v2.md 7.3 needs. Property blocks are shared: ~34% of
	// NiMaterialProperty are referenced by two or more nodes, while shader
	// properties never are. A Godot material fuses blocks with different
	// sharing granularity, so a consumer animating a shared property has to
	// fan the track out to every node that referenced the same block -- which
	// it can only do if the block index survives, not just the resolved value.
	std::vector<int32_t> property_block_indices;
	std::vector<std::string> property_types; // parallel to the above

	// NiAlphaProperty for a shape, decoded. Without it a shape whose only
	// pixels come from per-vertex alpha -- Bethesda's unlit AO fades and glow
	// overlays carry no texture at all -- renders as a solid opaque quad.
	//
	// `flags` is the niftools bitfield, stable across NIF versions:
	// bit 0 blend enable, bits 1-4 source blend function, bits 5-8
	// destination blend function, bit 9 alpha-test enable. `threshold` is a
	// raw 0..255 byte, normalized here.
	//
	// blend_func buckets the src/dst pair. A census of blend-enabled shapes
	// across ~2,000 shipped NIFs found exactly three combinations in use and
	// no others: 734/796 mix (SRC_ALPHA/INV_SRC_ALPHA), 40/796 add
	// (SRC_ALPHA/ONE or ONE/ONE -- light shafts and glow effects), 22/796
	// multiply (ZERO/SRC_COLOR -- dirt and grime decals). An unrecognised
	// pair falls back to mix.
	bool has_alpha_property = false;
	bool alpha_blend_enabled = false;
	bool alpha_test_enabled = false;
	float alpha_threshold = 0.5f; // 0..1
	std::string alpha_blend_func; // mix | add | multiply

	// NiObjectNET extra data attached to this node. Godot has no construct for
	// most of it, so nif_server_v2.md 5.3 puts it in node metadata rather than
	// dropping it: BSXFlags (12,578 blocks), NiStringExtraData (32,161),
	// NiTextKeyExtraData (7,745), BSBound, BSFurnitureMarker and the rest.
	// Typed payloads are decoded for the kinds that carry one; everything else
	// still reports its block type and name so nothing is silently lost.
	std::vector<ExtraData> extra_data;

	// Geometry, when this node is a shape. Empty positions means no geometry.
	Geometry geometry;

	// In-NIF morph targets (NiGeomMorpherController -> NiMorphData). File
	// content, so NifServer's concern; TRI/EGM FaceGen deformation is external
	// data and stays with the caller (nif_server_v2.md 9).
	std::vector<MorphFrame> morphs;
	float translation[3] = { 0.0f, 0.0f, 0.0f };
	float rotation[9] = { 1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f };
	float scale = 1.0f;
};

// One NiDefaultAVObjectPalette entry: Gamebryo's own name -> NiAVObject table,
// which NiControllerManager binds sequences through.
//
// The name is NOT redundant with the referenced block's own name. Across the
// shipped corpus 280 of 26,022 entries disagree, every one of them naming a
// block that exists nowhere else in the file, and 97 of those are the only way
// a live sequence resolves its target (nif_server_v2.md 8). Resolution order
// is therefore: block's own name first, then palette alias for names no block
// carries. Entries with a null objectRef are inert.
struct PaletteEntry {
	std::string name;
	int32_t object_block_index = -1; // -1 when the entry points nowhere
};

struct ObjectPalette {
	uint32_t block_index = 0;
	std::vector<PaletteEntry> entries;
};

// One ControllerLink, with every target string RESOLVED.
//
// Sequences address targets by five strings, but only inline when the file is
// version 20.1.0.1 or newer. Below that the link carries a NiStringPalette
// reference plus byte offsets into it, and nifly leaves the inline fields
// empty. Five shipped files use that form -- all player idles (eatidle,
// pistolvariant01, talk_handsatside_moving/moving2/still2) -- and they resolve
// to nothing at all unless the palette is read. See nif_server_v2.md 7.4.
// One authored keyframe. `interp` is the NiKeyType as authored -- LINEAR_KEY,
// QUADRATIC_KEY, TBC_KEY or CONST_KEY -- kept because Godot's own track
// interpolation modes are a strict subset and the caller decides how to map.
struct Vec3Key {
	float time = 0.0f;
	float value[3] = { 0.0f, 0.0f, 0.0f };
	std::string interp;
};

// Rotation keys are XYZW, matching Godot's Quaternion storage. The NIF
// serializes WXYZ; the swap happens here so no consumer repeats it.
struct QuatKey {
	float time = 0.0f;
	float value[4] = { 0.0f, 0.0f, 0.0f, 1.0f };
	std::string interp;
};

struct ScalarKey {
	float time = 0.0f;
	float value = 0.0f;
	std::string interp;
};

// The resolved animation curve behind one ControllerLink.
//
// Every interpolator type in the shipped corpus that carries authored curve
// data is handled: NiTransformInterpolator (6,850 files), the B-spline
// transform pair (4,069), NiFloatInterpolator (2,852), NiBoolInterpolator
// (1,516) and NiPoint3Interpolator (835). The NiBlend* family carries no data
// of its own -- it blends other interpolators at runtime -- and is reported
// with kind "blend" and no keys rather than being silently dropped.
struct Interpolator {
	bool present = false;
	uint32_t block_index = 0;
	std::string block_type;

	// transform | float | bool | point3 | blend | unsupported
	std::string kind;

	// True when the keys were SAMPLED rather than authored: the B-spline
	// forms store cubic control points, which have no keyframe equivalent, so
	// they are evaluated adaptively. Everything else is verbatim.
	bool resampled = false;

	// True when rotation keys were composed from NiTransformData's per-axis
	// float curves (rotationType == XYZ_ROTATION_KEY) rather than read as
	// quaternions. Composition order is X, Y, Z.
	bool rotation_from_euler = false;

	// The interpolator's own static value, which is what applies when it
	// carries no data block at all -- a real and common case, used to pin a
	// node to a pose for the length of a sequence.
	bool has_static_transform = false;
	float translation[3] = { 0.0f, 0.0f, 0.0f }; // meters
	float rotation[4] = { 0.0f, 0.0f, 0.0f, 1.0f }; // XYZW
	float scale = 1.0f;
	bool has_static_float = false;
	float static_float = 0.0f;

	std::vector<Vec3Key> translation_keys; // meters
	std::vector<QuatKey> rotation_keys;
	std::vector<ScalarKey> scale_keys;
	std::vector<ScalarKey> float_keys; // float and bool (0/1) interpolators
	std::vector<Vec3Key> point3_keys; // NiPoint3Interpolator, NOT converted
};

struct ControlledBlock {
	std::string node_name;
	std::string property_type;
	std::string controller_type;
	std::string controller_id;
	std::string interpolator_id;
	bool from_string_palette = false; // true when resolved via offsets

	// The curve this link plays. Absent when interpolatorRef is null, which
	// real sequences do carry.
	Interpolator interpolator;
};

struct Sequence {
	uint32_t block_index = 0;
	std::string name;
	std::string accum_root_name;
	uint32_t cycle_type = 0;
	float start_time = 0.0f;
	float stop_time = 0.0f;
	std::vector<ControlledBlock> controlled_blocks;

	// NiControllerSequence::textKeyRef -- the animation's own event markers
	// ("start", "end", sound cues, hit frames). A separate link from the
	// NiObjectNET::extraDataRefs chain that node-attached NiTextKeyExtraData
	// arrives through, and the one most blocks actually hang off.
	std::vector<TextKey> text_keys;
};

struct Document {
	std::string version;
	uint32_t block_count = 0;
	std::vector<SceneNode> nodes;
	std::vector<ObjectPalette> palettes;
	std::vector<Sequence> sequences;
	// True when the declared bones form a parent-child hierarchy inside THIS
	// file, i.e. the file contains a usable skeleton rather than a reference
	// to one held elsewhere. skeleton.nif is true; a body part whose bone list
	// is flat (86% of skinned NIFs) is false, because its rig lives in another
	// file and binding happens by name at assembly time.
	bool has_bone_hierarchy = false;

	std::vector<CollisionShape> collision_shapes;
	std::vector<CollisionBody> collision_bodies;
};

// Throws std::runtime_error when the bytes are not a loadable NIF.
//
// Reads the caller's buffer in place: no copy is made of the NIF payload at
// any point between here and nifly's parser.
Document load(const uint8_t *data, size_t size);

inline Document load(const std::vector<uint8_t> &bytes) {
	return load(bytes.data(), bytes.size());
}

} // namespace nifsrc

#endif // NIF_SOURCE_H
