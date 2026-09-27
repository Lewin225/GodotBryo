#include "esm_reader_gd.h"
#include "common/byte_reader.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <cctype>
#include <cmath>
#include <cstring>
#include <stdexcept>

using namespace godot;

namespace {
struct FaceGenFieldSpec {
	const char *tag;
	const char *raw_key;
	const char *values_key;
	const char *decoded_key;
	int expected_bytes;
};

void add_facegen_field(Dictionary &out, PackedStringArray &diagnostics,
		const esm::Subrecord *sub, const FaceGenFieldSpec &spec) {
	PackedByteArray raw;
	if (sub != nullptr) {
		raw.resize(static_cast<int>(sub->size));
		for (size_t i = 0; i < sub->size; ++i) raw[static_cast<int>(i)] = sub->data[i];
	}
	out[spec.raw_key] = raw;
	out[String(spec.tag) + "_present"] = sub != nullptr;
	out[spec.values_key] = PackedFloat32Array();
	out[spec.decoded_key] = false;
	if (sub == nullptr) return;
	if (sub->size != static_cast<size_t>(spec.expected_bytes)) {
		diagnostics.push_back(String(spec.tag) + " has unexpected byte size " + String::num_int64(static_cast<int64_t>(sub->size)));
		return;
	}
	PackedFloat32Array values;
	values.resize(static_cast<int>(sub->size / 4));
	for (size_t i = 0; i < sub->size / 4; ++i) {
		uint32_t bits = static_cast<uint32_t>(sub->data[i * 4]) |
			(static_cast<uint32_t>(sub->data[i * 4 + 1]) << 8) |
			(static_cast<uint32_t>(sub->data[i * 4 + 2]) << 16) |
			(static_cast<uint32_t>(sub->data[i * 4 + 3]) << 24);
		float value = 0.0f;
		std::memcpy(&value, &bits, sizeof(value));
		if (!std::isfinite(value)) {
			diagnostics.push_back(String(spec.tag) + " contains a non-finite float at index " + String::num_int64(static_cast<int64_t>(i)));
			return;
		}
		values[static_cast<int>(i)] = value;
	}
	out[spec.values_key] = values;
	out[spec.decoded_key] = true;
}

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
	d["script_form_id"] = static_cast<int64_t>(pl.script_form_id);
	d["emittance_form_id"] = static_cast<int64_t>(pl.emittance_form_id);
	d["primitive_type"] = static_cast<int64_t>(pl.primitive_type);
	if (pl.primitive_type != 0) {
		d["primitive_bounds"] = Vector3(pl.primitive_bounds[0], pl.primitive_bounds[1], pl.primitive_bounds[2]);
		d["primitive_color"] = Color(pl.primitive_color[0], pl.primitive_color[1], pl.primitive_color[2], pl.primitive_color[3]);
	}
	// phases/2/12-distant-object-lod.md: real per-REFR gate for whether the
	// game renders a distant-LOD variant of this placement at all -- always
	// false for SCOL parts (get_scol_parts()), which have no REFR record of
	// their own to carry the flag.
	d["visible_when_distant"] = pl.visible_when_distant;
	d["has_xtel"] = pl.has_xtel;
	d["has_xsrf_or_xsrd"] = pl.has_xsrf_or_xsrd;
	if (pl.has_xtel) {
		d["dest_refr_form_id"] = static_cast<int64_t>(pl.dest_refr_form_id);
		d["dest_position"] = Vector3(pl.dest_position[0], pl.dest_position[1], pl.dest_position[2]);
		d["dest_rotation"] = Vector3(pl.dest_rotation[0], pl.dest_rotation[1], pl.dest_rotation[2]);
	}
	// issue #52 chunk 5: only ever non-zero/true when get_cell_actors()
	// resolved an NPC_ base (see ReferencePlacement's own doc comment).
	d["race_form_id"] = static_cast<int64_t>(pl.race_form_id);
	d["is_female"] = pl.is_female;
	return d;
}
} // namespace

