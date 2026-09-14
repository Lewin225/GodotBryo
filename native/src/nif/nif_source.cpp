#include "nif_source.h"

#include "NifFile.hpp"
#include "../common/units.h"
#include "Geometry.hpp"
#include "Shaders.hpp"
#include "Skin.hpp"
#include "Animation.hpp"
#include "ExtraData.hpp"
#include "bhk.hpp"
#include "Nodes.hpp"
#include "Objects.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <istream>
#include <limits>
#include <map>
#include <set>
#include <unordered_map>
#include <stdexcept>
#include <streambuf>

namespace nifsrc {

// FNV's BSShaderTextureSet is 6 slots; 13 is Skyrim SE only.
static constexpr uint32_t kTextureSlotCount = 6;

// NiTexturingProperty's own slot count: base, dark, detail, gloss, glow,
// bump, then four decal slots.
static constexpr uint32_t kTexturingSlotCount = 10;

namespace {

// Mirrors the shape handling proven in nif_loader.cpp; the Havok unit factor
// there was established by comparing extracted collision AABBs against
// known-correct render-mesh AABBs, not from a single reference (units.h).
void fill_shape(const nifly::NifFile &nif, nifly::bhkShape *shape, CollisionShape &out) {
	if (auto *packed = dynamic_cast<nifly::bhkPackedNiTriStripsShape *>(shape)) {
		if (auto *data = nif.GetHeader().GetBlock<nifly::hkPackedNiTriStripsData>(packed->dataRef)) {
			out.kind = "triangle_mesh";
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
		out.kind = "box";
		out.half_extents[0] = box->dimensions.x * units::kHavokToMeters;
		out.half_extents[1] = box->dimensions.y * units::kHavokToMeters;
		out.half_extents[2] = box->dimensions.z * units::kHavokToMeters;
	} else if (auto *capsule = dynamic_cast<nifly::bhkCapsuleShape *>(shape)) {
		out.kind = "capsule";
		out.point_a[0] = capsule->point1.x * units::kHavokToMeters;
		out.point_a[1] = capsule->point1.y * units::kHavokToMeters;
		out.point_a[2] = capsule->point1.z * units::kHavokToMeters;
		out.point_b[0] = capsule->point2.x * units::kHavokToMeters;
		out.point_b[1] = capsule->point2.y * units::kHavokToMeters;
		out.point_b[2] = capsule->point2.z * units::kHavokToMeters;
		out.capsule_radius = capsule->radius1 * units::kHavokToMeters;
	} else if (auto *convex = dynamic_cast<nifly::bhkConvexVerticesShape *>(shape)) {
		out.kind = "convex_hull";
		out.positions.reserve(static_cast<size_t>(convex->verts.size()) * 3);
		for (uint32_t i = 0; i < convex->verts.size(); ++i) {
			const nifly::Vector4 &v = convex->verts[i];
			out.positions.push_back(v.x * units::kHavokToMeters);
			out.positions.push_back(v.y * units::kHavokToMeters);
			out.positions.push_back(v.z * units::kHavokToMeters);
		}
	} else if (auto *sphere = dynamic_cast<nifly::bhkSphereShape *>(shape)) {
		out.kind = "sphere";
		out.radius = sphere->radius * units::kHavokToMeters;
	}
}

// Walks a shape tree, flattening wrappers (MOPP trees, lists, transform
// shapes) down to the leaves that carry real geometry.
// Row-major 4x4 compose, bottom row (0,0,0,1). nifly's Matrix4 has no
// multiply, and the layout is a flat float[16] -- NOT [r][c] -- with the
// translation at indices 3, 7, 11.
void compose_4x4(const float *a, const float *b, float *out) {
	for (int r = 0; r < 4; r++) {
		for (int c = 0; c < 4; c++) {
			float sum = 0.0f;
			for (int k = 0; k < 4; k++) {
				sum += a[r * 4 + k] * b[k * 4 + c];
			}
			out[r * 4 + c] = sum;
		}
	}
}

// Constraints on a ragdoll body (nif_server_v2.md 5.3). Pivots carry a Havok
// length; axes and angles do not.
void fill_constraints(nifly::NiHeader &header, nifly::bhkRigidBody *body, CollisionBody &out) {
	for (const auto &ref : body->constraintRefs) {
		if (ref.IsEmpty()) {
			continue;
		}
		auto *constraint = header.GetBlock<nifly::bhkConstraint>(ref.index);
		if (constraint == nullptr) {
			continue;
		}
		CollisionConstraint cc;
		cc.block_index = ref.index;
		cc.block_type = header.GetBlockTypeStringById(ref.index);
		cc.kind = "unsupported";

		// bhkMalleableConstraint is a wrapper: it holds a ConstraintData whose
		// own `type` selects which descriptor is live. 14 of skeleton.nif's 17
		// constraints are this, so reading it as opaque loses most of the rig.
		const nifly::RagdollDesc *ragdoll_desc = nullptr;
		const nifly::LimitedHingeDesc *hinge_desc = nullptr;
		if (auto *malleable = dynamic_cast<nifly::bhkMalleableConstraint *>(constraint)) {
			cc.wrapped_by = cc.block_type;
			switch (malleable->subConstraint.type) {
				case nifly::Ragdoll: ragdoll_desc = &malleable->subConstraint.desc5; break;
				case nifly::LimitedHinge: hinge_desc = &malleable->subConstraint.desc3; break;
				default: break;
			}
		} else if (auto *ragdoll = dynamic_cast<nifly::bhkRagdollConstraint *>(constraint)) {
			ragdoll_desc = &ragdoll->ragdoll;
		} else if (auto *hinge = dynamic_cast<nifly::bhkLimitedHingeConstraint *>(constraint)) {
			hinge_desc = &hinge->limitedHinge;
		}

		if (ragdoll_desc != nullptr) {
			const auto &d = *ragdoll_desc;
			cc.kind = "ragdoll";
			cc.pivot_a[0] = d.pivotA.x * units::kHavokToMeters;
			cc.pivot_a[1] = d.pivotA.y * units::kHavokToMeters;
			cc.pivot_a[2] = d.pivotA.z * units::kHavokToMeters;
			cc.pivot_b[0] = d.pivotB.x * units::kHavokToMeters;
			cc.pivot_b[1] = d.pivotB.y * units::kHavokToMeters;
			cc.pivot_b[2] = d.pivotB.z * units::kHavokToMeters;
			cc.axis_a[0] = d.twistA.x; cc.axis_a[1] = d.twistA.y; cc.axis_a[2] = d.twistA.z;
			cc.axis_b[0] = d.twistB.x; cc.axis_b[1] = d.twistB.y; cc.axis_b[2] = d.twistB.z;
			cc.plane_a[0] = d.planeA.x; cc.plane_a[1] = d.planeA.y; cc.plane_a[2] = d.planeA.z;
			cc.plane_b[0] = d.planeB.x; cc.plane_b[1] = d.planeB.y; cc.plane_b[2] = d.planeB.z;
			cc.cone_max_angle = d.coneMaxAngle;
			cc.plane_min_angle = d.planeMinAngle;
			cc.plane_max_angle = d.planeMaxAngle;
			cc.twist_min_angle = d.twistMinAngle;
			cc.twist_max_angle = d.twistMaxAngle;
			cc.max_friction = d.maxFriction;
		} else if (hinge_desc != nullptr) {
			const auto &d = *hinge_desc;
			cc.kind = "hinge";
			cc.pivot_a[0] = d.pivotA.x * units::kHavokToMeters;
			cc.pivot_a[1] = d.pivotA.y * units::kHavokToMeters;
			cc.pivot_a[2] = d.pivotA.z * units::kHavokToMeters;
			cc.pivot_b[0] = d.pivotB.x * units::kHavokToMeters;
			cc.pivot_b[1] = d.pivotB.y * units::kHavokToMeters;
			cc.pivot_b[2] = d.pivotB.z * units::kHavokToMeters;
			cc.axis_a[0] = d.axleA.x; cc.axis_a[1] = d.axleA.y; cc.axis_a[2] = d.axleA.z;
			cc.axis_b[0] = d.axleB.x; cc.axis_b[1] = d.axleB.y; cc.axis_b[2] = d.axleB.z;
			cc.plane_a[0] = d.axleInA1.x; cc.plane_a[1] = d.axleInA1.y; cc.plane_a[2] = d.axleInA1.z;
			cc.plane_b[0] = d.axleInB1.x; cc.plane_b[1] = d.axleInB1.y; cc.plane_b[2] = d.axleInB1.z;
			cc.min_angle = d.minAngle;
			cc.max_angle = d.maxAngle;
			cc.max_friction = d.maxFriction;
		}
		out.constraints.push_back(std::move(cc));
	}
}

void collect_shapes(const nifly::NifFile &nif, uint32_t shape_block, int32_t node_index,
		int32_t body_index, Document &doc, int depth = 0,
		const float *parent_transform = nullptr) {
	if (depth > 8) {
		return;
	}
	auto &header = const_cast<nifly::NifFile &>(nif).GetHeader();
	auto *shape = header.GetBlock<nifly::bhkShape>(shape_block);
	if (shape == nullptr) {
		return;
	}
	if (auto *mopp = dynamic_cast<nifly::bhkMoppBvTreeShape *>(shape)) {
		if (!mopp->shapeRef.IsEmpty()) {
			collect_shapes(nif, mopp->shapeRef.index, node_index, body_index, doc, depth + 1, parent_transform);
		}
		return;
	}
	if (auto *list = dynamic_cast<nifly::bhkListShape *>(shape)) {
		for (const auto &sub : list->subShapeRefs) {
			if (!sub.IsEmpty()) {
				collect_shapes(nif, sub.index, node_index, body_index, doc, depth + 1, parent_transform);
			}
		}
		return;
	}
	// bhkConvexTransformShape derives from bhkTransformShape, so one cast
	// catches both. The wrapper exists purely to place the shape it holds.
	if (auto *xform = dynamic_cast<nifly::bhkTransformShape *>(shape)) {
		if (!xform->shapeRef.IsEmpty()) {
			float local[16];
			for (int i = 0; i < 16; i++) {
				local[i] = xform->xform[i];
			}
			// Translation is a Havok length; the rotation block is unitless.
			local[3] *= units::kHavokToMeters;
			local[7] *= units::kHavokToMeters;
			local[11] *= units::kHavokToMeters;

			float composed[16];
			if (parent_transform != nullptr) {
				compose_4x4(parent_transform, local, composed);
			} else {
				for (int i = 0; i < 16; i++) {
					composed[i] = local[i];
				}
			}
			collect_shapes(nif, xform->shapeRef.index, node_index, body_index, doc,
					depth + 1, composed);
		}
		return;
	}
	CollisionShape out;
	out.block_index = shape_block;
	out.block_type = header.GetBlockTypeStringById(shape_block);
	out.owning_node_index = node_index;
	out.body_index = body_index;
	fill_shape(nif, shape, out);
	if (parent_transform != nullptr) {
		out.has_transform = true;
		for (int i = 0; i < 16; i++) {
			out.transform[i] = parent_transform[i];
		}
	}
	if (!out.kind.empty()) {
		doc.collision_shapes.push_back(std::move(out));
	}
}

} // namespace

namespace {

// Reads straight out of the caller's buffer. nifly wants an istream, and the
// obvious route (vector -> string -> istringstream) copies the whole NIF three
// times before a byte is parsed. This copies none of it.
class MemoryBuffer : public std::streambuf {
public:
	MemoryBuffer(const uint8_t *data, size_t size) {
		char *begin = const_cast<char *>(reinterpret_cast<const char *>(data));
		setg(begin, begin, begin + size);
	}

protected:
	// nifly seeks while parsing (block offsets, footer), so both seek
	// overloads have to be real rather than inherited no-ops.
	pos_type seekoff(off_type off, std::ios_base::seekdir dir,
			std::ios_base::openmode which) override {
		if ((which & std::ios_base::in) == 0) {
			return pos_type(off_type(-1));
		}
		char *target = nullptr;
		switch (dir) {
			case std::ios_base::beg: target = eback() + off; break;
			case std::ios_base::cur: target = gptr() + off; break;
			case std::ios_base::end: target = egptr() + off; break;
			default: return pos_type(off_type(-1));
		}
		if (target < eback() || target > egptr()) {
			return pos_type(off_type(-1));
		}
		setg(eback(), target, egptr());
		return pos_type(target - eback());
	}

