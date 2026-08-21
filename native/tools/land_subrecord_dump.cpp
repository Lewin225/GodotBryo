#include "../src/esm/esm_file.h"
#include <cstdio>
#include <map>
#include <string>

using namespace esm;

int main(int argc, char **argv) {
	std::map<std::string, size_t> type_counts;
	std::map<std::string, size_t> type_max_size;
	std::map<std::string, size_t> type_min_size;
	int land_count = 0;
	for (int i = 1; i < argc; ++i) {
		EsmFile f;
		try {
			f.open(argv[i]);
		} catch (const std::exception &e) {
			std::printf("failed to open %s: %s\n", argv[i], e.what());
			continue;
		}
		f.for_each_record([&](const RecordInfo &rec) {
			if (rec.type != "LAND") return;
			try {
				land_count++;
				std::vector<uint8_t> data = f.read_record_data(rec);
				std::vector<Subrecord> subs = f.parse_subrecords(data);
				for (const auto &s : subs) {
					type_counts[s.type]++;
					if (!type_max_size.count(s.type) || s.size > type_max_size[s.type]) type_max_size[s.type] = s.size;
					if (!type_min_size.count(s.type) || s.size < type_min_size[s.type]) type_min_size[s.type] = s.size;
				}
			} catch (const std::exception &e) {
				std::printf("skip LAND record: %s\n", e.what());
			}
		});
	}
	std::printf("LAND records scanned: %d\n", land_count);
	std::printf("%-8s %10s %10s %10s\n", "type", "count", "min_size", "max_size");
	for (const auto &kv : type_counts) {
		std::printf("%-8s %10zu %10zu %10zu\n", kv.first.c_str(), kv.second, type_min_size[kv.first], type_max_size[kv.first]);
	}
	return 0;
}
