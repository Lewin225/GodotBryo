// Issue #52 chunk 1: verifies EsmFile::get_cell_actors() against real data --
// the Goodsprings exterior cell (WastelandNV, -17,0), independently known
// (test_phase1_integration.gd's own census check) to contain a genuine ACRE
// but no ACHR, and GSDocMitchellHouse, which should contain Doc Mitchell as
// an ACHR. Confirms ACHR/ACRE share REFR's NAME/DATA/XSCL subrecord layout
// (this project's own get_cell_references() precedent) rather than assuming it.
#include "esm/esm_file.h"

#include <cstdio>

namespace {
int failures = 0;

void check(bool cond, const char *msg) {
	if (cond) {
		printf("  OK   %s\n", msg);
	} else {
		printf("  FAIL %s\n", msg);
		failures++;
	}
}
} // namespace

int main() {
	esm::EsmFile esm_file;
	try {
		esm_file.open("fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}

	printf("=== Goodsprings exterior (-17, 0): expect ACRE, no ACHR ===\n");
	auto wrld = esm_file.find_worldspace_by_editor_id("WastelandNV");
	check(wrld.has_value(), "found WastelandNV worldspace");
	if (wrld) {
		auto cell = esm_file.find_exterior_cell(wrld->form_id, -17, 0);
		check(cell.has_value(), "found Goodsprings (-17,0) cell record");
		if (cell) {
			auto actors = esm_file.get_cell_actors(*cell);
			int achr = 0, acre = 0;
			for (const auto &a : actors) {
				if (a.base_type == "NPC_") achr++;
				else if (a.base_type == "CREA") acre++;
				printf("  actor refr=%08X base=%08X base_type=%s edid=%s pos=(%.2f,%.2f,%.2f)\n",
						a.refr_form_id, a.base_form_id, a.base_type.c_str(), a.base_editor_id.c_str(),
						a.position[0], a.position[1], a.position[2]);
			}
			check(acre > 0, "found at least one real ACRE (creature) placement");
			printf("  (achr=%d acre=%d)\n", achr, acre);
		}
	}

	printf("=== GSDocMitchellHouse: expect an ACHR resolving to NPC_ ===\n");
	auto house = esm_file.find_cell_by_editor_id("GSDocMitchellHouse");
	check(house.has_value(), "found GSDocMitchellHouse cell record");
	if (house) {
		auto actors = esm_file.get_cell_actors(*house);
		bool found_npc = false;
		for (const auto &a : actors) {
			printf("  actor refr=%08X base=%08X base_type=%s edid=%s pos=(%.2f,%.2f,%.2f)\n",
					a.refr_form_id, a.base_form_id, a.base_type.c_str(), a.base_editor_id.c_str(),
					a.position[0], a.position[1], a.position[2]);
			if (a.base_type == "NPC_") found_npc = true;
		}
		check(found_npc, "found at least one real ACHR resolving to an NPC_ base record");
	}

	printf("=======================\n");
	if (failures == 0) {
		printf("ALL CHECKS PASSED\n");
	} else {
		printf("FAILURES: %d\n", failures);
	}
	return failures > 0 ? 1 : 0;
}
