// Answers: when an NVTR triangle's Flags has bit e set (0x01 Edge 0-1,
// 0x02 Edge 1-2, 0x04 Edge 2-0), is that edge's value an index into the
// record's NVEX Edge Links -- naming exactly which local edge each
// cross-record link leaves from?
//
// Tests over every NAVM in the masters given:
//   flagged edges: value in [0, NVEX count)?  the linked target triangle's
//                  nearest point within 0.5 m / 2 m of this edge (metres)?
//   NVEX coverage: how many NVEX entries some flagged edge names.
//   unflagged edges: how many hold a value >= 0 (an in-record neighbour) vs -1.
//
//   tools/navm_edge_link_flag_census ../fresh_nv_copy/Data/FalloutNV.esm
#include "esm/esm_file.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <unordered_map>
#include <vector>

struct V { float x, y, z; };
struct Tri { uint16_t v[3]; int16_t e[3]; uint16_t flags; };
struct Link { uint32_t target; uint16_t tri; };
struct Mesh { std::vector<V> verts; std::vector<Tri> tris; std::vector<Link> links; };

static uint32_t rd_u32(const uint8_t *d, size_t n, size_t o) { return o + 4 > n ? 0 : d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (uint32_t(d[o + 3]) << 24); }
static uint16_t rd_u16(const uint8_t *d, size_t n, size_t o) { return o + 2 > n ? 0 : d[o] | (d[o + 1] << 8); }
static float rd_f(const uint8_t *d, size_t n, size_t o) { uint32_t u = rd_u32(d, n, o); float f; memcpy(&f, &u, 4); return f; }

