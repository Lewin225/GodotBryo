#include "esm_reader_gd.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <stdexcept>

using namespace godot;

namespace {
Dictionary placement_to_dict(const esm::ReferencePlacement &pl) {
	Dictionary d;
	d["refr_form_id"] = static_cast<int64_t>(pl.refr_form_id);
	d["base_form_id"] = static_cast<int64_t>(pl.base_form_id);
	d["base_type"] = String(pl.base_type.c_str());
	d["editor_id"] = String(pl.base_editor_id.c_str());
	d["model"] = String(pl.model_path.c_str());
	d["position"] = Vector3(pl.position[0], pl.position[1], pl.position[2]);
	d["rotation"] = Vector3(pl.rotation[0], pl.rotation[1], pl.rotation[2]);
	d["scale"] = pl.scale;
	return d;
}
} // namespace

void EsmReader::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open", "path"), &EsmReader::open);
	ClassDB::bind_method(D_METHOD("get_last_error"), &EsmReader::get_last_error);
	ClassDB::bind_method(D_METHOD("get_header_info"), &EsmReader::get_header_info);
	ClassDB::bind_method(D_METHOD("get_record_type_histogram"), &EsmReader::get_record_type_histogram);
	ClassDB::bind_method(D_METHOD("find_first_stat_model"), &EsmReader::find_first_stat_model);
	ClassDB::bind_method(D_METHOD("find_stat_by_editor_id", "editor_id"), &EsmReader::find_stat_by_editor_id);
	ClassDB::bind_method(D_METHOD("find_cell_by_editor_id", "editor_id"), &EsmReader::find_cell_by_editor_id);
	ClassDB::bind_method(D_METHOD("find_cell_by_form_id", "form_id"), &EsmReader::find_cell_by_form_id);
	ClassDB::bind_method(D_METHOD("get_cell_references", "cell_form_id"), &EsmReader::get_cell_references);
	ClassDB::bind_method(D_METHOD("get_scol_parts", "scol_form_id"), &EsmReader::get_scol_parts);
	ClassDB::bind_method(D_METHOD("get_light_data", "light_form_id"), &EsmReader::get_light_data);
	ClassDB::bind_method(D_METHOD("find_worldspace_by_editor_id", "editor_id"), &EsmReader::find_worldspace_by_editor_id);
	ClassDB::bind_method(D_METHOD("find_exterior_cell", "wrld_form_id", "x", "y"), &EsmReader::find_exterior_cell);
	ClassDB::bind_method(D_METHOD("get_land_data", "cell_form_id"), &EsmReader::get_land_data);
	ClassDB::bind_method(D_METHOD("get_cell_child_type_counts", "cell_form_id"), &EsmReader::get_cell_child_type_counts);
	ClassDB::bind_method(D_METHOD("resolve_ltex_texture_path", "ltex_form_id"), &EsmReader::resolve_ltex_texture_path);
	ClassDB::bind_method(D_METHOD("find_first_compressed_record"), &EsmReader::find_first_compressed_record);
}

bool EsmReader::open(const String &path) {
	try {
		file_.open(path.utf8().get_data());
		opened_ = true;
		last_error_ = "";
		return true;
	} catch (const std::exception &e) {
		opened_ = false;
		last_error_ = String(e.what());
		return false;
	}
}

Dictionary EsmReader::get_header_info() const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	const esm::FileHeader &h = file_.header();
	out["version"] = h.version;
	out["num_records"] = static_cast<int64_t>(h.num_records);
	out["next_object_id"] = static_cast<int64_t>(h.next_object_id);
	PackedStringArray masters;
	masters.resize(static_cast<int>(h.masters.size()));
	for (size_t i = 0; i < h.masters.size(); ++i) {
		masters[static_cast<int>(i)] = String(h.masters[i].c_str());
	}
	out["masters"] = masters;
	return out;
}

Dictionary EsmReader::get_record_type_histogram() const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		for (const auto &[type, count] : file_.record_type_histogram()) {
			out[String(type.c_str())] = static_cast<int>(count);
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::find_first_stat_model() const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		Dictionary found;
		file_.for_each_record([&](const esm::RecordInfo &r) {
			if (!found.is_empty() || r.type != "STAT") {
				return;
			}
			std::vector<uint8_t> data = file_.read_record_data(r);
			std::vector<esm::Subrecord> subs = esm::EsmFile::parse_subrecords(data);
			String editor_id;
			String model;
			for (const auto &s : subs) {
				if (s.type == "EDID") {
					editor_id = String(s.as_string().c_str());
				} else if (s.type == "MODL") {
					model = String(s.as_string().c_str());
				}
			}
			if (!model.is_empty()) {
				found["form_id"] = static_cast<int64_t>(r.form_id);
				found["editor_id"] = editor_id;
				found["model"] = model;
			}
		});
		return found;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return out;
	}
}