void EsmReader::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open", "path"), &EsmReader::open);
	ClassDB::bind_method(D_METHOD("get_last_error"), &EsmReader::get_last_error);
	ClassDB::bind_method(D_METHOD("get_header_info"), &EsmReader::get_header_info);
	ClassDB::bind_method(D_METHOD("get_record_type_histogram"), &EsmReader::get_record_type_histogram);
	ClassDB::bind_method(D_METHOD("find_first_stat_model"), &EsmReader::find_first_stat_model);
	ClassDB::bind_method(D_METHOD("get_message_by_editor_id", "editor_id"), &EsmReader::get_message_by_editor_id);
	ClassDB::bind_method(D_METHOD("get_message_by_form_id", "form_id"), &EsmReader::get_message_by_form_id);
	ClassDB::bind_method(D_METHOD("find_cell_by_editor_id", "editor_id"), &EsmReader::find_cell_by_editor_id);
	ClassDB::bind_method(D_METHOD("find_cell_by_form_id", "form_id"), &EsmReader::find_cell_by_form_id);
	ClassDB::bind_method(D_METHOD("find_cell_containing_ref", "refr_form_id"), &EsmReader::find_cell_containing_ref);
	ClassDB::bind_method(D_METHOD("get_cell_references", "cell_form_id"), &EsmReader::get_cell_references);
	ClassDB::bind_method(D_METHOD("get_cell_actors", "cell_form_id"), &EsmReader::get_cell_actors);
	ClassDB::bind_method(D_METHOD("get_all_placed_npc_actors"), &EsmReader::get_all_placed_npc_actors);
	ClassDB::bind_method(D_METHOD("get_all_xtel_doors"), &EsmReader::get_all_xtel_doors);
	ClassDB::bind_method(D_METHOD("get_persistent_refs_for_cell", "cell_form_id"), &EsmReader::get_persistent_refs_for_cell);
	ClassDB::bind_method(D_METHOD("get_persistent_refs_for_worldspace", "wrld_form_id"), &EsmReader::get_persistent_refs_for_worldspace);
	ClassDB::bind_method(D_METHOD("get_scol_parts", "scol_form_id"), &EsmReader::get_scol_parts);
	ClassDB::bind_method(D_METHOD("get_light_data", "light_form_id"), &EsmReader::get_light_data);
	ClassDB::bind_method(D_METHOD("get_sound_path", "sound_form_id"), &EsmReader::get_sound_path);
	ClassDB::bind_method(D_METHOD("get_race_body_parts", "race_form_id", "female"), &EsmReader::get_race_body_parts);
	ClassDB::bind_method(D_METHOD("get_race_head_parts", "race_form_id", "female"), &EsmReader::get_race_head_parts);
	ClassDB::bind_method(D_METHOD("get_actor_by_form_id", "base_form_id"), &EsmReader::get_actor_by_form_id);
	ClassDB::bind_method(D_METHOD("get_record_data", "form_id"), &EsmReader::get_record_data);
	ClassDB::bind_method(D_METHOD("get_record_index"), &EsmReader::get_record_index);
	ClassDB::bind_method(D_METHOD("get_facegen_data", "npc_form_id"), &EsmReader::get_facegen_data);
	ClassDB::bind_method(D_METHOD("get_emittance_data", "emittance_form_id"), &EsmReader::get_emittance_data);
	ClassDB::bind_method(D_METHOD("get_item_data", "item_form_id"), &EsmReader::get_item_data);
	ClassDB::bind_method(D_METHOD("get_terminal_data", "terminal_form_id"), &EsmReader::get_terminal_data);
	ClassDB::bind_method(D_METHOD("get_note_data", "note_form_id"), &EsmReader::get_note_data);
	ClassDB::bind_method(D_METHOD("find_placeable_by_id", "id_or_editor_id"), &EsmReader::find_placeable_by_id);
	ClassDB::bind_method(D_METHOD("get_cell_lighting_data", "cell_form_id"), &EsmReader::get_cell_lighting_data);
	ClassDB::bind_method(D_METHOD("get_script_data", "scpt_form_id"), &EsmReader::get_script_data);
	ClassDB::bind_method(D_METHOD("get_all_script_form_ids"), &EsmReader::get_all_script_form_ids);
	ClassDB::bind_method(D_METHOD("find_worldspace_by_editor_id", "editor_id"), &EsmReader::find_worldspace_by_editor_id);
	ClassDB::bind_method(D_METHOD("find_exterior_cell", "wrld_form_id", "x", "y"), &EsmReader::find_exterior_cell);
	ClassDB::bind_method(D_METHOD("get_exterior_cell_grid", "cell_form_id"), &EsmReader::get_exterior_cell_grid);
	ClassDB::bind_method(D_METHOD("get_exterior_cell_index"), &EsmReader::get_exterior_cell_index);
	ClassDB::bind_method(D_METHOD("get_reference_placement", "refr_form_id"), &EsmReader::get_reference_placement);
	ClassDB::bind_method(D_METHOD("get_placed_reference_cells"), &EsmReader::get_placed_reference_cells);
	ClassDB::bind_method(D_METHOD("get_cell_editor_id", "cell_form_id"), &EsmReader::get_cell_editor_id);
	ClassDB::bind_method(D_METHOD("get_cell_worldspace", "cell_form_id"), &EsmReader::get_cell_worldspace);
	ClassDB::bind_method(D_METHOD("get_land_data", "cell_form_id"), &EsmReader::get_land_data);
	ClassDB::bind_method(D_METHOD("get_grass_data", "grass_form_id"), &EsmReader::get_grass_data);
	ClassDB::bind_method(D_METHOD("get_ltex_grass_form_ids", "ltex_form_id"), &EsmReader::get_ltex_grass_form_ids);
	ClassDB::bind_method(D_METHOD("get_cell_child_type_counts", "cell_form_id"), &EsmReader::get_cell_child_type_counts);
	ClassDB::bind_method(D_METHOD("resolve_refr_xtel", "refr_form_id"), &EsmReader::resolve_refr_xtel);
	ClassDB::bind_method(D_METHOD("get_door_destination", "door_refr_form_id"), &EsmReader::get_door_destination);
	ClassDB::bind_method(D_METHOD("resolve_ltex_texture_path", "ltex_form_id"), &EsmReader::resolve_ltex_texture_path);
	ClassDB::bind_method(D_METHOD("resolve_ltex_normal_texture_path", "ltex_form_id"), &EsmReader::resolve_ltex_normal_texture_path);
	ClassDB::bind_method(D_METHOD("resolve_soun_filename", "soun_form_id"), &EsmReader::resolve_soun_filename);
	ClassDB::bind_method(D_METHOD("get_door_data", "door_form_id"), &EsmReader::get_door_data);
	ClassDB::bind_method(D_METHOD("find_first_compressed_record"), &EsmReader::find_first_compressed_record);
	ClassDB::bind_method(D_METHOD("get_all_item_candidates"), &EsmReader::get_all_item_candidates);
	ClassDB::bind_method(D_METHOD("get_all_cell_candidates"), &EsmReader::get_all_cell_candidates);
	// day-night / weather (feature/day-night-cycle)
	ClassDB::bind_method(D_METHOD("get_climate_data", "form_id"), &EsmReader::get_climate_data);
	ClassDB::bind_method(D_METHOD("get_weather_data", "form_id"), &EsmReader::get_weather_data);
	ClassDB::bind_method(D_METHOD("get_worldspace_climate", "wrld_form_id"), &EsmReader::get_worldspace_climate);
	ClassDB::bind_method(D_METHOD("get_global_variable", "form_id"), &EsmReader::get_global_variable);
	ClassDB::bind_method(D_METHOD("find_global_by_editor_id", "editor_id"), &EsmReader::find_global_by_editor_id);
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

