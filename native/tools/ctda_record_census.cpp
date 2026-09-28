// Which record types carry CTDA (condition) subrecords in FalloutNV.esm, how
// many records and CTDAs each, and the CTDA sizes.
#include "esm/esm_file.h"

#include <cstdio>
#include <map>
#include <string>

using namespace esm;

int main() {
	EsmFile esm_file;
	try { esm_file.open("../fresh_nv_copy/Data/FalloutNV.esm"); } catch (const std::exception &e) { fprintf(stderr, "%s\n", e.what()); return 1; }
	std::map<std::string, std::pair<int, int>> by_type; // type -> (records with CTDA, CTDAs)
	std::map<std::string, int> totals;
	std::map<size_t, int> sizes;
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type == "GRUP") return;
		totals[r.type]++;
		std::vector<uint8_t> data;
		try { data = esm_file.read_record_data(r); } catch (...) { return; }
		int n = 0;
		for (const auto &s : EsmFile::parse_subrecords(data)) {
			if (s.type == "CTDA") { n++; sizes[s.size]++; }
		}
		if (n) { by_type[r.type].first++; by_type[r.type].second += n; }
	});
	printf("%-6s %10s %8s %8s\n", "type", "records", "of", "CTDAs");
	for (auto &[t, c] : by_type) printf("%-6s %10d %8d %8d\n", t.c_str(), c.first, totals[t], c.second);
	for (auto &[k, v] : sizes) printf("CTDA size %zu x%d\n", k, v);
	return 0;
}
