#include "nif_loader.h"

#include "../common/units.h"

#include <NifFile.hpp>
#include <Geometry.hpp>
#include <bhk.hpp>
#include <Animation.hpp>

#include <Skin.hpp>

#include <algorithm>
#include <sstream>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace nif {

namespace {

// Translation is a position (Gamebryo units -> meters); rotation/scale are
// not (unitless matrix entries / a relative multiplier) — see units.h.
void flatten_transform(const nifly::MatTransform &t, SubMesh &out) {
	out.translation[0] = t.translation.x * units::kGamebryoUnitsToMeters;
	out.translation[1] = t.translation.y * units::kGamebryoUnitsToMeters;
	out.translation[2] = t.translation.z * units::kGamebryoUnitsToMeters;
	out.rotation[0] = t.rotation[0].x;
	out.rotation[1] = t.rotation[0].y;
	out.rotation[2] = t.rotation[0].z;
	out.rotation[3] = t.rotation[1].x;
	out.rotation[4] = t.rotation[1].y;
	out.rotation[5] = t.rotation[1].z;
	out.rotation[6] = t.rotation[2].x;
	out.rotation[7] = t.rotation[2].y;
	out.rotation[8] = t.rotation[2].z;
	out.scale = t.scale;
}

// A NiAVObject's own GetTransformToParent() is relative to its IMMEDIATE
// parent only, not flattened to the NIF's root. Bethesda's articulated
// props (doors, lidded containers) commonly put the actual positioning
// offset on an intermediate NiNode (a hinge/pivot node) one or more levels
// above the renderable NiShape/collision-bearing NiAVObject itself — using
// GetTransformToParent() alone silently drops that offset entirely.
// Confirmed against real data (phases/2/04-articulated-prop-transforms.md):
// Clutter\Fridge\FridgeClosed01.NIF's body render mesh has an identity
// local transform of its own; the real ~1.05m Z lift that keeps it off the
// floor lives entirely on its parent "FridgeContainer" NiNode.
//
// The file's own ROOT block's transform is deliberately NEVER composed in
// (whether encountered as an ancestor, or as the starting node itself, for
// the common case of collision attached directly to the root) — confirmed
// against real data (phases/2/05-root-transform-exclusion.md) that this is
// required, not optional: some Bethesda architecture-kit NIFs (e.g.
// NVCraftsmanRmEndB.nif) bake a real, nonzero rotation directly onto their
// root block (a -90 degree roll in that example) that is NOT meant to be
// applied when the file is instanced as a placed object — verified by
// comparing multiple real kit pieces, where the ones rendering correctly
// all have an identity root transform and the ones rendering wrong all
// have a nonzero one.
//
// phases/3/00-door-completion.md follow-up: this used to independently
// re-walk the NiAVObject parent chain via nifly's own GetParentNode() (an
// O(n) linear scan per step — see NifFile::GetParentNode()/GetBlockID()),
// the exact same walk the scene_nodes pass above already performs and
// caches. Re-deriving the same composition a second, separately-coded way
// was exactly the kind of divergence risk phases/3/00-door-completion.md's
// "generation of an object from a NIF should be a consistent code path"
// principle rules out: Static content's flattened SubMesh/CollisionShape
// transform and Dynamic content's real scene_nodes hierarchy would each be
// computed correctly on their own, but by two different algorithms that
// could quietly drift out of sync under a future edit to one and not the
// other. This now composes the SAME cached local transforms scene_nodes
// itself was built from (`local_raw`, parallel to mesh.scene_nodes),
// walking parent_index instead of re-querying nifly — one source of truth,
// with Static's flattening simply "peeling" a scalar result off of it
// rather than recomputing it independently. Mathematically identical
// result to the old per-shape walk (same steps, same order, same
// ComposeTransforms calls — just sourced from the cache instead of
// re-fetched), verified via the full regression suite's exact position/
// AABB assertions after this change.
nifly::MatTransform flatten_via_scene_nodes(nifly::NiAVObject *obj,
		const std::unordered_map<nifly::NiAVObject *, int32_t> &scene_node_index,
		const std::vector<nifly::MatTransform> &local_raw,
		const std::vector<SceneNode> &scene_nodes) {
	nifly::MatTransform result;
	result.Clear();
	auto it = scene_node_index.find(obj);
	int32_t idx = (it != scene_node_index.end()) ? it->second : -1;
	while (idx != -1) {
		result = local_raw[idx].ComposeTransforms(result);
		idx = scene_nodes[idx].parent_index;
	}
	return result; // idx == -1: `obj` is the file's own root, or wasn't tracked -- its transform is excluded either way
}

void flatten_transform(const nifly::MatTransform &t, CollisionShape &out) {
	out.translation[0] = t.translation.x * units::kGamebryoUnitsToMeters;
	out.translation[1] = t.translation.y * units::kGamebryoUnitsToMeters;
	out.translation[2] = t.translation.z * units::kGamebryoUnitsToMeters;
	out.rotation[0] = t.rotation[0].x;
	out.rotation[1] = t.rotation[0].y;
	out.rotation[2] = t.rotation[0].z;
	out.rotation[3] = t.rotation[1].x;
	out.rotation[4] = t.rotation[1].y;
	out.rotation[5] = t.rotation[1].z;
	out.rotation[6] = t.rotation[2].x;
	out.rotation[7] = t.rotation[2].y;
	out.rotation[8] = t.rotation[2].z;
}

// SceneNode's own transform is deliberately LOCAL (relative to its
// immediate parent), unlike SubMesh/CollisionShape's flatten_transform
// overloads above which write an already-flattened-to-root transform —
// different semantics despite the identical field layout, kept as a
// distinctly-named function so the two are never confused for
// interchangeable.
void write_local_transform(const nifly::MatTransform &t, SceneNode &out) {
	out.translation[0] = t.translation.x * units::kGamebryoUnitsToMeters;
	out.translation[1] = t.translation.y * units::kGamebryoUnitsToMeters;
	out.translation[2] = t.translation.z * units::kGamebryoUnitsToMeters;
	out.rotation[0] = t.rotation[0].x;
	out.rotation[1] = t.rotation[0].y;
	out.rotation[2] = t.rotation[0].z;
	out.rotation[3] = t.rotation[1].x;
	out.rotation[4] = t.rotation[1].y;
	out.rotation[5] = t.rotation[1].z;
	out.rotation[6] = t.rotation[2].x;
	out.rotation[7] = t.rotation[2].y;
	out.rotation[8] = t.rotation[2].z;
	out.scale = t.scale;
}

// SkinBoneTransform's own transform (bone bind pose / global<->skin) — same
// layout convention as write_local_transform's SceneNode overload, just a
// distinctly-named function/type since a bind transform isn't a scene-graph
// node.
void write_bind_transform(const nifly::MatTransform &t, SkinBoneTransform &out) {
	out.translation[0] = t.translation.x * units::kGamebryoUnitsToMeters;
	out.translation[1] = t.translation.y * units::kGamebryoUnitsToMeters;
	out.translation[2] = t.translation.z * units::kGamebryoUnitsToMeters;
	out.rotation[0] = t.rotation[0].x;
	out.rotation[1] = t.rotation[0].y;
	out.rotation[2] = t.rotation[0].z;
	out.rotation[3] = t.rotation[1].x;
	out.rotation[4] = t.rotation[1].y;
	out.rotation[5] = t.rotation[1].z;
	out.rotation[6] = t.rotation[2].x;
	out.rotation[7] = t.rotation[2].y;
	out.rotation[8] = t.rotation[2].z;
	out.scale = t.scale;
}

// Issue #46: extracts one SkinData from a skinned NiShape, via nifly's own
// high-level NifFile::GetShapeBoneList/GetShapeTransformSkinToBone/
// GetShapeTransformGlobalToSkin/GetShapeBoneWeights helpers rather than
// re-deriving NiSkinPartition's partition-local bone-palette remap by hand
// — those helpers already merge whichever real source the file stores
// weights in (BSTriShape vs. NiSkinData/NiSkinPartition, see NifFile.hpp's
// own doc comments on GetShapeBoneWeights) and are the same code nifly's own
// CreateSkinning/UpdateSkinPartitions round-trip through, so this reuses a
// proven path instead of a second, independently-coded partition merge that
// could quietly diverge from it. Returns a SkinData with empty bone_names if
// the shape has no resolvable bones — caller skips those.
SkinData extract_skin_data(const nifly::NifFile &nif, nifly::NiShape *shape, const std::vector<nifly::Vector3> &verts) {
	SkinData skin;

	std::vector<std::string> bone_names;
	uint32_t num_bones = nif.GetShapeBoneList(shape, bone_names);
	if (num_bones == 0) {
		return skin;
	}
	skin.target_node_name = shape->name.get();
	skin.bone_names = std::move(bone_names);

	nifly::MatTransform skin_to_global;
	if (nif.GetShapeTransformGlobalToSkin(shape, skin_to_global)) {
		write_bind_transform(skin_to_global, skin.skin_to_global_transform);
	}

	skin.bone_bind_transforms.resize(num_bones);
	for (uint32_t b = 0; b < num_bones; ++b) {
		nifly::MatTransform bind;
		if (nif.GetShapeTransformSkinToBone(shape, b, bind)) {
			write_bind_transform(bind, skin.bone_bind_transforms[b]);
		}
	}

	// Per-vertex accumulation of (bone index, weight) pairs across every
	// bone, before collapsing to the fixed 4-wide arrays Godot's own
	// ARRAY_BONES/ARRAY_WEIGHTS expects (see SkinData's own doc comment for
	// why 4 is confirmed sufficient for real FNV content).
	uint32_t vertex_count = static_cast<uint32_t>(verts.size());
	std::vector<std::vector<std::pair<uint16_t, float>>> per_vertex(vertex_count);
	for (uint32_t b = 0; b < num_bones; ++b) {
		std::unordered_map<uint16_t, float> weights;
		nif.GetShapeBoneWeights(shape, b, weights);
		for (const auto &entry : weights) {
			if (entry.first < vertex_count && entry.second > 0.0f) {
				per_vertex[entry.first].emplace_back(static_cast<uint16_t>(b), entry.second);
			}
		}
	}

	skin.vertex_bone_indices.assign(vertex_count, { 0, 0, 0, 0 });
	skin.vertex_bone_weights.assign(vertex_count, { 0.0f, 0.0f, 0.0f, 0.0f });
	for (uint32_t v = 0; v < vertex_count; ++v) {
		auto &entries = per_vertex[v];
		std::sort(entries.begin(), entries.end(),
				[](const std::pair<uint16_t, float> &a, const std::pair<uint16_t, float> &b) { return a.second > b.second; });
		if (entries.size() > 4) {
			entries.resize(4); // not observed in real data (see doc comment above) -- a safety cap, not the expected path
		}
		for (size_t i = 0; i < entries.size(); ++i) {
			skin.vertex_bone_indices[v][i] = entries[i].first;
			skin.vertex_bone_weights[v][i] = entries[i].second;
		}
	}

	if (auto *dismember = dynamic_cast<nifly::BSDismemberSkinInstance *>(
				nif.GetHeader().GetBlock<nifly::NiBoneContainer>(shape->SkinInstanceRef()))) {
		skin.partition_body_part_ids.reserve(dismember->partitions.size());
		for (const auto &p : dismember->partitions) {
			skin.partition_body_part_ids.push_back(p.partID);
		}
	}

	return skin;
}

// bhkRigidBodyT (the "T" == has its own Transform variant) carries a real
// translation + rotation that must be composed on top of the
// collision-bearing NiAVObject's own transform-to-root — needed when
// collision is attached directly to the NIF's root block, whose own
// transform is deliberately never composed in (see flatten_via_scene_nodes's
// comment on NVCraftsmanRmEndB.nif's stray root rotation), so the root
// case has nowhere else for a real offset to live. Confirmed real, not
// hypothetical: NVCraftsmanFireplace.NIF and NVCraftsmanRmDoor.NIF both
// have collision on the root block with a real bhkRigidBodyT translation
// (~1.35m, ~0.9m respectively) with no counterpart anywhere else — their
// collision was sitting at the NIF's local origin instead of over the
// render mesh without this.
//
// A PLAIN bhkRigidBody (not "T") must NOT have this applied, even though
// nifly parses the exact same translation/rotation fields for it — those
// values are Bethesda's own re-expression of the SAME offset the AV's node
// chain already carries (in Havok's unit scale), not an additional delta.
// Confirmed directly: Clutter\Fridge\FridgeClosed01.NIF's "FridgeContainer"
// node carries the real ~1.05m Z-lift documented in
// phases/2/04-articulated-prop-transforms.md as its own local_translation
// (73.589 raw units); its plain bhkRigidBody's translation.z is 10.5142
// Havok units, which times kHavokUnitsToGamebryoUnits is 73.6 -- the same
// number. Composing it unconditionally (an earlier version of this fix
// did) double-applies that lift, and produces the same kind of duplicate/
// stray offset or rotation on other plain-bhkRigidBody props (kit pieces,
// BookGeneric06b, Globe00, ...) — caught by direct visual report, not
// derivable from the fireplace/door case alone since those only exercise
// the root-collision, "T"-variant path.
nifly::MatTransform rigid_body_transform(const nifly::bhkRigidBody *body) {
	nifly::MatTransform t;
	t.Clear();
	if (!body || !dynamic_cast<const nifly::bhkRigidBodyT *>(body)) {
		return t;
	}
	t.translation = nifly::Vector3(
			body->translation.x * units::kHavokUnitsToGamebryoUnits,
			body->translation.y * units::kHavokUnitsToGamebryoUnits,
			body->translation.z * units::kHavokUnitsToGamebryoUnits);
	const auto &q = body->rotation; // xyzw
	t.rotation = nifly::Matrix3(
			1.0f - 2.0f * (q.y * q.y + q.z * q.z), 2.0f * (q.x * q.y - q.w * q.z), 2.0f * (q.x * q.z + q.w * q.y),
			2.0f * (q.x * q.y + q.w * q.z), 1.0f - 2.0f * (q.x * q.x + q.z * q.z), 2.0f * (q.y * q.z - q.w * q.x),
			2.0f * (q.x * q.z - q.w * q.y), 2.0f * (q.y * q.z + q.w * q.x), 1.0f - 2.0f * (q.x * q.x + q.y * q.y));
	return t;
}

// Unwraps a bhkMoppBvTreeShape (a Havok-compiled BVH acceleration wrapper —
// see phases/1/02-collision-extraction.md) to the real shape it wraps. The
// MOPP data itself is opaque/not decoded, only the underlying shape matters.
nifly::bhkShape *unwrap_shape(const nifly::NifFile &nif, nifly::bhkShape *shape) {
	while (shape) {
		auto *mopp = dynamic_cast<nifly::bhkMoppBvTreeShape *>(shape);
		if (!mopp) {
			return shape;
		}
		shape = nif.GetHeader().GetBlock<nifly::bhkShape>(mopp->shapeRef);
	}
	return nullptr;
}

// phases/3/00-door-completion.md, Part A: niftools' NiKeyType -> this
// codebase's own KeyInterpolation. A plain 1:1 mapping, kept as a named
// function rather than inlined at every call site so the "which enum
// values exist" question has exactly one answer in this file.
KeyInterpolation map_key_interpolation(nifly::NiKeyType t) {
	switch (t) {
		case nifly::LINEAR_KEY: return KeyInterpolation::kLinear;
		case nifly::QUADRATIC_KEY: return KeyInterpolation::kQuadratic;
		case nifly::TBC_KEY: return KeyInterpolation::kTbc;
		case nifly::CONST_KEY: return KeyInterpolation::kConstant;
		case nifly::XYZ_ROTATION_KEY: // never appears on an individual key's own type -- that value only appears on NiTransformData::rotationType itself, selecting the per-axis representation (see extract_track below). Falls through to kNone defensively, not silently misclassified as a real curve type.
		case nifly::NO_INTERP:
		default: return KeyInterpolation::kNone;
	}
}

std::vector<FloatKey> extract_float_keys(const nifly::NiAnimationKeyGroup<float> &group) {
	std::vector<FloatKey> out;
	uint32_t n = group.GetNumKeys();
	out.reserve(n);
	for (uint32_t i = 0; i < n; ++i) {
		nifly::NiAnimationKey<float> k = group.GetKey(static_cast<int>(i));
		FloatKey fk;
		fk.time = k.time;
		fk.value = k.value;
		fk.forward = k.forward;
		fk.backward = k.backward;
		fk.tension = k.tbc.tension;
		fk.bias = k.tbc.bias;
		fk.continuity = k.tbc.continuity;
		fk.interp = map_key_interpolation(k.type);
		out.push_back(fk);
	}
	return out;
}

// Translation keys specifically — the one key type that needs the
// Gamebryo-units-to-meters conversion applied (units.h: "applied at the
// true source... not per-consumer"). Rotation (both quaternion and
// per-axis) and scale carry no unit conversion — see units.h's own scope
// note ("only applies to positions/vertex coordinates").
std::vector<Vector3Key> extract_translation_keys(const nifly::NiAnimationKeyGroup<nifly::Vector3> &group) {
	std::vector<Vector3Key> out;
	uint32_t n = group.GetNumKeys();
	out.reserve(n);
	for (uint32_t i = 0; i < n; ++i) {
		nifly::NiAnimationKey<nifly::Vector3> k = group.GetKey(static_cast<int>(i));
		Vector3Key vk;
		vk.time = k.time;
		vk.value[0] = k.value.x * units::kGamebryoUnitsToMeters;
		vk.value[1] = k.value.y * units::kGamebryoUnitsToMeters;
		vk.value[2] = k.value.z * units::kGamebryoUnitsToMeters;
		vk.forward[0] = k.forward.x * units::kGamebryoUnitsToMeters;
		vk.forward[1] = k.forward.y * units::kGamebryoUnitsToMeters;
		vk.forward[2] = k.forward.z * units::kGamebryoUnitsToMeters;
		vk.backward[0] = k.backward.x * units::kGamebryoUnitsToMeters;
		vk.backward[1] = k.backward.y * units::kGamebryoUnitsToMeters;
		vk.backward[2] = k.backward.z * units::kGamebryoUnitsToMeters;
		vk.tension = k.tbc.tension;
		vk.bias = k.tbc.bias;
		vk.continuity = k.tbc.continuity;
		vk.interp = map_key_interpolation(k.type);
		out.push_back(vk);
	}
	return out;
}

// Builds one AnimationTrack from a resolved NiTransformData — the shared
// body for every ControllerLink whose interpolator is a NiTransformInterpolator
// (or a subclass, e.g. BSRotAccumTransfInterpolator — dynamic_cast at the
// call site already covers that). `rotationType == XYZ_ROTATION_KEY`
// (confirmed the dominant real case — see nif_types.h's own doc comment)
// selects the per-axis representation; any other rotationType with real
// quaternion keys present selects that instead. Neither is assumed present
// — a track can legitimately have zero rotation keys of either kind (a
// pure translation/scale track, e.g. a real elevator car).
AnimationTrack extract_track(const std::string &target_node_name, nifly::NiTransformData *td) {
	AnimationTrack track;
	track.target_node_name = target_node_name;

	if (!td->quaternionKeys.empty()) {
		track.has_quaternion_keys = true;
		track.quaternion_keys.reserve(td->quaternionKeys.size());
		for (const auto &k : td->quaternionKeys) {
			QuatKey qk;
			qk.time = k.time;
			qk.value[0] = k.value.x;
			qk.value[1] = k.value.y;
			qk.value[2] = k.value.z;
			qk.value[3] = k.value.w;
			qk.interp = map_key_interpolation(k.type);
			track.quaternion_keys.push_back(qk);
		}
	}
	if (td->rotationType == nifly::XYZ_ROTATION_KEY &&
			(td->xRotations.GetNumKeys() > 0 || td->yRotations.GetNumKeys() > 0 || td->zRotations.GetNumKeys() > 0)) {
		track.has_axis_keys = true;
		track.x_rotation_keys = extract_float_keys(td->xRotations);
		track.y_rotation_keys = extract_float_keys(td->yRotations);
		track.z_rotation_keys = extract_float_keys(td->zRotations);
	}
	track.translation_keys = extract_translation_keys(td->translations);
	track.scale_keys = extract_float_keys(td->scales);
	return track;
}

// Extracts one CollisionShape from a resolved bhkShape, or leaves kind ==
// kNone if it's a shape type not handled (bhkListShape/bhkConvexListShape
// composites, phantoms, etc. — not needed for Phase 1's static-world case).
CollisionShape extract_shape(const nifly::NifFile &nif, nifly::bhkShape *shape) {
	CollisionShape out;
	if (auto *packed = dynamic_cast<nifly::bhkPackedNiTriStripsShape *>(shape)) {
		auto *data = nif.GetHeader().GetBlock<nifly::hkPackedNiTriStripsData>(packed->dataRef);
		if (data) {
			out.kind = CollisionShapeKind::kTriangleMesh;
			out.positions.reserve(data->compressedVertData.size() * 3);
			for (const auto &v : data->compressedVertData) {
				out.positions.push_back(v.x * units::kHavokToMeters);
				out.positions.push_back(v.y * units::kHavokToMeters);
				out.positions.push_back(v.z * units::kHavokToMeters);
			}
			out.indices.reserve(data->triData.size() * 3);
			for (const auto &t : data->triData) {
				out.indices.push_back(t.tri.p1);
				out.indices.push_back(t.tri.p2);
				out.indices.push_back(t.tri.p3);
			}
		}
	} else if (auto *box = dynamic_cast<nifly::bhkBoxShape *>(shape)) {
		out.kind = CollisionShapeKind::kBox;
		out.half_extents[0] = box->dimensions.x * units::kHavokToMeters;
		out.half_extents[1] = box->dimensions.y * units::kHavokToMeters;
		out.half_extents[2] = box->dimensions.z * units::kHavokToMeters;
	} else if (auto *capsule = dynamic_cast<nifly::bhkCapsuleShape *>(shape)) {
		out.kind = CollisionShapeKind::kCapsule;
		out.point_a[0] = capsule->point1.x * units::kHavokToMeters;
		out.point_a[1] = capsule->point1.y * units::kHavokToMeters;
		out.point_a[2] = capsule->point1.z * units::kHavokToMeters;
		out.point_b[0] = capsule->point2.x * units::kHavokToMeters;
		out.point_b[1] = capsule->point2.y * units::kHavokToMeters;
		out.point_b[2] = capsule->point2.z * units::kHavokToMeters;
		out.capsule_radius = capsule->radius1 * units::kHavokToMeters;
	} else if (auto *convex = dynamic_cast<nifly::bhkConvexVerticesShape *>(shape)) {
		out.kind = CollisionShapeKind::kConvexHull;
		out.positions.reserve(static_cast<size_t>(convex->verts.size()) * 3);
		for (uint32_t i = 0; i < convex->verts.size(); ++i) {
			const nifly::Vector4 &v = convex->verts[i];
			out.positions.push_back(v.x * units::kHavokToMeters);
			out.positions.push_back(v.y * units::kHavokToMeters);
			out.positions.push_back(v.z * units::kHavokToMeters);
		}
	} else if (auto *sphere = dynamic_cast<nifly::bhkSphereShape *>(shape)) {
		out.kind = CollisionShapeKind::kSphere;
		out.radius = sphere->radius * units::kHavokToMeters;
	}
	return out;
}

} // namespace

