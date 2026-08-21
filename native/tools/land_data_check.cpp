#include "../src/esm/esm_file.h"
#include <cstdio>
#include <map>

using namespace esm;

int main(int argc, char **argv) {
	std::map<uint32_t, int> value_counts;
	int total = 0;
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
				std::vector<uint8_t> data = f.read_record_data(rec);
				std::vector<Subrecord> subs = EsmFile::parse_subrecords(data);
				for (const auto &s : subs) {
					if (s.type == "DATA" && s.size >= 4) {
						uint32_t v = s.data[0] | (s.data[1] << 8) | (s.data[2] << 16) | (s.data[3] << 24);
						value_counts[v]++;
						total++;
					}
				}
			} catch (...) {}
		});
	}
	std::printf("total DATA subrecords: %d, distinct values: %zu\n", total, value_counts.size());
	int shown = 0;
	for (const auto &kv : value_counts) {
		std::printf("  value=0x%08X (bits=", kv.first);
		for (int b = 31; b >= 0; --b) std::putchar((kv.first >> b) & 1 ? '1' : '0');
		std::printf(")  count=%d\n", kv.second);
		if (++shown >= 20) { std::printf("  ... (%zu more distinct values)\n", value_counts.size() - 20); break; }
	}
	return 0;
}
