#ifndef NV_NAVMESH_READER_GD_H
#define NV_NAVMESH_READER_GD_H

#include "navmesh_database.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// GDScript face of NavmeshDatabase: the whole game's authored navmesh, loaded
// once and then read-only.
//
// Positions in and out are meters in the raw authored Z-up axis order, exactly
// like EsmReader -- no axis swap happens at this layer, so a Vector3 from
// EsmReader and one from here are directly comparable without conversion.
//
// Thread safety: load() must finish before any query, but once it has, every
// query method is safe to call from any number of threads at once. Unlike
// EsmReader/BsaReader this holds no file handle after loading, so a worker pool
// shares ONE instance rather than needing one per thread.
class NavmeshReader : public RefCounted {
	GDCLASS(NavmeshReader, RefCounted)

protected:
	static void _bind_methods();

public:
	// Blocking. Call from a worker thread if the caller must stay responsive.
	bool load_plugins(const PackedStringArray &plugin_paths);
	bool is_loaded() const { return db_.is_loaded(); }
	String get_last_error() const { return last_error_; }

	Dictionary get_load_stats() const;

	int get_record_count() const { return (int)db_.record_count(); }
	int get_total_triangle_count() const { return (int)db_.total_triangles(); }
	// Connected walkable regions; a space is not one region (see NavmeshDatabase).
	int get_component_count() const { return (int)db_.component_count(); }

	PackedInt32Array get_space_ids() const;
	PackedInt32Array get_records_in_space(int space_form_id) const;
	Dictionary get_record_info(int record_index) const;

	// Flat triangle corner positions for one record, three entries per triangle
	// -- for debug visualization, not for queries.
	PackedVector3Array get_record_triangle_points(int record_index) const;

	// Every triangle in a whole space in one call, as
	// {points: PackedVector3Array (3 per triangle), record_indices:
	// PackedInt32Array (1 per triangle)}. The largest space holds 4041 records,
	// so a visualizer building this record-by-record pays 4041 round-trips;
	// this is the same data in one.
	Dictionary get_space_geometry(int space_form_id) const;
	PackedVector3Array get_space_cross_links(int space_form_id) const;
	Dictionary get_record_cross_links(int record_index) const;

	// Union of the authored NVGD bounds of every record in a space, as
	// {found, min, max}, for framing a camera without touching triangles.
	Dictionary get_space_bounds(int space_form_id) const;

	// Record-level connectivity, straight from authored NVEX targets.
	PackedInt32Array get_coarse_neighbors(int record_index) const;

	// Closest navmesh point to `position` within `max_distance` meters.
	// use_coarse_index only changes cost, never the answer.
	Dictionary snap(int space_form_id, const Vector3 &position, float max_distance, bool use_coarse_index) const;

	// A* between two points in one space. Returns {found, waypoints, triangles,
	// length, visited_nodes}.
	Dictionary find_route(int space_form_id, const Vector3 &from, const Vector3 &to,
			float snap_radius, bool use_coarse_index) const;

private:
	nav::NavmeshDatabase db_;
	String last_error_;
};

} // namespace godot

#endif
