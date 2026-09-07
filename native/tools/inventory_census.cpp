// Exhaustive inventory census for Fallout: New Vegas and all official
// masters. CNTO and LVLO are reported as authored references; this tool does
// not infer equipped state or expand leveled lists.
#include "esm/esm_file.h"

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <exception>
#include <string>
#include <vector>

namespace fs = std::filesystem;

static uint32_t u32(const uint8_t *p) {
	return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
		(static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

static std::string csv(const std::string &value) {
	std::string out = "\"";
	for (char c : value) out += (c == '"' ? "\"\"" : std::string(1, c));
	return out + "\"";
}

static std::string hex_id(uint32_t id) {
	char buffer[16];
	std::snprintf(buffer, sizeof(buffer), "0x%08X", id);
	return buffer;
}

struct File {
	std::string name;
	esm::EsmFile esm;
};

int main(int argc, char **argv) {
	fs::path data_root = argc > 1 ? fs::path(argv[1]) : fs::path("fresh_nv_copy/Data");
	fs::path output_root = argc > 2 ? fs::path(argv[2]) : fs::path("enginedocs/inventory_census");
	fs::create_directories(output_root);
	const std::vector<std::string> names = {
		"FalloutNV.esm", "CaravanPack.esm", "ClassicPack.esm", "DeadMoney.esm",
		"GunRunnersArsenal.esm", "HonestHearts.esm", "LonesomeRoad.esm",
		"MercenaryPack.esm", "OldWorldBlues.esm", "TribalPack.esm"};
	std::vector<std::unique_ptr<File>> files;
	std::map<uint32_t, std::string> types;
	for (const auto &name : names) {
		if (!fs::exists(data_root / name)) continue;
		auto file = std::make_unique<File>();
		file->name = name;
		try { file->esm.open((data_root / name).string()); }
		catch (const std::exception &) { continue; }
		file->esm.for_each_record([&](const esm::RecordInfo &record) {
			types.emplace(record.form_id, record.type);
		});
		files.push_back(std::move(file));
	}

	std::ofstream entries(output_root / "inventory_entries.csv");
	std::ofstream lists(output_root / "leveled_entries.csv");
	std::ofstream summary(output_root / "summary.txt");
	entries << "plugin,owner_type,owner_form_id,item_form_id,item_type,count,resolution\n";
	lists << "plugin,lvli_form_id,entry_index,referenced_form_id,referenced_type,bytes\n";
	std::map<std::string, uint64_t> counts;
	std::map<std::string, uint64_t> item_types;
	uint64_t unresolved = 0;
	uint64_t leveled_entries = 0;
	for (auto &file : files) {
		file->esm.for_each_record([&](const esm::RecordInfo &record) {
			if (record.type != "NPC_" && record.type != "CONT" && record.type != "LVLI") return;
			const auto data = file->esm.read_record_data(record);
			const auto subrecords = esm::EsmFile::parse_subrecords(data);
			int index = 0;
			for (const auto &sub : subrecords) {
				if ((record.type == "NPC_" || record.type == "CONT") && sub.type == "CNTO" && sub.size >= 8) {
					uint32_t item_id = u32(sub.data);
					uint32_t count = u32(sub.data + 4);
					auto found = types.find(item_id);
					std::string item_type = found == types.end() ? "UNRESOLVED" : found->second;
					entries << csv(file->name) << ',' << record.type << ',' << hex_id(record.form_id) << ','
						<< hex_id(item_id) << ',' << item_type << ',' << count << ','
						<< (found == types.end() ? "unresolved" : "resolved") << '\n';
					counts[file->name + ":" + record.type]++;
					item_types[item_type]++;
					if (found == types.end()) unresolved++;
				}
				if (record.type == "LVLI" && sub.type == "LVLO" && sub.size >= 8) {
					// FNV LVLO begins with level/flags (4 bytes), followed by
					// the referenced FormID. Remaining bytes are preserved in the
					// CSV size column until their meanings are census-confirmed.
					uint32_t item_id = u32(sub.data + 4);
					auto found = types.find(item_id);
					lists << csv(file->name) << ',' << hex_id(record.form_id) << ',' << index++ << ','
						<< hex_id(item_id) << ',' << (found == types.end() ? "UNRESOLVED" : found->second)
						<< ',' << sub.size << '\n';
					leveled_entries++;
				}
			}
		});
	}
	summary << "official_masters_loaded=" << files.size() << '\n';
	for (const auto &pair : counts) summary << pair.first << "=" << pair.second << '\n';
	for (const auto &pair : item_types) summary << "item_type." << pair.first << "=" << pair.second << '\n';
	summary << "unresolved_cnto=" << unresolved << '\n';
	summary << "lvli_entries=" << leveled_entries << '\n';
	return 0;
}