Mesh load_mesh(const std::vector<uint8_t> &bytes) {
	std::string buffer(reinterpret_cast<const char *>(bytes.data()), bytes.size());
	std::istringstream stream(buffer, std::ios::binary);

	nifly::NifFile nif;
	int rc = nif.Load(stream);
	if (rc != 0 || !nif.IsValid()) {
		throw std::runtime_error("nif::load_mesh: nifly failed to load NIF (code " + std::to_string(rc) + ")");
	}

	Mesh mesh;
	mesh.nif_version = nif.GetHeader().GetVersion().GetVersionInfo();

	// General node-graph preservation (SceneNode's own doc comment in
	// nif_types.h) — built first so the submesh/collision loops below can
	// fill in owning_node_index AND resolve their own flattened transform
	// (flatten_via_scene_nodes(), below) from it. Two passes: the first
	// assigns every non-root NiAVObject a scene_nodes slot (in block-index
	// order) and records a pointer -> index map; the second fills in each
	// entry's parent_index/local transform, and stashes the same local
	// transform in RAW (pre-unit-conversion) form in `local_raw` (parallel
	// to mesh.scene_nodes) — SceneNode's own translation is already
	// meters-converted for the GDScript side, but flatten_via_scene_nodes()
	// needs to compose in nifly's native MatTransform domain, matching what
	// flatten_transform() expects at the end of the whole composed chain.
	// GetParentNode() itself is an O(n) linear scan per call (nifly's own
	// NifFile::GetParentNode()/GetBlockID()); calling it once per block
	// here is the same cost this file already accepted before scene_nodes
	// existed. What the map buys is resolving a parent NiAVObject* to ITS
	// scene_nodes index in O(1), instead of a second nested block search.
	uint32_t num_blocks = nif.GetHeader().GetNumBlocks();
	std::unordered_map<nifly::NiAVObject *, int32_t> scene_node_index;
	for (uint32_t i = 0; i < num_blocks; ++i) {
		auto *av = nif.GetHeader().GetBlock<nifly::NiAVObject>(i);
		if (!av || !nif.GetParentNode(av)) {
			continue; // not an NiAVObject, or is the file's own root
		}
		scene_node_index[av] = static_cast<int32_t>(mesh.scene_nodes.size());
		SceneNode node;
		node.name = av->name.get();
		mesh.scene_nodes.push_back(std::move(node));
	}
	std::vector<nifly::MatTransform> local_raw(mesh.scene_nodes.size());
	for (uint32_t i = 0; i < num_blocks; ++i) {
		auto *av = nif.GetHeader().GetBlock<nifly::NiAVObject>(i);
		auto it = av ? scene_node_index.find(av) : scene_node_index.end();
		if (it == scene_node_index.end()) {
			continue;
		}
		SceneNode &node = mesh.scene_nodes[it->second];
		nifly::MatTransform local = av->GetTransformToParent();
		local_raw[it->second] = local;
		write_local_transform(local, node);
		nifly::NiNode *parent = nif.GetParentNode(av);
		auto parent_it = scene_node_index.find(parent);
		node.parent_index = (parent_it != scene_node_index.end()) ? parent_it->second : -1;
	}

	for (nifly::NiShape *shape : nif.GetShapes()) {
		const std::vector<nifly::Vector3> *verts = nif.GetVertsForShape(shape);
		if (!verts || verts->empty()) {
			// Collision-only or otherwise non-renderable node — skip. Actual
			// bhk* collision extraction is a fast-follow per the phase doc.
			continue;
		}

		SubMesh sub;
		sub.name = shape->name.get();

		sub.positions.reserve(verts->size() * 3);
		for (const auto &v : *verts) {
			sub.positions.push_back(v.x * units::kGamebryoUnitsToMeters);
			sub.positions.push_back(v.y * units::kGamebryoUnitsToMeters);
			sub.positions.push_back(v.z * units::kGamebryoUnitsToMeters);
		}

		if (const std::vector<nifly::Vector3> *normals = nif.GetNormalsForShape(shape)) {
			sub.normals.reserve(normals->size() * 3);
			for (const auto &n : *normals) {
				sub.normals.push_back(n.x);
				sub.normals.push_back(n.y);
				sub.normals.push_back(n.z);
			}
		}

		if (const std::vector<nifly::Vector2> *uvs = nif.GetUvsForShape(shape)) {
			sub.uvs.reserve(uvs->size() * 2);
			for (const auto &uv : *uvs) {
				sub.uvs.push_back(uv.u);
				sub.uvs.push_back(uv.v);
			}
		}

		if (shape->HasVertexColors()) {
			std::vector<nifly::Color4> colors;
			if (nif.GetColorsForShape(shape, colors)) {
				sub.colors.reserve(colors.size() * 4);
				for (const auto &c : colors) {
					sub.colors.push_back(c.r);
					sub.colors.push_back(c.g);
					sub.colors.push_back(c.b);
					sub.colors.push_back(c.a);
				}
			}
		}

		std::vector<nifly::Triangle> tris;
		shape->GetTriangles(tris);
		sub.indices.reserve(tris.size() * 3);
		for (const auto &t : tris) {
			// NIF/Gamebryo (DirectX-lineage) triangles are wound
			// clockwise-front; Godot (and glTF) expect counter-clockwise-
			// front. Swapping the last two indices reverses winding
			// without changing which vertices form the triangle. Found by
			// eye (backface culling showing through mesh interiors) rather
			// than by any acceptance check — see
			// phases/1/00-interior-cell-loader.md.
			sub.indices.push_back(t.p1);
			sub.indices.push_back(t.p3);
			sub.indices.push_back(t.p2);
		}

		nifly::NiShader *shader = nif.GetShader(shape);
		if (auto *unlit = dynamic_cast<nifly::BSShaderNoLightingProperty *>(shader)) {
			sub.no_lighting = true;
			sub.no_lighting_uses_falloff = (unlit->shaderFlags1 & nifly::SLSF1_USE_FALLOFF) != 0;
			sub.falloff_start_angle = unlit->falloffStartAngle;
			sub.falloff_stop_angle = unlit->falloffStopAngle;
			sub.falloff_start_opacity = unlit->falloffStartOpacity;
			sub.falloff_stop_opacity = unlit->falloffStopOpacity;
		}
		if (nifly::BSShaderProperty *bs_shader = dynamic_cast<nifly::BSShaderProperty *>(shader)) {
			sub.double_sided = bs_shader->IsDoubleSided();
		}

		std::string tex;
		nif.GetTextureSlot(shape, tex, 0); // slot 0: diffuse/base
		// Grass NIFs do not use BSShaderTextureSet: their real diffuse path
		// lives directly on TallGrassShaderProperty.fileName.  Leaving this
		// as an empty normal slot made every otherwise-valid GRAS mesh render
		// without its alpha-tested grass texture.
		if (tex.empty()) {
			if (auto *grass_shader = dynamic_cast<nifly::TallGrassShaderProperty *>(shader)) {
				tex = grass_shader->fileName.get();
			}
		}
		sub.texture_path = tex;
		nif.GetTextureSlot(shape, tex, 1); // slot 1: normal + gloss(alpha)
		sub.normal_texture_path = tex;
		nif.GetTextureSlot(shape, tex, 2); // slot 2: glow/emissive
		sub.glow_texture_path = tex;

		if (nifly::NiAlphaProperty *alpha = nif.GetAlphaProperty(shape)) {
			sub.has_alpha_property = true;
			// Standard NIF NiAlphaProperty.flags bitfield (niftools spec,
			// stable across NIF versions, not nifly-specific): bit 0 =
			// alpha blend enable, bits 1-4 = source blend function, bits
			// 5-8 = destination blend function, bit 9 = alpha test enable.
			// threshold is a raw 0..255 byte, normalized here to 0..1 for
			// the Godot side.
			sub.alpha_blend_enabled = (alpha->flags & 0x0001) != 0;
			sub.alpha_test_enabled = (alpha->flags & 0x0200) != 0;
			sub.alpha_threshold = static_cast<float>(alpha->threshold) / 255.0f;

			// niftools ALPHA_BLEND_FUNCTION enum values actually seen in
			// this game's data (see nif_types.h's own doc comment for the
			// real-data census this was sourced from).
			constexpr uint32_t kBlendOne = 0, kBlendZero = 1, kBlendSrcColor = 2,
					kBlendSrcAlpha = 6, kBlendInvSrcAlpha = 7;
			uint32_t src_func = (alpha->flags >> 1) & 0xF;
			uint32_t dst_func = (alpha->flags >> 5) & 0xF;
			if (src_func == kBlendSrcAlpha && dst_func == kBlendInvSrcAlpha) {
				sub.alpha_blend_func = SubMesh::BlendFunc::kMix;
			} else if ((src_func == kBlendSrcAlpha && dst_func == kBlendOne) ||
					(src_func == kBlendOne && dst_func == kBlendOne)) {
				sub.alpha_blend_func = SubMesh::BlendFunc::kAdd;
			} else if (src_func == kBlendZero && dst_func == kBlendSrcColor) {
				sub.alpha_blend_func = SubMesh::BlendFunc::kMultiply;
			} else {
				sub.alpha_blend_func = SubMesh::BlendFunc::kMix; // unrecognized combo, not seen in the real-data sample -- fall back to prior "always mix" behavior
			}
		}

		flatten_transform(flatten_via_scene_nodes(shape, scene_node_index, local_raw, mesh.scene_nodes), sub);
		{
			auto node_it = scene_node_index.find(shape);
			sub.owning_node_index = (node_it != scene_node_index.end()) ? node_it->second : -1;
		}

		if (shape->HasSkinInstance()) {
			SkinData skin = extract_skin_data(nif, shape, *verts);
			if (!skin.bone_names.empty()) {
				mesh.skin_data.push_back(std::move(skin));
			}
		}

		mesh.submeshes.push_back(std::move(sub));
	}

	// Collision (phases/1/02-collision-extraction.md): walk every NiAVObject
	// block (not just render NiShapes — collision is commonly attached to a
	// parent NiNode rather than the visible mesh itself) looking for a
	// non-empty collisionRef, then follow
	// NiAVObject -> bhkCollisionObject -> bhkRigidBody -> bhkShape.
	for (uint32_t i = 0; i < num_blocks; ++i) {
		nifly::NiAVObject *av = nif.GetHeader().GetBlock<nifly::NiAVObject>(i);
		if (!av || av->collisionRef.IsEmpty()) {
			continue;
		}
		// Collision was authored here regardless of whether we can parse
		// what it resolves to — set before any of the below can bail out.
		mesh.has_collision_data = true;
		nifly::bhkCollisionObject *co = nif.GetHeader().GetBlock<nifly::bhkCollisionObject>(av->collisionRef);
		if (!co) {
			continue; // bhkBlendCollisionObject/bhkNPCollisionObject etc — not handled
		}
		nifly::bhkRigidBody *body = nif.GetHeader().GetBlock<nifly::bhkRigidBody>(co->bodyRef);
		if (!body) {
			continue;
		}
		nifly::bhkShape *shape = unwrap_shape(nif, nif.GetHeader().GetBlock<nifly::bhkShape>(body->shapeRef));
		if (!shape) {
			continue;
		}

		CollisionShape cs = extract_shape(nif, shape);
		if (cs.kind == CollisionShapeKind::kNone) {
			continue; // unhandled shape type (composite/phantom) — not needed for Phase 1
		}
		cs.node_name = av->name.get();
		{
			auto node_it = scene_node_index.find(av);
			cs.owning_node_index = (node_it != scene_node_index.end()) ? node_it->second : -1;
		}
		// The rigid body's own translation/rotation is innermost — it maps
		// the raw collision-shape data into the AV node's local frame,
		// before the AV's own transform-to-root is applied on top.
		flatten_transform(flatten_via_scene_nodes(av, scene_node_index, local_raw, mesh.scene_nodes).ComposeTransforms(rigid_body_transform(body)), cs);
		mesh.collision_shapes.push_back(std::move(cs));
	}

	// phases/3/00-door-completion.md, Part A: rigid single-node transform
	// animation. Walks every top-level block for a NiControllerManager the
	// same way collision extraction above walks for a collisionRef, rather
	// than assuming exactly one — real NIFs weren't checked to guarantee
	// only one, and this costs nothing extra to get right. Deliberately
	// stops at NiTransformInterpolator/NiTransformData (see nif_types.h's
	// own doc comment for the real-data census that scoped this) — every
	// other interpolator type a ControllerLink can reference
	// (NiFloatInterpolator, NiBoolInterpolator, NiPoint3Interpolator, ...)
	// is silently skipped per-link, not per-file, so a sequence that mixes
	// real transform tracks with particle/visibility tracks (confirmed
	// real — e.g. a door-adjacent dust-blast effect NIF) still yields
	// exactly the transform tracks that matter here.
	auto extract_sequence = [&](nifly::NiControllerSequence *seq) -> AnimationSequence {
		AnimationSequence sequence;
		sequence.name = seq->name.get();
		sequence.start_time = seq->startTime;
		sequence.stop_time = seq->stopTime;
		switch (seq->cycleType) {
			case nifly::CYCLE_LOOP: sequence.cycle_type = SequenceCycleType::kLoop; break;
			case nifly::CYCLE_REVERSE: sequence.cycle_type = SequenceCycleType::kReverse; break;
			case nifly::CYCLE_CLAMP:
			default: sequence.cycle_type = SequenceCycleType::kClamp; break;
		}
		for (auto &link : seq->controlledBlocks) {
			auto *interp = nif.GetHeader().GetBlock<nifly::NiInterpolator>(link.interpolatorRef);
			if (!interp) {
				continue;
			}
			auto *xform_interp = dynamic_cast<nifly::NiTransformInterpolator *>(interp);
			if (!xform_interp) {
				continue; // a real, common case (particle/visibility/color track on the same sequence) -- not an error
			}
			auto *td = nif.GetHeader().GetBlock<nifly::NiTransformData>(xform_interp->dataRef);
			if (!td) {
				continue; // NiTransformInterpolator with no data block -- confirmed possible in real data, an empty/no-op track
			}
			sequence.tracks.push_back(extract_track(link.nodeName.get(), td));
		}
		return sequence;
	};

	std::unordered_set<uint32_t> manager_referenced_sequences;
	for (uint32_t i = 0; i < num_blocks; ++i) {
		auto *manager = nif.GetHeader().GetBlock<nifly::NiControllerManager>(i);
		if (!manager) {
			continue;
		}
		for (auto &seq_ref : manager->controllerSequenceRefs) {
			manager_referenced_sequences.insert(seq_ref.index);
			auto *seq = nif.GetHeader().GetBlock<nifly::NiControllerSequence>(seq_ref);
			if (!seq) {
				continue;
			}
			mesh.animation_sequences.push_back(extract_sequence(seq));
		}
	}

	// A standalone .kf animation file (e.g. real movement locomotion —
	// characters\_male\locomotion\male\mtforward.kf) is NOT embedded in a
	// mesh NIF with its own NiControllerManager the way a door's/flag's
	// animation is -- confirmed real via nif_block_dump.cpp: exactly one
	// top-level NiControllerSequence block, zero NiControllerManager
	// blocks, meant to be applied against a skeleton loaded from elsewhere.
	// Any sequence already reached via a manager above is skipped here to
	// avoid double-counting the (real, less common) case where a
	// manager-owning NIF's sequence is also independently enumerable at
	// top level.
	for (uint32_t i = 0; i < num_blocks; ++i) {
		if (manager_referenced_sequences.count(i)) {
			continue;
		}
		auto *seq = nif.GetHeader().GetBlock<nifly::NiControllerSequence>(i);
		if (!seq) {
			continue;
		}
		mesh.animation_sequences.push_back(extract_sequence(seq));
	}

	// Issue #47: vertex morph targets. A NiGeomMorpherController is attached
	// directly to its owning NiShape via that shape's own controllerRef
	// (NiObjectNET's own controller linked-list head, walked via
	// nextControllerRef the same way a real shape could chain more than one
	// controller) — NOT via NiControllerManager/NiControllerSequence like
	// the rigid-animation walk above, so this is a separate top-level pass
	// over every NiAVObject, mirroring how collision extraction above walks
	// every NiAVObject's own collisionRef rather than assuming a single
	// shared owner.
	for (uint32_t i = 0; i < num_blocks; ++i) {
		auto *av = nif.GetHeader().GetBlock<nifly::NiAVObject>(i);
		if (!av || av->controllerRef.IsEmpty()) {
			continue;
		}
		for (auto *ctrl = nif.GetHeader().GetBlock<nifly::NiTimeController>(av->controllerRef); ctrl;
				ctrl = nif.GetHeader().GetBlock<nifly::NiTimeController>(ctrl->nextControllerRef)) {
			auto *morpher = dynamic_cast<nifly::NiGeomMorpherController *>(ctrl);
			if (!morpher) {
				continue; // a real, common case on the same shape (e.g. a NiTransformController for pivot sway) -- not an error
			}
			auto *morph_data_block = nif.GetHeader().GetBlock<nifly::NiMorphData>(morpher->dataRef);
			if (!morph_data_block) {
				continue; // NiGeomMorpherController with no data block -- confirmed possible in principle, an empty/no-op controller
			}

			MorphData morph;
			morph.target_node_name = av->name.get();
			morph.relative_targets = morph_data_block->relativeTargets != 0;
			switch (morpher->flags & 0x3u) { // niftools NiTimeController flags bits 0-1, same CycleType convention as NiControllerSequence::cycleType
				case 0: morph.cycle_type = SequenceCycleType::kLoop; break;
				case 1: morph.cycle_type = SequenceCycleType::kReverse; break;
				default: morph.cycle_type = SequenceCycleType::kClamp; break;
			}
			morph.start_time = morpher->startTime;
			morph.stop_time = morpher->stopTime;

			std::vector<nifly::Morph> morphs = morph_data_block->GetMorphs();
			morph.targets.reserve(morphs.size());
			for (const nifly::Morph &m : morphs) {
				MorphTarget target;
				target.name = m.frameName.get();
				target.vertex_deltas.reserve(m.vectors.size() * 3);
				for (const nifly::Vector3 &v : m.vectors) {
					target.vertex_deltas.push_back(v.x * units::kGamebryoUnitsToMeters);
					target.vertex_deltas.push_back(v.y * units::kGamebryoUnitsToMeters);
					target.vertex_deltas.push_back(v.z * units::kGamebryoUnitsToMeters);
				}
				morph.targets.push_back(std::move(target));
			}

			for (size_t idx = 0; idx < morpher->interpWeights.size(); ++idx) {
				const nifly::MorphWeight &mw = morpher->interpWeights[idx];
				auto *float_interp = nif.GetHeader().GetBlock<nifly::NiFloatInterpolator>(mw.interpRef);
				if (!float_interp) {
					continue; // real: seen empty/unresolvable on some entries (e.g. the always-zero "Base" weight slot) -- not an error
				}
				auto *fd = nif.GetHeader().GetBlock<nifly::NiFloatData>(float_interp->dataRef);
				if (!fd) {
					continue;
				}
				MorphWeightTrack track;
				// interpWeights[] is index-parallel to morphs[] in every real
				// file sampled (nifly's own internal storage convention) --
				// used only to resolve a NAME here, not carried forward as an
				// implicit index contract (see MorphWeightTrack's own doc
				// comment).
				track.target_name = idx < morph.targets.size() ? morph.targets[idx].name : "";
				track.keys = extract_float_keys(fd->data);
				morph.weight_tracks.push_back(std::move(track));
			}

			mesh.morph_data.push_back(std::move(morph));
		}
	}

	return mesh;
}

} // namespace nif
