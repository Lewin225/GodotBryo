#include "esm/esm_file.h"
#include <cstdio>
#include <string>
#include <vector>
#include <unordered_set>

int main() {
	esm::EsmFile file;
	std::unordered_set<uint32_t> seen;
	file.open("fresh_nv_copy/Data/FalloutNV.esm");
	file.for_each_record([&](const esm::RecordInfo &record) {
		if (record.type != "NPC_" && record.type != "RACE") return;
		std::vector<uint8_t> data = file.read_record_data(record);
		std::string edid, full;
		uint32_t race = 0;
		for (const auto &sub : esm::EsmFile::parse_subrecords(data)) {
			if (sub.type == "EDID") edid = sub.as_string();
			if (sub.type == "FULL") full = sub.as_string();
			if (sub.type == "RNAM" && sub.size >= 4) race = static_cast<uint32_t>(sub.data[0]) | (static_cast<uint32_t>(sub.data[1]) << 8) | (static_cast<uint32_t>(sub.data[2]) << 16) | (static_cast<uint32_t>(sub.data[3]) << 24);
		}
		const bool common_race = race == 0x00000019 || race == 0x000038E5 || race == 0x000038E6 || race == 0x000042BE || race == 0x000042BF || race == 0x000042C0 || race == 0x000042C1 || race == 0x000042C2 || race == 0x000042C3 || race == 0x000042C4 || race == 0x000042C5 || race == 0x00003B3E || race == 0x000987DC || race == 0x000987DD || race == 0x000987DE || race == 0x000987DF || race == 0x0004BB8D || race == 0x0004BF70 || race == 0x0004BF71 || race == 0x0004BF72 || record.type == "RACE";
		if (record.type == "NPC_" && !common_race && seen.insert(race).second)
			std::printf("0x%08X,0x%08X,%s,%s\n", record.form_id, race, edid.c_str(), full.c_str());
	});
}
