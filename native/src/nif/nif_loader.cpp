#include "nif_loader.h"

#include "../common/units.h"

#include <NifFile.hpp>
#include <Geometry.hpp>
#include <bhk.hpp>

#include <sstream>
#include <stdexcept>

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

		std::string tex;
		nif.GetTextureSlot(shape, tex, 0); // slot 0: diffuse/base
		sub.texture_path = tex;
		nif.GetTextureSlot(shape, tex, 1); // slot 1: normal + gloss(alpha)
		sub.normal_texture_path = tex;
		nif.GetTextureSlot(shape, tex, 2); // slot 2: glow/emissive
		sub.glow_texture_path = tex;

		if (nifly::NiAlphaProperty *alpha = nif.GetAlphaProperty(shape)) {
			sub.has_alpha_property = true;
			// Standard NIF NiAlphaProperty.flags bitfield (niftools spec,
			// stable across NIF versions, not nifly-specific): bit 0 =
			// alpha blend enable, bit 9 = alpha test enable. threshold is a
			// raw 0..255 byte, normalized here to 0..1 for the Godot side.
			sub.alpha_blend_enabled = (alpha->flags & 0x0001) != 0;
			sub.alpha_test_enabled = (alpha->flags & 0x0200) != 0;
			sub.alpha_threshold = static_cast<float>(alpha->threshold) / 255.0f;
		}

		flatten_transform(shape->GetTransformToParent(), sub);

		mesh.submeshes.push_back(std::move(sub));
	}

	// Collision (phases/1/02-collision-extraction.md): walk every NiAVObject
	// block (not just render NiShapes — collision is commonly attached to a
	// parent NiNode rather than the visible mesh itself) looking for a
	// non-empty collisionRef, then follow
	// NiAVObject -> bhkCollisionObject -> bhkRigidBody -> bhkShape.
	uint32_t num_blocks = nif.GetHeader().GetNumBlocks();
	for (uint32_t i = 0; i < num_blocks; ++i) {
		nifly::NiAVObject *av = nif.GetHeader().GetBlock<nifly::NiAVObject>(i);
		if (!av || av->collisionRef.IsEmpty()) {
			continue;
		}
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
		flatten_transform(av->GetTransformToParent(), cs);
		mesh.collision_shapes.push_back(std::move(cs));
	}

	return mesh;
}

} // namespace nif
