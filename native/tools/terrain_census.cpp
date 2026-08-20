// terrain_census — one-off research tool for phases/2/13-terrain3d-integration.md.
//
// Answers three of that design doc's "open questions requiring real-data
// research" directly against the real FalloutNV.esm (+ optionally DLC
// masters passed as extra args):
//
//   1. Real ATXT/VTXT layer counts per LAND record (currently not decoded
//      anywhere in esm_file.cpp's get_land_data() — this tool parses them
//      independently, read-only, without touching that shared code path).
//   2. Distinct LTEX/TXST ground textures actually referenced across every
//      LAND record found (BTXT + ATXT), to check against Terrain3D's
//      32-slot global texture list.
//   3. A full subrecord-type inventory of every LTEX and TXST record in the
//      file, to check whether either carries any grass-related field at
//      all (candidate name unconfirmed — this just prints every subrecord
//      tag actually present so real data settles it either way).
//
// No Godot dependency, same build pattern as dump_object.cpp.

#include "../src/esm/esm_file.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

using namespace esm;

namespace {

struct LandLayers {
	int atxt_count = 0; // additional layers beyond BTXT's base 4 (one per quadrant), whole cell
	int atxt_per_quadrant[4] = { 0, 0, 0, 0 }; // the number that actually matters for a
	// per-pixel 2-layer (base+overlay) control map: how many ADDITIONAL layers stack on
	// top of BTXT within one quadrant's 17x17 sub-grid, not summed across all 4.
	int vtxt_count = 0;
	std::set<uint32_t> ltex_ids; // BTXT + ATXT ltex form ids referenced by this cell
};

void scan_land(const EsmFile &esm, const RecordInfo &land, LandLayers &out, std::set<uint32_t> &global_ltex, std::map<int, int> &atxt_per_cell_histogram) {
	std::vector<uint8_t> data = esm.read_record_data(land);
	std::vector<Subrecord> subs = EsmFile::parse_subrecords(data);

	int cell_atxt = 0;
	for (const auto &s : subs) {
		if (s.type == "BTXT" && s.size >= 8) {
			uint32_t ltex_id;
			std::memcpy(&ltex_id, s.data, 4);
			if (ltex_id != 0) {
				out.ltex_ids.insert(ltex_id);
				global_ltex.insert(ltex_id);
			}
		} else if (s.type == "ATXT" && s.size >= 8) {
			uint32_t ltex_id;
			std::memcpy(&ltex_id, s.data, 4);
			uint8_t quadrant = s.data[4];
			out.atxt_count++;
			cell_atxt++;
			if (quadrant < 4) {
				out.atxt_per_quadrant[quadrant]++;
			}
			if (ltex_id != 0) {
				out.ltex_ids.insert(ltex_id);
				global_ltex.insert(ltex_id);
			}
		} else if (s.type == "VTXT") {
			out.vtxt_count++;
		}
	}
	atxt_per_cell_histogram[cell_atxt]++;
}

int floor_div(int a, int b) {
	int q = a / b;
	int r = a % b;
	if (r != 0 && ((r < 0) != (b < 0))) {
		--q;
	}
	return q;
}

std::string path_basename(const std::string &path) {
	size_t pos = path.find_last_of('/');
	return pos == std::string::npos ? path : path.substr(pos + 1);
}

void scan_ltex_txst_subrecords(const EsmFile &esm, const RecordInfo &rec, std::map<std::string, int> &tag_counts, std::map<std::string, std::vector<std::pair<std::string, size_t>>> *examples) {
	std::vector<uint8_t> data = esm.read_record_data(rec);
	std::vector<Subrecord> subs = EsmFile::parse_subrecords(data);
	std::string edid;
	for (const auto &s : subs) {
		tag_counts[s.type]++;
		if (s.type == "EDID") {
			edid.assign(reinterpret_cast<const char *>(s.data), s.size);
		}
		if (examples && (*examples)[s.type].size() < 3) {
			(*examples)[s.type].push_back({ edid, s.size });
		}
	}
}

} // namespace

