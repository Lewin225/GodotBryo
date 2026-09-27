// Counts records carrying record-header flag 0x400 (xEdit: Quest Item on
// items, Persistent on placed references), by record type, in FalloutNV.esm.
#include "esm/esm_file.h"

#include <cstdio>
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
	std::map<std::string, std::pair<int, int>> counts; // type -> (with flag, total)
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type == "GRUP") return;
		auto &c = counts[r.type];
		c.second++;
		if (r.flags & 0x400) c.first++;
		if ((r.type == "WEAP" || r.type == "ARMO") && (r.flags & 0x400)) {
			const auto data = esm_file.read_record_data(r);
			for (const auto &sub : EsmFile::parse_subrecords(data))
				if (sub.type == "EDID") printf("  quest item %s %08X %s\n", r.type.c_str(), r.form_id, (const char *)sub.data);
		}
	});
	for (auto &[type, c] : counts)
		if (c.first) printf("%s %d / %d\n", type.c_str(), c.first, c.second);
	return 0;
}
