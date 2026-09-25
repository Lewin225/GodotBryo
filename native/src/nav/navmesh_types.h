#ifndef NV_NAVMESH_TYPES_H
#define NV_NAVMESH_TYPES_H

#include <cstdint>
#include <vector>

namespace nav {

// Plain float vector, kept independent of godot-cpp so the database and the
// offline census tools can share this header.
struct Vec3 {
	float x = 0.0f, y = 0.0f, z = 0.0f;
};

struct Aabb {
	Vec3 min, max;
	bool contains_xy(const Vec3 &p, float pad) const {
		return p.x >= min.x - pad && p.x <= max.x + pad && p.y >= min.y - pad && p.y <= max.y + pad;
	}
};

// One NVTR entry.
//
// "edge" holds what the raw subrecord holds and nothing more: -1 for no
// in-record neighbor, otherwise an index into the SAME record's triangle
// array. That encoding is not documented in the xEdit definitions vendored
// under enginedocs/xEdit/ (the schema routes these through a
// wbNVTREdgeToStr/wbNVTREdgeToInt callback whose body we do not have), so it
// was established by exhaustive census over every NAVM in every shipped
// master (native/tools/navm_edge_encoding_census.cpp):
//
//   what this is (fact): 2,479,896 edge slots -- 13.260% are exactly -1,
//   86.737% fall in [0, triangle_count), 0 are any other negative value, and
//   82 (0.003%) are exactly triangle_count, i.e. out of range by one.
//
//   what we infer from it: -1 means "no neighbor in this record" and any
//   other value is an in-record triangle index. The 82 out-of-range values
//   are malformed shipped data and are clamped to -1 at load rather than
//   trusted -- indexing on them would read past the triangle array.
struct Triangle {
	uint16_t vertex[3] = { 0, 0, 0 };
	int32_t edge[3] = { -1, -1, -1 };
	uint16_t flags = 0;
	uint16_t cover_flags = 0;
};

// One NVEX entry, stored as the raw subrecord holds it.
//
// Named for the confirmed observation, not an interpretation. What is
// established by exhaustive census over all 110,153 links in every shipped
// master (native/tools/navm_nvex_semantics_census.cpp):
//
//   what this is (fact): "target_navmesh_form_id" always resolves to a real
//   NAVM record (0 unresolved). "target_triangle_index" is in range for the
//   TARGET record's triangle array in 99.882% of links, but in range for the
//   OWNING record's array in only 78.932% -- so it indexes the target, not
//   the local record. Record-pair connectivity is 99.07% reciprocal
//   (count(A->B) == count(B->A) for 15,794 of 15,942 directed pairs).
//
//   what we infer from it: NVEX is the authoritative source of which NAVM
//   records connect to which. That much is solid and is what routing uses.
//
//   what is NOT established: what "type" means (95.50% are 0, 2.24% are 1,
//   2.24% are 2, 0.02% are 3 -- the enum body is not in the vendored xEdit
//   definitions), and whether the named target triangle is a precise
//   edge-seam pairing. It is probably not: only 10.631% of named target
//   triangles even have a boundary (-1) edge, so these are generally
//   interior triangles. Geometric seam matching was tested as an alternative
//   and ruled out -- only 2.10% of boundary edges in NVEX-linked records
//   share vertex positions with a linked record
//   (native/tools/navm_stitch_census.cpp). Nothing here assumes a seam
//   pairing; see NavmeshDatabase's derived cross-record stitch.
struct EdgeLink {
	uint32_t type = 0;
	uint32_t target_navmesh_form_id = 0;
	uint16_t target_triangle_index = 0;
};

// One NVDP entry: a link from a triangle to a placed door REFR.
struct DoorLink {
	uint32_t door_reference_form_id = 0;
	uint16_t triangle_index = 0;
};

// One NAVM record.
struct NavMeshRecord {
	uint32_t form_id = 0;
	uint32_t cell_form_id = 0;
	// The raw authored coordinate space this record's vertices live in: the
	// owning WRLD for an exterior CELL, or the CELL's own FormID for an
	// interior. Same identity mapping EsmServer.get_space_form_id_for_cell()
	// uses, so a caller can mix NSS actor spaces and navmesh spaces directly.
	uint32_t space_form_id = 0;
	bool is_exterior = false;

	std::vector<Vec3> vertices;
	std::vector<Triangle> triangles;
	std::vector<EdgeLink> edge_links;
	std::vector<DoorLink> door_links;

	// Authored NVGD "Navmesh Bounds", present on 6139/6139 records across every
	// shipped master -- an exhaustive result, so there is no derived-bounds
	// fallback path. "center" is the midpoint of those authored bounds; it is
	// only ever a broad-phase/heuristic aid and is never treated as a walkable
	// point (a record can be concave or hollow, putting its midpoint off-mesh).
	Aabb bounds;
	Vec3 center;

	// Index of this record's first triangle in the database-wide flat triangle
	// numbering, so a graph node can be a single integer.
	uint32_t global_triangle_offset = 0;
};

// A derived, geometric cross-record connection between two triangles.
//
// Not authored: the ESM gives record-level connectivity (NVEX) but no
// triangle-to-triangle seam pairing, and geometric seam matching was measured
// and ruled out. Each entry pairs the target triangle an NVEX link names with
// whichever triangle of the linking record is geometrically nearest to it.
// That makes these edges an approximation built on top of authored
// connectivity -- correct about WHICH records connect, approximate about
// exactly where the crossing happens.
struct CrossRecordLink {
	uint32_t from_global_triangle = 0;
	uint32_t to_global_triangle = 0;
	float cost = 0.0f;
};

} // namespace nav

#endif
