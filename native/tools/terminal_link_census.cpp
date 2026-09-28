// Placed terminals (REFR of a TERM base) whose base has a CTDA with Run On =
// Linked Reference (4): how many carry XLKR, and sample REFR FormIDs.
#include "esm/esm_file.h"

#include <cstdio>
#include <cstring>
#include <set>

using namespace esm;

static uint32_t u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

int main() {
	EsmFile esm_file;
	try { esm_file.open("../fresh_nv_copy/Data/FalloutNV.esm"); } catch (const std::exception &e) { fprintf(stderr, "%s\n", e.what()); return 1; }
	std::set<uint32_t> bases;
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "TERM") return;
		const auto data = esm_file.read_record_data(r);
		for (const auto &s : EsmFile::parse_subrecords(data))
			if (s.type == "CTDA" && s.size >= 28 && u32(s.data + 20) == 4) { bases.insert(r.form_id); break; }
	});
	int placed = 0, linked = 0, shown = 0;
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "REFR") return;
		std::vector<uint8_t> data;
		try { data = esm_file.read_record_data(r); } catch (...) { return; }
		uint32_t base = 0, link = 0;
		for (const auto &s : EsmFile::parse_subrecords(data)) {
			if (s.type == "NAME" && s.size >= 4) base = u32(s.data);
			if (s.type == "XLKR" && s.size >= 4) link = u32(s.data);
		}
		if (!bases.count(base)) return;
		placed++;
		if (link) linked++;
		if (shown++ < 4) printf("REFR %08X base %08X XLKR %08X\n", r.form_id, base, link);
	});
	printf("TERM bases with linked-reference conditions: %zu; placed: %d; with XLKR: %d\n", bases.size(), placed, linked);
	return 0;
}
