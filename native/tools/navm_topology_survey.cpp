// Answers two real-data questions before any nav-graph design gets built:
//   1. Is a NAVM one-per-interior-CELL and one-per-exterior-tile-CELL, or
//      something coarser/finer?
//   2. Are NVEX edge links dense (many per neighbor pair, ~one per shared
//      triangle edge) or sparse (a handful of links stitching two NAVMs
//      together)?
// NAVM DATA/NVEX layout confirmed against
// enginedocs/xEdit/Core/wbDefinitionsFNV.pas (see navm_census.cpp for the
// DATA layout notes). NVEX 'Edge Link' struct: Type u32, Navmesh FormID u32,
// Triangle u16 -- read positionally per that schema, not assumed padded.
#include <cstdio>
#include <cstdint>
#include <string>
#include <map>
#include <set>
#include "esm/esm_file.h"

static uint32_t read_u32(const std::vector<uint8_t> &d, size_t o) {
	if (o + 4 > d.size()) return 0;
	return d[o] | (d[o+1]<<8) | (d[o+2]<<16) | (uint32_t(d[o+3])<<24);
}
static uint16_t read_u16(const std::vector<uint8_t> &d, size_t o) {
	if (o + 2 > d.size()) return 0;
	return d[o] | (d[o+1]<<8);
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s <esm_path>\n", argv[0]);
		return 1;
	}
	esm::EsmFile file;
	file.open(argv[1]);

	// cell_form_id -> NAVM count placed directly in that cell.
	std::map<uint32_t, int> navm_per_cell;
	// navm_form_id -> its owning cell.
	std::map<uint32_t, uint32_t> navm_cell;
	// navm_form_id -> NVEX edge-link total count, and distinct target NAVM count.
	std::map<uint32_t, int> edge_link_count;
	std::map<uint32_t, std::set<uint32_t>> edge_link_targets;
	// (navm_a, navm_b) unordered pair -> link count between exactly that pair.
	std::map<std::pair<uint32_t,uint32_t>, int> pair_link_count;

	file.for_each_record([&](const esm::RecordInfo &record) {
		if (record.type != "NAVM") return;
		auto raw = file.read_record_data(record);
		auto subs = esm::EsmFile::parse_subrecords(raw);
		uint32_t cell_id = 0;
		for (const auto &sub : subs) {
			if (sub.type == "DATA") {
				std::vector<uint8_t> d(sub.data, sub.data + sub.size);
				cell_id = read_u32(d, 0);
			}
		}
		navm_cell[record.form_id] = cell_id;
		navm_per_cell[cell_id]++;
		int links = 0;
		for (const auto &sub : subs) {
			if (sub.type != "NVEX") continue;
			std::vector<uint8_t> d(sub.data, sub.data + sub.size);
			// Each Edge Link entry: Type(u32) + Navmesh FormID(u32) + Triangle(u16) = 10 bytes.
			for (size_t off = 0; off + 10 <= d.size(); off += 10) {
				uint32_t target = read_u32(d, off + 4);
				if (target == 0) continue;
				links++;
				edge_link_targets[record.form_id].insert(target);
				uint32_t a = record.form_id, b = target;
				if (a > b) std::swap(a, b);
				pair_link_count[{a, b}]++;
			}
		}
		edge_link_count[record.form_id] = links;
	});

	printf("Total NAVM records: %zu\n", navm_cell.size());
	int cells_with_multiple_navm = 0;
	int max_navm_in_one_cell = 0;
	for (auto &kv : navm_per_cell) {
		if (kv.second > 1) cells_with_multiple_navm++;
		max_navm_in_one_cell = std::max(max_navm_in_one_cell, kv.second);
	}
	printf("Distinct owning CELLs: %zu | CELLs with >1 NAVM: %d | max NAVM in one CELL: %d\n",
		navm_per_cell.size(), cells_with_multiple_navm, max_navm_in_one_cell);

	int interior_cells = 0, exterior_cells = 0;
	int interior_navm = 0, exterior_navm = 0;
	for (auto &kv : navm_per_cell) {
		auto wrld = file.get_cell_worldspace(kv.first);
		bool is_exterior = wrld.has_value() && *wrld != 0;
		if (is_exterior) { exterior_cells++; exterior_navm += kv.second; }
		else { interior_cells++; interior_navm += kv.second; }
	}
	printf("Interior CELLs with NAVM: %d (%d NAVM records) | Exterior CELLs with NAVM: %d (%d NAVM records)\n",
		interior_cells, interior_navm, exterior_cells, exterior_navm);

	long long total_links = 0;
	int navm_with_links = 0;
	int max_links_one_navm = 0;
	int max_distinct_neighbors_one_navm = 0;
	for (auto &kv : edge_link_count) {
		total_links += kv.second;
		if (kv.second > 0) navm_with_links++;
		max_links_one_navm = std::max(max_links_one_navm, kv.second);
	}
	for (auto &kv : edge_link_targets) {
		max_distinct_neighbors_one_navm = std::max(max_distinct_neighbors_one_navm, (int)kv.second.size());
	}
	printf("Total NVEX edge links: %lld | NAVMs with >=1 link: %d | max links from one NAVM: %d | max distinct neighbor NAVMs from one NAVM: %d\n",
		total_links, navm_with_links, max_links_one_navm, max_distinct_neighbors_one_navm);

	// Distribution of link-count-per-neighbor-pair: is it usually 1, or tens/hundreds?
	std::map<int, int> pair_count_histogram;
	int max_links_one_pair = 0;
	for (auto &kv : pair_link_count) {
		pair_count_histogram[kv.second]++;
		max_links_one_pair = std::max(max_links_one_pair, kv.second);
	}
	printf("Distinct NAVM-NAVM neighbor pairs: %zu | max links between a single pair: %d\n",
		pair_link_count.size(), max_links_one_pair);
	printf("Histogram of links-per-neighbor-pair (linkcount: how many pairs have exactly that many links), first 20 buckets:\n");
	int shown = 0;
	for (auto &kv : pair_count_histogram) {
		printf("  %d link(s): %d pair(s)\n", kv.first, kv.second);
		if (++shown >= 20) break;
	}
	return 0;
}
