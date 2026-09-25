#ifndef NV_NAVMESH_DATABASE_H
#define NV_NAVMESH_DATABASE_H

#include "navmesh_types.h"

#include <string>
#include <unordered_map>
#include <vector>

namespace esm {
class EsmFile;
}

namespace nav {

struct SnapResult {
	bool found = false;
	Vec3 position;            // closest point on the navmesh
	uint32_t navmesh_form_id = 0;
	uint32_t global_triangle = 0;
	uint32_t local_triangle = 0;
	uint32_t cell_form_id = 0;
	// Connected walkable region this triangle belongs to. Two points in the same
	// space but different components cannot be walked between -- the only link
	// is a door. See NavmeshDatabase::build_components().
	uint32_t component = 0;
	float distance = 0.0f;
};

struct RouteResult {
	bool found = false;
	std::vector<Vec3> waypoints;
	std::vector<uint32_t> triangles;   // global triangle indices, in order
	uint32_t visited_nodes = 0;        // search cost, for tuning/diagnostics
	float length = 0.0f;
};

struct LoadStats {
	double open_ms = 0, walk_ms = 0, read_ms = 0, parse_ms = 0, stitch_ms = 0, index_ms = 0, total_ms = 0;
	uint64_t records = 0, vertices = 0, triangles = 0;
	uint64_t authored_edge_links = 0, derived_cross_links = 0;
	uint64_t components = 0;                 // connected walkable regions
	uint64_t clamped_out_of_range_edges = 0; // the 82 known-malformed NVTR edges
	uint64_t unresolved_edge_link_targets = 0;
	size_t resident_bytes = 0;
};

// The whole game's navmesh, loaded once and then immutable.
//
// Thread safety: every query method is const and touches no file handle and no
// mutable state, so any number of threads may query concurrently once load()
// has returned. This is deliberately unlike EsmReader/BsaReader, which each own
// a FILE* and therefore need one instance per worker thread -- this database
// reads the ESM only during load() and never again.
class NavmeshDatabase {
public:
	NavmeshDatabase() = default;

	NavmeshDatabase(const NavmeshDatabase &) = delete;
	NavmeshDatabase &operator=(const NavmeshDatabase &) = delete;

	// Loads every NAVM record from the given plugin paths. Later files do not
	// override earlier ones -- the shipped masters' navmesh graphs are
	// self-contained (0 NVEX links resolve outside their own file, measured
	// across the base game alone and all six masters together), so records are
	// simply accumulated.
	void load(const std::vector<std::string> &plugin_paths);

	bool is_loaded() const { return loaded_; }
	const LoadStats &stats() const { return stats_; }

	size_t record_count() const { return records_.size(); }
	const NavMeshRecord *record_at(size_t index) const {
		return index < records_.size() ? &records_[index] : nullptr;
	}
	const NavMeshRecord *record_by_form_id(uint32_t form_id) const;

	// Records belonging to one raw authored coordinate space.
	const std::vector<uint32_t> &records_in_space(uint32_t space_form_id) const;
	std::vector<uint32_t> spaces() const;

	// Closest point on any triangle in `space_form_id` within max_distance.
	// When use_coarse_index is true the search first rejects whole records by
	// their authored NVGD bounds; when false it tests every triangle in the
	// space. Both paths return the same answer -- the flag exists so the
	// speedup can be measured rather than assumed.
	SnapResult snap(uint32_t space_form_id, const Vec3 &position, float max_distance,
			bool use_coarse_index = true) const;

	// A* between two points in the same space. Crosses record boundaries via
	// the derived cross-record links (see CrossRecordLink -- authored about
	// which records connect, approximate about exactly where). Waypoints are
	// funnelled per record (see build_waypoints), so the result is the shortest
	// line inside the triangle corridor rather than one point per triangle.
	RouteResult route(uint32_t space_form_id, const Vec3 &from, const Vec3 &to,
			float snap_radius, bool use_coarse_index = true) const;

	// Coarse record-level connectivity, straight from authored NVEX targets.
	const std::vector<uint32_t> &coarse_neighbors(uint32_t record_index) const;

	uint32_t total_triangles() const { return total_triangles_; }

	// Connected walkable regions. A "space" is NOT one region: the exterior
	// worldspace alone splits into 181 of them, holding 2.42% of its triangles,
	// because fenced compounds and rooftops connect to the rest only through
	// doors. Routing has to work at this granularity, not per space.
	uint32_t component_count() const { return component_count_; }
	uint32_t component_of_triangle(uint32_t global_triangle) const {
		return global_triangle < triangle_component_.size() ? triangle_component_[global_triangle] : 0;
	}
	// Splits a database-wide triangle index back into its record and local index.
	bool resolve_global_triangle(uint32_t global_triangle, uint32_t *out_record, uint32_t *out_local) const;
	Vec3 triangle_centroid(uint32_t record_index, uint32_t local_triangle) const;
	bool triangle_corners(uint32_t record_index, uint32_t local_triangle, Vec3 *a, Vec3 *b, Vec3 *c) const;

	// Turns an A* triangle corridor into walkable waypoints, funnelled per
	// record so the result is the shortest line inside that corridor rather
	// than a centroid-per-triangle zigzag.
	std::vector<Vec3> build_waypoints(const std::vector<uint32_t> &triangle_path,
			const Vec3 &start, const Vec3 &goal) const;

	// Re-seats a smoothed path onto the real navmesh surface. Smoothing
	// interpolates height linearly between waypoints, which floats the path off
	// uneven ground; since navmesh overlaps vertically, that risks snapping an
	// actor onto the wrong floor. Each sample is snapped from the height already
	// being walked, so the path tracks its own floor rather than the globally
	// nearest one.
	std::vector<Vec3> project_onto_navmesh(uint32_t space_form_id,
			const std::vector<Vec3> &waypoints, float step = 2.0f,
			float search_radius = 45.0f, float keep_tolerance = 0.3f) const;

	// True when every sampled point along the segment still lands on navmesh
	// within `tolerance`. Used to verify a shortcut before taking it.
	bool segment_stays_on_navmesh(uint32_t space_form_id, const Vec3 &from, const Vec3 &to,
			float tolerance = 1.0f, float sample_spacing = 1.5f) const;

	// Drops waypoints whose shortcut is verified to stay on navmesh. Straightens
	// across record seams, which the per-record funnel cannot do on its own.
	std::vector<Vec3> simplify_by_line_of_sight(uint32_t space_form_id,
			const std::vector<Vec3> &waypoints, float tolerance = 1.0f, int max_lookahead = 12) const;

private:
	void load_one(const std::string &path);
	void build_indices();
	void build_cross_record_links();
	void build_components();

	bool loaded_ = false;
	LoadStats stats_;
	std::vector<NavMeshRecord> records_;
	std::unordered_map<uint32_t, uint32_t> record_by_form_;
	std::unordered_map<uint32_t, std::vector<uint32_t>> records_by_space_;
	std::vector<std::vector<uint32_t>> coarse_adjacency_;

	// Fine graph edges that leave a record, keyed by global triangle index.
	std::unordered_map<uint32_t, std::vector<CrossRecordLink>> cross_links_;

	// global triangle index -> record index, via record start offsets.
	std::vector<uint32_t> record_triangle_offsets_;
	uint32_t total_triangles_ = 0;
	std::vector<uint32_t> triangle_component_;
	uint32_t component_count_ = 0;
};

} // namespace nav

#endif
