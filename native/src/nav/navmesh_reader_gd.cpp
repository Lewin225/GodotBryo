#include "navmesh_reader_gd.h"

#include <godot_cpp/core/class_db.hpp>

#include <cfloat>

using namespace godot;

void NavmeshReader::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_plugins", "plugin_paths"), &NavmeshReader::load_plugins);
	ClassDB::bind_method(D_METHOD("is_loaded"), &NavmeshReader::is_loaded);
	ClassDB::bind_method(D_METHOD("get_last_error"), &NavmeshReader::get_last_error);
	ClassDB::bind_method(D_METHOD("get_load_stats"), &NavmeshReader::get_load_stats);
	ClassDB::bind_method(D_METHOD("get_record_count"), &NavmeshReader::get_record_count);
	ClassDB::bind_method(D_METHOD("get_total_triangle_count"), &NavmeshReader::get_total_triangle_count);
	ClassDB::bind_method(D_METHOD("get_component_count"), &NavmeshReader::get_component_count);
	ClassDB::bind_method(D_METHOD("get_space_ids"), &NavmeshReader::get_space_ids);
	ClassDB::bind_method(D_METHOD("get_records_in_space", "space_form_id"), &NavmeshReader::get_records_in_space);
	ClassDB::bind_method(D_METHOD("get_record_info", "record_index"), &NavmeshReader::get_record_info);
	ClassDB::bind_method(D_METHOD("get_record_triangle_points", "record_index"), &NavmeshReader::get_record_triangle_points);
	ClassDB::bind_method(D_METHOD("get_space_geometry", "space_form_id"), &NavmeshReader::get_space_geometry);
	ClassDB::bind_method(D_METHOD("get_space_cross_links", "space_form_id"), &NavmeshReader::get_space_cross_links);
	ClassDB::bind_method(D_METHOD("get_space_bounds", "space_form_id"), &NavmeshReader::get_space_bounds);
	ClassDB::bind_method(D_METHOD("get_coarse_neighbors", "record_index"), &NavmeshReader::get_coarse_neighbors);
	ClassDB::bind_method(D_METHOD("snap", "space_form_id", "position", "max_distance", "use_coarse_index"),
			&NavmeshReader::snap, DEFVAL(8.0), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("find_route", "space_form_id", "from", "to", "snap_radius", "use_coarse_index"),
			&NavmeshReader::find_route, DEFVAL(8.0), DEFVAL(true));
}

static Vector3 to_godot(const nav::Vec3 &v) {
	return Vector3(v.x, v.y, v.z);
}
static nav::Vec3 to_nav(const Vector3 &v) {
	return nav::Vec3{ (float)v.x, (float)v.y, (float)v.z };
}

bool NavmeshReader::load_plugins(const PackedStringArray &plugin_paths) {
	std::vector<std::string> paths;
	paths.reserve(plugin_paths.size());
	for (int i = 0; i < plugin_paths.size(); ++i) {
		paths.push_back(std::string(plugin_paths[i].utf8().get_data()));
	}
	db_.load(paths);
	if (db_.record_count() == 0) {
		last_error_ = "No NAVM records loaded from the given plugins";
		return false;
	}
	last_error_ = "";
	return true;
}

Dictionary NavmeshReader::get_load_stats() const {
	const nav::LoadStats &s = db_.stats();
	Dictionary d;
	d["records"] = (int64_t)s.records;
	d["vertices"] = (int64_t)s.vertices;
	d["triangles"] = (int64_t)s.triangles;
	d["authored_edge_links"] = (int64_t)s.authored_edge_links;
	d["derived_cross_links"] = (int64_t)s.derived_cross_links;
	d["unresolved_edge_link_targets"] = (int64_t)s.unresolved_edge_link_targets;
	d["clamped_out_of_range_edges"] = (int64_t)s.clamped_out_of_range_edges;
	d["components"] = (int64_t)s.components;
	d["resident_bytes"] = (int64_t)s.resident_bytes;
	d["open_ms"] = s.open_ms;
	d["walk_ms"] = s.walk_ms;
	d["read_ms"] = s.read_ms;
	d["parse_ms"] = s.parse_ms;
	d["index_ms"] = s.index_ms;
	d["stitch_ms"] = s.stitch_ms;
	d["total_ms"] = s.total_ms;
	return d;
}

