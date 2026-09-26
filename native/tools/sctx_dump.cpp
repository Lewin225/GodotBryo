// Writes every SCTX (script source) subrecord in FalloutNV.esm to stdout,
// each prefixed by a line naming its record type and FormID.
#include "esm/esm_file.h"

#include <cstdio>

using namespace esm;

int main() {
	EsmFile esm_file;
	try {
		esm_file.open("../fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type == "GRUP") return;
		std::vector<uint8_t> data;
		try {
			data = esm_file.read_record_data(r);
		} catch (const std::exception &e) {
			fprintf(stderr, "skipped %s %08X: %s\n", r.type.c_str(), r.form_id, e.what());
			return;
		}
		for (const auto &s : EsmFile::parse_subrecords(data)) {
			if (s.type != "SCTX") continue;
			printf("\n@@@ %s %08X\n", r.type.c_str(), r.form_id);
			fwrite(s.data, 1, s.size, stdout);
		}
	});
	return 0;
}
