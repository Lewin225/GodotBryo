// actor_record_census: for ACHR, ACRE, NPC_ and CREA, how many records carry
// each subrecord, how many times it occurs, and its size range. Answers which
// fields placed NPCs and creatures (and their bases) share.
//
//   tools/actor_record_census ../fresh_nv_copy/Data/FalloutNV.esm
#include "esm/esm_file.h"
#include <algorithm>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>
using namespace esm;

struct Stat { int records = 0, occurrences = 0; uint32_t min_size = UINT32_MAX, max_size = 0; };

int main(int argc, char **argv) {
	const char *path = argc > 1 ? argv[1] : "../fresh_nv_copy/Data/FalloutNV.esm";
	EsmFile f;
	try { f.open(path); } catch (const std::exception &e) { fprintf(stderr, "%s\n", e.what()); return 1; }
	const std::vector<std::string> types = {"ACHR", "ACRE", "NPC_", "CREA"};
	std::map<std::string, int> totals;
	std::map<std::string, std::map<std::string, Stat>> stats; // type -> subrecord -> stat
	std::map<std::string, std::vector<std::string>> order;    // type -> subrecords in first-seen order
	f.for_each_record([&](const RecordInfo &r) {
		if (std::find(types.begin(), types.end(), r.type) == types.end()) return;
		totals[r.type]++;
		std::vector<uint8_t> d;
		try { d = f.read_record_data(r); } catch (...) { return; }
		std::set<std::string> seen;
		for (auto &s : EsmFile::parse_subrecords(d)) {
			Stat &st = stats[r.type][s.type];
			if (st.occurrences == 0) order[r.type].push_back(s.type);
			st.occurrences++;
			st.min_size = std::min<uint32_t>(st.min_size, s.size);
			st.max_size = std::max<uint32_t>(st.max_size, s.size);
			if (seen.insert(s.type).second) st.records++;
		}
	});
	for (auto &t : types) {
		printf("%s %d\n", t.c_str(), totals[t]);
		for (auto &sub : order[t]) {
			Stat &st = stats[t][sub];
			printf("  %s records %d occurrences %d size %u-%u\n", sub.c_str(), st.records, st.occurrences, st.min_size, st.max_size);
		}
	}
}
