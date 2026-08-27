#include "terrain_region_stager.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>

namespace godot {
std::mutex TerrainRegionStager::shared_catalogue_mutex_;
std::map<std::pair<std::string, uint32_t>, std::shared_ptr<TerrainRegionStager::WorldCatalogue>> TerrainRegionStager::shared_catalogues_;
namespace {
constexpr int REGION_SIZE = 256;
constexpr int CELL_SPAN = esm::kLandGridSize - 1;
constexpr float VERTEX_SPACING = 128.0f / 70.0f;
enum MapType { HEIGHT, CONTROL, COLOR, TEX_ID_A, TEX_ID_B, WEIGHT_A, WEIGHT_B, NORMAL, TYPE_MAX };

int floor_div(int value, int divisor) {
	int q = value / divisor;
	const int r = value % divisor;
	if (r != 0 && ((r < 0) != (divisor < 0))) --q;
	return q;
}
void add_regions(std::set<std::pair<int, int>> &regions, int x, int y) {
	const int x0 = x * CELL_SPAN, x1 = x0 + CELL_SPAN;
	const int z0 = -CELL_SPAN * (y + 1), z1 = -CELL_SPAN * y;
	for (int rx : { floor_div(x0, REGION_SIZE), floor_div(x1, REGION_SIZE) })
		for (int ry : { floor_div(z0, REGION_SIZE), floor_div(z1, REGION_SIZE) }) regions.insert({ rx, ry });
}
uint8_t unorm(float v) { return static_cast<uint8_t>(std::clamp(v, 0.0f, 1.0f) * 255.0f); }
uint8_t enc_normal(float v) { return unorm(v * 0.5f + 0.5f); }
struct Vec3 { float x = 0, y = 1, z = 0; };
Vec3 normalized(float x, float y, float z) {
	const float length = std::sqrt(x * x + y * y + z * z);
	return length > .0001f ? Vec3 { x / length, y / length, z / length } : Vec3 {};
}
Vec3 normal_for(const esm::LandData &land, int row, int col) {
	const size_t index = static_cast<size_t>(row * esm::kLandGridSize + col);
	if (land.vertex_normals_raw.size() >= (index + 1) * 3) {
		auto c = [&](size_t offset) { return float(static_cast<int8_t>(land.vertex_normals_raw[index * 3 + offset])) / 127.0f; };
		return normalized(c(0), c(2), -c(1));
	}
	const int l = std::max(col - 1, 0), r = std::min(col + 1, esm::kLandGridSize - 1);
	const int d = std::max(row - 1, 0), u = std::min(row + 1, esm::kLandGridSize - 1);
	const float hl = land.heights[row * esm::kLandGridSize + l], hr = land.heights[row * esm::kLandGridSize + r];
	const float hd = land.heights[d * esm::kLandGridSize + col], hu = land.heights[u * esm::kLandGridSize + col];
	return normalized(-2.0f * VERTEX_SPACING * (hr - hl), 4.0f * VERTEX_SPACING * VERTEX_SPACING,
			2.0f * VERTEX_SPACING * (hu - hd));
}
} // namespace

void TerrainRegionStager::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open_esm", "path"), &TerrainRegionStager::open_esm);
	ClassDB::bind_method(D_METHOD("get_last_error"), &TerrainRegionStager::get_last_error);
	ClassDB::bind_method(D_METHOD("index_worldspace", "worldspace_form_id"), &TerrainRegionStager::index_worldspace);
	ClassDB::bind_method(D_METHOD("compose_region", "worldspace_form_id", "region_location", "logical_slots"), &TerrainRegionStager::compose_region);
	ClassDB::bind_method(D_METHOD("compose_computed_normal_fixture", "heights"), &TerrainRegionStager::compose_computed_normal_fixture);
}

bool TerrainRegionStager::open_esm(const String &path) {
	try {
		esm_file_ = std::make_unique<esm::EsmFile>();
		esm_file_->open(path.utf8().get_data());
		esm_path_ = path.utf8().get_data(); catalogues_.clear(); last_error_ = ""; return true;
	} catch (const std::exception &e) {
		esm_file_.reset(); esm_path_.clear(); catalogues_.clear(); last_error_ = String(e.what()); return false;
	}
}

