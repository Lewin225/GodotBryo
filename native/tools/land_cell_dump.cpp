// Ad-hoc diagnostic (phases/2/14-native-terrain-texture-blend.md): dumps one
// real cell's real BTXT/ATXT ground-texture references, resolved all the way
// to real texture paths, entirely offline (no Godot) -- for cross-checking
// against a live-play white-terrain-patch report without needing to
// instrument the running game.
#include "../src/esm/esm_file.h"
#include <cstdio>

using namespace esm;

int main(int argc, char **argv) {
	if (argc < 3) {
		std::printf("usage: land_cell_dump <esm> <cell_form_id_hex>\n");
		std::printf("       land_cell_dump <esm> <grid_x>,<grid_y> [worldspace_editor_id=WastelandNV]\n");
		return 1;
	}

	EsmFile f;
	try {
		f.open(argv[1]);
	} catch (const std::exception &e) {
		std::printf("failed to open %s: %s\n", argv[1], e.what());
		return 1;
	}

	std::optional<RecordInfo> cell;
	std::string arg2 = argv[2];
	size_t comma = arg2.find(',');
	if (comma != std::string::npos) {
		int32_t gx = std::atoi(arg2.substr(0, comma).c_str());
		int32_t gy = std::atoi(arg2.substr(comma + 1).c_str());
		std::string wrld_id = argc > 3 ? argv[3] : "WastelandNV";
		auto wrld = f.find_worldspace_by_editor_id(wrld_id);
		if (!wrld) {
			std::printf("Worldspace '%s' not found\n", wrld_id.c_str());
			return 1;
		}
		cell = f.find_exterior_cell(wrld->form_id, gx, gy);
		if (!cell) {
			std::printf("No real exterior cell at grid (%d, %d) in worldspace '%s'\n", gx, gy, wrld_id.c_str());
			return 1;
		}
	} else {
		uint32_t cell_form_id = static_cast<uint32_t>(std::strtoul(argv[2], nullptr, 16));
		cell = f.find_record_by_form_id(cell_form_id);
		if (!cell || cell->type != "CELL") {
			std::printf("FormID 0x%06X is not a real CELL record in this file\n", cell_form_id);
			return 1;
		}
	}
	uint32_t cell_form_id = cell->form_id;

	RecordInfo land_record;
	bool found_land = false;
	for (const auto &c : f.get_child_records(*cell)) {
		if (c.type == "LAND") {
			land_record = c;
			found_land = true;
			break;
		}
	}
	if (!found_land) {
		std::printf("Cell 0x%06X has no real LAND child record\n", cell_form_id);
		return 1;
	}

	auto land = f.get_land_data(land_record);
	if (!land) {
		std::printf("get_land_data() failed for cell 0x%06X\n", cell_form_id);
		return 1;
	}

	std::printf("Cell 0x%06X real LAND data:\n\n", cell_form_id);
	std::printf("Quadrant base (BTXT), fopdoc order 0=BL,1=BR,2=TL,3=TR:\n");
	for (int q = 0; q < kLandQuadrantCount; ++q) {
		uint32_t ltex = land->quadrant_base_ltex[q];
		if (ltex == 0) {
			std::printf("  quadrant %d: BTXT=0 (no real base texture)\n", q);
			continue;
		}
		std::string path = f.resolve_ltex_texture_path(ltex);
		std::printf("  quadrant %d: LTEX 0x%06X -> %s\n", q, ltex, path.empty() ? "(unresolved)" : path.c_str());
	}

	std::printf("\nReal ATXT overlay layers (%zu total):\n", land->alpha_layers.size());
	for (const auto &layer : land->alpha_layers) {
		std::string path = f.resolve_ltex_texture_path(layer.ltex_form_id);
		float mass = 0.0f;
		int nonzero = 0;
		for (float op : layer.opacity) {
			mass += op;
			if (op > 0.0f) nonzero++;
		}
		std::printf("  quadrant %d, layer_index %d: LTEX 0x%06X -> %s (opacity mass %.2f, %d/%zu nonzero verts)\n",
				layer.quadrant, layer.layer_index, layer.ltex_form_id,
				path.empty() ? "(unresolved)" : path.c_str(), mass, nonzero, layer.opacity.size());
	}

	std::printf("\nVCLR present: %s\n", land->vertex_colors.empty() ? "no" : "yes");
	std::printf("VNML present: %s\n", land->vertex_normals_raw.empty() ? "no" : "yes");
	return 0;
}
