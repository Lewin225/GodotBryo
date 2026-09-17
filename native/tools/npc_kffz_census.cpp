// Census the raw NPC_.KFFZ animation filename lists across supplied official
// master files. KFFZ is an explicitly named field in xEdit's FNV schema; this
// tool establishes its real shipped frequency and values before it becomes an
// actor-animation selection rule.
//
// Build from native/:
// g++ -std=c++17 -O2 -Isrc tools/npc_kffz_census.cpp src/esm/esm_file.cpp \
//     -lz -o tools/npc_kffz_census
// Run: tools/npc_kffz_census ../fresh_nv_copy/Data/FalloutNV.esm [more .esm]

#include "esm/esm_file.h"

#include <cstdio>
#include <set>
#include <string>
#include <vector>

namespace {

std::string string_data(const esm::Subrecord& subrecord) {
	std::string value(reinterpret_cast<const char*>(subrecord.data), subrecord.size);
	if (!value.empty() && value.back() == '\0')
		value.pop_back();
	return value;
}

std::vector<std::string> nul_strings(const esm::Subrecord& subrecord) {
	std::vector<std::string> values;
	std::string current;
	for (size_t i = 0; i < subrecord.size; ++i) {
		const char byte = static_cast<char>(subrecord.data[i]);
		if (byte == '\0') {
			if (!current.empty())
				values.push_back(current);
			current.clear();
		} else {
			current += byte;
		}
	}
	if (!current.empty())
		values.push_back(current);
	return values;
}

std::string editor_id(const std::vector<esm::Subrecord>& subrecords) {
	for (const esm::Subrecord& subrecord : subrecords)
		if (subrecord.type == "EDID")
			return string_data(subrecord);
	return "";
}

} // namespace

int main(int argc, char** argv) {
	if (argc < 2) {
		std::fprintf(stderr, "usage: npc_kffz_census <master.esm> [more .esm]\n");
		return 2;
	}
	int all_npcs = 0;
	int npcs_with_kffz = 0;
	int kffz_values = 0;
	std::set<std::string> unique_values;
	for (int argument = 1; argument < argc; ++argument) {
		esm::EsmFile esm;
		try {
			esm.open(argv[argument]);
		} catch (const std::exception& error) {
			std::fprintf(stderr, "%s: %s\n", argv[argument], error.what());
			return 1;
		}
		int file_npcs = 0;
		int file_with_kffz = 0;
		int file_values = 0;
		esm.for_each_record([&](const esm::RecordInfo& record) {
			if (record.type != "NPC_")
				return;
			file_npcs++;
			const std::vector<esm::Subrecord> subrecords = esm::EsmFile::parse_subrecords(esm.read_record_data(record));
			std::vector<std::string> animations;
			for (const esm::Subrecord& subrecord : subrecords)
				if (subrecord.type == "KFFZ")
					for (const std::string& value : nul_strings(subrecord))
						animations.push_back(value);
			if (animations.empty())
				return;
			file_with_kffz++;
			file_values += static_cast<int>(animations.size());
			std::printf("%s NPC_ %08X %s KFFZ:", argv[argument], record.form_id, editor_id(subrecords).c_str());
			for (const std::string& animation : animations) {
				std::printf(" %s", animation.c_str());
				unique_values.insert(animation);
			}
			std::printf("\n");
		});
		all_npcs += file_npcs;
		npcs_with_kffz += file_with_kffz;
		kffz_values += file_values;
		std::printf("%s: NPC_=%d KFFZ records=%d KFFZ filenames=%d\n",
			argv[argument], file_npcs, file_with_kffz, file_values);
	}
	std::printf("TOTAL: NPC_=%d KFFZ records=%d KFFZ filenames=%d unique filenames=%zu\n",
		all_npcs, npcs_with_kffz, kffz_values, unique_values.size());
	return 0;
}
