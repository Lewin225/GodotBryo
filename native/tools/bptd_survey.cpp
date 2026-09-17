// One-off BPTD investigation: lists every Body Part Data record in one ESM
// and finds every record/subrecord that contains its exact FormID.
#include "esm/esm_file.h"
#include "common/byte_reader.h"

#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace {
uint32_t u32(const esm::Subrecord &sub) {
	util::ByteReader reader(sub.data, sub.size);
	return reader.read_u32();
}

std::string edid(const std::vector<esm::Subrecord> &subs) {
	for (const auto &sub : subs) if (sub.type == "EDID") {
		std::string value(reinterpret_cast<const char *>(sub.data), sub.size);
		if (!value.empty() && value.back() == '\0') value.pop_back();
		return value;
	}
	return "";
}

void print_hex(const esm::Subrecord &sub) {
	for (size_t i = 0; i < sub.size; ++i) std::printf("%02X", sub.data[i]);
}
}

int main(int argc, char **argv) {
	if (argc != 2) {
		std::fprintf(stderr, "usage: bptd_survey path/to/FalloutNV.esm\\n");
		return 2;
	}
	esm::EsmFile esm;
	try {
		esm.open(argv[1]);
	} catch (const std::exception &error) {
		std::fprintf(stderr, "open failed: %s\\n", error.what());
		return 1;
	}

	struct Bptd { esm::RecordInfo record; std::string editor_id; };
	std::vector<Bptd> bptds;
	esm.for_each_record([&](const esm::RecordInfo &record) {
		if (record.type != "BPTD") return;
		bptds.push_back({record, edid(esm::EsmFile::parse_subrecords(esm.read_record_data(record)))});
	});

	std::set<uint32_t> ids;
	for (const Bptd &bptd : bptds) ids.insert(bptd.record.form_id);
	std::printf("BPTD records: %zu\\n", bptds.size());
	for (const Bptd &bptd : bptds) {
		auto subs = esm::EsmFile::parse_subrecords(esm.read_record_data(bptd.record));
		std::map<std::string, int> tag_counts;
		for (const auto &sub : subs) tag_counts[sub.type]++;
		std::printf("  %08X %-32s", bptd.record.form_id, bptd.editor_id.c_str());
		for (const auto &[tag, count] : tag_counts) std::printf(" %s=%d", tag.c_str(), count);
		std::printf("\\n");
	}

	std::map<std::string, std::vector<std::string>> uses;
	esm.for_each_record([&](const esm::RecordInfo &record) {
		if (record.type != "NPC_" && record.type != "CREA" && record.type != "RACE") return;
		auto subs = esm::EsmFile::parse_subrecords(esm.read_record_data(record));
		std::string source = edid(subs);
		for (const auto &sub : subs) {
			if (sub.size != 4 || !ids.contains(u32(sub))) continue;
			char line[256];
			std::snprintf(line, sizeof(line), "%s %08X %s -> %08X", record.type.c_str(), record.form_id, source.c_str(), u32(sub));
			uses[sub.type].push_back(line);
		}
	});
	std::printf("\\nExact four-byte BPTD references by subrecord:\\n");
	for (const auto &[tag, entries] : uses) {
		std::printf("  %s: %zu\\n", tag.c_str(), entries.size());
		for (const auto &entry : entries) std::printf("    %s\\n", entry.c_str());
	}
}
