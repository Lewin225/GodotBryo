// Survey real TERM records and their placement context before implementing
// terminal parsing. Usage: terminal_survey FalloutNV.esm [EditorID substring].
#include "esm/esm_file.h"
#include "common/byte_reader.h"

#include <iomanip>
#include <iostream>
#include <string>
#include <unordered_set>

int main(int argc, char **argv) {
	if (argc < 2 || argc > 5) {
		std::cerr << "usage: terminal_survey <esm> [editor-id-substring] [--placements | --cell CELL_EDID]\n";
		return 2;
	}
	const std::string filter = argc >= 3 && std::string(argv[2]) != "--cell" ? argv[2] : "";
	const std::string cell_filter = argc == 5 && std::string(argv[3]) == "--cell" ? argv[4] : "";
	const bool find_placements = argc == 4 && std::string(argv[3]) == "--placements";
	esm::EsmFile file;
	file.open(argv[1]);
	int matched = 0;
	std::unordered_set<uint32_t> matched_forms;
	file.for_each_record([&](const esm::RecordInfo &record) {
		if (record.type != "TERM") return;
		const auto data = file.read_record_data(record);
		const auto subs = esm::EsmFile::parse_subrecords(data);
		std::string edid;
		for (const auto &sub : subs) if (sub.type == "EDID") edid = sub.as_string();
		if (!filter.empty() && edid.find(filter) == std::string::npos) return;
		++matched;
		matched_forms.insert(record.form_id);
		std::cout << "TERM 0x" << std::hex << record.form_id << std::dec << " " << edid << "\n";
		for (const auto &sub : subs) {
			std::cout << "  " << sub.type << " " << sub.size;
			if (sub.type == "EDID" || sub.type == "FULL" || sub.type == "MODL" || sub.type == "DESC" || sub.type == "ITXT" || sub.type == "RNAM") {
				std::cout << "  \"" << sub.as_string() << "\"";
			} else if ((sub.type == "INAM" || sub.type == "TNAM" || sub.type == "SNAM") && sub.size >= 4) {
				util::ByteReader bytes(sub.data, sub.size);
				std::cout << "  form 0x" << std::hex << bytes.read_u32() << std::dec;
			}
			std::cout << "\n";
		}
	});
	std::cout << "matched " << matched << " TERM record(s)\n";
	if (find_placements) {
		std::cout << "placements of matched TERM records:\n";
		file.for_each_record([&](const esm::RecordInfo &cell) {
			if (cell.type != "CELL") return;
			std::string cell_edid;
			for (const auto &sub : esm::EsmFile::parse_subrecords(file.read_record_data(cell))) {
				if (sub.type == "EDID") { cell_edid = sub.as_string(); break; }
			}
			for (const auto &placement : file.get_cell_references(cell)) {
				if (matched_forms.find(placement.base_form_id) != matched_forms.end())
					std::cout << "  CELL 0x" << std::hex << cell.form_id << std::dec << " " << cell_edid << " REFR 0x" << std::hex << placement.refr_form_id << " TERM 0x" << placement.base_form_id << std::dec << " " << placement.base_editor_id << "\n";
			}
		});
	}
	if (!cell_filter.empty()) {
		auto cell = file.find_cell_by_editor_id(cell_filter);
		if (!cell) {
			std::cerr << "CELL not found: " << cell_filter << "\n";
			return 1;
		}
		std::cout << "TERM placements in " << cell_filter << ":\n";
		for (const auto &placement : file.get_cell_references(*cell)) {
			if (placement.base_type == "TERM")
				std::cout << "  REFR 0x" << std::hex << placement.refr_form_id << " base 0x" << placement.base_form_id << std::dec << " " << placement.base_editor_id << "\n";
		}
	}
}