PackedInt32Array NavmeshReader::get_space_ids() const {
	PackedInt32Array out;
	for (uint32_t s : db_.spaces()) out.push_back((int32_t)s);
	return out;
}

PackedInt32Array NavmeshReader::get_records_in_space(int space_form_id) const {
	PackedInt32Array out;
	for (uint32_t r : db_.records_in_space((uint32_t)space_form_id)) out.push_back((int32_t)r);
	return out;
}

Dictionary NavmeshReader::get_record_info(int record_index) const {
	Dictionary d;
	const nav::NavMeshRecord *r = db_.record_at((size_t)record_index);
	if (r == nullptr) return d;
	d["form_id"] = (int64_t)r->form_id;
	d["cell_form_id"] = (int64_t)r->cell_form_id;
	d["space_form_id"] = (int64_t)r->space_form_id;
	d["is_exterior"] = r->is_exterior;
	d["vertex_count"] = (int)r->vertices.size();
	d["triangle_count"] = (int)r->triangles.size();
	d["edge_link_count"] = (int)r->edge_links.size();
	d["door_link_count"] = (int)r->door_links.size();
	d["bounds_min"] = to_godot(r->bounds.min);
	d["bounds_max"] = to_godot(r->bounds.max);
	// Authored-bounds midpoint. A broad-phase/heuristic aid only -- a record can
	// be concave or hollow, so this is not guaranteed to be a walkable point.
	d["center"] = to_godot(r->center);
	d["global_triangle_offset"] = (int64_t)r->global_triangle_offset;
	return d;
}

PackedVector3Array NavmeshReader::get_record_triangle_points(int record_index) const {
	PackedVector3Array out;
	const nav::NavMeshRecord *r = db_.record_at((size_t)record_index);
	if (r == nullptr) return out;
	out.resize(0);
	for (const nav::Triangle &t : r->triangles) {
		if (t.vertex[0] >= r->vertices.size() || t.vertex[1] >= r->vertices.size() || t.vertex[2] >= r->vertices.size()) continue;
		for (int i = 0; i < 3; ++i) out.push_back(to_godot(r->vertices[t.vertex[i]]));
	}
	return out;
}

// The derived cross-record links between records of one space, each pair once
// (lower global triangle first), as consecutive points: from-triangle centroid,
// then to-triangle centroid.
PackedVector3Array NavmeshReader::get_space_cross_links(int space_form_id) const {
	PackedVector3Array out;
	for (const auto &entry : db_.cross_record_links()) {
		for (const nav::CrossRecordLink &link : entry.second) {
			if (link.from_global_triangle > link.to_global_triangle) continue;
			uint32_t from_record = 0, from_local = 0, to_record = 0, to_local = 0;
			if (!db_.resolve_global_triangle(link.from_global_triangle, &from_record, &from_local)) continue;
			if (!db_.resolve_global_triangle(link.to_global_triangle, &to_record, &to_local)) continue;
			if (db_.record_at(from_record)->space_form_id != (uint32_t)space_form_id) continue;
			if (db_.record_at(to_record)->space_form_id != (uint32_t)space_form_id) continue;
			out.push_back(to_godot(db_.triangle_centroid(from_record, from_local)));
			out.push_back(to_godot(db_.triangle_centroid(to_record, to_local)));
		}
	}
	return out;
}

