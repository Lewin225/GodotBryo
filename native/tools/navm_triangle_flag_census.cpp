// Answers: what do NVTR's per-triangle Flags and Cover Flags (u16 each) hold?
// xEdit names them through wbNavmeshTriangleFlags / wbNavmeshCoverFlags, whose
// bodies are not in the vendored enginedocs/xEdit copy.
//
// Over every NAVM in the masters given:
//   per bit of Flags and of Cover Flags: triangles with it set;
//   cross-checks against what the record says independently:
//     NVDP door triangles, NVCA cover triangles, triangles with an open edge
//     (no neighbour, no link) and with a link-flagged edge.
//
//   tools/navm_triangle_flag_census ../fresh_nv_copy/Data/*.esm
#include "esm/esm_file.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <unordered_map>
#include <vector>

static uint32_t rd_u32(const uint8_t *d, size_t n, size_t o) { return o + 4 > n ? 0 : d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (uint32_t(d[o + 3]) << 24); }
static uint16_t rd_u16(const uint8_t *d, size_t n, size_t o) { return o + 2 > n ? 0 : d[o] | (d[o + 1] << 8); }

struct Tally {
	uint64_t total = 0;
	uint64_t flags_bit[16] = {};
	uint64_t cover_bit[16] = {};
};

int main(int argc, char **argv) {
	Tally all, door, cover_listed, open_edge, link_edge, no_open_edge;
	std::map<uint16_t, uint64_t> cover_values;
	uint64_t cover_nonzero_listed = 0, cover_nonzero_unlisted = 0, listed = 0;
	uint64_t cover_nonzero_without_open_edge = 0, cover_nonzero = 0;
	std::set<uint32_t> seen;
	// Cover groups: low six bits and next six; is the edge they would describe
	// (0-1, 1-2) open, and is edge 2-0 open?
	uint64_t group_set[2] = {}, group_edge_open[2][3] = {};
	// Flags 0x0010 / 0x0040 / 0x0200: triangles with the bit, and how many of
	// their in-record neighbours also have it.
	const uint16_t probe_bits[3] = { 0x0010, 0x0040, 0x0200 };
	uint64_t probe_neighbours[3] = {}, probe_neighbours_same[3] = {};
	std::map<uint32_t, uint64_t> probe_cells[3];
	auto add = [](Tally &t, uint16_t flags, uint16_t cover) {
		++t.total;
		for (int b = 0; b < 16; ++b) {
			if (flags & (1u << b)) ++t.flags_bit[b];
			if (cover & (1u << b)) ++t.cover_bit[b];
		}
	};
	for (int i = 1; i < argc; ++i) {
		esm::EsmFile file;
		try { file.open(argv[i]); } catch (const std::exception &e) { fprintf(stderr, "%s: %s\n", argv[i], e.what()); continue; }
		file.for_each_record([&](const esm::RecordInfo &rec) {
			if (rec.type != "NAVM" || !seen.insert(rec.form_id).second) return;
			std::vector<uint8_t> raw;
			try { raw = file.read_record_data(rec); } catch (...) { return; }
			uint32_t tc = 0;
			auto subs = esm::EsmFile::parse_subrecords(raw);
			uint32_t cell = 0;
			for (auto &s : subs) if (s.type == "DATA") { tc = rd_u32(s.data, s.size, 8); cell = rd_u32(s.data, s.size, 0); }
			std::set<uint16_t> doors, covers;
			const uint8_t *tr = nullptr;
			size_t tr_size = 0;
			for (auto &s : subs) {
				if (s.type == "NVTR") { tr = s.data; tr_size = s.size; }
				else if (s.type == "NVDP") { for (size_t o = 0; o + 8 <= s.size; o += 8) doors.insert(rd_u16(s.data, s.size, o + 4)); }
				else if (s.type == "NVCA") { for (size_t o = 0; o + 2 <= s.size; o += 2) covers.insert(rd_u16(s.data, s.size, o)); }
			}
			if (!tr) return;
			size_t count = std::min<size_t>(tc ? tc : tr_size / 16, tr_size / 16);
			for (size_t k = 0; k < count; ++k) {
				size_t o = k * 16;
				uint16_t flags = rd_u16(tr, tr_size, o + 12), cover = rd_u16(tr, tr_size, o + 14);
				bool has_open = false, has_link = false;
				for (int e = 0; e < 3; ++e) {
					int16_t edge = (int16_t)rd_u16(tr, tr_size, o + 6 + e * 2);
					if (flags & (1u << e)) has_link = true;
					else if (edge == -1) has_open = true;
				}
				add(all, flags, cover);
				for (int g = 0; g < 2; ++g) {
					if (!((cover >> (g * 6)) & 0x3F)) continue;
					++group_set[g];
					for (int e = 0; e < 3; ++e) {
						int16_t edge = (int16_t)rd_u16(tr, tr_size, o + 6 + e * 2);
						if (!(flags & (1u << e)) && edge == -1) ++group_edge_open[g][e];
					}
				}
				for (int p = 0; p < 3; ++p) {
					if (!(flags & probe_bits[p])) continue;
					++probe_cells[p][cell];
					for (int e = 0; e < 3; ++e) {
						int16_t edge = (int16_t)rd_u16(tr, tr_size, o + 6 + e * 2);
						if ((flags & (1u << e)) || edge < 0 || (size_t)edge >= count) continue;
						++probe_neighbours[p];
						if (rd_u16(tr, tr_size, edge * 16 + 12) & probe_bits[p]) ++probe_neighbours_same[p];
					}
				}
				if (doors.count((uint16_t)k)) add(door, flags, cover);
				if (covers.count((uint16_t)k)) { add(cover_listed, flags, cover); ++listed; }
				if (has_open) add(open_edge, flags, cover); else add(no_open_edge, flags, cover);
				if (has_link) add(link_edge, flags, cover);
				if (cover) {
					++cover_nonzero;
					++cover_values[cover];
					if (covers.count((uint16_t)k)) ++cover_nonzero_listed; else ++cover_nonzero_unlisted;
					if (!has_open) ++cover_nonzero_without_open_edge;
				}
			}
		});
	}
	auto pct = [](uint64_t a, uint64_t b) { return b ? 100.0 * a / b : 0.0; };
	printf("triangles %llu; NVDP door triangles %llu; NVCA-listed %llu; with an open edge %llu; with a link edge %llu\n",
			(unsigned long long)all.total, (unsigned long long)door.total, (unsigned long long)cover_listed.total, (unsigned long long)open_edge.total, (unsigned long long)link_edge.total);
	printf("\nFlags bit: all%% | door%% | NVCA%% | open-edge%% | no-open-edge%% | link-edge%%\n");
	for (int b = 0; b < 16; ++b) {
		if (!all.flags_bit[b]) continue;
		printf("  0x%04X %9llu  %6.2f | %6.2f | %6.2f | %6.2f | %6.2f | %6.2f\n", 1u << b, (unsigned long long)all.flags_bit[b],
				pct(all.flags_bit[b], all.total), pct(door.flags_bit[b], door.total), pct(cover_listed.flags_bit[b], cover_listed.total),
				pct(open_edge.flags_bit[b], open_edge.total), pct(no_open_edge.flags_bit[b], no_open_edge.total), pct(link_edge.flags_bit[b], link_edge.total));
	}
	printf("\nCover Flags bit: all%% | NVCA%% | open-edge%% | no-open-edge%%\n");
	for (int b = 0; b < 16; ++b) {
		if (!all.cover_bit[b]) continue;
		printf("  0x%04X %9llu  %6.2f | %6.2f | %6.2f | %6.2f\n", 1u << b, (unsigned long long)all.cover_bit[b],
				pct(all.cover_bit[b], all.total), pct(cover_listed.cover_bit[b], cover_listed.total), pct(open_edge.cover_bit[b], open_edge.total), pct(no_open_edge.cover_bit[b], no_open_edge.total));
	}
	printf("\nnonzero Cover Flags: %llu; NVCA-listed %llu, not listed %llu; on triangles with no open edge %llu\n",
			(unsigned long long)cover_nonzero, (unsigned long long)cover_nonzero_listed, (unsigned long long)cover_nonzero_unlisted, (unsigned long long)cover_nonzero_without_open_edge);
	for (int g = 0; g < 2; ++g) {
		printf("cover group %d (bits %d-%d) set on %llu triangles; edge 0-1 open %.2f%%, 1-2 open %.2f%%, 2-0 open %.2f%%\n", g, g * 6, g * 6 + 5, (unsigned long long)group_set[g],
				pct(group_edge_open[g][0], group_set[g]), pct(group_edge_open[g][1], group_set[g]), pct(group_edge_open[g][2], group_set[g]));
	}
	for (int p = 0; p < 3; ++p) {
		uint64_t with_bit = all.flags_bit[__builtin_ctz(probe_bits[p])];
		printf("Flags 0x%04X: in-record neighbours sharing it %.1f%% (bit's overall rate %.2f%%); in %zu cells; top cells:", probe_bits[p],
				pct(probe_neighbours_same[p], probe_neighbours[p]), pct(with_bit, all.total), probe_cells[p].size());
		std::vector<std::pair<uint64_t, uint32_t>> cells;
		for (auto &kv : probe_cells[p]) cells.push_back({ kv.second, kv.first });
		std::sort(cells.rbegin(), cells.rend());
		for (size_t i = 0; i < cells.size() && i < 8; ++i) printf(" %08X:%llu", cells[i].second, (unsigned long long)cells[i].first);
		printf("\n");
	}
	std::vector<std::pair<uint64_t, uint16_t>> top;
	for (auto &kv : cover_values) top.push_back({ kv.second, kv.first });
	std::sort(top.rbegin(), top.rend());
	printf("distinct nonzero Cover Flags values: %zu; most common:", top.size());
	for (size_t i = 0; i < top.size() && i < 16; ++i) printf(" %04X:%llu", top[i].second, (unsigned long long)top[i].first);
	printf("\n");
}
