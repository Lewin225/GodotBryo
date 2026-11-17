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
// Each edge slot holds one of two things, chosen by the triangle's Flags:
// bit e (0x01 Edge 0-1, 0x02 Edge 1-2, 0x04 Edge 2-0) set means the slot is
// an index into the record's NVEX Edge Links, the link that edge crosses into
// another record; clear means -1 (no neighbour) or an index into this
// record's triangles. Established over every NAVM in FalloutNV.esm
// (native/tools/navm_edge_link_flag_census.cpp): all 94,543 flagged slots
// hold a valid NVEX index, one per NVEX entry, and 99.2% of the named target
// triangles lie within 0.5 m of the flagged edge; unflagged slots hold only
// -1 or an in-record index.
//
// "edge" is the in-record neighbour (-1 for a flagged slot); "edge_link" the
// NVEX index (-1 for an unflagged slot).
struct Triangle {
	uint16_t vertex[3] = { 0, 0, 0 };
	int16_t edge[3] = { -1, -1, -1 };
	int16_t edge_link[3] = { -1, -1, -1 };
	uint16_t flags = 0;
	uint16_t cover_flags = 0;
};

// One NVEX entry, stored as the raw subrecord holds it.
//
// Established by exhaustive census over every shipped master
// (native/tools/navm_nvex_semantics_census.cpp,
// native/tools/navm_edge_link_flag_census.cpp):
//
//   "target_navmesh_form_id" always resolves to a real NAVM record (0
//   unresolved). "target_triangle_index" indexes the TARGET record's
//   triangles (in range for it in 99.882% of links). Each NVEX entry is named
//   by exactly one link-flagged NVTR edge of the owning record (110,078 of
//   110,078 across the masters), the edge the link crosses; the target
//   triangle lies within 0.5 m of that edge for 95.1% of them.
//
//   Not established: what "type" means (95.50% are 0, 2.24% are 1, 2.24%
//   are 2, 0.02% are 3 -- the enum body is not in the vendored xEdit
//   definitions). Nothing reads it.
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

// A cross-record connection between two triangles: a flagged NVTR edge and
// the NVEX target triangle it names. Stored in both directions; the crossing
// is the flagged edge, held as the triangle that owns it and its slot.
struct CrossRecordLink {
	uint32_t from_global_triangle = 0;
	uint32_t to_global_triangle = 0;
	float cost = 0.0f;
	// The triangle whose flagged edge this link crosses (from_ or
	// to_global_triangle), and that edge's slot.
	uint32_t edge_global_triangle = 0;
	uint8_t edge_slot = 0;
};

} // namespace nav

#endif