bool TerrainRegionStager::build_catalogue(uint32_t worldspace, WorldCatalogue &catalogue) {
	if (!esm_file_) { last_error_ = "TerrainRegionStager has no open ESM"; return false; }
	try {
		esm_file_->for_each_record([&](const esm::RecordInfo &record) {
			if (record.type != "CELL") return;
			try {
			auto grid = esm_file_->get_exterior_cell_grid(record.form_id);
			auto owner = esm_file_->get_cell_worldspace(record.form_id);
			if (!grid || !owner || *owner != worldspace) return;
			auto indexed = esm_file_->find_exterior_cell(worldspace, grid->x, grid->y);
			if (!indexed || indexed->form_id != record.form_id) return;
			for (const auto &child : esm_file_->get_child_records(record)) {
				if (child.type != "LAND") continue;
				auto land = esm_file_->get_land_data(child);
				if (!land) break;
				CellPayload payload;
				payload.cell_form_id = record.form_id;
				payload.land = std::move(*land);
				for (int q = 0; q < esm::kLandQuadrantCount; ++q) {
					auto &prepared = payload.quadrants[q];
					prepared.base_ltex_form_id = payload.land.quadrant_base_ltex[q];
					for (size_t i = 0; i < payload.land.alpha_layers.size(); ++i)
						if (payload.land.alpha_layers[i].quadrant == q) prepared.overlay_indices.push_back(i);
					std::stable_sort(prepared.overlay_indices.begin(), prepared.overlay_indices.end(), [&](size_t a, size_t b) {
						return payload.land.alpha_layers[a].layer_index < payload.land.alpha_layers[b].layer_index;
					});
					if (!prepared.base_ltex_form_id && !prepared.overlay_indices.empty()) {
						auto strongest = std::max_element(prepared.overlay_indices.begin(), prepared.overlay_indices.end(), [&](size_t a, size_t b) {
							float am = 0, bm = 0;
							for (float v : payload.land.alpha_layers[a].opacity) am += v;
							for (float v : payload.land.alpha_layers[b].opacity) bm += v;
							return am < bm;
						});
						prepared.base_ltex_form_id = payload.land.alpha_layers[*strongest].ltex_form_id;
						prepared.overlay_indices.erase(strongest);
					}
				}
				for (uint32_t id : payload.land.quadrant_base_ltex) if (id) catalogue.ltex_form_ids.insert(id);
				for (const auto &layer : payload.land.alpha_layers) if (layer.ltex_form_id) catalogue.ltex_form_ids.insert(layer.ltex_form_id);
				catalogue.cells[{ grid->x, grid->y }] = std::move(payload);
				add_regions(catalogue.touched_regions, grid->x, grid->y);
				break;
			}
			} catch (const std::exception &) {
				// A malformed real CELL/LAND is not a usable catalogue entry. Match
				// the census tool's per-cell isolation rather than losing the world.
				return;
			}
		});
		if (catalogue.ltex_form_ids.size() > 127) { last_error_ = "Worldspace has more than 127 logical LTEX identities"; return false; }
		if (!catalogue.touched_regions.empty()) {
			catalogue.min_region_x = catalogue.max_region_x = catalogue.touched_regions.begin()->first;
			catalogue.min_region_y = catalogue.max_region_y = catalogue.touched_regions.begin()->second;
			for (const auto &[x, y] : catalogue.touched_regions) {
				catalogue.min_region_x = std::min(catalogue.min_region_x, x); catalogue.max_region_x = std::max(catalogue.max_region_x, x);
				catalogue.min_region_y = std::min(catalogue.min_region_y, y); catalogue.max_region_y = std::max(catalogue.max_region_y, y);
			}
		}
		last_error_ = ""; return true;
	} catch (const std::exception &e) { last_error_ = String(e.what()); return false; }
}

