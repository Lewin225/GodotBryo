// terrain_worldspace_census -- finite LAND queue-domain research for issue #19.
//
// Scans each supplied master independently, but identifies terrain through the
// owning exterior CELL rather than walking a WRLD's nested child GRUP. That
// matters because some real DLC WRLD groups contain structures the old broad
// walk cannot consume, while EsmFile's CELL ownership/grid APIs already handle
// their actual on-disk hierarchy correctly.
//
// Reports, per terrain-owning worldspace: real LAND coordinates, the finite
// rectangular coordinate domain and its holes, logical LTEX identities, and
// the actual Terrain3D region range implied by Terrain3DBridge's transform.

#include "../src/esm/esm_file.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <vector>

using namespace esm;

namespace {

constexpr int kCellIntervals = 32;
constexpr int kTerrainRegionSize = 256;
constexpr int kTerrainRegionMapSize = 32;
constexpr int kTerrainRegionMin = -kTerrainRegionMapSize / 2;
constexpr int kTerrainRegionMax = kTerrainRegionMapSize / 2 - 1;

struct WorldspaceStats {
	std::string editor_id;
	std::set<std::pair<int, int>> exterior_cells;
	std::set<std::pair<int, int>> land_cells;
	std::set<uint32_t> ltex_ids;
	std::set<std::pair<int, int>> terrain_regions;
	int usable_land_payloads = 0;
	int unusable_first_land_payloads = 0;
	int malformed_cells = 0;
};

int floor_div(int value, int divisor) {
	int quotient = value / divisor;
	int remainder = value % divisor;
	if (remainder != 0 && ((remainder < 0) != (divisor < 0))) {
		--quotient;
	}
	return quotient;
}

std::string editor_id(const EsmFile &esm, const RecordInfo &record) {
	const std::vector<uint8_t> data = esm.read_record_data(record);
	for (const Subrecord &sub : EsmFile::parse_subrecords(data)) {
		if (sub.type == "EDID") {
			return sub.as_string();
		}
	}
	return "<unnamed>";
}

void collect_ltex_ids(const EsmFile &esm, const RecordInfo &land, std::set<uint32_t> &out) {
	const std::vector<uint8_t> data = esm.read_record_data(land);
	for (const Subrecord &sub : EsmFile::parse_subrecords(data)) {
		if ((sub.type != "BTXT" && sub.type != "ATXT") || sub.size < 4) {
			continue;
		}
		uint32_t form_id = 0;
		std::memcpy(&form_id, sub.data, sizeof(form_id));
		if (form_id != 0) {
			out.insert(form_id);
		}
	}
}

void add_terrain_regions(WorldspaceStats &stats, int grid_x, int grid_y) {
	const int x0 = grid_x * kCellIntervals;
	const int x1 = x0 + kCellIntervals;
	// Terrain3DBridge flips LAND rows and maps Bethesda +Y to Godot -Z:
	// z = -32 * (grid_y + 1) through -32 * grid_y, inclusive at both edges.
	const int z0 = -kCellIntervals * (grid_y + 1);
	const int z1 = -kCellIntervals * grid_y;
	for (const int region_x : { floor_div(x0, kTerrainRegionSize), floor_div(x1, kTerrainRegionSize) }) {
		for (const int region_z : { floor_div(z0, kTerrainRegionSize), floor_div(z1, kTerrainRegionSize) }) {
			stats.terrain_regions.insert({ region_x, region_z });
		}
	}
}

void print_coordinate_domain(const std::set<std::pair<int, int>> &coords, const char *label) {
	if (coords.empty()) {
		std::printf("  %s: none\n", label);
		return;
	}
	int min_x = coords.begin()->first;
	int max_x = min_x;
	int min_y = coords.begin()->second;
	int max_y = min_y;
	for (const auto &[x, y] : coords) {
		min_x = std::min(min_x, x);
		max_x = std::max(max_x, x);
		min_y = std::min(min_y, y);
		max_y = std::max(max_y, y);
	}
	const long long rectangular_count = static_cast<long long>(max_x - min_x + 1) * (max_y - min_y + 1);
	const long long holes = rectangular_count - static_cast<long long>(coords.size());
	std::printf("  %s: %zu; grid x=[%d, %d], y=[%d, %d]; rectangular domain=%lld, holes=%lld\n",
			label, coords.size(), min_x, max_x, min_y, max_y, rectangular_count, holes);
}

void print_region_domain(const std::set<std::pair<int, int>> &regions) {
	if (regions.empty()) {
		std::printf("  Terrain3D regions: none\n");
		return;
	}
	int min_x = regions.begin()->first;
	int max_x = min_x;
	int min_z = regions.begin()->second;
	int max_z = min_z;
	for (const auto &[x, z] : regions) {
		min_x = std::min(min_x, x);
		max_x = std::max(max_x, x);
		min_z = std::min(min_z, z);
		max_z = std::max(max_z, z);
	}
	const long long rectangular_layers = static_cast<long long>(max_x - min_x + 1) * (max_z - min_z + 1);
	const bool fits = min_x >= kTerrainRegionMin && max_x <= kTerrainRegionMax
		&& min_z >= kTerrainRegionMin && max_z <= kTerrainRegionMax;
	std::printf("  Terrain3D regions touched: %zu; x=[%d, %d], z=[%d, %d]; fixed-layer rectangle=%lld; %s 32x32 bounds [%d, %d]\n",
			regions.size(), min_x, max_x, min_z, max_z, rectangular_layers,
			fits ? "fits" : "EXCEEDS", kTerrainRegionMin, kTerrainRegionMax);
}

} // namespace

