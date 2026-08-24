// Lists the first placed KEYM references with their containing CELL. Build:
// g++ -std=c++17 -O2 -Isrc tools/keym_placements.cpp src/esm/esm_file.cpp -lz -o tools/keym_placements
#include "esm/esm_file.h"
#include <iostream>

int main(int argc, char **argv) {
	if (argc != 2) return 2;
	esm::EsmFile esm;
	esm.open(argv[1]);
	int found = 0;
	esm.for_each_record([&](const esm::RecordInfo &cell) {
		if (cell.type != "CELL" || found >= 20) return;
		std::string cell_edid;
		auto cell_bytes = esm.read_record_data(cell);
		for (const auto &s : esm::EsmFile::parse_subrecords(cell_bytes)) if (s.type == "EDID") cell_edid = s.as_string();
		for (const auto &p : esm.get_cell_references(cell)) {
			if (p.base_type != "KEYM") continue;
			std::cout << (cell_edid.empty() ? "(unnamed)" : cell_edid) << " CELL 0x" << std::hex << cell.form_id << "  KEYM 0x" << p.base_form_id
				<< "  REFR 0x" << p.refr_form_id << "  " << p.base_editor_id << "  " << p.model_path << "\n";
			++found;
			if (found >= 20) break;
		}
	});
}