int main(int argc, char **argv) {
	if (argc < 2) {
		std::fprintf(stderr, "usage: %s FalloutNV.esm [extra.esm ...]\n", argv[0]);
		return 1;
	}

	int total_land = 0;
	int cells_with_atxt = 0;
	int max_atxt_in_one_cell = 0;
	int max_atxt_in_one_quadrant = 0;
	long long total_atxt = 0;
	long long total_vtxt = 0;
	std::set<uint32_t> global_ltex;
	std::map<int, int> atxt_per_cell_histogram; // atxt-count-in-cell -> number of cells with that count
	std::map<int, int> atxt_per_quadrant_histogram; // atxt-count-in-ONE-quadrant -> number of quadrants with that count

	std::map<std::string, int> ltex_tag_counts;
	std::map<std::string, std::vector<std::pair<std::string, size_t>>> ltex_examples;
	int ltex_count = 0;

	std::map<std::string, int> txst_tag_counts;
	std::map<std::string, std::vector<std::pair<std::string, size_t>>> txst_examples;
	int txst_count = 0;

	std::map<std::string, int> gras_tag_counts;
	std::map<std::string, std::vector<std::pair<std::string, size_t>>> gras_examples;
	int gras_count_total = 0;

	for (int i = 1; i < argc; ++i) {
		std::string path = argv[i];
		std::printf("=== %s ===\n", path.c_str());
		EsmFile esm;
		try {
			esm.open(path);
		} catch (const std::exception &e) {
			std::fprintf(stderr, "  failed to open: %s\n", e.what());
			continue;
		}

		int land_errors = 0;
		esm.for_each_record([&](const RecordInfo &rec) {
			try {
				if (rec.type == "LAND") {
					total_land++;
					LandLayers layers;
					scan_land(esm, rec, layers, global_ltex, atxt_per_cell_histogram);
					total_atxt += layers.atxt_count;
					total_vtxt += layers.vtxt_count;
					if (layers.atxt_count > 0) {
						cells_with_atxt++;
					}
					if (layers.atxt_count > max_atxt_in_one_cell) {
						max_atxt_in_one_cell = layers.atxt_count;
					}
					for (int q = 0; q < 4; ++q) {
						atxt_per_quadrant_histogram[layers.atxt_per_quadrant[q]]++;
						if (layers.atxt_per_quadrant[q] > max_atxt_in_one_quadrant) {
							max_atxt_in_one_quadrant = layers.atxt_per_quadrant[q];
						}
					}
				} else if (rec.type == "LTEX") {
					ltex_count++;
					scan_ltex_txst_subrecords(esm, rec, ltex_tag_counts, &ltex_examples);
				} else if (rec.type == "TXST") {
					txst_count++;
					scan_ltex_txst_subrecords(esm, rec, txst_tag_counts, &txst_examples);
				} else if (rec.type == "GRAS") {
					gras_count_total++;
					scan_ltex_txst_subrecords(esm, rec, gras_tag_counts, &gras_examples);
				}
			} catch (const std::exception &e) {
				land_errors++;
			}
		});
		if (land_errors > 0) {
			std::fprintf(stderr, "  %d record(s) in %s failed to decompress/parse and were skipped\n", land_errors, path.c_str());
		}
	}

	std::printf("\n--- LAND / ATXT / VTXT census ---\n");
	std::printf("LAND records scanned:        %d\n", total_land);
	std::printf("cells with >=1 ATXT layer:    %d (%.1f%%)\n", cells_with_atxt, total_land ? 100.0 * cells_with_atxt / total_land : 0.0);
	std::printf("max ATXT layers in one cell (summed across all 4 quadrants): %d\n", max_atxt_in_one_cell);
	std::printf("max ATXT layers in a SINGLE quadrant (the number that actually matters for a\n");
	std::printf("  per-pixel base+overlay control map, since each quadrant paints independently): %d\n", max_atxt_in_one_quadrant);
	std::printf("  (so max simultaneous layers at one point incl. BTXT base = up to %d)\n", max_atxt_in_one_quadrant + 1);
	std::printf("total ATXT subrecords:        %lld\n", total_atxt);
	std::printf("total VTXT subrecords:        %lld\n", total_vtxt);
	std::printf("ATXT-count-per-cell histogram (atxt_count -> num_cells):\n");
	for (const auto &kv : atxt_per_cell_histogram) {
		std::printf("  %2d ATXT: %6d cells\n", kv.first, kv.second);
	}
	std::printf("ATXT-count-per-QUADRANT histogram (atxt_count_in_one_quadrant -> num_quadrants):\n");
	for (const auto &kv : atxt_per_quadrant_histogram) {
		std::printf("  %2d ATXT: %6d quadrants\n", kv.first, kv.second);
	}

	std::printf("\n--- LTEX/TXST texture budget census ---\n");
	std::printf("distinct LTEX FormIDs referenced by any LAND BTXT/ATXT: %zu\n", global_ltex.size());
	std::printf("(Terrain3D control map budget: 32 global slots)\n");
	std::printf("total LTEX records in file(s): %d\n", ltex_count);
	std::printf("total TXST records in file(s): %d\n", txst_count);

	std::printf("\n--- LTEX subrecord tag inventory (hunting for grass fields) ---\n");
	for (const auto &kv : ltex_tag_counts) {
		std::printf("  %s : %d occurrences, %zu example(s):\n", kv.first.c_str(), kv.second, ltex_examples[kv.first].size());
		for (const auto &ex : ltex_examples[kv.first]) {
			std::printf("      edid=%-30s size=%zu\n", ex.first.c_str(), ex.second);
		}
	}

	std::printf("\n--- TXST subrecord tag inventory (hunting for grass fields) ---\n");
	for (const auto &kv : txst_tag_counts) {
		std::printf("  %s : %d occurrences, %zu example(s):\n", kv.first.c_str(), kv.second, txst_examples[kv.first].size());
		for (const auto &ex : txst_examples[kv.first]) {
			std::printf("      edid=%-30s size=%zu\n", ex.first.c_str(), ex.second);
		}
	}

	std::printf("\n--- GRAS subrecord tag inventory ---\n");
	for (const auto &kv : gras_tag_counts) {
		std::printf("  %s : %d occurrences, %zu example(s):\n", kv.first.c_str(), kv.second, gras_examples[kv.first].size());
		for (const auto &ex : gras_examples[kv.first]) {
			std::printf("      edid=%-30s size=%zu\n", ex.first.c_str(), ex.second);
		}
	}

	std::printf("\n--- per-worldspace LTEX budget (is the 32-slot limit a per-file or per-worldspace problem?) ---\n");
	for (int i = 1; i < argc; ++i) {
		EsmFile esm;
		try {
			esm.open(argv[i]);
		} catch (...) {
			continue;
		}
		std::vector<RecordInfo> wrlds;
		esm.for_each_record([&](const RecordInfo &rec) {
			if (rec.type == "WRLD") {
				wrlds.push_back(rec);
			}
		});
		for (const auto &wrld : wrlds) {
			try {
				std::vector<uint8_t> data = esm.read_record_data(wrld);
				std::vector<Subrecord> subs = EsmFile::parse_subrecords(data);
				std::string edid;
				for (const auto &s : subs) {
					if (s.type == "EDID") {
						edid.assign(reinterpret_cast<const char *>(s.data), s.size);
						if (!edid.empty() && edid.back() == '\0') edid.pop_back();
						break;
					}
				}
				std::vector<RecordInfo> children = esm.get_child_records(wrld);
				std::set<uint32_t> ws_ltex;
				int ws_land_count = 0;
				int ws_max_atxt = 0;
				for (const auto &child : children) {
					if (child.type != "LAND") continue;
					try {
						ws_land_count++;
						LandLayers layers;
						std::map<int, int> dummy_hist;
						std::set<uint32_t> dummy_global;
						scan_land(esm, child, layers, dummy_global, dummy_hist);
						for (uint32_t id : layers.ltex_ids) ws_ltex.insert(id);
						if (layers.atxt_count > ws_max_atxt) ws_max_atxt = layers.atxt_count;
					} catch (...) {
					}
				}
				if (ws_land_count > 0) {
					// Dedupe by resolved texture path (LTEX -> TXST -> TX00), not
					// just raw LTEX FormID -- distinct LTEX records can point at
					// the exact same .dds (e.g. gameplay-material-only variants
					// sharing one visual), so the real Terrain3D slot count may
					// be smaller than the raw FormID count.
					std::map<std::string, std::vector<uint32_t>> path_to_ltex;
					int unresolved = 0;
					for (uint32_t id : ws_ltex) {
						std::string tex_path = esm.resolve_ltex_texture_path(id);
						if (tex_path.empty()) {
							unresolved++;
							continue;
						}
						path_to_ltex[tex_path].push_back(id);
					}
					std::printf("  %-20s (%s): %d LAND cells, %zu distinct LTEX, %zu distinct TEXTURE PATHS (%d unresolved), max %d ATXT/cell\n",
							edid.c_str(), path_basename(argv[i]).c_str(), ws_land_count, ws_ltex.size(), path_to_ltex.size(), unresolved, ws_max_atxt);
					if (ws_ltex.size() > 32) {
						std::printf("      -- over 32-slot budget, dumping duplicate-path groups + full path list --\n");
						bool any_dupes = false;
						for (const auto &kv : path_to_ltex) {
							if (kv.second.size() > 1) {
								any_dupes = true;
								std::printf("      DUPLICATE (%zu LTEX -> 1 path): %s\n", kv.second.size(), kv.first.c_str());
								for (uint32_t id : kv.second) {
									std::printf("          ltex_form_id=0x%06X\n", id);
								}
							}
						}
						if (!any_dupes) {
							std::printf("      (no exact path duplicates found -- all %zu paths distinct)\n", path_to_ltex.size());
						}
						std::printf("      full distinct path list (%zu):\n", path_to_ltex.size());
						for (const auto &kv : path_to_ltex) {
							std::printf("          %s  (%zu ltex)\n", kv.first.c_str(), kv.second.size());
						}

						// Per-REGION locality: does any single Terrain3D region
						// (16x16 cells, matching the region_size=512 alignment
						// proposed in phases/2/13-terrain3d-integration.md) ever
						// actually need more than 32 distinct textures at once,
						// even though the worldspace as a whole does? If ground
						// textures are geographically clustered (a real, likely
						// property -- biomes don't teleport around the map),
						// per-region local diversity could be far under the
						// worldspace-wide total, which would mean per-region (or
						// per-zone) texture-list scoping actually solves the
						// budget gap instead of needing lossy reduction.
						constexpr int kCellsPerRegion = 8; // region_size=256 / 32 cell-intervals -- see design doc's cell-alignment section
						std::map<std::pair<int, int>, std::set<std::string>> region_paths;
						int cur_x = 0, cur_y = 0;
						bool have_cur = false;
						for (const auto &child : children) {
							if (child.type == "CELL") {
								auto grid = esm.get_exterior_cell_grid(child.form_id);
								if (grid) {
									cur_x = grid->x;
									cur_y = grid->y;
									have_cur = true;
								} else {
									have_cur = false;
								}
							} else if (child.type == "LAND" && have_cur) {
								try {
									LandLayers layers;
									std::map<int, int> dummy_hist;
									std::set<uint32_t> dummy_global;
									scan_land(esm, child, layers, dummy_global, dummy_hist);
									auto region_key = std::make_pair(floor_div(cur_x, kCellsPerRegion), floor_div(cur_y, kCellsPerRegion));
									for (uint32_t id : layers.ltex_ids) {
										std::string p = esm.resolve_ltex_texture_path(id);
										if (!p.empty()) {
											region_paths[region_key].insert(p);
										}
									}
								} catch (...) {
								}
							}
						}
						size_t max_region_textures = 0;
						std::pair<int, int> max_region_key;
						int regions_over_32 = 0;
						for (const auto &kv : region_paths) {
							if (kv.second.size() > max_region_textures) {
								max_region_textures = kv.second.size();
								max_region_key = kv.first;
							}
							if (kv.second.size() > 32) {
								regions_over_32++;
							}
						}
						std::printf("      -- per-%dx%d-cell REGION locality (kCellsPerRegion=%d) --\n", kCellsPerRegion, kCellsPerRegion, kCellsPerRegion);
						std::printf("      %zu regions covered; max distinct textures in any ONE region: %zu (at region (%d,%d)); regions exceeding 32: %d\n",
								region_paths.size(), max_region_textures, max_region_key.first, max_region_key.second, regions_over_32);

						// A single region fitting under 32 doesn't prove the
						// texture LIST fits under 32 if the streamer keeps
						// several NEIGHBORING regions concurrently resident (a
						// player near a region boundary needs that region's
						// neighbors loaded too) -- check the union of each
						// region's own set with its 8 immediate neighbors (a 3x3
						// block, the realistic minimum concurrently-resident set
						// for smooth streaming across a boundary).
						size_t max_union9 = 0;
						std::pair<int, int> max_union9_key;
						int union9_over_32 = 0;
						for (const auto &kv : region_paths) {
							std::set<std::string> u = kv.second;
							for (int dx = -1; dx <= 1; ++dx) {
								for (int dy = -1; dy <= 1; ++dy) {
									if (dx == 0 && dy == 0) continue;
									auto it = region_paths.find({ kv.first.first + dx, kv.first.second + dy });
									if (it != region_paths.end()) {
										u.insert(it->second.begin(), it->second.end());
									}
								}
							}
							if (u.size() > max_union9) {
								max_union9 = u.size();
								max_union9_key = kv.first;
							}
							if (u.size() > 32) {
								union9_over_32++;
							}
						}
						std::printf("      3x3-region-block UNION (realistic concurrently-resident set): max = %zu (centered at region (%d,%d)); center-regions whose 3x3 union exceeds 32: %d\n",
								max_union9, max_union9_key.first, max_union9_key.second, union9_over_32);
						std::vector<std::pair<std::pair<int, int>, size_t>> sorted_regions;
						for (const auto &kv : region_paths) {
							sorted_regions.push_back({ kv.first, kv.second.size() });
						}
						std::sort(sorted_regions.begin(), sorted_regions.end(), [](const auto &a, const auto &b) { return a.second > b.second; });
						std::printf("      all regions, sorted by distinct-texture count:\n");
						for (const auto &r : sorted_regions) {
							std::printf("          region (%3d,%3d): %2zu distinct textures%s\n", r.first.first, r.first.second, r.second, r.second > 32 ? "   <-- OVER BUDGET" : "");
						}
					}
				}
			} catch (const std::exception &e) {
				std::fprintf(stderr, "  (skipped one WRLD in %s: %s)\n", path_basename(argv[i]).c_str(), e.what());
			}
		}
	}

	std::printf("\n--- GRAS record presence check ---\n");
	// Also check whether any GRAS records exist at all in these files, and
	// whether LTEX/TXST reference one (grep the tag inventories above for a
	// field pointing at a GRAS -- printed generically since we don't know
	// the subrecord tag ahead of time).
	for (int i = 1; i < argc; ++i) {
		EsmFile esm;
		try {
			esm.open(argv[i]);
		} catch (...) {
			continue;
		}
		int gras_count = 0;
		esm.for_each_record([&](const RecordInfo &rec) {
			if (rec.type == "GRAS") {
				gras_count++;
			}
		});
		std::printf("  %s: %d GRAS records\n", argv[i], gras_count);
	}

	return 0;
}