int main(int argc, char **argv) {
	std::string csv_path;
	std::vector<std::string> esm_paths;
	for (int arg = 1; arg < argc; ++arg) {
		if (std::string(argv[arg]) == "--csv") {
			if (arg + 1 >= argc) {
				std::fprintf(stderr, "--csv requires an output path\n");
				return 1;
			}
			csv_path = argv[++arg];
			continue;
		}
		esm_paths.emplace_back(argv[arg]);
	}
	if (esm_paths.empty()) {
		std::fprintf(stderr, "usage: %s [--csv queue.csv] FalloutNV.esm [DLC.esm ...]\n", argv[0]);
		return 1;
	}
	std::ofstream csv;
	if (!csv_path.empty()) {
		csv.open(csv_path);
		if (!csv) {
			std::fprintf(stderr, "could not open CSV output: %s\n", csv_path.c_str());
			return 1;
		}
		csv << "source_esm,wrld_form_id,wrld_editor_id,grid_x,grid_y\n";
	}

	for (const std::string &path : esm_paths) {
		EsmFile esm;
		try {
			esm.open(path);
		} catch (const std::exception &error) {
			std::fprintf(stderr, "%s: failed to open: %s\n", path.c_str(), error.what());
			continue;
		}

		std::map<uint32_t, WorldspaceStats> worlds;
		std::map<uint32_t, std::string> defined_world_names;
		esm.for_each_record([&](const RecordInfo &record) {
			if (record.type == "WRLD") {
				try {
					const std::string name = editor_id(esm, record);
					// Later override records can omit EDID. Keep the authored name
					// discovered on the defining record rather than replacing it
					// with that legitimate empty override.
					if (!name.empty()) {
						defined_world_names[record.form_id] = name;
					}
				} catch (const std::exception &) {
					worlds[record.form_id].editor_id = "<unreadable EDID>";
				}
				return;
			}
			if (record.type != "CELL") {
				return;
			}
			try {
				auto grid = esm.get_exterior_cell_grid(record.form_id);
				auto world_id = esm.get_cell_worldspace(record.form_id);
				if (!grid || !world_id) {
					return;
				}
				// A WRLD persistent CELL can carry XCLC too, and must never enter
				// the terrain queue. find_exterior_cell() walks Bethesda's actual
				// Block/Sub-Block hierarchy and therefore accepts only a real grid
				// tile at this coordinate.
				auto indexed_cell = esm.find_exterior_cell(*world_id, grid->x, grid->y);
				if (!indexed_cell || indexed_cell->form_id != record.form_id) {
					return;
				}
				WorldspaceStats &stats = worlds[*world_id];
				const std::pair<int, int> coord { grid->x, grid->y };
				stats.exterior_cells.insert(coord);
				// Match EsmReader.get_land_data(cell_form_id) exactly: first LAND
				// child wins. Some real CELL child walks expose later LAND records;
				// counting all of them would invent payloads the live bridge cannot
				// currently read.
				for (const RecordInfo &child : esm.get_child_records(record)) {
					if (child.type != "LAND") {
						continue;
					}
					if (!esm.get_land_data(child)) {
						stats.unusable_first_land_payloads++;
						break;
					}
					stats.usable_land_payloads++;
					stats.land_cells.insert(coord);
					collect_ltex_ids(esm, child, stats.ltex_ids);
					add_terrain_regions(stats, grid->x, grid->y);
					break;
				}
			} catch (const std::exception &) {
				auto grid = esm.get_exterior_cell_grid(record.form_id);
				auto world_id = esm.get_cell_worldspace(record.form_id);
				if (grid && world_id) {
					worlds[*world_id].malformed_cells++;
				}
			}
		});

		std::printf("=== %s ===\n", path.c_str());
		int terrain_worlds = 0;
		for (const auto &[form_id, stats] : worlds) {
			if (stats.land_cells.empty()) {
				continue;
			}
			terrain_worlds++;
			const auto defined_name = defined_world_names.find(form_id);
			const std::string name = defined_name == defined_world_names.end()
				? "<WRLD definition not found in this file>"
				: defined_name->second;
			std::printf("WRLD %s (0x%08X)\n", name.c_str(), form_id);
			if (csv) {
				for (const auto &[x, y] : stats.land_cells) {
					csv << path << ",0x";
					char form_id_hex[9];
					std::snprintf(form_id_hex, sizeof(form_id_hex), "%08X", form_id);
					csv << form_id_hex << ',' << name << ',' << x << ',' << y << '\n';
				}
			}
			print_coordinate_domain(stats.exterior_cells, "Exterior CELL coordinates");
			print_coordinate_domain(stats.land_cells, "LAND queue coordinates");
			std::printf("  Usable first-LAND payloads=%d; unusable first-LAND payloads=%d; distinct raw LTEX FormIDs=%zu; malformed CELL reads=%d\n",
				stats.usable_land_payloads, stats.unusable_first_land_payloads, stats.ltex_ids.size(), stats.malformed_cells);
			print_region_domain(stats.terrain_regions);
		}
		std::printf("Terrain-owning worldspaces: %d\n\n", terrain_worlds);
	}
	return 0;
}