Dictionary NavmeshReader::get_space_geometry(int space_form_id) const {
	Dictionary d;
	PackedVector3Array points;
	PackedInt32Array record_indices;
	const std::vector<uint32_t> &records = db_.records_in_space((uint32_t)space_form_id);

	size_t triangle_total = 0;
	for (uint32_t ri : records) {
		const nav::NavMeshRecord *r = db_.record_at(ri);
		if (r != nullptr) triangle_total += r->triangles.size();
	}
	points.resize((int64_t)triangle_total * 3);
	record_indices.resize((int64_t)triangle_total);
	Vector3 *point_write = points.ptrw();
	int32_t *index_write = record_indices.ptrw();

	int64_t triangle_cursor = 0;
	for (uint32_t ri : records) {
		const nav::NavMeshRecord *r = db_.record_at(ri);
		if (r == nullptr) continue;
		for (const nav::Triangle &t : r->triangles) {
			if (t.vertex[0] >= r->vertices.size() || t.vertex[1] >= r->vertices.size() || t.vertex[2] >= r->vertices.size()) {
				// Degenerate entry: emit a zero-area triangle rather than
				// shifting every later index, so points and record_indices stay
				// in lockstep with the record's own triangle numbering.
				for (int i = 0; i < 3; ++i) point_write[triangle_cursor * 3 + i] = Vector3();
			} else {
				for (int i = 0; i < 3; ++i) point_write[triangle_cursor * 3 + i] = to_godot(r->vertices[t.vertex[i]]);
			}
			index_write[triangle_cursor] = (int32_t)ri;
			triangle_cursor++;
		}
	}

	d["points"] = points;
	d["record_indices"] = record_indices;
	d["triangle_count"] = (int64_t)triangle_total;
	d["record_count"] = (int)records.size();
	return d;
}

Dictionary NavmeshReader::get_space_bounds(int space_form_id) const {
	Dictionary d;
	const std::vector<uint32_t> &records = db_.records_in_space((uint32_t)space_form_id);
	if (records.empty()) {
		d["found"] = false;
		return d;
	}
	nav::Vec3 lo{ FLT_MAX, FLT_MAX, FLT_MAX };
	nav::Vec3 hi{ -FLT_MAX, -FLT_MAX, -FLT_MAX };
	for (uint32_t ri : records) {
		const nav::NavMeshRecord *r = db_.record_at(ri);
		if (r == nullptr) continue;
		lo.x = MIN(lo.x, r->bounds.min.x); lo.y = MIN(lo.y, r->bounds.min.y); lo.z = MIN(lo.z, r->bounds.min.z);
		hi.x = MAX(hi.x, r->bounds.max.x); hi.y = MAX(hi.y, r->bounds.max.y); hi.z = MAX(hi.z, r->bounds.max.z);
	}
	d["found"] = true;
	d["min"] = to_godot(lo);
	d["max"] = to_godot(hi);
	return d;
}

PackedInt32Array NavmeshReader::get_coarse_neighbors(int record_index) const {
	PackedInt32Array out;
	for (uint32_t n : db_.coarse_neighbors((uint32_t)record_index)) out.push_back((int32_t)n);
	return out;
}

Dictionary NavmeshReader::snap(int space_form_id, const Vector3 &position, float max_distance, bool use_coarse_index) const {
	nav::SnapResult r = db_.snap((uint32_t)space_form_id, to_nav(position), max_distance, use_coarse_index);
	Dictionary d;
	d["found"] = r.found;
	if (!r.found) return d;
	d["position"] = to_godot(r.position);
	d["distance"] = r.distance;
	d["navmesh_form_id"] = (int64_t)r.navmesh_form_id;
	d["cell_form_id"] = (int64_t)r.cell_form_id;
	d["global_triangle"] = (int64_t)r.global_triangle;
	d["local_triangle"] = (int64_t)r.local_triangle;
	d["component"] = (int64_t)r.component;
	return d;
}

Dictionary NavmeshReader::find_route(int space_form_id, const Vector3 &from, const Vector3 &to,
		float snap_radius, bool use_coarse_index) const {
	nav::RouteResult r = db_.route((uint32_t)space_form_id, to_nav(from), to_nav(to), snap_radius, use_coarse_index);
	Dictionary d;
	d["found"] = r.found;
	d["visited_nodes"] = (int64_t)r.visited_nodes;
	if (!r.found) return d;
	PackedVector3Array waypoints;
	for (const nav::Vec3 &w : r.waypoints) waypoints.push_back(to_godot(w));
	d["waypoints"] = waypoints;
	PackedInt32Array triangles;
	for (uint32_t t : r.triangles) triangles.push_back((int32_t)t);
	d["triangles"] = triangles;
	d["length"] = r.length;
	return d;
}
