// Answers: what do NVTR triangle edge values (Edge 0-1 / 1-2 / 2-0, itS16)
// actually contain across the whole shipped population?
//
// xEdit's FNV schema routes these through wbNVTREdgeToStr/wbNVTREdgeToInt,
// whose definitions are not in the files vendored under enginedocs/xEdit/, so
// the encoding is NOT documented for us. This settles it empirically over
// every NAVM in every master rather than from a sample, because the answer
// decides how cross-record navmesh stitching is built.
//
// Buckets tested, per edge slot:
//   -1                      : conventional "no neighbor"
//   0 .. triangle_count-1   : in-record neighbor triangle index
//   other negative          : some other encoding (would need decoding)
//   >= triangle_count       : out-of-range for an in-record index
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <map>
#include <vector>
#include <string>
#include "esm/esm_file.h"

static uint32_t rd_u32(const uint8_t *d, size_t n, size_t o) {
	if (o + 4 > n) return 0;
	return d[o] | (d[o+1] << 8) | (d[o+2] << 16) | (uint32_t(d[o+3]) << 24);
}
static uint16_t rd_u16(const uint8_t *d, size_t n, size_t o) {
	if (o + 2 > n) return 0;
	return d[o] | (d[o+1] << 8);
}

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: %s <esm...>\n", argv[0]); return 1; }

	uint64_t minus_one = 0, in_range = 0, other_negative = 0, out_of_range = 0, total = 0;
	std::map<int, uint64_t> other_negative_values; // exact values, if any
	uint64_t max_out_of_range_excess = 0;
	// Cross-check: does the count of boundary (-1) edges relate to NVEX count?
	uint64_t records = 0, total_nvex = 0, total_boundary_edges = 0;

	for (int i = 1; i < argc; ++i) {
		esm::EsmFile file;
		try { file.open(argv[i]); } catch (const std::exception &e) {
			fprintf(stderr, "open failed %s: %s\n", argv[i], e.what()); continue;
		}
		file.for_each_record([&](const esm::RecordInfo &record) {
			if (record.type != "NAVM") return;
			auto raw = file.read_record_data(record);
			auto subs = esm::EsmFile::parse_subrecords(raw);
			uint32_t triangle_count = 0, edge_link_count = 0;
			for (const auto &s : subs) if (s.type == "DATA") {
				triangle_count = rd_u32(s.data, s.size, 8);
				edge_link_count = rd_u32(s.data, s.size, 12);
			}
			records++;
			total_nvex += edge_link_count;
			for (const auto &s : subs) {
				if (s.type != "NVTR") continue;
				size_t count = triangle_count ? triangle_count : s.size / 16;
				for (size_t k = 0; k < count; ++k) {
					size_t o = k * 16;
					if (o + 16 > s.size) break;
					for (int e = 0; e < 3; ++e) {
						int16_t v = (int16_t)rd_u16(s.data, s.size, o + 6 + e * 2);
						total++;
						if (v == -1) { minus_one++; total_boundary_edges++; }
						else if (v >= 0 && (uint32_t)v < triangle_count) in_range++;
						else if (v < 0) { other_negative++; other_negative_values[v]++; }
						else {
							out_of_range++;
							uint64_t excess = (uint64_t)v - triangle_count;
							if (excess > max_out_of_range_excess) max_out_of_range_excess = excess;
						}
					}
				}
			}
		});
	}

	printf("NAVM records scanned: %llu\n", (unsigned long long)records);
	printf("Total NVTR edge slots: %llu\n", (unsigned long long)total);
	printf("  == -1 (no neighbor)          : %llu (%.3f%%)\n",
		(unsigned long long)minus_one, 100.0 * minus_one / (total ? total : 1));
	printf("  in [0, triangle_count)       : %llu (%.3f%%)\n",
		(unsigned long long)in_range, 100.0 * in_range / (total ? total : 1));
	printf("  other negative               : %llu (%.3f%%)\n",
		(unsigned long long)other_negative, 100.0 * other_negative / (total ? total : 1));
	printf("  >= triangle_count            : %llu (%.3f%%)  max excess over count: %llu\n",
		(unsigned long long)out_of_range, 100.0 * out_of_range / (total ? total : 1),
		(unsigned long long)max_out_of_range_excess);
	if (!other_negative_values.empty()) {
		printf("  distinct other-negative values (up to 20):\n");
		int shown = 0;
		for (auto &kv : other_negative_values) {
			printf("    %d : %llu occurrence(s)\n", kv.first, (unsigned long long)kv.second);
			if (++shown >= 20) break;
		}
	}
	printf("\nBoundary (-1) edge slots: %llu | total NVEX edge links: %llu\n",
		(unsigned long long)total_boundary_edges, (unsigned long long)total_nvex);
	printf("(If NVEX were one-per-boundary-edge these would match; a large gap means most\n"
	       " boundary edges are true outer perimeter with no neighboring navmesh at all.)\n");
	return 0;
}
