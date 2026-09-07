// Exhaustive official-master equipment census.
//
// Walks every official FNV master, expands ARMO.BIPL -> FLST.LNAM -> ARMA,
// records all gender/world model fields and BMDT slot masks, then resolves
// every referenced NIF through the official BSAs and reports skin targets and
// BSDismember partition IDs.  It deliberately keeps BMDT masks and NIF
// partition IDs as separate observations: their relationship is a question
// for the compositor, not an assumption made by this tool.

#include "bsa/bsa_archive.h"
#include "esm/esm_file.h"
#include "nif/nif_loader.h"

#include <algorithm>
#include <cstdint>
#include <cctype>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using esm::EsmFile;
using esm::RecordInfo;

struct Record {
	std::string plugin;
	RecordInfo header;
	std::vector<uint8_t> data;
};

struct ModelRef {
	std::string plugin;
	std::string owner_type;
	uint32_t owner_form_id = 0;
	uint32_t addon_form_id = 0;
	std::string model_field;
	std::string path;
	uint32_t slot_mask = 0;
};

static uint32_t u32(const uint8_t *p) {
	return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
			(static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

static std::string str(const esm::Subrecord &s) {
	return s.as_string();
}

static std::string lower(std::string value) {
	std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
	return value;
}

static std::string normalize_path(std::string value) {
	value = lower(value);
	std::replace(value.begin(), value.end(), '/', '\\');
	if (value.rfind("meshes\\", 0) == 0) value.erase(0, 7);
	return value;
}

static std::string csv(const std::string &value) {
	std::string out = "\"";
	for (char c : value) out += (c == '"' ? "\"\"" : std::string(1, c));
	return out + "\"";
}

static std::string hex_id(uint32_t id) {
	std::ostringstream out;
	out << "0x" << std::hex << std::setw(8) << std::setfill('0') << id;
	return out.str();
}

static std::string ids(const std::vector<uint16_t> &values) {
	std::ostringstream out;
	for (size_t i = 0; i < values.size(); ++i) { if (i) out << '|'; out << values[i]; }
	return out.str();
}

static std::string names(const std::vector<std::string> &values) {
	std::ostringstream out;
	for (size_t i = 0; i < values.size(); ++i) { if (i) out << '|'; out << values[i]; }
	return out.str();
}

static std::string edid(const Record &record) {
	for (const auto &s : EsmFile::parse_subrecords(record.data)) if (s.type == "EDID") return str(s);
	return {};
}

static std::vector<esm::Subrecord> subs(const Record &record) {
	return EsmFile::parse_subrecords(record.data);
}

static const Record *resolve_record(const std::vector<const Record *> &same_plugin,
		const std::map<uint32_t, std::vector<const Record *>> &global, uint32_t form_id) {
	for (const Record *record : same_plugin) if (record->header.form_id == form_id) return record;
	auto it = global.find(form_id);
	if (it != global.end() && it->second.size() == 1) return it->second.front();
	return nullptr;
}

class ArchiveSet {
public:
	void add(const fs::path &path) {
		auto archive = std::make_unique<bsa::BsaArchive>();
		try { archive->open(path.string()); archives_.push_back(std::move(archive)); }
		catch (const std::exception &error) { std::fprintf(stderr, "warning: %s: %s\n", path.filename().c_str(), error.what()); }
	}
	std::optional<std::vector<uint8_t>> extract(const std::string &relative_path) const {
		std::string path = "meshes\\" + normalize_path(relative_path);
		for (const auto &archive : archives_) {
			const bsa::Entry *entry = archive->find(path);
			if (entry) return archive->extract(*entry);
		}
		return std::nullopt;
	}
private:
	std::vector<std::unique_ptr<bsa::BsaArchive>> archives_;
};

int main(int argc, char **argv) {
	fs::path data_root = argc > 1 ? fs::path(argv[1]) : fs::path("fresh_nv_copy/Data");
	fs::path output_root = argc > 2 ? fs::path(argv[2]) : fs::path("enginedocs/equipment_census");
	fs::create_directories(output_root);

	const std::vector<std::string> master_names = {
		"FalloutNV.esm", "CaravanPack.esm", "ClassicPack.esm", "DeadMoney.esm",
		"GunRunnersArsenal.esm", "HonestHearts.esm", "LonesomeRoad.esm",
		"MercenaryPack.esm", "OldWorldBlues.esm", "TribalPack.esm"};
	std::vector<std::unique_ptr<EsmFile>> files;
	std::vector<std::vector<Record>> records_by_plugin;
	std::map<uint32_t, std::vector<const Record *>> global_records;
	for (const std::string &name : master_names) {
		fs::path path = data_root / name;
		if (!fs::exists(path)) { std::fprintf(stderr, "warning: missing master %s\n", path.c_str()); continue; }
		files.push_back(std::make_unique<EsmFile>());
		try { files.back()->open(path.string()); }
		catch (const std::exception &error) { std::fprintf(stderr, "warning: %s: %s\n", name.c_str(), error.what()); files.pop_back(); continue; }
		records_by_plugin.emplace_back();
		auto &records = records_by_plugin.back();
		files.back()->for_each_record([&](const RecordInfo &header) {
			if (header.type != "ARMO" && header.type != "ARMA" && header.type != "WEAP" && header.type != "FLST" && header.type != "RACE") return;
			Record record{name, header, files.back()->read_record_data(header)};
			records.push_back(std::move(record));
		});
	}
	for (auto &records : records_by_plugin) for (auto &record : records) global_records[record.header.form_id].push_back(&record);

	ArchiveSet archives;
	std::vector<fs::path> bsa_paths;
	for (const auto &entry : fs::directory_iterator(data_root)) if (entry.path().extension() == ".bsa") bsa_paths.push_back(entry.path());
	std::sort(bsa_paths.begin(), bsa_paths.end());
	for (const auto &path : bsa_paths) archives.add(path);

	std::ofstream record_out(output_root / "equipment_records.csv");
	std::ofstream nif_out(output_root / "equipment_nifs.csv");
	std::ofstream summary_out(output_root / "summary.txt");
	record_out << "plugin,owner_type,owner_form_id,owner_edid,addon_form_id,model_field,model_path,slot_mask_hex\n";
	nif_out << "model_path,source_kind,submesh_name,vertex_count,skin_target,bone_count,partition_ids\n";

	std::map<std::string, int> record_counts;
	std::map<std::string, int> model_field_counts;
	std::map<std::string, int> nif_status;
	std::set<std::string> equipment_nif_paths;
	std::set<std::string> nude_nif_paths;
	int armor_lists = 0, armor_list_entries = 0, armor_addon_entries = 0, unresolved_entries = 0;

	for (size_t pi = 0; pi < records_by_plugin.size(); ++pi) {
		const auto &records = records_by_plugin[pi];
		std::vector<const Record *> pointers; for (const auto &record : records) pointers.push_back(&record);
		for (const Record &record : records) {
			if (record.header.type == "ARMO" || record.header.type == "ARMA" || record.header.type == "WEAP") record_counts[record.header.type]++;
			if (record.header.type == "ARMA") {
				uint32_t addon_mask = 0;
				for (const auto &s : subs(record)) if (s.type == "BMDT" && s.size >= 4) addon_mask = u32(s.data);
				for (const auto &s : subs(record)) {
					if (s.type != "MODL" && s.type != "MOD2" && s.type != "MOD3" && s.type != "MOD4") continue;
					std::string path = str(s); if (path.empty()) continue;
					model_field_counts["ARMA." + s.type]++;
					record_out << csv(record.plugin) << ',' << record.header.type << ',' << hex_id(record.header.form_id) << ',' << csv(edid(record)) << ',' << hex_id(record.header.form_id) << ',' << s.type << ',' << csv(path) << ",0x" << std::hex << addon_mask << std::dec << '\n';
					equipment_nif_paths.insert(normalize_path(path));
				}
				continue;
			}
			if (record.header.type != "ARMO") continue;
			uint32_t armor_mask = 0, bipl = 0;
			std::vector<std::string> model_fields;
			for (const auto &s : subs(record)) {
				if (s.type == "BMDT" && s.size >= 4) armor_mask = u32(s.data);
				if (s.type == "BIPL" && s.size >= 4) bipl = u32(s.data);
				if ((s.type == "MODL" || s.type == "MOD2" || s.type == "MOD3" || s.type == "MOD4") && s.size > 0) model_fields.push_back(s.type);
			}
			for (const auto &s : subs(record)) {
				if (s.type != "MODL" && s.type != "MOD2" && s.type != "MOD3" && s.type != "MOD4") continue;
				std::string path = str(s); if (path.empty()) continue;
				model_field_counts["ARMO." + s.type]++;
				record_out << csv(record.plugin) << ',' << record.header.type << ',' << hex_id(record.header.form_id) << ',' << csv(edid(record)) << ",0x00000000," << s.type << ',' << csv(path) << ",0x" << std::hex << armor_mask << std::dec << '\n';
				equipment_nif_paths.insert(normalize_path(path));
			}
			if (!bipl) continue;
			const Record *list = resolve_record(pointers, global_records, bipl);
			if (!list || list->header.type != "FLST") { unresolved_entries++; continue; }
			armor_lists++;
			for (const auto &ls : subs(*list)) {
				if (ls.type != "LNAM" || ls.size < 4) continue;
				armor_list_entries++;
				uint32_t addon_id = u32(ls.data);
				const Record *addon = resolve_record(pointers, global_records, addon_id);
				if (!addon || addon->header.type != "ARMA") { unresolved_entries++; continue; }
				armor_addon_entries++;
				for (const auto &as : subs(*addon)) {
					if (as.type != "MODL" && as.type != "MOD2" && as.type != "MOD3" && as.type != "MOD4") continue;
					std::string path = str(as); if (path.empty()) continue;
					model_field_counts[as.type]++;
					record_out << csv(record.plugin) << ',' << record.header.type << ',' << hex_id(record.header.form_id) << ',' << csv(edid(record)) << ',' << hex_id(addon_id) << ',' << as.type << ',' << csv(path) << ",0x" << std::hex << armor_mask << std::dec << '\n';
					equipment_nif_paths.insert(normalize_path(path));
				}
			}
		}
		// The native RACE resolver is the verified source for nude body paths.
		for (const Record &record : records) if (record.header.type == "RACE") for (bool female : {false, true}) {
			for (const auto &part : files[pi]->get_race_body_parts(record.header.form_id, female)) if (!part.model_path.empty()) nude_nif_paths.insert(normalize_path(part.model_path));
		}
	}

	for (const std::string &path : equipment_nif_paths) {
		auto bytes = archives.extract(path);
		if (!bytes) { nif_status["missing"]++; continue; }
		try {
			nif::Mesh mesh = nif::load_mesh(*bytes);
			nif_status["loaded"]++;
			for (const auto &submesh : mesh.submeshes) {
				const nif::SkinData *skin = nullptr;
				for (const auto &candidate : mesh.skin_data) if (candidate.target_node_name == submesh.name) { skin = &candidate; break; }
				nif_out << csv(path) << ",equipment," << csv(submesh.name) << ',' << (submesh.positions.size() / 3) << ','
						<< csv(skin ? skin->target_node_name : "") << ',' << (skin ? skin->bone_names.size() : 0) << ','
						<< csv(skin ? ids(skin->partition_body_part_ids) : "") << '\n';
			}
		} catch (const std::exception &error) { nif_status["parse_error"]++; std::fprintf(stderr, "warning: %s: %s\n", path.c_str(), error.what()); }
	}
	for (const std::string &path : nude_nif_paths) {
		auto bytes = archives.extract(path);
		if (!bytes) { nif_status["nude_missing"]++; continue; }
		try {
			nif::Mesh mesh = nif::load_mesh(*bytes);
			nif_status["nude_loaded"]++;
			for (const auto &skin : mesh.skin_data) nif_out << csv(path) << ",nude_body," << csv(skin.target_node_name) << ',' << 0 << ',' << csv(skin.target_node_name) << ',' << skin.bone_names.size() << ',' << csv(ids(skin.partition_body_part_ids)) << '\n';
		} catch (const std::exception &error) { nif_status["nude_parse_error"]++; std::fprintf(stderr, "warning: nude %s: %s\n", path.c_str(), error.what()); }
	}

	summary_out << "official masters loaded=" << records_by_plugin.size() << "\n";
	for (const auto &p : record_counts) summary_out << p.first << "=" << p.second << "\n";
	summary_out << "ARMO BIPL lists=" << armor_lists << "\nARMO FLST LNAM entries=" << armor_list_entries << "\nARMA addon entries=" << armor_addon_entries << "\nunresolved list/addon entries=" << unresolved_entries << "\n";
	for (const auto &p : model_field_counts) summary_out << p.first << " references=" << p.second << "\n";
	summary_out << "unique equipment NIF paths=" << equipment_nif_paths.size() << "\nunique nude-body NIF paths=" << nude_nif_paths.size() << "\n";
	for (const auto &p : nif_status) summary_out << "nif_" << p.first << "=" << p.second << "\n";

	std::printf("wrote %s and %s\n", (output_root / "equipment_records.csv").c_str(), (output_root / "equipment_nifs.csv").c_str());
	return 0;
}