static V sub(V a, V b) { return { a.x - b.x, a.y - b.y, a.z - b.z }; }
static float dot(V a, V b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static float dist_point_segment(V p, V a, V b) {
	V ab = sub(b, a);
	float len = dot(ab, ab);
	float t = len > 0 ? dot(sub(p, a), ab) / len : 0;
	t = t < 0 ? 0 : (t > 1 ? 1 : t);
	V c = { a.x + ab.x * t, a.y + ab.y * t, a.z + ab.z * t };
	V d = sub(p, c);
	return std::sqrt(dot(d, d));
}
// Smallest distance between segment [a,b] and triangle t's edges (metres).
static float segment_to_triangle(V a, V b, const Mesh &m, const Tri &t) {
	float best = 1e30f;
	for (int e = 0; e < 3; ++e) {
		V p = m.verts[t.v[e]], q = m.verts[t.v[(e + 1) % 3]];
		for (int s = 0; s <= 8; ++s) {
			float k = s / 8.0f;
			V on = { p.x + (q.x - p.x) * k, p.y + (q.y - p.y) * k, p.z + (q.z - p.z) * k };
			float d = dist_point_segment(on, a, b);
			if (d < best) best = d;
		}
	}
	return best;
}

int main(int argc, char **argv) {
	std::unordered_map<uint32_t, Mesh> meshes;
	for (int i = 1; i < argc; ++i) {
		esm::EsmFile file;
		try { file.open(argv[i]); } catch (const std::exception &e) { fprintf(stderr, "%s: %s\n", argv[i], e.what()); continue; }
		file.for_each_record([&](const esm::RecordInfo &rec) {
			if (rec.type != "NAVM") return;
			std::vector<uint8_t> raw;
			try { raw = file.read_record_data(rec); } catch (...) { return; }
			Mesh m;
			uint32_t vc = 0, tc = 0, lc = 0;
			auto subs = esm::EsmFile::parse_subrecords(raw);
			for (auto &s : subs) if (s.type == "DATA") { vc = rd_u32(s.data, s.size, 4); tc = rd_u32(s.data, s.size, 8); lc = rd_u32(s.data, s.size, 12); }
			for (auto &s : subs) {
				if (s.type == "NVVX") {
					size_t c = std::min<size_t>(vc ? vc : s.size / 12, s.size / 12);
					for (size_t k = 0; k < c; ++k) m.verts.push_back({ rd_f(s.data, s.size, k * 12) / 70.0f, rd_f(s.data, s.size, k * 12 + 4) / 70.0f, rd_f(s.data, s.size, k * 12 + 8) / 70.0f });
				} else if (s.type == "NVTR") {
					size_t c = std::min<size_t>(tc ? tc : s.size / 16, s.size / 16);
					for (size_t k = 0; k < c; ++k) {
						Tri t;
						size_t o = k * 16;
						for (int j = 0; j < 3; ++j) t.v[j] = rd_u16(s.data, s.size, o + j * 2);
						for (int j = 0; j < 3; ++j) t.e[j] = (int16_t)rd_u16(s.data, s.size, o + 6 + j * 2);
						t.flags = rd_u16(s.data, s.size, o + 12);
						m.tris.push_back(t);
					}
				} else if (s.type == "NVEX") {
					size_t c = std::min<size_t>(lc ? lc : s.size / 10, s.size / 10);
					for (size_t k = 0; k < c; ++k) m.links.push_back({ rd_u32(s.data, s.size, k * 10 + 4), rd_u16(s.data, s.size, k * 10 + 8) });
				}
			}
			meshes[rec.form_id] = std::move(m);
		});
	}
	uint64_t flagged = 0, flagged_in_range = 0, flagged_near_05 = 0, flagged_near_2 = 0, flagged_target_missing = 0;
	uint64_t unflagged = 0, unflagged_neighbour = 0, unflagged_minus_one = 0, unflagged_other = 0;
	uint64_t nvex_total = 0, nvex_named = 0;
	uint64_t flagged_but_value_minus_one = 0;
	// What the loader did before knowing the flags: an edge value >= the
	// record's triangle count was clamped as out of range; any other >= 0
	// value was taken as an in-record neighbour.
	uint64_t flagged_at_or_over_triangle_count = 0, flagged_read_as_neighbour = 0, unflagged_at_or_over_triangle_count = 0;
	for (auto &kv : meshes) {
		Mesh &m = kv.second;
		nvex_total += m.links.size();
		std::vector<bool> named(m.links.size(), false);
		for (const Tri &t : m.tris) {
			for (int e = 0; e < 3; ++e) {
				bool is_flagged = (t.flags >> e) & 1;
				int v = t.e[e];
				if (v >= 0 && (size_t)v >= m.tris.size()) {
					if (is_flagged) ++flagged_at_or_over_triangle_count;
					else ++unflagged_at_or_over_triangle_count;
				} else if (v >= 0 && is_flagged) {
					++flagged_read_as_neighbour;
				}
				if (!is_flagged) {
					++unflagged;
					if (v == -1) ++unflagged_minus_one;
					else if (v >= 0 && (size_t)v < m.tris.size()) ++unflagged_neighbour;
					else ++unflagged_other;
					continue;
				}
				++flagged;
				if (v == -1) { ++flagged_but_value_minus_one; continue; }
				if (v < 0 || (size_t)v >= m.links.size()) continue;
				++flagged_in_range;
				named[v] = true;
				const Link &link = m.links[v];
				auto it = meshes.find(link.target);
				if (it == meshes.end() || link.tri >= it->second.tris.size()) { ++flagged_target_missing; continue; }
				if (t.v[e] >= m.verts.size() || t.v[(e + 1) % 3] >= m.verts.size()) continue;
				const Tri &target = it->second.tris[link.tri];
				bool ok = true;
				for (int j = 0; j < 3; ++j) if (target.v[j] >= it->second.verts.size()) ok = false;
				if (!ok) continue;
				float d = segment_to_triangle(m.verts[t.v[e]], m.verts[t.v[(e + 1) % 3]], it->second, target);
				if (d <= 0.5f) ++flagged_near_05;
				if (d <= 2.0f) ++flagged_near_2;
			}
		}
		for (bool b : named) if (b) ++nvex_named;
	}
	printf("NAVM records: %zu\n", meshes.size());
	printf("flagged edges: %llu; value -1: %llu; value a valid NVEX index: %llu\n", (unsigned long long)flagged, (unsigned long long)flagged_but_value_minus_one, (unsigned long long)flagged_in_range);
	printf("  of those, target missing: %llu; target triangle within 0.5 m of the edge: %llu; within 2 m: %llu\n", (unsigned long long)flagged_target_missing, (unsigned long long)flagged_near_05, (unsigned long long)flagged_near_2);
	printf("NVEX entries: %llu; named by some flagged edge: %llu\n", (unsigned long long)nvex_total, (unsigned long long)nvex_named);
	printf("edge values >= triangle count (clamped by the old loader): flagged %llu, unflagged %llu\n", (unsigned long long)flagged_at_or_over_triangle_count, (unsigned long long)unflagged_at_or_over_triangle_count);
	printf("flagged edges the old loader read as in-record neighbours: %llu\n", (unsigned long long)flagged_read_as_neighbour);
	printf("unflagged edges: %llu; -1: %llu; in-record neighbour: %llu; other: %llu\n", (unsigned long long)unflagged, (unsigned long long)unflagged_minus_one, (unsigned long long)unflagged_neighbour, (unsigned long long)unflagged_other);
}
