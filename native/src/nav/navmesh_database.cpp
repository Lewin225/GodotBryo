#include "navmesh_database.h"

#include "common/units.h"
#include "esm/esm_file.h"

#include <algorithm>
#include <cfloat>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <functional>
#include <queue>

namespace nav {

namespace {

using Clock = std::chrono::steady_clock;
double ms_since(Clock::time_point t) {
	return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}

uint32_t rd_u32(const uint8_t *d, size_t n, size_t o) {
	if (o + 4 > n) return 0;
	return d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (uint32_t(d[o + 3]) << 24);
}
uint16_t rd_u16(const uint8_t *d, size_t n, size_t o) {
	if (o + 2 > n) return 0;
	return d[o] | (d[o + 1] << 8);
}
float rd_f32(const uint8_t *d, size_t n, size_t o) {
	if (o + 4 > n) return 0.0f;
	float f;
	std::memcpy(&f, d + o, 4);
	return f;
}
// NVVX vertices and NVGD bounds are raw Gamebryo units. Every position this
// codebase returns is in meters by construction, converted at the true source
// rather than per-consumer (see common/units.h) -- so the conversion belongs
// here, at the only point navmesh coordinates are read out of raw data, and
// nowhere downstream. Verified against real data: NAVM 0x00175F7E in
// HooverDamIntPowerPlant01 spans z 10368..11652 raw, i.e. 148..166 m, and that
// cell's ACHRs sit at z 149.7..166.2 m, which only overlap once this is applied.
Vec3 rd_vec3_meters(const uint8_t *d, size_t n, size_t o) {
	return Vec3{
		rd_f32(d, n, o) * units::kGamebryoUnitsToMeters,
		rd_f32(d, n, o + 4) * units::kGamebryoUnitsToMeters,
		rd_f32(d, n, o + 8) * units::kGamebryoUnitsToMeters
	};
}

Vec3 sub(const Vec3 &a, const Vec3 &b) { return Vec3{ a.x - b.x, a.y - b.y, a.z - b.z }; }
Vec3 add(const Vec3 &a, const Vec3 &b) { return Vec3{ a.x + b.x, a.y + b.y, a.z + b.z }; }
Vec3 mul(const Vec3 &a, float s) { return Vec3{ a.x * s, a.y * s, a.z * s }; }
float dot(const Vec3 &a, const Vec3 &b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
float length(const Vec3 &a) { return std::sqrt(dot(a, a)); }
float distance(const Vec3 &a, const Vec3 &b) { return length(sub(a, b)); }
float distance_sq(const Vec3 &a, const Vec3 &b) { Vec3 d = sub(a, b); return dot(d, d); }

// Closest point on triangle abc to p (Ericson, Real-Time Collision Detection).
Vec3 closest_point_on_triangle(const Vec3 &p, const Vec3 &a, const Vec3 &b, const Vec3 &c) {
	Vec3 ab = sub(b, a), ac = sub(c, a), ap = sub(p, a);
	float d1 = dot(ab, ap), d2 = dot(ac, ap);
	if (d1 <= 0.0f && d2 <= 0.0f) return a;

	Vec3 bp = sub(p, b);
	float d3 = dot(ab, bp), d4 = dot(ac, bp);
	if (d3 >= 0.0f && d4 <= d3) return b;

	float vc = d1 * d4 - d3 * d2;
	if (vc <= 0.0f && d1 >= 0.0f && d3 <= 0.0f) {
		float denom = d1 - d3;
		float v = denom != 0.0f ? d1 / denom : 0.0f;
		return add(a, mul(ab, v));
	}

	Vec3 cp = sub(p, c);
	float d5 = dot(ab, cp), d6 = dot(ac, cp);
	if (d6 >= 0.0f && d5 <= d6) return c;

	float vb = d5 * d2 - d1 * d6;
	if (vb <= 0.0f && d2 >= 0.0f && d6 <= 0.0f) {
		float denom = d2 - d6;
		float w = denom != 0.0f ? d2 / denom : 0.0f;
		return add(a, mul(ac, w));
	}

	float va = d3 * d6 - d5 * d4;
	if (va <= 0.0f && (d4 - d3) >= 0.0f && (d5 - d6) >= 0.0f) {
		float denom = (d4 - d3) + (d5 - d6);
		float w = denom != 0.0f ? (d4 - d3) / denom : 0.0f;
		return add(b, mul(sub(c, b), w));
	}

	float denom = va + vb + vc;
	if (denom == 0.0f) return a;
	float v = vb / denom, w = vc / denom;
	return add(add(a, mul(ab, v)), mul(ac, w));
}

const std::vector<uint32_t> kEmptyIndices;

// Approximate closest points between two triangles, by projecting back and
// forth a few times. Used where a route crosses into another NAVM record with
// no usable gate (build_waypoints): the crossing hops between these points
// rather than between the triangles' centroids.
void closest_points_between_triangles(const Vec3 &a0, const Vec3 &a1, const Vec3 &a2,
		const Vec3 &b0, const Vec3 &b1, const Vec3 &b2, Vec3 *out_a, Vec3 *out_b) {
	Vec3 pa = mul(add(add(a0, a1), a2), 1.0f / 3.0f);
	Vec3 pb = mul(add(add(b0, b1), b2), 1.0f / 3.0f);
	for (int i = 0; i < 4; ++i) {
		pb = closest_point_on_triangle(pa, b0, b1, b2);
		pa = closest_point_on_triangle(pb, a0, a1, a2);
	}
	*out_a = pa;
	*out_b = pb;
}

// Twice the signed area of triangle abc projected on XY. Positive is
// counter-clockwise. Navmesh walking happens in the XY plane (this data is
// Z-up), so every funnel side test ignores height.
float signed_area_xy(const Vec3 &a, const Vec3 &b, const Vec3 &c) {
	return (c.x - a.x) * (b.y - a.y) - (b.x - a.x) * (c.y - a.y);
}

// One gate the path passes through: the edge shared by two consecutive
// triangles, as a left/right pair seen from the direction of travel.
struct Gate {
	Vec3 left, right;
};

// Simple Stupid Funnel Algorithm (Mikko Mononen). Turns a corridor of gates
// into the shortest path that stays inside it, which is what removes both
// artifacts of a centroid path: the zigzag through dense triangles and the
// unnecessarily long straight across large ones.
std::vector<Vec3> funnel(const Vec3 &start, const Vec3 &end, const std::vector<Gate> &gates) {
	std::vector<Vec3> path;
	path.push_back(start);

	std::vector<Gate> full;
	full.reserve(gates.size() + 2);
	full.push_back(Gate{ start, start });
	for (const Gate &g : gates) full.push_back(g);
	full.push_back(Gate{ end, end });

	Vec3 apex = start, left = start, right = start;
	size_t apex_index = 0, left_index = 0, right_index = 0;

	for (size_t i = 1; i < full.size(); ++i) {
		const Vec3 &l = full[i].left;
		const Vec3 &r = full[i].right;

		// Tighten the right side.
		if (signed_area_xy(apex, right, r) <= 0.0f) {
			if (distance_sq(apex, right) < 1e-12f || signed_area_xy(apex, left, r) > 0.0f) {
				right = r;
				right_index = i;
			} else {
				// Right crossed left: the left endpoint becomes the new apex.
				path.push_back(left);
				apex = left;
				apex_index = left_index;
				left = apex;
				right = apex;
				left_index = apex_index;
				right_index = apex_index;
				i = apex_index;
				continue;
			}
		}

		// Tighten the left side.
		if (signed_area_xy(apex, left, l) >= 0.0f) {
			if (distance_sq(apex, left) < 1e-12f || signed_area_xy(apex, right, l) < 0.0f) {
				left = l;
				left_index = i;
			} else {
				path.push_back(right);
				apex = right;
				apex_index = right_index;
				left = apex;
				right = apex;
				left_index = apex_index;
				right_index = apex_index;
				i = apex_index;
				continue;
			}
		}
	}

	if (path.empty() || distance_sq(path.back(), end) > 1e-8f) path.push_back(end);
	return path;
}

} // namespace

void NavmeshDatabase::load(const std::vector<std::string> &plugin_paths) {
	auto total_start = Clock::now();
	records_.clear();
	record_by_form_.clear();
	records_by_space_.clear();
	coarse_adjacency_.clear();
	cross_links_.clear();
	record_triangle_offsets_.clear();
	total_triangles_ = 0;
	stats_ = LoadStats();

	for (const std::string &path : plugin_paths) {
		load_one(path);
	}
	build_indices();
	build_cross_record_links();
	build_components();

	stats_.records = records_.size();
	stats_.total_ms = ms_since(total_start);
	loaded_ = true;
}

void NavmeshDatabase::load_one(const std::string &path) {
	auto t_open = Clock::now();
	esm::EsmFile file;
	try {
		file.open(path);
	} catch (const std::exception &) {
		// A plugin that will not open is skipped rather than aborting the whole
		// load; the caller sees it in the record/stat totals.
		return;
	}
	stats_.open_ms += ms_since(t_open);

	auto t_walk = Clock::now();
	std::vector<esm::RecordInfo> navm_records;
	file.for_each_record([&](const esm::RecordInfo &record) {
		if (record.type == "NAVM") navm_records.push_back(record);
	});
	stats_.walk_ms += ms_since(t_walk);

	for (const esm::RecordInfo &info : navm_records) {
		auto t_read = Clock::now();
		std::vector<uint8_t> raw = file.read_record_data(info);
		stats_.read_ms += ms_since(t_read);

		auto t_parse = Clock::now();
		std::vector<esm::Subrecord> subs = esm::EsmFile::parse_subrecords(raw);
		NavMeshRecord record;
		record.form_id = info.form_id;
		uint32_t vertex_count = 0, triangle_count = 0, edge_link_count = 0, door_link_count = 0;

		for (const esm::Subrecord &sub : subs) {
			if (sub.type != "DATA") continue;
			record.cell_form_id = rd_u32(sub.data, sub.size, 0);
			vertex_count = rd_u32(sub.data, sub.size, 4);
			triangle_count = rd_u32(sub.data, sub.size, 8);
			edge_link_count = rd_u32(sub.data, sub.size, 12);
			door_link_count = rd_u32(sub.data, sub.size, 20);
			break;
		}

		for (const esm::Subrecord &sub : subs) {
			const uint8_t *d = sub.data;
			size_t n = sub.size;
			if (sub.type == "NVVX") {
				size_t count = vertex_count ? vertex_count : n / 12;
				count = std::min(count, n / 12);
				record.vertices.resize(count);
				for (size_t k = 0; k < count; ++k) record.vertices[k] = rd_vec3_meters(d, n, k * 12);
			} else if (sub.type == "NVTR") {
				size_t count = triangle_count ? triangle_count : n / 16;
				count = std::min(count, n / 16);
				record.triangles.resize(count);
				for (size_t k = 0; k < count; ++k) {
					size_t o = k * 16;
					Triangle &t = record.triangles[k];
					for (int j = 0; j < 3; ++j) t.vertex[j] = rd_u16(d, n, o + j * 2);
					t.flags = rd_u16(d, n, o + 12);
					t.cover_flags = rd_u16(d, n, o + 14);
					for (int j = 0; j < 3; ++j) {
						int16_t raw_edge = (int16_t)rd_u16(d, n, o + 6 + j * 2);
						// Flags bit j: the slot is an NVEX index (checked against
						// the NVEX count in build_cross_record_links).
						if (t.flags & (1u << j)) {
							t.edge_link[j] = raw_edge;
							continue;
						}
						// An in-record index past the triangle array would read
						// past it; none occur unflagged in FalloutNV.esm.
						if (raw_edge >= 0 && (size_t)raw_edge >= count) {
							t.edge[j] = -1;
							stats_.clamped_out_of_range_edges++;
						} else {
							t.edge[j] = raw_edge;
						}
					}
				}
			} else if (sub.type == "NVEX") {
				size_t count = edge_link_count ? edge_link_count : n / 10;
				count = std::min(count, n / 10);
				record.edge_links.resize(count);
				for (size_t k = 0; k < count; ++k) {
					size_t o = k * 10;
					record.edge_links[k].type = rd_u32(d, n, o + 0);
					record.edge_links[k].target_navmesh_form_id = rd_u32(d, n, o + 4);
					record.edge_links[k].target_triangle_index = rd_u16(d, n, o + 8);
				}
			} else if (sub.type == "NVDP") {
				size_t count = door_link_count ? door_link_count : n / 8;
				count = std::min(count, n / 8);
				record.door_links.resize(count);
				for (size_t k = 0; k < count; ++k) {
					size_t o = k * 8;
					record.door_links[k].door_reference_form_id = rd_u32(d, n, o + 0);
					record.door_links[k].triangle_index = rd_u16(d, n, o + 4);
				}
			} else if (sub.type == "NVGD") {
				if (n >= 36) {
					record.bounds.min = rd_vec3_meters(d, n, 12);
					record.bounds.max = rd_vec3_meters(d, n, 24);
					record.center = mul(add(record.bounds.min, record.bounds.max), 0.5f);
				}
			}
		}

		// Space identity: owning WRLD for an exterior CELL, the CELL itself for
		// an interior. Matches EsmServer.get_space_form_id_for_cell().
		auto worldspace = file.get_cell_worldspace(record.cell_form_id);
		if (worldspace.has_value() && *worldspace != 0) {
			record.space_form_id = *worldspace;
			record.is_exterior = true;
		} else {
			record.space_form_id = record.cell_form_id;
			record.is_exterior = false;
		}

		stats_.vertices += record.vertices.size();
		stats_.triangles += record.triangles.size();
		stats_.authored_edge_links += record.edge_links.size();
		stats_.parse_ms += ms_since(t_parse);
		records_.push_back(std::move(record));
	}
}

void NavmeshDatabase::build_indices() {
	auto t_index = Clock::now();

	record_triangle_offsets_.resize(records_.size());
	total_triangles_ = 0;
	for (size_t i = 0; i < records_.size(); ++i) {
		records_[i].global_triangle_offset = total_triangles_;
		record_triangle_offsets_[i] = total_triangles_;
		total_triangles_ += (uint32_t)records_[i].triangles.size();
		record_by_form_[records_[i].form_id] = (uint32_t)i;
		records_by_space_[records_[i].space_form_id].push_back((uint32_t)i);
	}

	coarse_adjacency_.assign(records_.size(), {});
	for (size_t i = 0; i < records_.size(); ++i) {
		std::vector<uint32_t> &adj = coarse_adjacency_[i];
		for (const EdgeLink &link : records_[i].edge_links) {
			auto it = record_by_form_.find(link.target_navmesh_form_id);
			if (it == record_by_form_.end()) {
				stats_.unresolved_edge_link_targets++;
				continue;
			}
			if (std::find(adj.begin(), adj.end(), it->second) == adj.end()) {
				adj.push_back(it->second);
			}
		}
	}

	stats_.index_ms += ms_since(t_index);
}

void NavmeshDatabase::build_cross_record_links() {
	auto t_stitch = Clock::now();

	// Each flagged NVTR edge names the NVEX link it crosses: this triangle,
	// across that edge, to the NVEX target triangle. Both directions are
	// stored, each knowing the edge it crosses.
	for (size_t i = 0; i < records_.size(); ++i) {
		const NavMeshRecord &from = records_[i];
		for (size_t t = 0; t < from.triangles.size(); ++t) {
			const Triangle &tri = from.triangles[t];
			for (int e = 0; e < 3; ++e) {
				int32_t link_index = tri.edge_link[e];
				if (link_index < 0 || (size_t)link_index >= from.edge_links.size()) continue;
				const EdgeLink &link = from.edge_links[link_index];
				auto it = record_by_form_.find(link.target_navmesh_form_id);
				if (it == record_by_form_.end()) continue;
				const NavMeshRecord &to = records_[it->second];
				if (link.target_triangle_index >= to.triangles.size()) continue;

				uint32_t from_global = from.global_triangle_offset + (uint32_t)t;
				uint32_t to_global = to.global_triangle_offset + link.target_triangle_index;
				float cost = distance(triangle_centroid((uint32_t)i, (uint32_t)t), triangle_centroid(it->second, link.target_triangle_index));

				cross_links_[from_global].push_back(CrossRecordLink{ from_global, to_global, cost, from_global, (uint8_t)e });
				cross_links_[to_global].push_back(CrossRecordLink{ to_global, from_global, cost, from_global, (uint8_t)e });
				stats_.derived_cross_links++;
			}
		}
	}

	stats_.stitch_ms += ms_since(t_stitch);

	size_t bytes = 0;
	for (const NavMeshRecord &r : records_) {
		bytes += r.vertices.size() * sizeof(Vec3);
		bytes += r.triangles.size() * sizeof(Triangle);
		bytes += r.edge_links.size() * sizeof(EdgeLink);
		bytes += r.door_links.size() * sizeof(DoorLink);
		bytes += sizeof(NavMeshRecord);
	}
	for (const auto &adj : coarse_adjacency_) bytes += adj.size() * sizeof(uint32_t);
	for (const auto &kv : cross_links_) bytes += kv.second.size() * sizeof(CrossRecordLink) + sizeof(uint32_t);
	stats_.resident_bytes = bytes;
}

void NavmeshDatabase::build_components() {
	// Union-find over every triangle, joined by authored in-record adjacency and
	// by the cross-record links. What comes out is the set of regions an
	// actor can actually walk between without using a door.
	//
	// This exists because "same space" does not mean "reachable". NCR
	// Correctional Facility sits in the exterior worldspace but inside a fence,
	// and its yard is only reachable through a building -- so a same-space route
	// into it has no walkable path at all, and without this it fell back to a
	// straight line clipping through the fence.
	triangle_component_.assign(total_triangles_, 0);
	std::vector<uint32_t> parent(total_triangles_);
	for (uint32_t i = 0; i < total_triangles_; ++i) parent[i] = i;
	std::function<uint32_t(uint32_t)> find = [&](uint32_t x) {
		while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
		return x;
	};
	auto join = [&](uint32_t a, uint32_t b) {
		a = find(a); b = find(b);
		if (a != b) parent[a] = b;
	};

	for (const NavMeshRecord &record : records_) {
		for (size_t t = 0; t < record.triangles.size(); ++t) {
			for (int e = 0; e < 3; ++e) {
				int32_t neighbor = record.triangles[t].edge[e];
				if (neighbor < 0 || (size_t)neighbor >= record.triangles.size()) continue;
				join(record.global_triangle_offset + (uint32_t)t, record.global_triangle_offset + (uint32_t)neighbor);
			}
		}
	}
	for (const auto &entry : cross_links_) {
		for (const CrossRecordLink &link : entry.second) {
			join(link.from_global_triangle, link.to_global_triangle);
		}
	}

	std::unordered_map<uint32_t, uint32_t> label;
	for (uint32_t i = 0; i < total_triangles_; ++i) {
		uint32_t root = find(i);
		auto it = label.find(root);
		if (it == label.end()) {
			uint32_t next = (uint32_t)label.size();
			label[root] = next;
			triangle_component_[i] = next;
		} else {
			triangle_component_[i] = it->second;
		}
	}
	component_count_ = (uint32_t)label.size();
	stats_.components = component_count_;
}

const NavMeshRecord *NavmeshDatabase::record_by_form_id(uint32_t form_id) const {
	auto it = record_by_form_.find(form_id);
	return it == record_by_form_.end() ? nullptr : &records_[it->second];
}

const std::vector<uint32_t> &NavmeshDatabase::records_in_space(uint32_t space_form_id) const {
	auto it = records_by_space_.find(space_form_id);
	return it == records_by_space_.end() ? kEmptyIndices : it->second;
}

std::vector<uint32_t> NavmeshDatabase::spaces() const {
	std::vector<uint32_t> result;
	result.reserve(records_by_space_.size());
	for (const auto &kv : records_by_space_) result.push_back(kv.first);
	std::sort(result.begin(), result.end());
	return result;
}

const std::vector<uint32_t> &NavmeshDatabase::coarse_neighbors(uint32_t record_index) const {
	return record_index < coarse_adjacency_.size() ? coarse_adjacency_[record_index] : kEmptyIndices;
}

bool NavmeshDatabase::triangle_corners(uint32_t record_index, uint32_t local_triangle,
		Vec3 *a, Vec3 *b, Vec3 *c) const {
	if (record_index >= records_.size()) return false;
	const NavMeshRecord &r = records_[record_index];
	if (local_triangle >= r.triangles.size()) return false;
	const Triangle &t = r.triangles[local_triangle];
	if (t.vertex[0] >= r.vertices.size() || t.vertex[1] >= r.vertices.size() || t.vertex[2] >= r.vertices.size()) return false;
	*a = r.vertices[t.vertex[0]];
	*b = r.vertices[t.vertex[1]];
	*c = r.vertices[t.vertex[2]];
	return true;
}

namespace {

Vec3 subtract(const Vec3 &p, const Vec3 &q) { return { p.x - q.x, p.y - q.y, p.z - q.z }; }
float dot_product(const Vec3 &p, const Vec3 &q) { return p.x * q.x + p.y * q.y + p.z * q.z; }

// Closest points between segments p1-q1 and p2-q2 (Ericson, Real-Time
// Collision Detection 5.1.9); returns their distance.
float closest_segment_points(const Vec3 &p1, const Vec3 &q1, const Vec3 &p2, const Vec3 &q2, Vec3 *c1, Vec3 *c2) {
	Vec3 d1 = subtract(q1, p1), d2 = subtract(q2, p2), r = subtract(p1, p2);
	float a = dot_product(d1, d1), e = dot_product(d2, d2), f = dot_product(d2, r);
	float s = 0.0f, t = 0.0f;
	if (a > 1e-9f || e > 1e-9f) {
		if (a <= 1e-9f) {
			t = std::clamp(f / e, 0.0f, 1.0f);
		} else {
			float c = dot_product(d1, r);
			if (e <= 1e-9f) {
				s = std::clamp(-c / a, 0.0f, 1.0f);
			} else {
				float b = dot_product(d1, d2), denominator = a * e - b * b;
				s = denominator != 0.0f ? std::clamp((b * f - c * e) / denominator, 0.0f, 1.0f) : 0.0f;
				t = (b * s + f) / e;
				if (t < 0.0f) {
					t = 0.0f;
					s = std::clamp(-c / a, 0.0f, 1.0f);
				} else if (t > 1.0f) {
					t = 1.0f;
					s = std::clamp((b - c) / a, 0.0f, 1.0f);
				}
			}
		}
	}
	*c1 = { p1.x + d1.x * s, p1.y + d1.y * s, p1.z + d1.z * s };
	*c2 = { p2.x + d2.x * t, p2.y + d2.y * t, p2.z + d2.z * t };
	Vec3 gap = subtract(*c1, *c2);
	return std::sqrt(dot_product(gap, gap));
}

// Each open edge of a record as its two end points.
std::vector<std::pair<Vec3, Vec3>> open_edges(const NavMeshRecord &record) {
	std::vector<std::pair<Vec3, Vec3>> edges;
	for (const Triangle &t : record.triangles) {
		for (int e = 0; e < 3; ++e) {
			if (t.edge[e] != -1) continue;
			uint16_t i0 = t.vertex[e], i1 = t.vertex[(e + 1) % 3];
			if (i0 >= record.vertices.size() || i1 >= record.vertices.size()) continue;
			edges.push_back({ record.vertices[i0], record.vertices[i1] });
		}
	}
	return edges;
}

} // namespace

float NavmeshDatabase::closest_open_edge_points(uint32_t record_a, uint32_t record_b, Vec3 *point_a, Vec3 *point_b) const {
	const NavMeshRecord *a = record_at(record_a);
	const NavMeshRecord *b = record_at(record_b);
	if (a == nullptr || b == nullptr) return FLT_MAX;
	auto edges_a = open_edges(*a);
	auto edges_b = open_edges(*b);
	float best = FLT_MAX;
	for (auto &edge_a : edges_a) {
		for (auto &edge_b : edges_b) {
			Vec3 c1, c2;
			float distance = closest_segment_points(edge_a.first, edge_a.second, edge_b.first, edge_b.second, &c1, &c2);
			if (distance < best) {
				best = distance;
				*point_a = c1;
				*point_b = c2;
			}
		}
	}
	return best;
}

Vec3 NavmeshDatabase::triangle_centroid(uint32_t record_index, uint32_t local_triangle) const {
	if (record_index >= records_.size()) return Vec3();
	const NavMeshRecord &r = records_[record_index];
	if (local_triangle >= r.triangles.size()) return Vec3();
	const Triangle &t = r.triangles[local_triangle];
	Vec3 sum;
	for (int i = 0; i < 3; ++i) {
		uint16_t vi = t.vertex[i];
		if (vi < r.vertices.size()) sum = add(sum, r.vertices[vi]);
	}
	return mul(sum, 1.0f / 3.0f);
}

bool NavmeshDatabase::resolve_global_triangle(uint32_t global_triangle, uint32_t *out_record, uint32_t *out_local) const {
	if (global_triangle >= total_triangles_ || record_triangle_offsets_.empty()) return false;
	auto it = std::upper_bound(record_triangle_offsets_.begin(), record_triangle_offsets_.end(), global_triangle);
	size_t index = (size_t)(it - record_triangle_offsets_.begin()) - 1;
	if (index >= records_.size()) return false;
	if (out_record) *out_record = (uint32_t)index;
	if (out_local) *out_local = global_triangle - record_triangle_offsets_[index];
	return true;
}

namespace {

// Orders edge (a, b) of triangle (a, b, c) as a gate's left and right, seen
// travelling out of that triangle across the edge (`leaving`) or into it.
void orient_gate(const Vec3 &a, const Vec3 &b, const Vec3 &c, bool leaving, Vec3 *left, Vec3 *right) {
	bool swap = signed_area_xy(a, b, c) < 0.0f;
	if (!leaving) swap = !swap;
	*left = swap ? b : a;
	*right = swap ? a : b;
}

// Distance from segment (p, q) to triangle (a, b, c): its edges, and the
// segment's ends and middle over the triangle.
float segment_triangle_distance(const Vec3 &p, const Vec3 &q, const Vec3 &a, const Vec3 &b, const Vec3 &c) {
	Vec3 c1, c2;
	float best = closest_segment_points(p, q, a, b, &c1, &c2);
	best = std::min(best, closest_segment_points(p, q, b, c, &c1, &c2));
	best = std::min(best, closest_segment_points(p, q, c, a, &c1, &c2));
	Vec3 middle = mul(add(p, q), 0.5f);
	for (const Vec3 &point : { p, q, middle }) {
		best = std::min(best, distance(point, closest_point_on_triangle(point, a, b, c)));
	}
	return best;
}

} // namespace

bool NavmeshDatabase::in_record_gate(uint32_t here, uint32_t next, Vec3 *left, Vec3 *right) const {
	uint32_t record_index = 0, local = 0, next_local = 0;
	if (!resolve_global_triangle(here, &record_index, &local)) return false;
	if (!resolve_global_triangle(next, nullptr, &next_local)) return false;
	const NavMeshRecord &record = records_[record_index];
	if (local >= record.triangles.size()) return false;
	const Triangle &tri = record.triangles[local];
	// Edge slot e spans vertices e and (e+1)%3 -- the xEdit schema's own
	// field naming ("Edge 0-1", "Edge 1-2", "Edge 2-0").
	for (int e = 0; e < 3; ++e) {
		if (tri.edge[e] < 0 || (uint32_t)tri.edge[e] != next_local) continue;
		uint16_t a = tri.vertex[e], b = tri.vertex[(e + 1) % 3], c = tri.vertex[(e + 2) % 3];
		if (a >= record.vertices.size() || b >= record.vertices.size() || c >= record.vertices.size()) return false;
		orient_gate(record.vertices[a], record.vertices[b], record.vertices[c], true, left, right);
		return true;
	}
	return false;
}

bool NavmeshDatabase::crossing_gate(uint32_t here, uint32_t next, Vec3 *left, Vec3 *right) const {
	auto links = cross_links_.find(here);
	if (links == cross_links_.end()) return false;
	for (const CrossRecordLink &link : links->second) {
		if (link.to_global_triangle != next) continue;
		uint32_t edge_record = 0, edge_local = 0, other_record = 0, other_local = 0;
		uint32_t other = link.edge_global_triangle == here ? next : here;
		if (!resolve_global_triangle(link.edge_global_triangle, &edge_record, &edge_local)) continue;
		if (!resolve_global_triangle(other, &other_record, &other_local)) continue;
		const NavMeshRecord &record = records_[edge_record];
		const Triangle &tri = record.triangles[edge_local];
		uint16_t a = tri.vertex[link.edge_slot], b = tri.vertex[(link.edge_slot + 1) % 3], c = tri.vertex[(link.edge_slot + 2) % 3];
		if (a >= record.vertices.size() || b >= record.vertices.size() || c >= record.vertices.size()) continue;
		Vec3 o0, o1, o2;
		if (!triangle_corners(other_record, other_local, &o0, &o1, &o2)) continue;
		if (segment_triangle_distance(record.vertices[a], record.vertices[b], o0, o1, o2) > MAX_GATE_GAP) continue;
		orient_gate(record.vertices[a], record.vertices[b], record.vertices[c], link.edge_global_triangle == here, left, right);
		return true;
	}
	return false;
}

std::vector<Vec3> NavmeshDatabase::build_waypoints(const std::vector<uint32_t> &triangle_path,
		const Vec3 &start, const Vec3 &goal) const {
	if (triangle_path.empty()) return { start, goal };
	std::vector<Vec3> waypoints;
	std::vector<Gate> gates;
	Vec3 run_from = start;
	auto finish_run = [&](const Vec3 &run_to) {
		for (const Vec3 &p : funnel(run_from, run_to, gates)) {
			if (waypoints.empty() || distance_sq(waypoints.back(), p) > 1e-6f) waypoints.push_back(p);
		}
		gates.clear();
	};

	for (size_t i = 0; i + 1 < triangle_path.size(); ++i) {
		uint32_t here = triangle_path[i], next = triangle_path[i + 1];
		uint32_t here_record = 0, next_record = 0, here_local = 0, next_local = 0;
		if (!resolve_global_triangle(here, &here_record, &here_local)) continue;
		if (!resolve_global_triangle(next, &next_record, &next_local)) continue;
		Gate gate;
		if (here_record == next_record) {
			// Not edge-adjacent: no gate, the corridor stays open here.
			if (in_record_gate(here, next, &gate.left, &gate.right)) gates.push_back(gate);
			continue;
		}
		if (crossing_gate(here, next, &gate.left, &gate.right)) {
			gates.push_back(gate);
			continue;
		}
		// No usable crossing gate: this funnel ends at the point of `here`
		// closest to `next`, and the next one starts at the point of `next`
		// closest to `here`.
		Vec3 a0, a1, a2, b0, b1, b2, from_here, to_next;
		if (!triangle_corners(here_record, here_local, &a0, &a1, &a2) || !triangle_corners(next_record, next_local, &b0, &b1, &b2)) continue;
		closest_points_between_triangles(a0, a1, a2, b0, b1, b2, &from_here, &to_next);
		finish_run(from_here);
		run_from = to_next;
	}
	finish_run(goal);

	if (waypoints.empty()) return { start, goal };
	if (distance_sq(waypoints.back(), goal) > 1e-6f) waypoints.push_back(goal);
	return waypoints;
}

// Known limitation, stated rather than hidden: this is a sampled test, not an
// exact one. A gap narrower than roughly sample_spacing + 2*tolerance can fall
// between two samples that both land on mesh, so a shortcut may bridge a thin
// crack. Tightening either parameter shrinks the window at proportional cost.
// An exact answer would mean walking the triangle corridor instead of sampling.
std::vector<Vec3> NavmeshDatabase::project_onto_navmesh(uint32_t space_form_id,
		const std::vector<Vec3> &waypoints, float step, float search_radius, float keep_tolerance) const {
	// Seats the path's HEIGHT on the real surface without touching its shape.
	//
	// Why insert-only: the funnel already produces waypoints that lie exactly on
	// the mesh (they are triangle corners) with every segment inside the walkable
	// corridor. Measured, that path is 0.00% off-mesh. Earlier versions of this
	// pass also resampled and re-simplified it, and both attempts pushed
	// waypoints OFF the mesh -- 6.7% and then 11.9% -- because moving or dropping
	// a point can cut a corner out of the corridor the funnel guaranteed.
	//
	// So this only ever ADDS points along existing segments and never moves or
	// removes one. Inserted points keep the segment's own XY (still inside the
	// corridor) and take their height from the surface beneath, queried from the
	// height already being walked so overlapping floors stay distinguished. A
	// sample with no surface near that height is simply not inserted, leaving the
	// original segment untouched rather than fabricating a point.
	//
	// This matters because navmesh overlaps vertically: a path floating off its
	// own floor can snap an actor onto the wrong one when it physicalises.
	(void)keep_tolerance;
	if (waypoints.size() < 2) return waypoints;

	std::vector<Vec3> result;
	result.reserve(waypoints.size() * 2);
	float running_z = waypoints.front().z;

	for (size_t i = 0; i + 1 < waypoints.size(); ++i) {
		const Vec3 &a = waypoints[i];
		const Vec3 &b = waypoints[i + 1];
		result.push_back(a);
		running_z = a.z;

		float span = std::sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y));
		int steps = (int)(span / std::max(step, 0.5f));
		if (steps > 512) steps = 512;
		for (int sample = 1; sample < steps; ++sample) {
			float t = (float)sample / (float)steps;
			Vec3 probe{ a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, running_z };
			SnapResult hit = snap(space_form_id, probe, search_radius, true);
			if (!hit.found) continue;
			// snap() returns the closest point on a triangle, which sits at a
			// different XY when the probe is horizontally outside every triangle.
			// Pairing the probe's XY with that height would place a waypoint off
			// the mesh -- the very thing this pass exists to prevent -- so only
			// accept a hit that is genuinely below or above the probe.
			float horizontal_offset = std::sqrt(
					(hit.position.x - probe.x) * (hit.position.x - probe.x) +
					(hit.position.y - probe.y) * (hit.position.y - probe.y));
			if (horizontal_offset > 0.5f) continue;
			float interpolated_z = a.z + (b.z - a.z) * t;
			running_z = hit.position.z;
			// Only worth a waypoint where the surface actually departs from the
			// straight interpolation; otherwise the segment already describes it.
			if (std::fabs(hit.position.z - interpolated_z) > 0.35f) {
				result.push_back(Vec3{ probe.x, probe.y, hit.position.z });
			}
		}
	}
	result.push_back(waypoints.back());
	return result;
}

