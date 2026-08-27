// One-off: find the hanging saloon sign (and its chain/beam parts) placed
// around Goodsprings exterior cell (-17, 0) in WastelandNV, to check whether
// its NIF is a plain NiNode chain or already has a bone/skin setup worth
// reusing as an early skeletal-animation test case.
#include "esm/esm_file.h"
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <string>

static std::string lower(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
	return s;
}

static void dump_cell(esm::EsmFile &esm, const esm::RecordInfo &cell, int32_t gx, int32_t gy) {
	auto refs = esm.get_cell_references(cell);
	for (const auto &r : refs) {
		std::string needle = lower(r.base_editor_id) + " " + lower(r.model_path);
		if (needle.find("sign") != std::string::npos || needle.find("chain") != std::string::npos ||
				needle.find("saloon") != std::string::npos) {
			printf("(%d,%d) base=%s edid=%s model=%s pos=(%.1f,%.1f,%.1f)\n",
					gx, gy, r.base_type.c_str(), r.base_editor_id.c_str(), r.model_path.c_str(),
					r.position[0], r.position[1], r.position[2]);
		}
	}
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
	if (!wrld) {
		fprintf(stderr, "no WastelandNV\n");
		return 1;
	}
	for (int32_t gx = -19; gx <= -16; ++gx) {
		for (int32_t gy = -1; gy <= 1; ++gy) {
			auto cell = esm.find_exterior_cell(wrld->form_id, gx, gy);
			if (cell) dump_cell(esm, *cell, gx, gy);
		}
	}
	return 0;
}
