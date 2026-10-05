// navm_seam_gap_census: how NAVM records meet, in FalloutNV.esm. An open edge
// is one whose NVTR neighbour is -1.
//
// 1. For every pair of records joined by NVEX (either direction), the smallest
//    3D distance between an open edge of one and an open edge of the other.
// 2. For every NVEX entry, the smallest distance from its authored target
//    triangle to an open edge of the source record: the gap at the link the
//    ESM actually names.
// 3. Pairs of records in one space that NVEX does not join but whose open
//    edges come within Godot's 0.25 m edge connection margin: joins an edge
//    connection would make that the ESM never authored.
//
//   tools/navm_seam_gap_census
#include "nav/navmesh_database.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace {

struct Segment {
	nav::Vec3 a, b;
};

nav::Vec3 sub(const nav::Vec3 &p, const nav::Vec3 &q) { return { p.x - q.x, p.y - q.y, p.z - q.z }; }
float dot(const nav::Vec3 &p, const nav::Vec3 &q) { return p.x * q.x + p.y * q.y + p.z * q.z; }

// Closest distance between two segments (Ericson, Real-Time Collision
// Detection 5.1.9).
float segment_distance(const Segment &s1, const Segment &s2) {
	nav::Vec3 d1 = sub(s1.b, s1.a), d2 = sub(s2.b, s2.a), r = sub(s1.a, s2.a);
	float a = dot(d1, d1), e = dot(d2, d2), f = dot(d2, r);
	float s = 0.0f, t = 0.0f;
	if (a <= 1e-9f && e <= 1e-9f) {
	} else if (a <= 1e-9f) {
		t = std::clamp(f / e, 0.0f, 1.0f);
	} else {
		float c = dot(d1, r);
		if (e <= 1e-9f) {
			s = std::clamp(-c / a, 0.0f, 1.0f);
		} else {
			float b = dot(d1, d2), denom = a * e - b * b;
			s = denom != 0.0f ? std::clamp((b * f - c * e) / denom, 0.0f, 1.0f) : 0.0f;
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
	nav::Vec3 p = { s1.a.x + d1.x * s, s1.a.y + d1.y * s, s1.a.z + d1.z * s };
	nav::Vec3 q = { s2.a.x + d2.x * t, s2.a.y + d2.y * t, s2.a.z + d2.z * t };
	nav::Vec3 d = sub(p, q);
	return std::sqrt(dot(d, d));
}

// Smallest distance from a triangle (its three edges) to any segment.
float triangle_to_segments(const nav::Vec3 &a, const nav::Vec3 &b, const nav::Vec3 &c, const std::vector<Segment> &segments) {
	float best = 1e9f;
	const Segment sides[3] = { { a, b }, { b, c }, { c, a } };
	for (auto &side : sides) {
		for (auto &segment : segments) best = std::min(best, segment_distance(side, segment));
	}
	return best;
}

std::vector<Segment> open_edges(const nav::NavMeshRecord &record) {
	std::vector<Segment> out;
	for (const nav::Triangle &t : record.triangles) {
		for (int e = 0; e < 3; ++e) {
			if (t.edge[e] != -1) continue;
			uint16_t i0 = t.vertex[e], i1 = t.vertex[(e + 1) % 3];
			if (i0 >= record.vertices.size() || i1 >= record.vertices.size()) continue;
			out.push_back({ record.vertices[i0], record.vertices[i1] });
		}
	}
	return out;
}

} // namespace

int main() {
	nav::NavmeshDatabase db;
	db.load({ "../fresh_nv_copy/Data/FalloutNV.esm" });
	std::set<std::pair<uint32_t, uint32_t>> pairs;
	for (uint32_t i = 0; db.record_at(i) != nullptr; ++i) {
		for (uint32_t j : db.coarse_neighbors(i)) {
			if (i != j) pairs.insert({ std::min(i, j), std::max(i, j) });
		}
	}
	const float buckets[] = { 0.01f, 0.1f, 0.25f, 0.5f, 1.0f, 2.0f, 4.0f, 1e9f };
	const char *labels[] = { "<=0.01", "<=0.1", "<=0.25", "<=0.5", "<=1", "<=2", "<=4", ">4" };
	std::map<int, int> interior, exterior;
	std::vector<std::pair<float, std::pair<uint32_t, uint32_t>>> worst_interior;
	for (auto &[i, j] : pairs) {
		const nav::NavMeshRecord *a = db.record_at(i);
		const nav::NavMeshRecord *b = db.record_at(j);
		auto ea = open_edges(*a), eb = open_edges(*b);
		float best = 1e9f;
		for (auto &s1 : ea) {
			for (auto &s2 : eb) best = std::min(best, segment_distance(s1, s2));
		}
		int bucket = 0;
		while (best > buckets[bucket]) bucket++;
		(a->is_exterior ? exterior : interior)[bucket]++;
		if (!a->is_exterior) worst_interior.push_back({ best, { a->form_id, b->form_id } });
	}
	std::printf("NVEX-joined record pairs: %zu\n", pairs.size());
	std::printf("closest open-edge gap, metres (exterior | interior):\n");
	for (int k = 0; k < 8; ++k) std::printf("  %-7s %6d | %6d\n", labels[k], exterior[k], interior[k]);
	// 2. Authored link gaps.
	std::map<int, int> link_interior, link_exterior;
	for (uint32_t i = 0; db.record_at(i) != nullptr; ++i) {
		const nav::NavMeshRecord *source = db.record_at(i);
		auto source_edges = open_edges(*source);
		for (const nav::EdgeLink &link : source->edge_links) {
			const nav::NavMeshRecord *target = db.record_by_form_id(link.target_navmesh_form_id);
			if (target == nullptr || link.target_triangle_index >= target->triangles.size()) continue;
			const nav::Triangle &t = target->triangles[link.target_triangle_index];
			if (t.vertex[0] >= target->vertices.size() || t.vertex[1] >= target->vertices.size() || t.vertex[2] >= target->vertices.size()) continue;
			float gap = triangle_to_segments(target->vertices[t.vertex[0]], target->vertices[t.vertex[1]], target->vertices[t.vertex[2]], source_edges);
			int bucket = 0;
			while (gap > buckets[bucket]) bucket++;
			(source->is_exterior ? link_exterior : link_interior)[bucket]++;
		}
	}
	std::printf("NVEX entries: target triangle to the source record's nearest open edge, metres (exterior | interior):\n");
	for (int k = 0; k < 8; ++k) std::printf("  %-7s %6d | %6d\n", labels[k], link_exterior[k], link_interior[k]);

	// 3. Unauthored joins within 0.25 m.
	constexpr float kMargin = 0.25f;
	int unlinked_pairs_checked = 0, unauthored_joins = 0;
	std::map<std::string, int> unauthored_by_gap;
	std::vector<std::string> unauthored_gapped;
	std::vector<std::string> unauthored_samples;
	for (uint32_t space : db.spaces()) {
		const auto &records = db.records_in_space(space);
		for (size_t x = 0; x < records.size(); ++x) {
			for (size_t y = x + 1; y < records.size(); ++y) {
				uint32_t i = records[x], j = records[y];
				if (pairs.count({ std::min(i, j), std::max(i, j) })) continue;
				const nav::NavMeshRecord *a = db.record_at(i);
				const nav::NavMeshRecord *b = db.record_at(j);
				if (a->bounds.max.x + kMargin < b->bounds.min.x || b->bounds.max.x + kMargin < a->bounds.min.x) continue;
				if (a->bounds.max.y + kMargin < b->bounds.min.y || b->bounds.max.y + kMargin < a->bounds.min.y) continue;
				if (a->bounds.max.z + kMargin < b->bounds.min.z || b->bounds.max.z + kMargin < a->bounds.min.z) continue;
				unlinked_pairs_checked++;
				auto ea = open_edges(*a), eb = open_edges(*b);
				float best = 1e9f;
				for (auto &s1 : ea) {
					for (auto &s2 : eb) best = std::min(best, segment_distance(s1, s2));
				}
				if (best <= kMargin) {
					unauthored_joins++;
					const char *gap = best <= 0.001f ? "<=0.001" : (best <= 0.01f ? "<=0.01" : (best <= 0.1f ? "<=0.1" : "<=0.25"));
					unauthored_by_gap[std::string(gap) + (a->is_exterior ? " exterior" : " interior")]++;
					if (best > 0.001f && unauthored_gapped.size() < 10) {
						char line[96];
						std::snprintf(line, sizeof line, "%08X-%08X %.3f m%s", a->form_id, b->form_id, best, a->is_exterior ? "" : " (interior)");
						unauthored_gapped.push_back(line);
					}
					if (unauthored_samples.size() < 8) {
						char line[96];
						std::snprintf(line, sizeof line, "%08X-%08X %.3f m%s", a->form_id, b->form_id, best, a->is_exterior ? "" : " (interior)");
						unauthored_samples.push_back(line);
					}
				}
			}
		}
	}
	std::printf("record pairs NVEX does not join, with overlapping bounds: %d; open edges within %.2f m: %d\n", unlinked_pairs_checked, kMargin, unauthored_joins);
	for (auto &[label, count] : unauthored_by_gap) std::printf("  %s: %d\n", label.c_str(), count);
	std::printf("  not coincident (examples):");
	for (auto &line : unauthored_gapped) std::printf(" %s;", line.c_str());
	std::printf("\n");

	std::sort(worst_interior.rbegin(), worst_interior.rend());
	std::printf("widest interior gaps:");
	for (size_t k = 0; k < worst_interior.size() && k < 6; ++k) std::printf(" %08X-%08X %.2f m;", worst_interior[k].second.first, worst_interior[k].second.second, worst_interior[k].first);
	std::printf("\n");
	return 0;
}