bool NavmeshDatabase::segment_stays_on_navmesh(uint32_t space_form_id, const Vec3 &from, const Vec3 &to,
		float tolerance, float sample_spacing) const {
	// Walks the segment tracking the height of the surface underneath, rather
	// than testing against the linearly interpolated height. Two reasons:
	//
	//  - Interpolated height drifts off uneven ground, so a test against it
	//    either rejects good shortcuts on hills or (with a loose tolerance)
	//    accepts ones that leave the mesh.
	//  - Navmesh overlaps vertically. Snapping from the height already being
	//    walked keeps the test on ONE floor; a shortcut that would hop to a
	//    walkway overhead or a room below fails the per-step rise limit instead
	//    of silently passing because some triangle happened to be nearby.
	float span = std::sqrt((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y));
	if (span <= sample_spacing) return true;
	int samples = (int)(span / sample_spacing);
	if (samples < 1) samples = 1;
	// Cap total work, but never let spacing degrade past 4 m -- a very long
	// shortcut must be rejected rather than waved through on coarse sampling.
	if (samples > 512) {
		if (span / 512.0f > 4.0f) return false;
		samples = 512;
	}
	// Largest step in surface height allowed between adjacent samples. Real
	// walkable slopes stay well under this; a level change does not.
	const float max_rise_per_sample = 1.5f + sample_spacing;
	float running_z = from.z;
	for (int i = 1; i < samples; ++i) {
		float t = (float)i / (float)samples;
		Vec3 probe{ from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t, running_z };
		SnapResult hit = snap(space_form_id, probe, tolerance, true);
		if (!hit.found) return false;
		// The sample must be directly OVER mesh. snap() alone is not enough: it
		// returns the closest point on a triangle, so a probe hanging over a gap
		// still "finds" the mesh at the gap's rim. Requiring the hit to be
		// beneath the probe is what stops a shortcut spanning a hole.
		float horizontal_offset = std::sqrt(
				(hit.position.x - probe.x) * (hit.position.x - probe.x) +
				(hit.position.y - probe.y) * (hit.position.y - probe.y));
		if (horizontal_offset > 0.5f) return false;
		if (std::fabs(hit.position.z - running_z) > max_rise_per_sample) return false;
		running_z = hit.position.z;
	}
	// The shortcut must also finish on the floor it started on, not merely end
	// somewhere near the target point.
	return std::fabs(running_z - to.z) <= max_rise_per_sample * 2.0f;
}