Dictionary EsmReader::get_message_by_editor_id(const String &editor_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	std::string target = editor_id.utf8().get_data();
	try {
		Dictionary found;
		file_.for_each_record([&](const esm::RecordInfo &r) {
			if (!found.is_empty() || r.type != "MESG") {
				return;
			}
			std::vector<uint8_t> data = file_.read_record_data(r);
			std::vector<esm::Subrecord> subs = esm::EsmFile::parse_subrecords(data);
			std::string edid, title, text;
			PackedStringArray buttons;
			uint32_t flags = 0;
			float display_time = 2.0f;
			for (const auto &s : subs) {
				if (s.type == "EDID") {
					edid = s.as_string();
				} else if (s.type == "FULL") {
					title = s.as_string();
				} else if (s.type == "DESC") {
					text = s.as_string();
				} else if (s.type == "ITXT") {
					buttons.push_back(String(s.as_string().c_str()));
				} else if (s.type == "DNAM" && s.size >= 4) {
					flags = *reinterpret_cast<const uint32_t*>(s.data);
				} else if (s.type == "TNAM" && s.size >= 4) {
					display_time = *reinterpret_cast<const float*>(s.data);
				}
			}
			if (edid == target) {
				found["form_id"] = static_cast<int64_t>(r.form_id);
				found["editor_id"] = String(edid.c_str());
				found["title"] = String(title.c_str());
				found["text"] = String(text.c_str());
				found["flags"] = static_cast<int64_t>(flags);
				found["is_message_box"] = (flags & 0x1) != 0 || !buttons.is_empty();
				found["buttons"] = buttons;
				found["display_time"] = display_time;
			}
		});
		return found;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return out;
	}
}