	pos_type seekpos(pos_type pos, std::ios_base::openmode which) override {
		return seekoff(off_type(pos), std::ios_base::beg, which);
	}
};

// ---------------------------------------------------------------------------
// Interpolators (nif_server_v2.md section 7). A ControllerLink names a target;
// the curve it plays lives behind its interpolatorRef, and without it a
// sequence is a list of names with nothing to animate.
// ---------------------------------------------------------------------------

const char *key_interp_name(nifly::NiKeyType type) {
	switch (type) {
		case nifly::LINEAR_KEY: return "linear";
		case nifly::QUADRATIC_KEY: return "quadratic";
		case nifly::TBC_KEY: return "tbc";
		case nifly::XYZ_ROTATION_KEY: return "xyz";
		case nifly::CONST_KEY: return "const";
		case nifly::NO_INTERP:
		default: return "none";
	}
}

std::vector<ScalarKey> scalar_keys_of(const nifly::NiAnimationKeyGroup<float> &group) {
	std::vector<ScalarKey> out;
	const uint32_t n = group.GetNumKeys();
	out.reserve(n);
	for (uint32_t i = 0; i < n; i++) {
		const nifly::NiAnimationKey<float> k = group.GetKey(static_cast<int>(i));
		ScalarKey sk;
		sk.time = k.time;
		sk.value = k.value;
		sk.interp = key_interp_name(k.type);
		out.push_back(std::move(sk));
	}
	return out;
}

// Translation is the one channel carrying a unit: units.h applies the
// Gamebryo-to-meters factor at the source, so a consumer never scales a key.
// Rotation and scale are unitless.
std::vector<Vec3Key> vec3_keys_of(const nifly::NiAnimationKeyGroup<nifly::Vector3> &group, float factor) {
	std::vector<Vec3Key> out;
	const uint32_t n = group.GetNumKeys();
	out.reserve(n);
	for (uint32_t i = 0; i < n; i++) {
		const nifly::NiAnimationKey<nifly::Vector3> k = group.GetKey(static_cast<int>(i));
		Vec3Key vk;
		vk.time = k.time;
		vk.value[0] = k.value.x * factor;
		vk.value[1] = k.value.y * factor;
		vk.value[2] = k.value.z * factor;
		vk.interp = key_interp_name(k.type);
		out.push_back(std::move(vk));
	}
	return out;
}

// Samples a float key group at an arbitrary time, linearly. Used only to line
// the three per-axis rotation curves of an XYZ_ROTATION_KEY block up onto one
// shared time base, which a quaternion track needs and they do not share.
float sample_scalar(const std::vector<ScalarKey> &keys, float time) {
	if (keys.empty()) {
		return 0.0f;
	}
	if (time <= keys.front().time) {
		return keys.front().value;
	}
	if (time >= keys.back().time) {
		return keys.back().value;
	}
	for (size_t i = 1; i < keys.size(); i++) {
		if (time <= keys[i].time) {
			const float span = keys[i].time - keys[i - 1].time;
			if (span <= 0.0f) {
				return keys[i].value;
			}
			const float f = (time - keys[i - 1].time) / span;
			return keys[i - 1].value + (keys[i].value - keys[i - 1].value) * f;
		}
	}
	return keys.back().value;
}

// Composition order is X, Y, Z -- matching Godot's EULER_ORDER_XYZ, which is
// what the existing animation path already feeds these curves through.
void euler_xyz_to_quat(float x, float y, float z, float out[4]) {
	const float hx = x * 0.5f, hy = y * 0.5f, hz = z * 0.5f;
	const float cx = std::cos(hx), sx = std::sin(hx);
	const float cy = std::cos(hy), sy = std::sin(hy);
	const float cz = std::cos(hz), sz = std::sin(hz);
	// q = qx * qy * qz, each a unit axis rotation.
	const float xy_w = cx * cy, xy_x = sx * cy, xy_y = cx * sy, xy_z = -sx * sy;
	out[3] = xy_w * cz - xy_z * sz; // w
	out[0] = xy_x * cz + xy_y * sz; // x
	out[1] = xy_y * cz - xy_x * sz; // y
	out[2] = xy_w * sz + xy_z * cz; // z
}

// --- B-spline sampling ------------------------------------------------------
//
// NIF's compressed clips are not keyframes: they are cubic, clamped-uniform
// B-spline control points over one shared time domain. Godot has no such
// track, so they are evaluated. The evaluator is duplicated from
// nif_loader.cpp deliberately -- that file stays untouched (see this file's
// own header comment), and this is the whole of the shared surface.

struct SplineValue {
	float v[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
	int dimensions = 0;
};

// Clamped uniform knot vector for a cubic: knot j is repeated at both ends
// and uniform in the middle, so the useful domain is [0, count - 3] and the
// first and last samples equal the first and last control points.
constexpr int kSplineDegree = 3;

float spline_knot(int j, int count) {
	if (j <= kSplineDegree) {
		return 0.0f;
	}
	if (j >= count) {
		return static_cast<float>(count - kSplineDegree);
	}
	return static_cast<float>(j - kSplineDegree);
}

// De Boor's algorithm. Only degree+1 control points influence any point on a
// B-spline, so this is O(degree^2) per sample. The textbook Cox-de Boor
// recurrence summed over every control point instead -- correct, and far too
// slow to run over the whole corpus: 4,069 files carry compressed clips.
SplineValue evaluate_spline(const std::vector<SplineValue> &controls, float normalized_time) {
	SplineValue out;
	if (controls.empty()) {
		return out;
	}
	if (controls.size() < 4) {
		return controls[std::min<size_t>(controls.size() - 1,
				static_cast<size_t>(normalized_time * static_cast<float>(controls.size())))];
	}
	const int count = static_cast<int>(controls.size());
	const float u = std::clamp(normalized_time, 0.0f, 1.0f) * static_cast<float>(count - kSplineDegree);
	const int dimensions = controls.front().dimensions;
	out.dimensions = dimensions;

	// The span containing u. Knots are integers here, so this is a floor
	// rather than a search; the clamp keeps the closing endpoint in the last
	// real span instead of one past it.
	const int span = std::clamp(kSplineDegree + static_cast<int>(std::floor(u)),
			kSplineDegree, count - 1);

	SplineValue d[kSplineDegree + 1];
	for (int j = 0; j <= kSplineDegree; j++) {
		d[j] = controls[static_cast<size_t>(j + span - kSplineDegree)];
	}
	for (int r = 1; r <= kSplineDegree; r++) {
		for (int j = kSplineDegree; j >= r; j--) {
			const int i = j + span - kSplineDegree;
			const float lo = spline_knot(i, count);
			const float hi = spline_knot(i + 1 + kSplineDegree - r, count);
			const float alpha = hi > lo ? (u - lo) / (hi - lo) : 0.0f;
			for (int dim = 0; dim < dimensions; dim++) {
				d[j].v[dim] = (1.0f - alpha) * d[j - 1].v[dim] + alpha * d[j].v[dim];
			}
		}
	}
	for (int dim = 0; dim < dimensions; dim++) {
		out.v[dim] = d[kSplineDegree].v[dim];
	}
	return out;
}

float spline_error(const SplineValue &a, const SplineValue &b, bool rotation) {
	if (rotation) {
		float dot = 0.0f;
		for (int i = 0; i < 4; i++) {
			dot += a.v[i] * b.v[i];
		}
		dot = std::clamp(std::fabs(dot), 0.0f, 1.0f);
		return 2.0f * std::acos(dot);
	}
	float error = 0.0f;
	for (int i = 0; i < a.dimensions; i++) {
		error = std::max(error, std::fabs(a.v[i] - b.v[i]));
	}
	return error;
}

std::vector<float> adaptive_spline_times(const std::vector<SplineValue> &controls,
		float start, float stop, bool rotation, float tolerance) {
	std::vector<float> times;
	if (controls.empty() || stop <= start) {
		return times;
	}
	auto value_at = [&](float t) { return evaluate_spline(controls, (t - start) / (stop - start)); };
	std::function<void(float, float, const SplineValue &, const SplineValue &, int)> split;
	split = [&](float a, float b, const SplineValue &va, const SplineValue &vb, int depth) {
		const float m = (a + b) * 0.5f;
		const float q1 = (a + m) * 0.5f;
		const float q3 = (m + b) * 0.5f;
		const SplineValue vm = value_at(m), vq1 = value_at(q1), vq3 = value_at(q3);
		auto chord = [&](float t) {
			SplineValue v;
			v.dimensions = va.dimensions;
			const float f = (t - a) / (b - a);
			for (int d = 0; d < v.dimensions; d++) {
				v.v[d] = va.v[d] + (vb.v[d] - va.v[d]) * f;
			}
			return v;
		};
		const SplineValue lq1 = chord(q1), lm = chord(m), lq3 = chord(q3);
		const float error = std::max({ spline_error(vq1, lq1, rotation),
				spline_error(vq3, lq3, rotation), spline_error(vm, lm, rotation) });
		if (error > tolerance && depth < 12 && (b - a) > 1.0f / 240.0f) {
			split(a, m, va, vm, depth + 1);
			split(m, b, vm, vb, depth + 1);
		} else {
			if (times.empty()) {
				times.push_back(a);
			}
			times.push_back(b);
		}
	};
	split(start, stop, value_at(start), value_at(stop), 0);
	std::sort(times.begin(), times.end());
	times.erase(std::unique(times.begin(), times.end()), times.end());
	return times;
}

// Compact streams store bias + short * multiplier / 32767 (PyFFI/NIFTools).
std::vector<SplineValue> spline_controls(const nifly::NiBSplineData *data, uint32_t offset,
		uint32_t count, int dimensions, bool compact, float bias, float multiplier) {
	std::vector<SplineValue> out;
	if (data == nullptr || offset == 65535 || count == 0) {
		return out;
	}
	const size_t stride = static_cast<size_t>(dimensions);
	const size_t needed = static_cast<size_t>(offset) + static_cast<size_t>(count) * stride;
	if (compact) {
		if (needed > data->shortControlPoints.size()) {
			return out;
		}
	} else if (needed > data->floatControlPoints.size()) {
		return out;
	}
	out.resize(count);
	for (uint32_t i = 0; i < count; i++) {
		out[i].dimensions = dimensions;
		for (int d = 0; d < dimensions; d++) {
			const size_t index = static_cast<size_t>(offset) + static_cast<size_t>(i) * stride + d;
			out[i].v[d] = compact
					? bias + static_cast<float>(data->shortControlPoints.data()[index]) * multiplier / 32767.0f
					: data->floatControlPoints.data()[index];
		}
	}
	return out;
}

void fill_bspline(const nifly::NiHeader &header, nifly::NiBSplineTransformInterpolator *interp,
		Interpolator &out) {
	auto *data = header.GetBlock<nifly::NiBSplineData>(interp->splineDataRef);
	auto *basis = header.GetBlock<nifly::NiBSplineBasisData>(interp->basisDataRef);
	if (data == nullptr || basis == nullptr || basis->numControlPoints == 0) {
		return;
	}
	const uint32_t count = basis->numControlPoints;
	const bool compact = dynamic_cast<nifly::NiBSplineCompTransformInterpolator *>(interp) != nullptr;
	float tb = 0.0f, tm = 1.0f, rb = 0.0f, rm = 1.0f, sb = 0.0f, sm = 1.0f;
	if (auto *comp = dynamic_cast<nifly::NiBSplineCompTransformInterpolator *>(interp)) {
		tb = comp->translationBias;
		tm = comp->translationMultiplier;
		rb = comp->rotationBias;
		rm = comp->rotationMultiplier;
		sb = comp->scaleBias;
		sm = comp->scaleMultiplier;
	}
	out.resampled = true;
	const float start = interp->startTime, stop = interp->stopTime;
	if (!(stop > start)) {
		return;
	}

	// Tolerances: 1 cm of translation, 0.2 degrees of rotation, 0.2% of scale.
	const auto translations = spline_controls(data, interp->translationOffset, count, 3, compact, tb, tm);
	for (const float t : adaptive_spline_times(translations, start, stop, false, 0.01f)) {
		const SplineValue v = evaluate_spline(translations, (t - start) / (stop - start));
		Vec3Key key;
		key.time = t;
		for (int d = 0; d < 3; d++) {
			key.value[d] = v.v[d] * units::kGamebryoUnitsToMeters;
		}
		key.interp = "linear";
		out.translation_keys.push_back(std::move(key));
	}

	const auto rotations = spline_controls(data, interp->rotationOffset, count, 4, compact, rb, rm);
	for (const float t : adaptive_spline_times(rotations, start, stop, true, 0.00349066f)) {
		const SplineValue v = evaluate_spline(rotations, (t - start) / (stop - start));
		float length = 0.0f;
		for (int d = 0; d < 4; d++) {
			length += v.v[d] * v.v[d];
		}
		if (length <= std::numeric_limits<float>::epsilon()) {
			continue;
		}
		length = std::sqrt(length);
		QuatKey key;
		key.time = t;
		// Control points are WXYZ like every other serialized NIF quaternion.
		key.value[0] = v.v[1] / length;
		key.value[1] = v.v[2] / length;
		key.value[2] = v.v[3] / length;
		key.value[3] = v.v[0] / length;
		key.interp = "linear";
		out.rotation_keys.push_back(std::move(key));
	}

	const auto scales = spline_controls(data, interp->scaleOffset, count, 1, compact, sb, sm);
	for (const float t : adaptive_spline_times(scales, start, stop, false, 0.002f)) {
		const SplineValue v = evaluate_spline(scales, (t - start) / (stop - start));
		ScalarKey key;
		key.time = t;
		key.value = v.v[0];
		key.interp = "linear";
		out.scale_keys.push_back(std::move(key));
	}
}

void fill_interpolator(const nifly::NiHeader &header, uint32_t block_index, Interpolator &out) {
	auto *interp = header.GetBlock<nifly::NiInterpolator>(block_index);
	if (interp == nullptr) {
		return;
	}
	out.present = true;
	out.block_index = block_index;
	out.block_type = interp->GetBlockName();
	out.kind = "unsupported";

	// The B-spline forms are NOT NiTransformInterpolator subclasses in nifly,
	// so they have to be tested for first.
	if (auto *spline = dynamic_cast<nifly::NiBSplineTransformInterpolator *>(interp)) {
		out.kind = "transform";
		out.has_static_transform = true;
		out.translation[0] = spline->translation.x * units::kGamebryoUnitsToMeters;
		out.translation[1] = spline->translation.y * units::kGamebryoUnitsToMeters;
		out.translation[2] = spline->translation.z * units::kGamebryoUnitsToMeters;
		out.rotation[0] = spline->rotation.x;
		out.rotation[1] = spline->rotation.y;
		out.rotation[2] = spline->rotation.z;
		out.rotation[3] = spline->rotation.w;
		out.scale = spline->scale;
		fill_bspline(header, spline, out);
		return;
	}

	if (auto *xform = dynamic_cast<nifly::NiTransformInterpolator *>(interp)) {
		out.kind = "transform";
		// The interpolator's own transform is the pose that applies where a
		// channel has no keys; nifly leaves it NaN-free but a missing data
		// block makes it the only value there is.
		out.has_static_transform = true;
		out.translation[0] = xform->translation.x * units::kGamebryoUnitsToMeters;
		out.translation[1] = xform->translation.y * units::kGamebryoUnitsToMeters;
		out.translation[2] = xform->translation.z * units::kGamebryoUnitsToMeters;
		out.rotation[0] = xform->rotation.x;
		out.rotation[1] = xform->rotation.y;
		out.rotation[2] = xform->rotation.z;
		out.rotation[3] = xform->rotation.w;
		out.scale = xform->scale;

		auto *td = header.GetBlock<nifly::NiTransformData>(xform->dataRef);
		if (td == nullptr) {
			return; // Static pose only -- a real case, not a failure.
		}
		out.translation_keys = vec3_keys_of(td->translations, units::kGamebryoUnitsToMeters);
		out.scale_keys = scalar_keys_of(td->scales);
		if (!td->quaternionKeys.empty()) {
			out.rotation_keys.reserve(td->quaternionKeys.size());
			for (const auto &k : td->quaternionKeys) {
				QuatKey qk;
				qk.time = k.time;
				qk.value[0] = k.value.x;
				qk.value[1] = k.value.y;
				qk.value[2] = k.value.z;
				qk.value[3] = k.value.w;
				qk.interp = key_interp_name(k.type);
				out.rotation_keys.push_back(std::move(qk));
			}
		} else if (td->rotationType == nifly::XYZ_ROTATION_KEY) {
			// Three independent per-axis curves with their own key times.
			// Composed here onto the union of those times: a quaternion track
			// cannot carry them separately, and re-deriving this per consumer
			// is the kind of work section 7 puts at the source.
			const auto xs = scalar_keys_of(td->xRotations);
			const auto ys = scalar_keys_of(td->yRotations);
			const auto zs = scalar_keys_of(td->zRotations);
			std::set<float> times;
			for (const auto &k : xs) { times.insert(k.time); }
			for (const auto &k : ys) { times.insert(k.time); }
			for (const auto &k : zs) { times.insert(k.time); }
			if (!times.empty()) {
				out.rotation_from_euler = true;
				out.rotation_keys.reserve(times.size());
				for (const float t : times) {
					QuatKey qk;
					qk.time = t;
					euler_xyz_to_quat(sample_scalar(xs, t), sample_scalar(ys, t),
							sample_scalar(zs, t), qk.value);
					qk.interp = "linear";
					out.rotation_keys.push_back(std::move(qk));
				}
			}
		}
		return;
	}

	if (auto *fi = dynamic_cast<nifly::NiFloatInterpolator *>(interp)) {
		out.kind = "float";
		out.has_static_float = true;
		out.static_float = fi->floatValue;
		if (auto *fd = header.GetBlock<nifly::NiFloatData>(fi->dataRef)) {
			out.float_keys = scalar_keys_of(fd->data);
		}
		return;
	}

	if (auto *bi = dynamic_cast<nifly::NiBoolInterpolator *>(interp)) {
		out.kind = "bool";
		out.has_static_float = true;
		out.static_float = bi->boolValue != 0 ? 1.0f : 0.0f;
		if (auto *bd = header.GetBlock<nifly::NiBoolData>(bi->dataRef)) {
			const uint32_t n = bd->data.GetNumKeys();
			out.float_keys.reserve(n);
			for (uint32_t i = 0; i < n; i++) {
				const auto k = bd->data.GetKey(static_cast<int>(i));
				ScalarKey sk;
				sk.time = k.time;
				sk.value = k.value != 0 ? 1.0f : 0.0f;
				// A boolean never interpolates, whatever the key claims.
				sk.interp = "const";
				out.float_keys.push_back(std::move(sk));
			}
		}
		return;
	}

	if (auto *pi = dynamic_cast<nifly::NiPoint3Interpolator *>(interp)) {
		// NOT a position: NiPoint3Interpolator drives colours and other
		// three-component properties, so no unit conversion is applied.
		out.kind = "point3";
		if (auto *pd = header.GetBlock<nifly::NiPosData>(pi->dataRef)) {
			out.point3_keys = vec3_keys_of(pd->data, 1.0f);
		}
		return;
	}

	if (dynamic_cast<nifly::NiBlendInterpolator *>(interp) != nullptr) {
		// Holds no data: it blends other interpolators at runtime.
		out.kind = "blend";
	}
}

} // namespace

Document load(const uint8_t *data, size_t size) {
	if (data == nullptr || size == 0) {
		throw std::runtime_error("nifsrc: empty buffer");
	}
	MemoryBuffer membuf(data, size);
	std::istream stream(&membuf);

	nifly::NifFile nif;
	if (nif.Load(stream) != 0 || !nif.IsValid()) {
		throw std::runtime_error("nifsrc: nifly rejected the file");
	}

	auto &header = nif.GetHeader();
	Document doc;
	doc.version = header.GetVersion().String();
	doc.block_count = header.GetNumBlocks();

	// Parent relationships come from NiNode::childRefs -- the scene graph's
	// only structural channel. NiNode::effectRefs is empty in all 20,746
	// shipped NIFs (nif_server_v2.md 3.4), so lights arrive as ordinary
	// children and no second traversal is needed.
	std::map<uint32_t, uint32_t> parent_of;
	for (uint32_t i = 0; i < doc.block_count; i++) {
		if (auto *node = header.GetBlock<nifly::NiNode>(i)) {
			for (auto &child : node->childRefs) {
				if (!child.IsEmpty()) {
					parent_of[child.index] = i;
				}
			}
		}
	}

	std::map<uint32_t, int32_t> node_index_of;
	for (uint32_t i = 0; i < doc.block_count; i++) {
		if (header.GetBlock<nifly::NiAVObject>(i) != nullptr) {
			node_index_of[i] = static_cast<int32_t>(doc.nodes.size());
			doc.nodes.emplace_back();
		}
	}

	for (const auto &entry : node_index_of) {
		const uint32_t block = entry.first;
		SceneNode &out = doc.nodes[entry.second];
		auto *av = header.GetBlock<nifly::NiAVObject>(block);
		out.name = av->name.get();
		out.block_type = header.GetBlockTypeStringById(block);
		out.block_index = block;
		// Match the legacy loader's definition precisely: any NiAVObject with
		// no NIF parent is a file root. Preserve it in NifSource as raw,
		// inspectable data; NifTreeBuilder owns the later instancing policy.
		out.is_file_root = nif.GetParentNode(av) == nullptr;

		const auto parent = parent_of.find(block);
		if (parent != parent_of.end()) {
			const auto mapped = node_index_of.find(parent->second);
			out.parent_index = mapped == node_index_of.end() ? -1 : mapped->second;
		}

		for (const auto &ref : av->extraDataRefs) {
			if (ref.IsEmpty()) {
				continue;
			}
			auto *extra = header.GetBlock<nifly::NiExtraData>(ref.index);
			if (extra == nullptr) {
				continue;
			}
			ExtraData ed;
			ed.block_index = ref.index;
			ed.block_type = header.GetBlockTypeStringById(ref.index);
			ed.name = extra->name.get();

			// BSXFlags derives from NiIntegerExtraData, so it is covered here.
			if (auto *as_int = header.GetBlock<nifly::NiIntegerExtraData>(ref.index)) {
				ed.has_integer = true;
				ed.integer_value = as_int->integerData;
			}
			if (auto *as_float = header.GetBlock<nifly::NiFloatExtraData>(ref.index)) {
				ed.has_float = true;
				ed.float_value = as_float->floatData;
			}
			if (auto *as_string = header.GetBlock<nifly::NiStringExtraData>(ref.index)) {
				ed.has_string = true;
				ed.string_value = as_string->stringData.get();
			}
			if (auto *as_bound = header.GetBlock<nifly::BSBound>(ref.index)) {
				ed.has_bounds = true;
				ed.bounds_center[0] = as_bound->center.x;
				ed.bounds_center[1] = as_bound->center.y;
				ed.bounds_center[2] = as_bound->center.z;
				ed.bounds_half_extents[0] = as_bound->halfExtents.x;
				ed.bounds_half_extents[1] = as_bound->halfExtents.y;
				ed.bounds_half_extents[2] = as_bound->halfExtents.z;
			}
			if (auto *as_keys = header.GetBlock<nifly::NiTextKeyExtraData>(ref.index)) {
				for (const auto &key : as_keys->textKeys) {
					TextKey tk;
					tk.time = key.time;
					tk.value = key.value.get();
					ed.text_keys.push_back(std::move(tk));
				}
			}
			out.extra_data.push_back(std::move(ed));
		}

		for (const auto &prop : av->propertyRefs) {
			if (prop.IsEmpty()) {
				continue;
			}
			out.property_block_indices.push_back(static_cast<int32_t>(prop.index));
			out.property_types.push_back(header.GetBlockTypeStringById(prop.index));
		}

		if (auto *billboard = header.GetBlock<nifly::NiBillboardNode>(block)) {
			switch (billboard->billboardMode) {
				case nifly::ALWAYS_FACE_CAMERA: out.billboard_mode = "always_face_camera"; break;
				case nifly::ROTATE_ABOUT_UP:
				case nifly::ROTATE_ABOUT_UP2: out.billboard_mode = "rotate_about_up"; break;
				case nifly::RIGID_FACE_CAMERA: out.billboard_mode = "rigid_face_camera"; break;
				case nifly::ALWAYS_FACE_CENTER: out.billboard_mode = "always_face_center"; break;
				case nifly::RIGID_FACE_CENTER: out.billboard_mode = "rigid_face_center"; break;
				case nifly::BSROTATE_ABOUT_UP: out.billboard_mode = "bs_rotate_about_up"; break;
				default: out.billboard_mode = "always_face_camera"; break;
			}
		}

		if (auto *shape = header.GetBlock<nifly::NiShape>(block)) {
			if (auto *alpha = nif.GetAlphaProperty(shape)) {
				out.has_alpha_property = true;
				out.alpha_blend_enabled = (alpha->flags & 0x0001) != 0;
				out.alpha_test_enabled = (alpha->flags & 0x0200) != 0;
				out.alpha_threshold = static_cast<float>(alpha->threshold) / 255.0f;

				constexpr uint32_t kBlendOne = 0, kBlendZero = 1, kBlendSrcColor = 2,
						kBlendSrcAlpha = 6, kBlendInvSrcAlpha = 7;
				const uint32_t src = (alpha->flags >> 1) & 0xF;
				const uint32_t dst = (alpha->flags >> 5) & 0xF;
				if (src == kBlendSrcAlpha && dst == kBlendOne) {
					out.alpha_blend_func = "add";
				} else if (src == kBlendOne && dst == kBlendOne) {
					out.alpha_blend_func = "add";
				} else if (src == kBlendZero && dst == kBlendSrcColor) {
					out.alpha_blend_func = "multiply";
				} else {
					// Includes the SRC_ALPHA/INV_SRC_ALPHA majority and any
					// pair the census did not see.
					out.alpha_blend_func = "mix";
				}
			}

			if (const auto *verts = nif.GetVertsForShape(shape)) {
				out.geometry.positions.reserve(verts->size() * 3);
				for (const auto &v : *verts) {
					out.geometry.positions.push_back(v.x * units::kGamebryoUnitsToMeters);
					out.geometry.positions.push_back(v.y * units::kGamebryoUnitsToMeters);
					out.geometry.positions.push_back(v.z * units::kGamebryoUnitsToMeters);
				}
			}
			if (const auto *normals = nif.GetNormalsForShape(shape)) {
				for (const auto &n : *normals) {
					out.geometry.normals.push_back(n.x);
					out.geometry.normals.push_back(n.y);
					out.geometry.normals.push_back(n.z);
				}
			}
			if (const auto *uvs = nif.GetUvsForShape(shape)) {
				for (const auto &uv : *uvs) {
					out.geometry.uvs.push_back(uv.u);
					out.geometry.uvs.push_back(uv.v);
				}
			}
			if (const auto *colors = nif.GetColorsForShape(shape)) {
				for (const auto &col : *colors) {
					out.geometry.colors.push_back(col.r);
					out.geometry.colors.push_back(col.g);
					out.geometry.colors.push_back(col.b);
					out.geometry.colors.push_back(col.a);
				}
			}
			std::vector<nifly::Triangle> tris;
			if (shape->GetTriangles(tris)) {
				out.geometry.indices.reserve(tris.size() * 3);
				for (const auto &t : tris) {
					// NIF/Gamebryo (DirectX lineage) winds triangles
					// clockwise-front; Godot and glTF expect counter-
					// clockwise-front. Swapping the last two indices reverses
					// winding without changing which vertices form the
					// triangle. Without this, backface culling shows straight
					// through a mesh interior.
					out.geometry.indices.push_back(t.p1);
					out.geometry.indices.push_back(t.p3);
					out.geometry.indices.push_back(t.p2);
				}
			}

			std::vector<std::string> bones;
			if (shape->IsSkinned() && nif.GetShapeBoneList(shape, bones) > 0) {
				out.geometry.has_skin = true;
				out.geometry.skin.bone_names = bones;

				const size_t vertex_count = out.geometry.positions.size() / 3;
				out.geometry.skin.bone_indices.assign(vertex_count * 4, 0);
				out.geometry.skin.bone_weights.assign(vertex_count * 4, 0.0f);
				std::vector<uint8_t> filled(vertex_count, 0);

				for (uint32_t b = 0; b < bones.size(); b++) {
					nifly::MatTransform skin_to_bone;
					if (nif.GetShapeTransformSkinToBone(shape, b, skin_to_bone)) {
						// Matrix4 is a flat row-major float[16]; translation sits
						// at 3, 7 and 11. Only those are distances -- rotation
						// and scale are unitless.
						auto m = skin_to_bone.ToMatrix();
						for (int k = 0; k < 16; k++) {
							float value = m[k];
							if (k == 3 || k == 7 || k == 11) {
								value *= units::kGamebryoUnitsToMeters;
							}
							out.geometry.skin.bind_transforms.push_back(value);
						}
					} else {
						static const float identity[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
						out.geometry.skin.bind_transforms.insert(
								out.geometry.skin.bind_transforms.end(), identity, identity + 16);
					}

					std::unordered_map<uint16_t, float> weights;
					nif.GetShapeBoneWeights(shape, b, weights);
					for (const auto &entry : weights) {
						const uint16_t vertex = entry.first;
						if (vertex >= vertex_count || filled[vertex] >= 4) {
							continue;
						}
						const size_t slot = static_cast<size_t>(vertex) * 4 + filled[vertex];
						out.geometry.skin.bone_indices[slot] = static_cast<int32_t>(b);
						out.geometry.skin.bone_weights[slot] = entry.second;
						filled[vertex]++;
					}
				}
			}

			// Only populate when the shape really has a texture set, so an
			// empty vector means "no set" rather than "a set of empty slots".
			// A set is shared between shapes, hence the block index too.
			auto *shader = nif.GetShader(shape);
			if (shader != nullptr) {
				out.shader_type = header.GetBlockTypeStringById(nif.GetBlockID(shader));
			}

			// Resolution order matches nifly's own GetTextureSlot: a real
			// BSShaderTextureSet first, then the effect-shader inline paths,
			// then NiTexturingProperty's NiSourceTexture chain. Each is
			// reported under its own slot convention, never merged.
			const auto *set_ref = shader != nullptr ? shader->TextureSetRef() : nullptr;
			if (set_ref != nullptr && !set_ref->IsEmpty()) {
				out.texture_set_block_index = static_cast<int32_t>(set_ref->index);
				out.texture_convention = "shader_set";
				out.texture_slots.resize(kTextureSlotCount);
			} else if (dynamic_cast<nifly::BSEffectShaderProperty *>(shader) != nullptr) {
				out.texture_convention = "effect_shader";
				out.texture_slots.resize(kTextureSlotCount);
			} else if (auto *texturing = nif.GetTexturingProperty(shape)) {
				out.texture_convention = "texturing_property";
				out.texture_slots.resize(
						std::min<size_t>(texturing->textureCount, kTexturingSlotCount));
			}
			for (size_t slot = 0; slot < out.texture_slots.size(); slot++) {
				std::string tex;
				nif.GetTextureSlot(shape, tex, static_cast<uint32_t>(slot));
				out.texture_slots[slot] = tex;
			}
			// A convention that resolved nothing at all is not a convention.
			bool any = false;
			for (const auto &tex : out.texture_slots) {
				any = any || !tex.empty();
			}
			if (!any) {
				out.texture_slots.clear();
				out.texture_convention.clear();
			}
		}

		if (!av->collisionRef.IsEmpty()) {
			out.collision_block_index = static_cast<int32_t>(av->collisionRef.index);
			out.collision_type = header.GetBlockTypeStringById(av->collisionRef.index);

			if (auto *co = header.GetBlock<nifly::NiCollisionObject>(av->collisionRef.index)) {
				if (!co->targetRef.IsEmpty()) {
					out.collision_target_block_index = static_cast<int32_t>(co->targetRef.index);
				}
			}
			if (auto *collision = header.GetBlock<nifly::bhkNiCollisionObject>(av->collisionRef.index)) {
				if (!collision->bodyRef.IsEmpty()) {
					if (auto *body = header.GetBlock<nifly::bhkRigidBody>(collision->bodyRef.index)) {
						CollisionBody cb;
						cb.block_index = collision->bodyRef.index;
						cb.block_type = header.GetBlockTypeStringById(collision->bodyRef.index);
						cb.owning_node_index = entry.second;
						cb.mass = body->mass;
						cb.friction = body->friction;
						cb.restitution = body->restitution;
						cb.linear_damping = body->linearDamping;
						cb.angular_damping = body->angularDamping;
						// bhkRigidBodyT carries its own transform; plain
						// bhkRigidBody leaves it at the origin.
						cb.translation[0] = body->translation.x * units::kHavokToMeters;
						cb.translation[1] = body->translation.y * units::kHavokToMeters;
						cb.translation[2] = body->translation.z * units::kHavokToMeters;
						// Already XYZW here: bhkRigidBody stores a
						// QuaternionXYZW, unlike the WXYZ Quaternion every
						// other block in the format uses.
						cb.rotation[0] = body->rotation.x;
						cb.rotation[1] = body->rotation.y;
						cb.rotation[2] = body->rotation.z;
						cb.rotation[3] = body->rotation.w;
						fill_constraints(header, body, cb);
						const int32_t body_index = static_cast<int32_t>(doc.collision_bodies.size());
						doc.collision_bodies.push_back(std::move(cb));
						if (!body->shapeRef.IsEmpty()) {
							collect_shapes(nif, body->shapeRef.index, entry.second, body_index, doc);
						}
					}
				}
			}
		}

		// In-NIF morph targets hang off the shape's controller chain.
		// Controllers form a chain through nextControllerRef. Checking only
		// the head misses every morpher that is not first -- skeleton.nif
		// carries a NiGeomMorpherController and yielded nothing.
		for (uint32_t ctrl = av->controllerRef.IsEmpty() ? nifly::NIF_NPOS : av->controllerRef.index,
				guard = 0;
				ctrl != nifly::NIF_NPOS && guard < 64; guard++) {
			auto *controller = header.GetBlock<nifly::NiTimeController>(ctrl);
			if (controller == nullptr) {
				break;
			}
			ctrl = controller->nextControllerRef.IsEmpty()
					? nifly::NIF_NPOS
					: controller->nextControllerRef.index;
			if (auto *morpher = dynamic_cast<nifly::NiGeomMorpherController *>(controller)) {
				if (auto *morph_data = header.GetBlock<nifly::NiMorphData>(morpher->dataRef.index)) {
					for (const auto &morph : morph_data->GetMorphs()) {
						MorphFrame frame;
						frame.name = morph.frameName.get();
						frame.deltas.reserve(morph.vectors.size() * 3);
						for (const auto &v : morph.vectors) {
							frame.deltas.push_back(v.x * units::kGamebryoUnitsToMeters);
							frame.deltas.push_back(v.y * units::kGamebryoUnitsToMeters);
							frame.deltas.push_back(v.z * units::kGamebryoUnitsToMeters);
						}
						out.morphs.push_back(std::move(frame));
					}
				}
			}
		}

		// Translation is a distance and converts to meters like every other
		// position this codebase returns (units.h); rotation and scale are
		// unitless. Without this the scene graph sits in raw Gamebryo units
		// while the vertices inside it are in meters -- a ~70x mismatch that
		// is invisible in any per-mesh local-space measurement.
		const auto &t = av->transform;
		out.translation[0] = t.translation.x * units::kGamebryoUnitsToMeters;
		out.translation[1] = t.translation.y * units::kGamebryoUnitsToMeters;
		out.translation[2] = t.translation.z * units::kGamebryoUnitsToMeters;
		for (int r = 0; r < 3; r++) {
			for (int c = 0; c < 3; c++) {
				out.rotation[r * 3 + c] = t.rotation[r][c];
			}
		}
		out.scale = t.scale;
	}

	// Bones are declared, not inferred. Two authored sources: a skin's bone
	// list, and NiBoneLODController's per-LOD bone arrays.
	std::set<uint32_t> declared_bones;
	for (uint32_t i = 0; i < doc.block_count; i++) {
		if (auto *container = header.GetBlock<nifly::NiBoneContainer>(i)) {
			for (auto &ref : container->boneRefs) {
				if (!ref.IsEmpty()) {
					declared_bones.insert(ref.index);
				}
			}
		}
		if (auto *bone_lod = header.GetBlock<nifly::NiBoneLODController>(i)) {
			// boneArrays' iterators are non-const, so take a mutable handle.
			for (auto &group : bone_lod->boneArrays) {
				for (auto &ref : group) {
					if (!ref.IsEmpty()) {
						declared_bones.insert(ref.index);
					}
				}
			}
		}
	}
	for (uint32_t block : declared_bones) {
		const auto mapped = node_index_of.find(block);
		if (mapped != node_index_of.end()) {
			doc.nodes[mapped->second].is_declared_bone = true;
		}
		// A bone whose parent is also a declared bone means the rig is
		// present in this file, not merely referenced.
		const auto parent = parent_of.find(block);
		if (parent != parent_of.end() && declared_bones.count(parent->second) > 0) {
			doc.has_bone_hierarchy = true;
		}
	}

	for (uint32_t i = 0; i < doc.block_count; i++) {
		auto *seq = header.GetBlock<nifly::NiControllerSequence>(i);
		if (seq == nullptr) {
			continue;
		}
		Sequence out;
		out.block_index = i;
		out.name = seq->name.get();
		out.accum_root_name = seq->accumRootName.get();
		out.cycle_type = static_cast<uint32_t>(seq->cycleType);
		out.start_time = seq->startTime;
		out.stop_time = seq->stopTime;
		if (!seq->textKeyRef.IsEmpty()) {
			if (auto *tk = header.GetBlock<nifly::NiTextKeyExtraData>(seq->textKeyRef.index)) {
				for (const auto &key : tk->textKeys) {
					TextKey out_key;
					out_key.time = key.time;
					out_key.value = key.value.get();
					out.text_keys.push_back(std::move(out_key));
				}
			}
		}
		for (const auto &link : seq->controlledBlocks) {
			ControlledBlock cb;
			cb.node_name = link.nodeName.get();
			cb.property_type = link.propType.get();
			cb.controller_type = link.ctrlType.get();
			cb.controller_id = link.ctrlID.get();
			cb.interpolator_id = link.interpID.get();

			// Older files carry offsets into a NiStringPalette instead.
			if (cb.node_name.empty() && !link.stringPaletteRef.IsEmpty()) {
				if (auto *pal = header.GetBlock<nifly::NiStringPalette>(link.stringPaletteRef.index)) {
					const std::string &buffer = pal->palette.get();
					auto at = [&buffer](uint32_t offset) -> std::string {
						if (offset == nifly::NIF_NPOS || offset >= buffer.size()) {
							return std::string();
						}
						const size_t end = buffer.find('\0', offset);
						return buffer.substr(offset,
								end == std::string::npos ? std::string::npos : end - offset);
					};
					cb.node_name = at(link.nodeNameOffset);
					cb.property_type = at(link.propertyTypeOffset);
					cb.controller_type = at(link.controllerTypeOffset);
					cb.controller_id = at(link.controllerIDOffset);
					cb.interpolator_id = at(link.interpIDOffset);
					cb.from_string_palette = true;
				}
			}
			if (!link.interpolatorRef.IsEmpty()) {
				fill_interpolator(header, link.interpolatorRef.index, cb.interpolator);
			}
			out.controlled_blocks.push_back(std::move(cb));
		}
		doc.sequences.push_back(std::move(out));
	}

	for (uint32_t i = 0; i < doc.block_count; i++) {
		auto *palette = header.GetBlock<nifly::NiDefaultAVObjectPalette>(i);
		if (palette == nullptr) {
			continue;
		}
		ObjectPalette out;
		out.block_index = i;
		out.entries.reserve(palette->objects.size());
		for (const auto &object : palette->objects) {
			PaletteEntry entry;
			entry.name = object.name.get();
			if (!object.objectRef.IsEmpty()) {
				entry.object_block_index = static_cast<int32_t>(object.objectRef.index);
			}
			out.entries.push_back(std::move(entry));
		}
		doc.palettes.push_back(std::move(out));
	}

	return doc;
}

} // namespace nifsrc
