// light_nif_correlation — throwaway scratch tool. Answers a real-data
// question: when a placed object's model has an authored NiLight block
// (e.g. lamplightchandelier.nif), is there a SEPARATE LIGH-type REFR
// nearby providing the actual in-game light, or is the NIF's own NiLight
// the only light source? Scans every CELL for a REFR whose base model
// matches, then lists every other REFR in that same cell with its
// distance from the match -- so LIGH refs sitting right on top of it are
// obvious, not asserted from memory.
//
// Usage: light_nif_correlation <DataDir> <esm file> <model path substr>

#include "../src/esm/esm_file.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <string>

static std::string to_lower(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
	return s;
}

int main(int argc, char **argv) {
	if (argc < 4) {
		std::cerr << "usage: light_nif_correlation <DataDir> <esm file> <model path substr>\n";
		return 1;
	}
	std::string data_dir = argv[1], esm_name = argv[2], pat = to_lower(argv[3]);

	esm::EsmFile esm_file;
	esm_file.open(data_dir + "/" + esm_name);

	int cells_checked = 0, matches = 0;
	esm_file.for_each_record([&](const esm::RecordInfo &r) {
		if (r.type != "CELL") return;
		cells_checked++;
		auto refs = esm_file.get_cell_references(r);

		// Find any REFR in this cell whose model matches the pattern.
		std::vector<const esm::ReferencePlacement *> target_refs;
		for (auto &p : refs) {
			if (to_lower(p.model_path).find(pat) != std::string::npos) {
				target_refs.push_back(&p);
			}
		}
		if (target_refs.empty()) return;

		matches++;
		std::string cell_edid = esm_file.get_cell_editor_id(r.form_id);
		std::cout << "\n=== CELL '" << cell_edid << "' (form_id=" << std::hex << r.form_id << std::dec
				  << ") -- " << refs.size() << " refs ===\n";
		for (auto *t : target_refs) {
			std::cout << "  MATCH refr=" << std::hex << t->refr_form_id << std::dec
					  << " base=" << t->base_type << " '" << t->base_editor_id << "'"
					  << " pos=(" << t->position[0] << "," << t->position[1] << "," << t->position[2] << ")\n";
			// Every other ref in the cell, sorted by distance to this match.
			std::vector<std::pair<float, const esm::ReferencePlacement *>> by_dist;
			for (auto &p : refs) {
				if (p.refr_form_id == t->refr_form_id) continue;
				float dx = p.position[0] - t->position[0];
				float dy = p.position[1] - t->position[1];
				float dz = p.position[2] - t->position[2];
				float d = std::sqrt(dx * dx + dy * dy + dz * dz);
				by_dist.push_back({ d, &p });
			}
			std::sort(by_dist.begin(), by_dist.end(), [](auto &a, auto &b) { return a.first < b.first; });
			int shown = 0;
			for (auto &kv : by_dist) {
				if (kv.second->base_type == "LIGH" && kv.first < 8.0f) { // positions are already meters (EsmFile::get_cell_references applies units::kGamebryoUnitsToMeters)
					std::cout << "    nearby LIGH: refr=" << std::hex << kv.second->refr_form_id << std::dec
							  << " '" << kv.second->base_editor_id << "'"
							  << " dist=" << kv.first << "m\n";
					shown++;
					if (shown >= 5) break;
				}
			}
			if (shown == 0) std::cout << "    (no LIGH refs within 8m in this cell)\n";
		}
	});

	std::cout << "\ncells checked: " << cells_checked << "  cells with a match: " << matches << "\n";
	return 0;
}