Dictionary EsmReader::get_message_by_form_id(int64_t form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	uint32_t target = static_cast<uint32_t>(form_id);
	try {
		Dictionary found;
		file_.for_each_record([&](const esm::RecordInfo &r) {
			if (!found.is_empty() || r.type != "MESG" || r.form_id != target) {
				return;
			}
			std::vector<uint8_t> data = file_.read_record_data(r);
			std::vector<esm::Subrecord> subs = esm::EsmFile::parse_subrecords(data);
			std::string edid, title, text;
			PackedStringArray buttons;
			uint32_t flags = 0;
			float display_time = 2.0f;
			for (const auto &s : subs) {
				if (s.type == "EDID") {
					edid = s.as_string();
				} else if (s.type == "FULL") {
					title = s.as_string();
				} else if (s.type == "DESC") {
					text = s.as_string();
				} else if (s.type == "ITXT") {
					buttons.push_back(String(s.as_string().c_str()));
				} else if (s.type == "DNAM" && s.size >= 4) {
					flags = *reinterpret_cast<const uint32_t*>(s.data);
				} else if (s.type == "TNAM" && s.size >= 4) {
					display_time = *reinterpret_cast<const float*>(s.data);
				}
			}
			found["form_id"] = static_cast<int64_t>(r.form_id);
			found["editor_id"] = String(edid.c_str());
			found["title"] = String(title.c_str());
			found["text"] = String(text.c_str());
			found["flags"] = static_cast<int64_t>(flags);
			found["is_message_box"] = (flags & 0x1) != 0 || !buttons.is_empty();
			found["buttons"] = buttons;
			found["display_time"] = display_time;
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

Dictionary EsmReader::find_cell_containing_ref(int64_t refr_form_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto cell = file_.find_cell_containing_ref(static_cast<uint32_t>(refr_form_id));
		if (cell) out["cell_form_id"] = static_cast<int64_t>(cell->form_id);
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

// issue #52 chunk 1: same Dictionary shape as get_cell_references(), but for
// ACHR/ACRE (placed NPC_/CREA) instead of REFR — see EsmFile::get_cell_actors().
Array EsmReader::get_cell_actors(int64_t cell_form_id) const {
	Array out;
	if (!opened_) {
		return out;
	}
	try {
		auto cell = file_.find_cell_by_form_id(static_cast<uint32_t>(cell_form_id));
		if (!cell) {
			return out;
		}
		for (const auto &pl : file_.get_cell_actors(*cell)) {
			out.push_back(placement_to_dict(pl));
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Array EsmReader::get_all_placed_npc_actors() const {
	Array out;
	if (!opened_) {
		return out;
	}
	try {
		// FormID lookup elsewhere in EsmFile resolves the last record when a
		// master contains an override duplicate. Match that established
		// canonical identity rule here rather than emitting two placements for
		// one authored instance ID.
		std::unordered_map<uint32_t, int> output_index_by_form_id;
		file_.for_each_record([&](const esm::RecordInfo &cell) {
			if (cell.type != "CELL") {
				return;
			}
			for (const auto &placement : file_.get_cell_actors(cell)) {
				if (placement.base_type != "NPC_") {
					continue;
				}
				Dictionary entry = placement_to_dict(placement);
				entry["cell_form_id"] = static_cast<int64_t>(cell.form_id);
				auto existing = output_index_by_form_id.find(placement.refr_form_id);
				if (existing == output_index_by_form_id.end()) {
					output_index_by_form_id[placement.refr_form_id] = out.size();
					out.push_back(entry);
				} else {
					out[existing->second] = entry;
				}
			}
		});
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Array EsmReader::get_all_xtel_doors() const {
	Array out;
	if (!opened_) {
		return out;
	}
	try {
		std::unordered_map<uint32_t, int> output_index_by_form_id;
		file_.for_each_record([&](const esm::RecordInfo &cell) {
			if (cell.type != "CELL") {
				return;
			}
			for (const auto &placement : file_.get_cell_references(cell)) {
				if (placement.base_type != "DOOR" || !placement.has_xtel) {
					continue;
				}
				Dictionary entry = placement_to_dict(placement);
				entry["cell_form_id"] = static_cast<int64_t>(cell.form_id);
				auto existing = output_index_by_form_id.find(placement.refr_form_id);
				if (existing == output_index_by_form_id.end()) {
					output_index_by_form_id[placement.refr_form_id] = out.size();
					out.push_back(entry);
				} else {
					out[existing->second] = entry;
				}
			}
		});
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

// phases/2/07-runtime-cell-loader.md's "Known gap": the refs a caller loading
// `cell_form_id` also needs to place alongside the cell's own
// get_cell_references() — its owning worldspace's persistent cell (see
// EsmFile::get_worldspace_persistent_cell()'s doc comment), or {} for an
// interior cell (no worldspace) or one whose worldspace has no persistent
// cell at all.
Array EsmReader::get_persistent_refs_for_cell(int64_t cell_form_id) const {
	if (!opened_) {
		return Array();
	}
	try {
		auto wrld_form_id = file_.get_cell_worldspace(static_cast<uint32_t>(cell_form_id));
		if (!wrld_form_id) {
			return Array();
		}
		return get_persistent_refs_for_worldspace(static_cast<int64_t>(*wrld_form_id));
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return Array();
	}
}

// phases/2/08-world-cell-streaming.md: WorldStreamer knows the WRLD FormID
// directly (from its own activate(wrld_form_id)) rather than any one cell's
// FormID, so it needs this instead of going by way of get_persistent_refs_for_cell().
Array EsmReader::get_persistent_refs_for_worldspace(int64_t wrld_form_id) const {
	Array out;
	if (!opened_) {
		return out;
	}
	try {
		auto persistent_cell = file_.get_worldspace_persistent_cell(static_cast<uint32_t>(wrld_form_id));
		if (!persistent_cell) {
			return out;
		}
		for (const auto &pl : file_.get_cell_references(*persistent_cell)) {
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
		out["time"] = light->time;
		out["radius"] = light->radius;
		out["color"] = Color(light->color[0] / 255.0f, light->color[1] / 255.0f, light->color[2] / 255.0f, 1.0f);
		out["color_alpha"] = static_cast<int64_t>(light->color[3]);
		out["flags"] = static_cast<int64_t>(light->flags);
		out["falloff"] = light->falloff;
		out["fov_degrees"] = light->fov_degrees;
		out["value"] = light->value;
		out["weight"] = light->weight;
		out["is_spot"] = light->is_spot();
		out["off_by_default"] = light->off_by_default();
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

String EsmReader::get_sound_path(int64_t sound_form_id) const {
	if (!opened_) return String();
	try {
		return String(file_.resolve_soun_filename(static_cast<uint32_t>(sound_form_id)).c_str());
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return String();
}

Array EsmReader::get_race_body_parts(int64_t race_form_id, bool female) const {
	Array out;
	if (!opened_) {
		return out;
	}
	try {
		for (const auto &part : file_.get_race_body_parts(static_cast<uint32_t>(race_form_id), female)) {
			Dictionary d;
			d["index"] = static_cast<int64_t>(part.index);
			d["model"] = String(part.model_path.c_str());
			d["icon"] = String(part.icon_path.c_str());
			out.push_back(d);
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Array EsmReader::get_race_head_parts(int64_t race_form_id, bool female) const {
	Array out;
	if (!opened_) return out;
	try {
		for (const auto &part : file_.get_race_head_parts(static_cast<uint32_t>(race_form_id), female)) {
			Dictionary d;
			d["index"] = static_cast<int64_t>(part.index);
			d["model"] = String(part.model_path.c_str());
			d["icon"] = String(part.icon_path.c_str());
			out.push_back(d);
		}
	} catch (const std::exception &e) { last_error_ = String(e.what()); }
	return out;
}

Dictionary EsmReader::get_actor_by_form_id(int64_t base_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		auto pl = file_.get_actor_by_form_id(static_cast<uint32_t>(base_form_id));
		if (!pl) {
			return out;
		}
		out = placement_to_dict(*pl);
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_record_data(int64_t form_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto record = file_.find_record_by_form_id(static_cast<uint32_t>(form_id));
		if (!record) return out;
		out["form_id"] = static_cast<int64_t>(record->form_id);
		out["record_type"] = String(record->type.c_str());
		out["record_flags"] = static_cast<int64_t>(record->flags);
		Array subrecords;
		const auto data = file_.read_record_data(*record);
		for (const auto &sub : esm::EsmFile::parse_subrecords(data)) {
			Dictionary item;
			item["type"] = String(sub.type.c_str());
			PackedByteArray bytes;
			bytes.resize(static_cast<int>(sub.size));
			for (size_t i = 0; i < sub.size; ++i) bytes[static_cast<int>(i)] = sub.data[i];
			item["data"] = bytes;
			subrecords.push_back(item);
		}
		out["subrecords"] = subrecords;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Array EsmReader::get_record_index() const {
	Array out;
	if (!opened_) return out;
	try {
		file_.for_each_record([&](const esm::RecordInfo &r) {
			Dictionary entry;
			entry["form_id"] = static_cast<int64_t>(r.form_id);
			entry["record_type"] = String(r.type.c_str());
			entry["editor_id"] = String();
			entry["full_name"] = String();
			try {
				std::string editor_id;
				std::string full_name;
				// Subrecords point into `data`; it must outlive the loop.
				const std::vector<uint8_t> data = file_.read_record_data(r);
				for (const auto &sub : esm::EsmFile::parse_subrecords(data)) {
					if (sub.type == "EDID") editor_id = sub.as_string();
					else if (sub.type == "FULL") full_name = sub.as_string();
				}
				entry["editor_id"] = String(editor_id.c_str());
				entry["full_name"] = String(full_name.c_str());
			} catch (const std::exception &e) {
				// A bad optional payload must not hide every record that follows it.
				// The header remains useful to the browser (type/FormID), while
				// callers can hydrate the record separately if needed.
				last_error_ = String((std::string("record ") + std::to_string(r.form_id) + ": " + e.what()).c_str());
			}
			out.push_back(entry);
		});
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_facegen_data(int64_t npc_form_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto record = file_.find_record_by_form_id(static_cast<uint32_t>(npc_form_id));
		if (!record || record->type != "NPC_") return out;
		out["form_id"] = static_cast<int64_t>(record->form_id);
		out["record_type"] = String(record->type.c_str());
		const auto data = file_.read_record_data(*record);
		const auto subrecords = esm::EsmFile::parse_subrecords(data);
		PackedStringArray diagnostics;
		const FaceGenFieldSpec specs[] = {
			{"FGGS", "fggs", "fggs_values", "fggs_decoded", 200},
			{"FGGA", "fgga", "fgga_values", "fgga_decoded", 120},
			{"FGTS", "fgts", "fgts_values", "fgts_decoded", 200},
		};
		for (const auto &spec : specs) {
			const esm::Subrecord *found = nullptr;
			for (const auto &sub : subrecords) {
				if (sub.type == spec.tag) { found = &sub; break; }
			}
			add_facegen_field(out, diagnostics, found, spec);
		}
		out["diagnostics"] = diagnostics;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_emittance_data(int64_t emittance_form_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto color = file_.get_emittance_color(static_cast<uint32_t>(emittance_form_id));
		if (!color) return out;
		// XEMI supplies tint only. Its source records' fourth byte is not the
		// effect opacity (the NIF's texture/vertex alpha remains authoritative).
		out["color"] = Color((*color)[0] / 255.0f, (*color)[1] / 255.0f, (*color)[2] / 255.0f, 1.0f);
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_item_data(int64_t item_form_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto item = file_.get_item_data(static_cast<uint32_t>(item_form_id));
		if (!item) return out;
		out["full_name"] = String(item->full_name.c_str());
		out["value"] = item->value;
		out["weight"] = item->weight;
		out["inventory_icon"] = String(item->inventory_icon.c_str());
		out["message_icon"] = String(item->message_icon.c_str());
	} catch (const std::exception &e) { last_error_ = String(e.what()); }
	return out;
}

Dictionary EsmReader::get_terminal_data(int64_t terminal_form_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto terminal = file_.get_terminal_data(static_cast<uint32_t>(terminal_form_id));
		if (!terminal) return out;
		out["editor_id"] = String(terminal->editor_id.c_str());
		out["full_name"] = String(terminal->full_name.c_str());
		out["model_path"] = String(terminal->model_path.c_str());
		out["welcome_text"] = String(terminal->welcome_text.c_str());
		out["flags"] = static_cast<int64_t>(terminal->flags);
		Array items;
		for (const auto &item : terminal->items) {
			Dictionary d;
			d["text"] = String(item.text.c_str());
			d["result_text"] = String(item.result_text.c_str());
			d["note_form_id"] = static_cast<int64_t>(item.note_form_id);
			d["submenu_form_id"] = static_cast<int64_t>(item.submenu_form_id);
			d["flags"] = static_cast<int64_t>(item.flags);
			d["condition_count"] = static_cast<int64_t>(item.condition_count);
			d["script_source"] = String(item.script_source.c_str());
			items.push_back(d);
		}
		out["items"] = items;
	} catch (const std::exception &e) { last_error_ = String(e.what()); }
	return out;
}

Dictionary EsmReader::get_note_data(int64_t note_form_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto note = file_.get_note_data(static_cast<uint32_t>(note_form_id));
		if (!note) return out;
		out["editor_id"] = String(note->editor_id.c_str());
		out["full_name"] = String(note->full_name.c_str());
		out["text"] = String(note->text.c_str());
	} catch (const std::exception &e) { last_error_ = String(e.what()); }
	return out;
}

Dictionary EsmReader::find_placeable_by_id(const String &id_or_editor_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		std::string query = id_or_editor_id.utf8().get_data();
		std::optional<esm::RecordInfo> record;
		// Console FormIDs are hexadecimal even without a 0x prefix.  Only
		// treat a pure hex run as one -- editor IDs like Apple remain names.
		bool hex = !query.empty();
		for (char c : query) {
			if (!std::isxdigit(static_cast<unsigned char>(c))) { hex = false; break; }
		}
		if (hex) record = file_.find_record_by_form_id(static_cast<uint32_t>(std::stoul(query, nullptr, 16)));
		if (!record) {
			file_.for_each_record([&](const esm::RecordInfo &candidate) {
				if (record) return;
				auto data = file_.read_record_data(candidate);
				for (const auto &sub : esm::EsmFile::parse_subrecords(data)) {
					if (sub.type == "EDID" && sub.as_string() == query) { record = candidate; break; }
				}
			});
		}
		if (!record) return out;
		out["form_id"] = static_cast<int64_t>(record->form_id);
		out["base_type"] = String(record->type.c_str());
		auto data = file_.read_record_data(*record);
		for (const auto &sub : esm::EsmFile::parse_subrecords(data)) {
			if (sub.type == "EDID") out["editor_id"] = String(sub.as_string().c_str());
			else if (sub.type == "MODL") out["model"] = String(sub.as_string().c_str());
			else if (sub.type == "SCRI" && sub.size >= 4) {
				util::ByteReader sr(sub.data, sub.size);
				out["script_form_id"] = static_cast<int64_t>(sr.read_u32());
			}
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_cell_lighting_data(int64_t cell_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		auto lighting = file_.get_cell_lighting_data(static_cast<uint32_t>(cell_form_id));
		if (!lighting) {
			return out;
		}
		const auto &resolved = lighting->resolved;
		const auto &authored = lighting->cell_authored;
		out["ambient_color"] = Color(resolved.ambient_color[0] / 255.0f, resolved.ambient_color[1] / 255.0f, resolved.ambient_color[2] / 255.0f, 1.0f);
		out["directional_color"] = Color(resolved.directional_color[0] / 255.0f, resolved.directional_color[1] / 255.0f, resolved.directional_color[2] / 255.0f, 1.0f);
		out["fog_color"] = Color(resolved.fog_color[0] / 255.0f, resolved.fog_color[1] / 255.0f, resolved.fog_color[2] / 255.0f, 1.0f);
		out["fog_near"] = resolved.fog_near;
		out["fog_far"] = resolved.fog_far;
		out["directional_rotation_xy"] = resolved.directional_rotation_xy;
		out["directional_rotation_z"] = resolved.directional_rotation_z;
		out["directional_fade"] = resolved.directional_fade;
		out["fog_clip_distance"] = resolved.fog_clip_distance;
		out["fog_power"] = resolved.fog_power;
		out["template_form_id"] = static_cast<int64_t>(lighting->template_form_id);
		out["inheritance_flags"] = static_cast<int64_t>(lighting->inherited_fields);
		out["cell_ambient_color"] = Color(authored.ambient_color[0] / 255.0f, authored.ambient_color[1] / 255.0f, authored.ambient_color[2] / 255.0f, 1.0f);
		out["cell_directional_color"] = Color(authored.directional_color[0] / 255.0f, authored.directional_color[1] / 255.0f, authored.directional_color[2] / 255.0f, 1.0f);
		out["cell_fog_color"] = Color(authored.fog_color[0] / 255.0f, authored.fog_color[1] / 255.0f, authored.fog_color[2] / 255.0f, 1.0f);
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_script_data(int64_t scpt_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		auto script = file_.get_script_data(static_cast<uint32_t>(scpt_form_id));
		if (!script) {
			return out;
		}
		out["editor_id"] = String(script->editor_id.c_str());
		out["source_text"] = String(script->source_text.c_str());
		out["script_type"] = static_cast<int64_t>(script->script_type);

		Array locals;
		for (const auto &var : script->locals) {
			Dictionary d;
			d["name"] = String(var.name.c_str());
			d["index"] = static_cast<int64_t>(var.index);
			locals.push_back(d);
		}
		out["locals"] = locals;

		PackedInt64Array refs;
		for (uint32_t form_id : script->referenced_form_ids) {
			refs.push_back(static_cast<int64_t>(form_id));
		}
		out["referenced_form_ids"] = refs;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

PackedInt64Array EsmReader::get_all_script_form_ids() const {
	PackedInt64Array out;
	if (!opened_) {
		return out;
	}
	try {
		file_.for_each_record([&](const esm::RecordInfo &r) {
			if (r.type == "SCPT") {
				out.push_back(static_cast<int64_t>(r.form_id));
			}
		});
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

int64_t EsmReader::get_cell_worldspace(int64_t cell_form_id) const {
	if (!opened_) {
		return -1;
	}
	try {
		auto wrld_form_id = file_.get_cell_worldspace(static_cast<uint32_t>(cell_form_id));
		return wrld_form_id ? static_cast<int64_t>(*wrld_form_id) : -1;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return -1;
	}
}

String EsmReader::get_cell_editor_id(int64_t cell_form_id) const {
	if (!opened_) {
		return "";
	}
	try {
		return String(file_.get_cell_editor_id(static_cast<uint32_t>(cell_form_id)).c_str());
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return "";
	}
}

Dictionary EsmReader::get_reference_placement(int64_t refr_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		if (auto pl = file_.get_reference_placement(static_cast<uint32_t>(refr_form_id))) {
			out = placement_to_dict(*pl);
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

PackedInt64Array EsmReader::get_placed_reference_cells() const {
	PackedInt64Array out;
	if (!opened_) {
		return out;
	}
	try {
		const auto pairs = file_.get_placed_reference_cells();
		out.resize(static_cast<int64_t>(pairs.size() * 2));
		int64_t i = 0;
		for (const auto &pair : pairs) {
			out[i++] = static_cast<int64_t>(pair.first);
			out[i++] = static_cast<int64_t>(pair.second);
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Array EsmReader::get_exterior_cell_index() const {
	Array out;
	if (!opened_) {
		return out;
	}
	try {
		for (const auto &world : file_.get_exterior_cell_index()) {
			PackedInt64Array grid;
			grid.resize(static_cast<int64_t>(world.grid_cells.size() * 3));
			int64_t i = 0;
			for (const auto &cell : world.grid_cells) {
				grid[i++] = cell.x;
				grid[i++] = cell.y;
				grid[i++] = static_cast<int64_t>(cell.cell_form_id);
			}
			Dictionary entry;
			entry["wrld_form_id"] = static_cast<int64_t>(world.wrld_form_id);
			entry["persistent_cell_form_id"] = static_cast<int64_t>(world.persistent_cell_form_id);
			entry["grid"] = grid;
			out.push_back(entry);
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_exterior_cell_grid(int64_t cell_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		if (auto grid = file_.get_exterior_cell_grid(static_cast<uint32_t>(cell_form_id))) {
			out["x"] = grid->x;
			out["y"] = grid->y;
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
		Array alpha_layers;
		for (const auto &layer : land->alpha_layers) {
			Dictionary layer_dict;
			layer_dict["ltex_form_id"] = static_cast<int64_t>(layer.ltex_form_id);
			layer_dict["quadrant"] = static_cast<int>(layer.quadrant);
			layer_dict["layer_index"] = static_cast<int>(layer.layer_index);
			PackedFloat32Array opacity;
			opacity.resize(static_cast<int>(layer.opacity.size()));
			for (size_t i = 0; i < layer.opacity.size(); ++i) {
				opacity[static_cast<int>(i)] = layer.opacity[i];
			}
			layer_dict["opacity"] = opacity;
			alpha_layers.push_back(layer_dict);
		}
		out["alpha_layers"] = alpha_layers;
		// phases/2/14-native-terrain-texture-blend.md: real VCLR/VNML, raw bytes
		// (PackedByteArray already matches VCLR's own 0-255-unsigned-RGB layout
		// exactly; VNML decode -- signed byte, (X,Z,Y) file axis order -- is left
		// to the caller, see LandData::vertex_normals_raw's own comment).
		PackedByteArray vertex_colors;
		vertex_colors.resize(static_cast<int>(land->vertex_colors.size()));
		for (size_t i = 0; i < land->vertex_colors.size(); ++i) {
			vertex_colors[static_cast<int>(i)] = land->vertex_colors[i];
		}
		out["vertex_colors"] = vertex_colors;
		PackedByteArray vertex_normals_raw;
		vertex_normals_raw.resize(static_cast<int>(land->vertex_normals_raw.size()));
		for (size_t i = 0; i < land->vertex_normals_raw.size(); ++i) {
			vertex_normals_raw[static_cast<int>(i)] = land->vertex_normals_raw[i];
		}
		out["vertex_normals_raw"] = vertex_normals_raw;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_grass_data(int64_t grass_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		auto grass = file_.get_grass_data(static_cast<uint32_t>(grass_form_id));
		if (!grass) {
			return out;
		}
		out["editor_id"] = String(grass->editor_id.c_str());
		out["model_path"] = String(grass->model_path.c_str());
		out["density"] = static_cast<int>(grass->density);
		out["min_slope"] = static_cast<int>(grass->min_slope);
		out["max_slope"] = static_cast<int>(grass->max_slope);
		out["units_from_water_amount"] = static_cast<int>(grass->units_from_water_amount);
		out["units_from_water_type"] = static_cast<int64_t>(grass->units_from_water_type);
		out["position_range"] = grass->position_range;
		out["height_range"] = grass->height_range;
		out["color_range"] = grass->color_range;
		out["wave_period"] = grass->wave_period;
		out["flags"] = static_cast<int>(grass->flags);
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Array EsmReader::get_ltex_grass_form_ids(int64_t ltex_form_id) const {
	Array out;
	if (!opened_) {
		return out;
	}
	try {
		for (uint32_t form_id : file_.get_ltex_grass_form_ids(static_cast<uint32_t>(ltex_form_id))) {
			out.push_back(static_cast<int64_t>(form_id));
		}
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

String EsmReader::resolve_ltex_normal_texture_path(int64_t ltex_form_id) const {
	if (!opened_) {
		return String();
	}
	try {
		return String(file_.resolve_ltex_normal_texture_path(static_cast<uint32_t>(ltex_form_id)).c_str());
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return String();
	}
}

String EsmReader::resolve_soun_filename(int64_t soun_form_id) const {
	if (!opened_) {
		return String();
	}
	try {
		return String(file_.resolve_soun_filename(static_cast<uint32_t>(soun_form_id)).c_str());
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return String();
	}
}

Dictionary EsmReader::get_door_data(int64_t door_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		auto door = file_.get_door_data(static_cast<uint32_t>(door_form_id));
		if (!door) {
			return out;
		}
		out["open_sound_path"] = String(door->open_sound_path.c_str());
		out["close_sound_path"] = String(door->close_sound_path.c_str());
		out["loop_sound_path"] = String(door->loop_sound_path.c_str());
		out["flags"] = static_cast<int64_t>(door->flags);
		out["is_automatic_door"] = door->is_automatic_door();
		out["is_hidden"] = door->is_hidden();
		out["is_minimal_use"] = door->is_minimal_use();
		out["is_sliding_door"] = door->is_sliding_door();
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
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

Dictionary EsmReader::resolve_refr_xtel(int64_t refr_form_id) const {
	Dictionary out;
	if (!opened_) {
		return out;
	}
	try {
		auto dest = file_.resolve_refr_xtel(static_cast<uint32_t>(refr_form_id));
		if (!dest) {
			return out;
		}
		out["dest_cell_form_id"] = static_cast<int64_t>(dest->dest_cell_form_id);
		out["dest_position"] = Vector3(dest->dest_position[0], dest->dest_position[1], dest->dest_position[2]);
		out["dest_rotation"] = Vector3(dest->dest_rotation[0], dest->dest_rotation[1], dest->dest_rotation[2]);
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

PackedStringArray EsmReader::get_all_item_candidates() const {
	PackedStringArray arr;
	if (!opened_) {
		return arr;
	}
	try {
		const auto items = file_.get_all_item_candidates();
		arr.resize(static_cast<int64_t>(items.size()));
		for (size_t i = 0; i < items.size(); ++i) {
			arr[static_cast<int64_t>(i)] = String(items[i].c_str());
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return arr;
}

PackedStringArray EsmReader::get_all_cell_candidates() const {
	PackedStringArray arr;
	if (!opened_) {
		return arr;
	}
	try {
		const auto cells = file_.get_all_cell_candidates();
		arr.resize(static_cast<int64_t>(cells.size()));
		for (size_t i = 0; i < cells.size(); ++i) {
			arr[static_cast<int64_t>(i)] = String(cells[i].c_str());
		}
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return arr;
}

// ---------------------------------------------------------------------------
// day-night / weather (feature/day-night-cycle)
// ---------------------------------------------------------------------------

Dictionary EsmReader::get_climate_data(int64_t form_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto opt = file_.get_climate_data(static_cast<uint32_t>(form_id));
		if (!opt) return out;
		const auto &c = *opt;
		out["form_id"]           = static_cast<int64_t>(c.form_id);
		out["editor_id"]         = String(c.editor_id.c_str());
		out["sun_texture"]       = String(c.sun_texture_path.c_str());
		out["sun_glare_texture"] = String(c.sun_glare_texture_path.c_str());
		out["night_sky_model"]   = String(c.night_sky_model_path.c_str());
		out["sunrise_begin"]     = c.sunrise_begin;
		out["sunrise_end"]       = c.sunrise_end;
		out["sunset_begin"]      = c.sunset_begin;
		out["sunset_end"]        = c.sunset_end;
		out["volatility"]        = static_cast<int64_t>(c.volatility);
		out["moon_phase_length"] = static_cast<int64_t>(c.moon_phase_length);
		Array chances;
		for (const auto &wc : c.weather_chances) {
			Dictionary d;
			d["weather_form_id"] = static_cast<int64_t>(wc.weather_form_id);
			d["chance"]          = static_cast<int64_t>(wc.chance);
			d["global_form_id"]  = static_cast<int64_t>(wc.global_form_id);
			chances.push_back(d);
		}
		out["weather_chances"] = chances;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::get_weather_data(int64_t form_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto opt = file_.get_weather_data(static_cast<uint32_t>(form_id));
		if (!opt) return out;
		const auto &w = *opt;
		out["form_id"]               = static_cast<int64_t>(w.form_id);
		out["editor_id"]             = String(w.editor_id.c_str());
		out["cloud_texture_upper"]   = String(w.cloud_texture_upper.c_str());
		out["cloud_texture_horizon"] = String(w.cloud_texture_horizon.c_str());
		out["cloud_texture_lower1"]  = String(w.cloud_texture_lower1.c_str());
		out["cloud_texture_lower2"]  = String(w.cloud_texture_lower2.c_str());
		// Flatten color table to PackedByteArray: 10 types × 6 times × 4 RGBA bytes.
		PackedByteArray colors;
		colors.resize(esm::kWthrColorTypes * esm::kWthrColorTimes * 4);
		int idx = 0;
		for (int t = 0; t < esm::kWthrColorTypes; ++t) {
			for (int i = 0; i < esm::kWthrColorTimes; ++i) {
				colors[idx++] = w.colors[t][i].r;
				colors[idx++] = w.colors[t][i].g;
				colors[idx++] = w.colors[t][i].b;
				colors[idx++] = w.colors[t][i].a;
			}
		}
		out["colors"]            = colors;
		out["fog_day_near"]      = w.fog.day_near;
		out["fog_day_far"]       = w.fog.day_far;
		out["fog_night_near"]    = w.fog.night_near;
		out["fog_night_far"]     = w.fog.night_far;
		out["fog_day_power"]     = w.fog.day_power;
		out["fog_night_power"]   = w.fog.night_power;
		out["wind_speed"]        = static_cast<int64_t>(w.wind_speed);
		out["cloud_speed_lower"] = static_cast<int64_t>(w.cloud_speed_lower);
		out["cloud_speed_upper"] = static_cast<int64_t>(w.cloud_speed_upper);
		out["classification"]    = static_cast<int64_t>(w.classification);
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

int64_t EsmReader::get_worldspace_climate(int64_t wrld_form_id) const {
	if (!opened_) return 0;
	try {
		return static_cast<int64_t>(
			file_.get_worldspace_climate(static_cast<uint32_t>(wrld_form_id)));
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return 0;
	}
}

Dictionary EsmReader::get_global_variable(int64_t form_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto opt = file_.get_global_variable(static_cast<uint32_t>(form_id));
		if (!opt) return out;
		out["form_id"]   = static_cast<int64_t>(opt->form_id);
		out["editor_id"] = String(opt->editor_id.c_str());
		out["type"]      = String(std::string(1, opt->type).c_str());
		out["value"]     = opt->value;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}

Dictionary EsmReader::find_global_by_editor_id(const String &editor_id) const {
	Dictionary out;
	if (!opened_) return out;
	try {
		auto opt = file_.find_global_by_editor_id(editor_id.utf8().get_data());
		if (!opt) return out;
		out["form_id"]   = static_cast<int64_t>(opt->form_id);
		out["editor_id"] = String(opt->editor_id.c_str());
		out["type"]      = String(std::string(1, opt->type).c_str());
		out["value"]     = opt->value;
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
	}
	return out;
}
