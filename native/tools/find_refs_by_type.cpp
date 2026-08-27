// One-off: find real DOOR placements near Goodsprings (for a controller-
// flags comparison against the animated saloon sign) and any windmill/
// windvane-named STAT anywhere in WastelandNV.
#include "esm/esm_file.h"
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <string>

static std::string lower(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
	return s;
}

int main() {
	esm::EsmFile esm;
	try {
		esm.open("fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}
	auto wrld = esm.find_worldspace_by_editor_id("WastelandNV");
	if (!wrld) return 1;
	for (int32_t gx = -19; gx <= -16; ++gx) {
		for (int32_t gy = -1; gy <= 1; ++gy) {
			auto cell = esm.find_exterior_cell(wrld->form_id, gx, gy);
			if (!cell) continue;
			for (const auto &r : esm.get_cell_references(*cell)) {
				if (r.base_type == "DOOR")
					printf("DOOR (%d,%d) edid=%s model=%s\n", gx, gy, r.base_editor_id.c_str(), r.model_path.c_str());
				std::string needle = lower(r.base_editor_id) + " " + lower(r.model_path);
				if (needle.find("wind") != std::string::npos || needle.find("vane") != std::string::npos || needle.find("mill") != std::string::npos)
					printf("WIND (%d,%d) base=%s edid=%s model=%s\n", gx, gy, r.base_type.c_str(), r.base_editor_id.c_str(), r.model_path.c_str());
			}
		}
	}
	return 0;
}