Dictionary TerrainRegionStager::index_worldspace(int64_t form_id) {
	Dictionary result;
	const uint32_t worldspace = static_cast<uint32_t>(form_id);
	auto found = catalogues_.find(worldspace);
	if (found == catalogues_.end()) {
		std::shared_ptr<WorldCatalogue> catalogue;
		{
			std::lock_guard<std::mutex> lock(shared_catalogue_mutex_);
			const auto key = std::make_pair(esm_path_, worldspace);
			auto shared = shared_catalogues_.find(key);
			if (shared != shared_catalogues_.end()) catalogue = shared->second;
			else {
				catalogue = std::make_shared<WorldCatalogue>();
				if (!build_catalogue(worldspace, *catalogue)) { result["error"] = last_error_; return result; }
				shared_catalogues_.emplace(key, catalogue);
			}
		}
		found = catalogues_.emplace(worldspace, std::move(catalogue)).first;
	}
	const auto &catalogue = *found->second;
	Array cells;
	for (const auto &[coord, payload] : catalogue.cells) {
		Dictionary cell; cell["coord"] = Vector2i(coord.first, coord.second); cell["cell_form_id"] = int64_t(payload.cell_form_id); cells.push_back(cell);
	}
	TypedArray<Vector2i> regions, domain;
	for (const auto &[x, y] : catalogue.touched_regions) regions.push_back(Vector2i(x, y));
	if (!catalogue.touched_regions.empty()) for (int y = catalogue.min_region_y; y <= catalogue.max_region_y; ++y)
		for (int x = catalogue.min_region_x; x <= catalogue.max_region_x; ++x) domain.push_back(Vector2i(x, y));
	PackedInt64Array ids; for (uint32_t id : catalogue.ltex_form_ids) ids.push_back(int64_t(id));
	Dictionary bounds;
	bounds["min"] = Vector2i(catalogue.min_region_x, catalogue.min_region_y); bounds["max"] = Vector2i(catalogue.max_region_x, catalogue.max_region_y);
	bounds["size"] = Vector2i(catalogue.max_region_x - catalogue.min_region_x + 1, catalogue.max_region_y - catalogue.min_region_y + 1);
	result["usable_cells"] = cells; result["regions"] = regions; result["region_domain"] = domain;
	result["region_bounds"] = bounds; result["ltex_form_ids"] = ids; result["error"] = ""; return result;
}

