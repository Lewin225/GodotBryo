#ifndef TERRAIN_REGION_STAGER_H
#define TERRAIN_REGION_STAGER_H

#include "esm/esm_file.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <array>
#include <map>
#include <memory>
#include <set>
#include <mutex>
#include <string>

namespace godot {

// Worker-owned LAND catalogue and region composer. Each instance owns its ESM
// reader and decoded catalogue; it never receives Terrain3D or scene objects.
class TerrainRegionStager : public RefCounted {
	GDCLASS(TerrainRegionStager, RefCounted)

	struct CellPayload {
		struct QuadrantLayers {
			uint32_t base_ltex_form_id = 0;
			std::vector<size_t> overlay_indices;
		};
		uint32_t cell_form_id = 0;
		esm::LandData land;
		std::array<QuadrantLayers, esm::kLandQuadrantCount> quadrants;
	};
	struct WorldCatalogue {
		std::map<std::pair<int, int>, CellPayload> cells;
		std::set<std::pair<int, int>> touched_regions;
		std::set<uint32_t> ltex_form_ids;
		int min_region_x = 0;
		int max_region_x = -1;
		int min_region_y = 0;
		int max_region_y = -1;
	};

	std::unique_ptr<esm::EsmFile> esm_file_;
	std::string esm_path_;
	std::map<uint32_t, std::shared_ptr<WorldCatalogue>> catalogues_;
	static std::mutex shared_catalogue_mutex_;
	// Process-lifetime cache for the current finite-master scope. If DLC/mod
	// worldspaces expand this set, add an explicit eviction/ownership policy;
	// TerrainStreamer.deactivate() cannot currently reclaim these shared values.
	static std::map<std::pair<std::string, uint32_t>, std::shared_ptr<WorldCatalogue>> shared_catalogues_;
	String last_error_;

	bool build_catalogue(uint32_t p_worldspace_form_id, WorldCatalogue &r_catalogue);

protected:
	static void _bind_methods();

public:
	bool open_esm(const String &path);
	String get_last_error() const { return last_error_; }
	Dictionary index_worldspace(int64_t worldspace_form_id);
	Dictionary compose_region(int64_t worldspace_form_id, const Vector2i &region_location,
			const Dictionary &logical_slots);
	// Deterministic synthetic-fixture hook for the computed-normal fallback.
	// Real usable FalloutNV.esm first-LAND payloads all contain VNML, so this
	// keeps the otherwise-unreachable fallback under byte-level test coverage.
	PackedByteArray compose_computed_normal_fixture(const PackedFloat32Array &heights);
};

} // namespace godot

#endif