std::vector<Vec3> NavmeshDatabase::simplify_by_line_of_sight(uint32_t space_form_id,
		const std::vector<Vec3> &waypoints, float tolerance, int max_lookahead) const {
	// The funnel runs per record, so a path crossing many records still turns
	// at every seam even where the ground is open. This pass removes a waypoint
	// only when the shortcut past it is SAMPLED and found to stay on real
	// navmesh -- so it can straighten across seams without ever inventing a
	// line over a gap, which is the failure mode that matters here.
	if (waypoints.size() <= 2) return waypoints;
	std::vector<Vec3> result;
	result.push_back(waypoints.front());
	size_t anchor = 0;
	while (anchor + 1 < waypoints.size()) {
		size_t best_next = anchor + 1;
		size_t limit = anchor + (size_t)max_lookahead;
		if (limit >= waypoints.size()) limit = waypoints.size() - 1;
		for (size_t candidate = limit; candidate > anchor + 1; --candidate) {
			if (segment_stays_on_navmesh(space_form_id, waypoints[anchor], waypoints[candidate], tolerance, 1.5f)) {
				best_next = candidate;
				break;
			}
		}
		result.push_back(waypoints[best_next]);
		anchor = best_next;
	}
	return result;
}

SnapResult NavmeshDatabase::snap(uint32_t space_form_id, const Vec3 &position, float max_distance,
		bool use_coarse_index) const {
	SnapResult result;
	const std::vector<uint32_t> &candidates = records_in_space(space_form_id);
	float best_dist_sq = max_distance > 0.0f ? max_distance * max_distance : std::numeric_limits<float>::max();

	for (uint32_t ri : candidates) {
		const NavMeshRecord &r = records_[ri];
		if (use_coarse_index) {
			// Authored NVGD bounds reject whole records before any triangle is
			// touched. Present on 100% of records, so this never falls back.
			if (!r.bounds.contains_xy(position, max_distance)) continue;
			if (position.z < r.bounds.min.z - max_distance || position.z > r.bounds.max.z + max_distance) continue;
		}
		for (size_t t = 0; t < r.triangles.size(); ++t) {
			const Triangle &tri = r.triangles[t];
			if (tri.vertex[0] >= r.vertices.size() || tri.vertex[1] >= r.vertices.size() || tri.vertex[2] >= r.vertices.size()) continue;
			Vec3 cp = closest_point_on_triangle(position,
					r.vertices[tri.vertex[0]], r.vertices[tri.vertex[1]], r.vertices[tri.vertex[2]]);
			float d = distance_sq(cp, position);
			if (d < best_dist_sq) {
				best_dist_sq = d;
				result.found = true;
				result.position = cp;
				result.navmesh_form_id = r.form_id;
				result.local_triangle = (uint32_t)t;
				result.global_triangle = r.global_triangle_offset + (uint32_t)t;
				result.cell_form_id = r.cell_form_id;
				result.component = component_of_triangle(result.global_triangle);
			}
		}
	}
	if (result.found) result.distance = std::sqrt(best_dist_sq);
	return result;
}