Dictionary EsmReader::find_stat_by_editor_id(const String &editor_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	std::string target = editor_id.utf8().get_data();
	try {
		Dictionary found;
		file_.for_each_record([&](const esm::RecordInfo &r) {
			if (!found.is_empty() || r.type != "STAT") {
				return;
			}
			std::vector<uint8_t> data = file_.read_record_data(r);
			std::vector<esm::Subrecord> subs = esm::EsmFile::parse_subrecords(data);
			std::string edid, model;
			for (const auto &s : subs) {
				if (s.type == "EDID") {
					edid = s.as_string();
				} else if (s.type == "MODL") {
					model = s.as_string();
				}
			}
			if (edid == target && !model.empty()) {
				found["form_id"] = static_cast<int64_t>(r.form_id);
				found["editor_id"] = String(edid.c_str());
				found["model"] = String(model.c_str());
			}
		});
		return found;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return out;
	}
}

Dictionary EsmReader::find_cell_by_editor_id(const String &editor_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		if (auto cell = file_.find_cell_by_editor_id(editor_id.utf8().get_data())) {
			out["form_id"] = static_cast<int64_t>(cell->form_id);
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::find_cell_by_form_id(int64_t form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		if (auto cell = file_.find_cell_by_form_id(static_cast<uint32_t>(form_id))) {
			out["form_id"] = static_cast<int64_t>(cell->form_id);
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Array EsmReader::get_cell_references(int64_t cell_form_id) const {
	Array out;
	if (!opened_) {
		return out;
	}
	try {
		auto cell = file_.find_cell_by_form_id(static_cast<uint32_t>(cell_form_id));
		if (!cell) {
			return out;
		}
		for (const auto &pl : file_.get_cell_references(*cell)) {
			out.push_back(placement_to_dict(pl));
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Array EsmReader::get_scol_parts(int64_t scol_form_id) const {
	Array out;
	if (!opened_) {
		return out;
	}
	try {
		auto scol = file_.find_record_by_form_id(static_cast<uint32_t>(scol_form_id));
		if (!scol || scol->type != "SCOL") {
			return out;
		}
		for (const auto &pl : file_.get_scol_parts(*scol)) {
			out.push_back(placement_to_dict(pl));
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_light_data(int64_t light_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		auto light = file_.get_light_data(static_cast<uint32_t>(light_form_id));
		if (!light) {
			return out;
		}
		out["radius"] = light->radius;
		out["color"] = Color(light->color[0] / 255.0f, light->color[1] / 255.0f, light->color[2] / 255.0f, 1.0f);
		out["flags"] = static_cast<int64_t>(light->flags);
		out["falloff"] = light->falloff;
		out["fov_degrees"] = light->fov_degrees;
		out["is_spot"] = light->is_spot();
		out["off_by_default"] = light->off_by_default();
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::find_worldspace_by_editor_id(const String &editor_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		if (auto wrld = file_.find_worldspace_by_editor_id(editor_id.utf8().get_data())) {
			out["form_id"] = static_cast<int64_t>(wrld->form_id);
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::find_exterior_cell(int64_t wrld_form_id, int32_t x, int32_t y) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		if (auto cell = file_.find_exterior_cell(static_cast<uint32_t>(wrld_form_id), x, y)) {
			out["form_id"] = static_cast<int64_t>(cell->form_id);
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_land_data(int64_t cell_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		auto cell = file_.find_record_by_form_id(static_cast<uint32_t>(cell_form_id));
		if (!cell || cell->type != "CELL") {
			return out;
		}
		esm::RecordInfo land_record;
		bool found_land = false;
		for (const auto &c : file_.get_child_records(*cell)) {
			if (c.type == "LAND") {
				land_record = c;
				found_land = true;
				break;
			}
		}
		if (!found_land) {
			return out;
		}
		auto land = file_.get_land_data(land_record);
		if (!land) {
			return out;
		}
		PackedFloat32Array heights;
		heights.resize(static_cast<int>(land->heights.size()));
		for (size_t i = 0; i < land->heights.size(); ++i) {
			heights[static_cast<int>(i)] = land->heights[i];
		}
		out["heights"] = heights;
		PackedInt64Array ltex;
		ltex.resize(esm::kLandQuadrantCount);
		for (int i = 0; i < esm::kLandQuadrantCount; ++i) {
			ltex[i] = static_cast<int64_t>(land->quadrant_base_ltex[i]);
		}
		out["quadrant_base_ltex"] = ltex;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

String EsmReader::resolve_ltex_texture_path(int64_t ltex_form_id) const {
	if (!opened_) {
		return String();
	}
	try {
		return String(file_.resolve_ltex_texture_path(static_cast<uint32_t>(ltex_form_id)).c_str());
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return String();
	}
}

Dictionary EsmReader::get_cell_child_type_counts(int64_t cell_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		auto cell = file_.find_record_by_form_id(static_cast<uint32_t>(cell_form_id));
		if (!cell || cell->type != "CELL") {
			return out;
		}
		for (const auto &c : file_.get_child_records(*cell)) {
			String type = String(c.type.c_str());
			out[type] = int64_t(out.get(type, 0)) + 1;
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::find_first_compressed_record() const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		Dictionary found;
		file_.for_each_record([&](const esm::RecordInfo &r) {
			if (!found.is_empty() || !r.is_compressed()) {
				return;
			}
			std::vector<uint8_t> data = file_.read_record_data(r); // throws on zlib failure
			found["type"] = String(r.type.c_str());
			found["form_id"] = static_cast<int64_t>(r.form_id);
			found["compressed_size"] = static_cast<int64_t>(r.data_size);
			found["decompressed_size"] = static_cast<int64_t>(data.size());
		});
		return found;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return out;
	}
}
