// Census of placed-actor (ACHR, ACRE) subrecords: how many records carry
// each tag, and the values of XHLP, XCNT, XRDS and XPRD.
#include "esm/esm_file.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <string>

using namespace esm;

int main() {
	EsmFile esm_file;
	try {
		esm_file.open("../fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}
	std::map<std::string, int> records;
	std::map<std::string, std::map<std::string, int>> tags;
	std::map<std::string, std::map<std::string, int>> values;
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "ACHR" && r.type != "ACRE") return;
		std::vector<uint8_t> data;
		try { data = esm_file.read_record_data(r); } catch (...) { return; }
		records[r.type]++;
		std::map<std::string, bool> seen;
		for (const auto &s : EsmFile::parse_subrecords(data)) {
			seen[s.type] = true;
			char buf[64] = "";
			if ((s.type == "XHLP" || s.type == "XRDS" || s.type == "XPRD") && s.size >= 4) {
				float f; memcpy(&f, s.data, 4); snprintf(buf, sizeof buf, "%g", f);
			} else if (s.type == "XCNT" && s.size >= 4) {
				int32_t i; memcpy(&i, s.data, 4); snprintf(buf, sizeof buf, "%d", i);
			}
			if (buf[0]) values[r.type + " " + s.type][buf]++;
		}
		for (auto &[t, _] : seen) tags[r.type][t]++;
	});
	for (auto &[type, n] : records) {
		printf("%s records: %d\n", type.c_str(), n);
		for (auto &[t, c] : tags[type]) printf("  %s %d\n", t.c_str(), c);
	}
	for (auto &[k, m] : values) {
		printf("%s values:", k.c_str());
		int shown = 0;
		for (auto &[v, c] : m) { if (shown++ < 25) printf(" %s x%d,", v.c_str(), c); }
		printf(" (%zu distinct)\n", m.size());
	}
	return 0;
}