RouteResult NavmeshDatabase::route(uint32_t space_form_id, const Vec3 &from, const Vec3 &to,
		float snap_radius, bool use_coarse_index) const {
	RouteResult result;
	SnapResult start = snap(space_form_id, from, snap_radius, use_coarse_index);
	SnapResult goal = snap(space_form_id, to, snap_radius, use_coarse_index);
	if (!start.found || !goal.found) return result;

	if (start.global_triangle == goal.global_triangle) {
		result.found = true;
		result.waypoints = { start.position, goal.position };
		result.triangles = { start.global_triangle };
		result.length = distance(start.position, goal.position);
		return result;
	}

	// A* over triangles: in-record neighbours come from authored NVTR edges,
	// record crossings from the flagged-edge cross-record links. A triangle is
	// entered at a point on the edge crossed into it (the start triangle at the
	// start point): the point of that edge closest to the line from the
	// previous entry point to the goal, where a straight walk would cross it.
	// A step costs the distance between entry points, and the heuristic is the
	// distance from the entry point to the goal. Centroid or edge-midpoint
	// costs mislead in fans of long thin triangles, where those points lie far
	// from where a walk crosses.
	std::unordered_map<uint32_t, float> g_score;
	std::unordered_map<uint32_t, uint32_t> came_from;
	std::unordered_map<uint32_t, Vec3> entry_point;
	using Entry = std::pair<float, uint32_t>; // (f score, global triangle)
	std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> open;

	g_score[start.global_triangle] = 0.0f;
	entry_point[start.global_triangle] = start.position;
	open.push({ distance(start.position, goal.position), start.global_triangle });

	bool reached = false;
	while (!open.empty()) {
		Entry current = open.top();
		open.pop();
		uint32_t node = current.second;
		result.visited_nodes++;

		if (node == goal.global_triangle) { reached = true; break; }

		auto g_it = g_score.find(node);
		if (g_it == g_score.end()) continue;
		float node_g = g_it->second;
		Vec3 node_entry = entry_point[node];

		uint32_t ri = 0, li = 0;
		if (!resolve_global_triangle(node, &ri, &li)) continue;
		const NavMeshRecord &r = records_[ri];

		auto consider = [&](uint32_t neighbor, const Vec3 &edge_a, const Vec3 &edge_b) {
			Vec3 crossing, on_line;
			closest_segment_points(edge_a, edge_b, node_entry, goal.position, &crossing, &on_line);
			float tentative = node_g + distance(node_entry, crossing);
			auto it = g_score.find(neighbor);
			if (it != g_score.end() && it->second <= tentative) return;
			g_score[neighbor] = tentative;
			came_from[neighbor] = node;
			entry_point[neighbor] = crossing;
			open.push({ tentative + distance(crossing, goal.position), neighbor });
		};

		if (li < r.triangles.size()) {
			const Triangle &tri = r.triangles[li];
			for (int e = 0; e < 3; ++e) {
				int32_t nb = tri.edge[e];
				if (nb < 0 || (size_t)nb >= r.triangles.size()) continue;
				uint16_t a = tri.vertex[e], b = tri.vertex[(e + 1) % 3];
				if (a >= r.vertices.size() || b >= r.vertices.size()) continue;
				consider(r.global_triangle_offset + (uint32_t)nb, r.vertices[a], r.vertices[b]);
			}
		}
		auto cross = cross_links_.find(node);
		if (cross != cross_links_.end()) {
			for (const CrossRecordLink &link : cross->second) {
				uint32_t edge_record = 0, edge_local = 0;
				if (!resolve_global_triangle(link.edge_global_triangle, &edge_record, &edge_local)) continue;
				const NavMeshRecord &er = records_[edge_record];
				const Triangle &et = er.triangles[edge_local];
				uint16_t a = et.vertex[link.edge_slot], b = et.vertex[(link.edge_slot + 1) % 3];
				if (a >= er.vertices.size() || b >= er.vertices.size()) continue;
				consider(link.to_global_triangle, er.vertices[a], er.vertices[b]);
			}
		}
	}

	if (!reached) return result;

	std::vector<uint32_t> path;
	uint32_t node = goal.global_triangle;
	path.push_back(node);
	while (node != start.global_triangle) {
		auto it = came_from.find(node);
		if (it == came_from.end()) return result; // broken chain, report no route
		node = it->second;
		path.push_back(node);
	}
	std::reverse(path.begin(), path.end());

	result.found = true;
	result.triangles = path;
	result.waypoints = project_onto_navmesh(space_form_id,
			simplify_by_line_of_sight(space_form_id,
					build_waypoints(path, start.position, goal.position)));
	for (size_t i = 1; i < result.waypoints.size(); ++i) {
		result.length += distance(result.waypoints[i - 1], result.waypoints[i]);
	}
	return result;
}

} // namespace nav
