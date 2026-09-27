// MESG TNAM (display time) census in FalloutNV.esm: raw uint32 values and
// how many messages carry one, for the tutorial messages in particular.
#include "esm/esm_file.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <string>

using namespace esm;

int main() {
	EsmFile esm_file;
	try { esm_file.open("../fresh_nv_copy/Data/FalloutNV.esm"); } catch (const std::exception &e) { fprintf(stderr, "%s\n", e.what()); return 1; }
	std::map<uint32_t, int> values;
	int total = 0, with_tnam = 0;
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "MESG") return;
		total++;
		const auto data = esm_file.read_record_data(r);
		std::string edid; uint32_t tnam = 0; bool has = false; uint32_t dnam = 0; size_t tsize = 0;
		for (const auto &s : EsmFile::parse_subrecords(data)) {
			if (s.type == "EDID") edid.assign((const char *)s.data, strnlen((const char *)s.data, s.size));
			if (s.type == "TNAM" && s.size >= 4) { memcpy(&tnam, s.data, 4); has = true; tsize = s.size; }
			if (s.type == "DNAM" && s.size >= 4) memcpy(&dnam, s.data, 4);
		}
		if (has) { with_tnam++; values[tnam]++; }
		if (edid == "VCGTutorialJump" || edid == "VCGTutorialGrab2")
			printf("%s TNAM size %zu uint32 %u (as float %g) DNAM flags %u\n", edid.c_str(), tsize, tnam, *reinterpret_cast<float *>(&tnam), dnam);
	});
	printf("MESG %d, with TNAM %d\n", total, with_tnam);
	for (auto &[v, c] : values) printf("  TNAM %u x%d\n", v, c);
	return 0;
}
