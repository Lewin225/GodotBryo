// gmst_dump: GMST records in FalloutNV.esm whose EditorID contains every
// argument (case-sensitive), with their value.
//
//   tools/gmst_dump Follow
#include "esm/esm_file.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace esm;

int main(int argc, char **argv) {
	EsmFile file;
	try {
		file.open("../fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		std::fprintf(stderr, "%s\n", e.what());
		return 1;
	}
	file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "GMST") return;
		std::vector<uint8_t> data;
		try {
			data = file.read_record_data(r);
		} catch (...) {
			return;
		}
		std::string editor_id;
		const Subrecord *value = nullptr;
		auto subrecords = EsmFile::parse_subrecords(data);
		for (auto &s : subrecords) {
			if (s.type == "EDID") editor_id = (const char *)s.data;
			if (s.type == "DATA") value = &s;
		}
		for (int i = 1; i < argc; ++i) {
			if (editor_id.find(argv[i]) == std::string::npos) return;
		}
		if (value == nullptr) return;
		if (editor_id[0] == 'f' && value->size >= 4) {
			float f;
			std::memcpy(&f, value->data, 4);
			std::printf("%s = %g\n", editor_id.c_str(), f);
		} else if (editor_id[0] == 'i' && value->size >= 4) {
			int32_t n;
			std::memcpy(&n, value->data, 4);
			std::printf("%s = %d\n", editor_id.c_str(), n);
		} else {
			std::printf("%s = \"%.*s\"\n", editor_id.c_str(), (int)value->size, (const char *)value->data);
		}
	});
	return 0;
}