Dictionary TerrainRegionStager::compose_region(int64_t form_id, const Vector2i &location, const Dictionary &logical_slots) {
	Dictionary result; result["region_location"] = location;
	Dictionary indexed = index_worldspace(form_id);
	const String index_error = indexed.get("error", String());
	if (!index_error.is_empty()) { result["error"] = index_error; return result; }
	const auto &catalogue = *catalogues_.at(static_cast<uint32_t>(form_id));
	if (!catalogue.touched_regions.count({ location.x, location.y })) { result["error"] = "Region is not touched by usable LAND"; return result; }
	std::map<uint32_t, uint8_t> slots;
	int expected_slot = 1;
	for (uint32_t id : catalogue.ltex_form_ids) {
		const Variant key = int64_t(id);
		if (!logical_slots.has(key)) { result["error"] = "Logical slot table is missing an indexed LTEX identity"; return result; }
		const int64_t slot = logical_slots[key];
		if (slot != expected_slot || slot > 127) { result["error"] = "Logical LTEX slots must follow unsigned FormID order in the range 1..127"; return result; }
		slots[id] = uint8_t(slot);
		++expected_slot;
	}
	const auto logical_slot = [&](uint32_t id) -> uint8_t {
		const auto found = slots.find(id);
		return found == slots.end() ? 0 : found->second;
	};
	std::array<PackedByteArray, TYPE_MAX> buffers;
	for (auto &buffer : buffers) buffer.resize(REGION_SIZE * REGION_SIZE * 4);
	for (int pixel = 0; pixel < REGION_SIZE * REGION_SIZE; ++pixel) {
		buffers[CONTROL].encode_u32(pixel * 4, 1u);
		uint8_t *c = buffers[COLOR].ptrw() + pixel * 4; c[0] = c[1] = c[2] = 255; c[3] = 127;
		uint8_t *n = buffers[NORMAL].ptrw() + pixel * 4; n[0] = 127; n[1] = 255; n[2] = 127; n[3] = 255;
	}
	std::set<std::pair<int, int>> contributors;
	std::set<uint32_t> used;
	for (int y = 0; y < REGION_SIZE; ++y) {
		const int gz = location.y * REGION_SIZE + y;
		for (int x = 0; x < REGION_SIZE; ++x) {
			const int gx = location.x * REGION_SIZE + x;
			const int px = floor_div(gx, CELL_SPAN), py = -floor_div(gz, CELL_SPAN) - 1;
			std::vector<std::pair<int, int>> candidates { { px, py } };
			if (gx % CELL_SPAN == 0) candidates.push_back({ px - 1, py });
			if (gz % CELL_SPAN == 0) { candidates.push_back({ px, py + 1 }); if (gx % CELL_SPAN == 0) candidates.push_back({ px - 1, py + 1 }); }
			std::sort(candidates.begin(), candidates.end());
			const CellPayload *payload = nullptr; std::pair<int, int> owner;
			for (const auto &candidate : candidates) { auto cell = catalogue.cells.find(candidate); if (cell != catalogue.cells.end()) { payload = &cell->second; owner = candidate; break; } }
			if (!payload) continue;
			contributors.insert(owner);
			const int col = gx - owner.first * CELL_SPAN, row = -gz - owner.second * CELL_SPAN;
			if (row < 0 || row >= esm::kLandGridSize || col < 0 || col >= esm::kLandGridSize) continue;
			const auto &land = payload->land; const size_t vertex = size_t(row * esm::kLandGridSize + col); const int offset = (y * REGION_SIZE + x) * 4;
			std::memcpy(buffers[HEIGHT].ptrw() + offset, &land.heights[vertex], 4);
			if (land.vertex_colors.size() >= (vertex + 1) * 3) { uint8_t *c = buffers[COLOR].ptrw() + offset; c[0] = land.vertex_colors[vertex*3]; c[1] = land.vertex_colors[vertex*3+1]; c[2] = land.vertex_colors[vertex*3+2]; c[3] = 127; }
			const Vec3 vn = normal_for(land, row, col); uint8_t *n = buffers[NORMAL].ptrw() + offset;
			n[0] = enc_normal(vn.x); n[1] = enc_normal(vn.y); n[2] = enc_normal(vn.z); n[3] = 255;
			const int q = (row >= 16 ? 2 : 0) + (col >= 16 ? 1 : 0);
			const auto &prepared = payload->quadrants[q];
			const uint32_t base = prepared.base_ltex_form_id;
			const int rs = q >= 2 ? 16 : 0, cs = q % 2 ? 16 : 0; const size_t local = size_t((row-rs)*17 + col-cs);
			std::array<uint8_t,7> ids {}; std::array<uint8_t,6> weights {};
			if (base) { ids[0] = logical_slot(base); if (ids[0]) used.insert(base); }
			for (size_t i=0; i<std::min<size_t>(prepared.overlay_indices.size(),6); ++i) { const auto &layer = land.alpha_layers[prepared.overlay_indices[i]]; const float op = local<layer.opacity.size()?std::clamp(layer.opacity[local],0.0f,1.0f):0.0f; if(op<=0)continue; ids[i+1]=logical_slot(layer.ltex_form_id); weights[i]=unorm(op); if(ids[i+1]) used.insert(layer.ltex_form_id); }
			uint8_t *ia=buffers[TEX_ID_A].ptrw()+offset,*ib=buffers[TEX_ID_B].ptrw()+offset,*wa=buffers[WEIGHT_A].ptrw()+offset,*wb=buffers[WEIGHT_B].ptrw()+offset;
			for(int i=0;i<4;++i){ia[i]=ids[i];wa[i]=weights[i];} ib[0]=ids[4];ib[1]=ids[5];ib[2]=ids[6]; wb[0]=weights[4];wb[1]=weights[5];
		}
	}
	TypedArray<Image> maps; for(int type=0;type<TYPE_MAX;++type) maps.push_back(Image::create_from_data(REGION_SIZE,REGION_SIZE,false,type<=CONTROL?Image::FORMAT_RF:Image::FORMAT_RGBA8,buffers[type]));
	Array cells; for(const auto &[x,y]:contributors) cells.push_back(Vector2i(x,y)); PackedInt64Array used_ids; for(uint32_t id:used) used_ids.push_back(int64_t(id));
	result["maps"]=maps; result["contributing_cells"]=cells; result["used_ltex_form_ids"]=used_ids; result["error"]=""; return result;
}

PackedByteArray TerrainRegionStager::compose_computed_normal_fixture(const PackedFloat32Array &heights) {
	PackedByteArray output;
	if (heights.size() != esm::kLandGridSize * esm::kLandGridSize) return output;
	esm::LandData land;
	land.heights.assign(heights.ptr(), heights.ptr() + heights.size());
	output.resize(heights.size() * 4);
	for (int row = 0; row < esm::kLandGridSize; ++row) {
		for (int col = 0; col < esm::kLandGridSize; ++col) {
			const Vec3 n = normal_for(land, row, col);
			uint8_t *pixel = output.ptrw() + (row * esm::kLandGridSize + col) * 4;
			pixel[0] = enc_normal(n.x); pixel[1] = enc_normal(n.y); pixel[2] = enc_normal(n.z); pixel[3] = 255;
		}
	}
	return output;
}

} // namespace godot
