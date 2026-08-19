#include "esm_file.h"

#include "../common/byte_reader.h"
#include "../common/units.h"

#include <cmath>
#include <cstring>
#include <stdexcept>
#include <zlib.h>

namespace esm {

namespace {

// Both GRUP and record headers are 24 bytes: a 4-char tag followed by five
// uint32 fields. What the last four fields mean differs (group_size/label/
// group_type/stamp/unknown vs. data_size/flags/form_id/vcs/internal), but
// the layout is identical, so both are read the same way here.
constexpr size_t kHeaderSize = 24;

float read_f32(util::ByteReader &r) {
	uint32_t bits = r.read_u32();
	float f;
	std::memcpy(&f, &bits, sizeof(float));
	return f;
}

} // namespace

EsmFile::~EsmFile() {
	if (file_) {
		std::fclose(file_);
	}
}

std::vector<uint8_t> EsmFile::read_at(long offset, size_t size) const {
	if (std::fseek(file_, offset, SEEK_SET) != 0) {
		throw std::runtime_error("EsmFile: seek failed");
	}
	std::vector<uint8_t> buf(size);
	if (size > 0 && std::fread(buf.data(), 1, size, file_) != size) {
		throw std::runtime_error("EsmFile: read past end of file at offset " + std::to_string(offset));
	}
	return buf;
}

void EsmFile::walk(long start, long end, const std::function<void(const RecordInfo &)> &callback) const {
	long pos = start;
	while (pos < end) {
		std::vector<uint8_t> hdr = read_at(pos, kHeaderSize);
		util::ByteReader hr(hdr.data(), hdr.size());
		std::string tag(reinterpret_cast<const char *>(hr.read_bytes(4).data()), 4);

		if (tag == "GRUP") {
			uint32_t group_size = hr.read_u32(); // includes this 24-byte header
			hr.read_u32(); // label — meaning depends on group_type, unused here
			hr.read_u32(); // group_type
			hr.read_u32(); // timestamp
			hr.read_u32(); // unknown/VCS

			long content_start = pos + static_cast<long>(kHeaderSize);
			long content_end = pos + static_cast<long>(group_size);
			if (group_size < kHeaderSize || content_end > end) {
				throw std::runtime_error("EsmFile: malformed GRUP size at offset " + std::to_string(pos));
			}
			walk(content_start, content_end, callback);
			pos = content_end;
		} else {
			RecordInfo info;
			info.type = tag;
			info.data_size = hr.read_u32();
			info.flags = hr.read_u32();
			info.form_id = hr.read_u32();
			hr.read_u32(); // version control info (timestamp/last user) — unused
			hr.read_u32(); // internal form version + unknown — unused
			info.data_offset = pos + static_cast<long>(kHeaderSize);

			callback(info);
			pos = info.data_offset + static_cast<long>(info.data_size);
		}
	}
}

std::optional<RecordInfo> EsmFile::find_owner_of(long start, long end, long target_header_offset, uint32_t *out_wrld_form_id) const {
	long pos = start;
	bool have_last = false;
	RecordInfo last_record;

	while (pos < end) {
		std::vector<uint8_t> hdr = read_at(pos, kHeaderSize);
		util::ByteReader hr(hdr.data(), hdr.size());
		std::string tag(reinterpret_cast<const char *>(hr.read_bytes(4).data()), 4);

		if (tag == "GRUP") {
			uint32_t group_size = hr.read_u32();
			uint32_t label = hr.read_u32();
			uint32_t group_type = hr.read_u32();
			hr.read_u32(); // timestamp
			hr.read_u32(); // unknown/VCS

			long content_start = pos + static_cast<long>(kHeaderSize);
			long content_end = pos + static_cast<long>(group_size);
			if (target_header_offset >= content_start && target_header_offset < content_end) {
				if (group_type == 1 && out_wrld_form_id != nullptr) {
					*out_wrld_form_id = label; // "World Children" — label is the WRLD's own FormID
				}
				if (auto deeper = find_owner_of(content_start, content_end, target_header_offset, out_wrld_form_id)) {
					return deeper;
				}
				// target is a direct child of this GRUP — the owner is
				// whatever record's bytes immediately preceded it.
				return have_last ? std::optional<RecordInfo>(last_record) : std::nullopt;
			}
			pos = content_end;
		} else {
			RecordInfo info;
			info.type = tag;
			info.data_size = hr.read_u32();
			info.flags = hr.read_u32();
			info.form_id = hr.read_u32();
			hr.read_u32(); // version control info — unused
			hr.read_u32(); // internal form version + unknown — unused
			info.data_offset = pos + static_cast<long>(kHeaderSize);

			last_record = info;
			have_last = true;
			pos = info.data_offset + static_cast<long>(info.data_size);
		}
	}
	return std::nullopt;
}

std::optional<RecordInfo> EsmFile::find_cell_containing_ref(uint32_t refr_form_id) const {
	return find_cell_containing_ref(refr_form_id, nullptr);
}

std::optional<RecordInfo> EsmFile::find_cell_containing_ref(uint32_t refr_form_id, uint32_t *out_wrld_form_id) const {
	auto target = find_record_by_form_id(refr_form_id);
	if (!target) {
		return std::nullopt;
	}
	long target_header_offset = target->data_offset - static_cast<long>(kHeaderSize);
	auto owner = find_owner_of(0, file_size_, target_header_offset, out_wrld_form_id);
	if (owner && owner->type == "CELL") {
		return owner;
	}
	return std::nullopt;
}

std::optional<DoorDestination> EsmFile::resolve_refr_xtel(uint32_t refr_form_id) const {
	auto refr = find_record_by_form_id(refr_form_id);
	if (!refr || refr->type != "REFR") {
		return std::nullopt;
	}

	std::vector<uint8_t> data = read_record_data(*refr);
	std::vector<Subrecord> subs = parse_subrecords(data);

	for (const auto &s : subs) {
		if (s.type != "XTEL" || s.size < 32) {
			continue;
		}
		util::ByteReader sr(s.data, s.size);
		uint32_t dest_refr_form_id = sr.read_u32();
		float dest_position_raw[3]; // raw Gamebryo units — kept for the grid math below
		dest_position_raw[0] = read_f32(sr);
		dest_position_raw[1] = read_f32(sr);
		dest_position_raw[2] = read_f32(sr);
		float dest_position[3];
		dest_position[0] = dest_position_raw[0] * units::kGamebryoUnitsToMeters;
		dest_position[1] = dest_position_raw[1] * units::kGamebryoUnitsToMeters;
		dest_position[2] = dest_position_raw[2] * units::kGamebryoUnitsToMeters;
		float dest_rotation[3];
		dest_rotation[0] = read_f32(sr);
		dest_rotation[1] = read_f32(sr);
		dest_rotation[2] = read_f32(sr);

		uint32_t dest_wrld_form_id = 0;
		auto dest_cell = find_cell_containing_ref(dest_refr_form_id, &dest_wrld_form_id);
		if (!dest_cell) {
			return std::nullopt;
		}
		uint32_t resolved_cell_form_id = dest_cell->form_id;

		// dest_wrld_form_id != 0 means the landing REFR's structural parent
		// CELL belongs to a worldspace (an exterior destination) rather than
		// being a plain interior cell. For exterior destinations, that
		// structurally-found CELL is NOT necessarily the right one to load:
		// a worldspace has exactly one "persistent" cell (a bookkeeping
		// bucket outside the normal grid block/sub-block hierarchy, holding
		// always-loaded refs like quest markers/LOD — not tied to any real
		// location) that landing markers are commonly filed under instead
		// of the real geographic tile. Confirmed real, not hypothetical:
		// WastelandNV's persistent cell holds 4468 refs spanning the whole
		// map (Black Mountain to Hoover Dam to The Strip) and reports a
		// nominal XCLC of (0,0) that has nothing to do with where a door
		// actually leads. The original engine never uses "which CELL
		// structurally owns this REFR" to pick an exterior load target
		// anyway — it always derives the grid cell from the landing
		// position itself, so that's what's done here instead of trusting
		// structural containment.
		if (dest_wrld_form_id != 0) {
			constexpr float kCellSizeRawUnits = 4096.0f;
			int32_t grid_x = static_cast<int32_t>(std::floor(dest_position_raw[0] / kCellSizeRawUnits));
			int32_t grid_y = static_cast<int32_t>(std::floor(dest_position_raw[1] / kCellSizeRawUnits));
			if (auto real_cell = find_exterior_cell(dest_wrld_form_id, grid_x, grid_y)) {
				resolved_cell_form_id = real_cell->form_id;
			}
			// else: no cell at that grid coordinate (e.g. an ungenerated
			// edge tile) — fall back to the structurally-found cell rather
			// than failing the whole resolution.
		}

		DoorDestination dest;
		dest.dest_cell_form_id = resolved_cell_form_id;
		std::memcpy(dest.dest_position, dest_position, sizeof(dest_position));
		std::memcpy(dest.dest_rotation, dest_rotation, sizeof(dest_rotation));
		return dest;
	}
	return std::nullopt; // no XTEL — a non-teleporting door
}

std::vector<uint8_t> EsmFile::read_record_data(const RecordInfo &record) const {
	std::vector<uint8_t> raw = read_at(record.data_offset, record.data_size);
	if (!record.is_compressed()) {
		return raw;
	}
	if (raw.size() < 4) {
		throw std::runtime_error("EsmFile: compressed record too small to contain size prefix");
	}
	util::ByteReader rr(raw.data(), raw.size());
	uint32_t original_size = rr.read_u32();

	std::vector<uint8_t> out(original_size);
	uLongf dest_len = original_size;
	int rc = uncompress(out.data(), &dest_len, raw.data() + 4, static_cast<uLong>(raw.size() - 4));
	if (rc != Z_OK) {
		throw std::runtime_error("EsmFile: zlib decompression failed for record " + record.type +
				", code " + std::to_string(rc));
	}
	if (dest_len != original_size) {
		out.resize(dest_len);
	}
	return out;
}

std::vector<Subrecord> EsmFile::parse_subrecords(const std::vector<uint8_t> &data) {
	std::vector<Subrecord> out;
	util::ByteReader r(data.data(), data.size());

	uint32_t pending_oversize = 0; // set by a preceding XXXX marker, consumed by the next subrecord
	while (!r.at_end()) {
		auto tag_bytes = r.read_bytes(4);
		std::string tag(reinterpret_cast<const char *>(tag_bytes.data()), 4);
		uint16_t size16 = r.read_u16();

		if (tag == "XXXX") {
			// XXXX's own "size" field is always 4; its data is the real
			// uint32 size of the subrecord immediately following it.
			pending_oversize = r.read_u32();
			continue;
		}

		size_t size = (size16 == kSubrecordOversizeMarker && pending_oversize != 0)
				? pending_oversize
				: size16;
		pending_oversize = 0;

		Subrecord sub;
		sub.type = tag;
		sub.size = size;
		sub.data = r.ptr_at(r.position());
		r.skip(size);
		out.push_back(sub);
	}
	return out;
}

void EsmFile::for_each_record(const std::function<void(const RecordInfo &)> &callback) const {
	walk(0, file_size_, callback);
}

std::unordered_map<std::string, uint32_t> EsmFile::record_type_histogram() const {
	std::unordered_map<std::string, uint32_t> counts;
	for_each_record([&](const RecordInfo &r) {
		counts[r.type]++;
	});
	return counts;
}

void EsmFile::open(const std::string &path) {
	file_ = std::fopen(path.c_str(), "rb");
	if (!file_) {
		throw std::runtime_error("EsmFile: could not open file: " + path);
	}
	std::fseek(file_, 0, SEEK_END);
	file_size_ = std::ftell(file_);
	std::fseek(file_, 0, SEEK_SET);

	// The very first record in any master/plugin file is TES4, uncompressed.
	std::vector<uint8_t> hdr = read_at(0, kHeaderSize);
	util::ByteReader hr(hdr.data(), hdr.size());
	std::string tag(reinterpret_cast<const char *>(hr.read_bytes(4).data()), 4);
	if (tag != "TES4") {
		throw std::runtime_error("EsmFile: expected TES4 as the first record, found '" + tag + "': " + path);
	}
	tes4_record_.type = tag;
	tes4_record_.data_size = hr.read_u32();
	tes4_record_.flags = hr.read_u32();
	tes4_record_.form_id = hr.read_u32();
	hr.read_u32();
	hr.read_u32();
	tes4_record_.data_offset = static_cast<long>(kHeaderSize);

	std::vector<uint8_t> data = read_record_data(tes4_record_);
	std::vector<Subrecord> subs = parse_subrecords(data);
	for (const auto &s : subs) {
		if (s.type == "HEDR" && s.size >= 12) {
			util::ByteReader sr(s.data, s.size);
			header_.version = 0.0f;
			uint32_t bits = sr.read_u32();
			std::memcpy(&header_.version, &bits, sizeof(float));
			header_.num_records = sr.read_u32();
			header_.next_object_id = sr.read_u32();
		} else if (s.type == "MAST") {
			header_.masters.push_back(s.as_string());
		}
	}
}

void EsmFile::ensure_form_id_index() const {
	if (form_id_index_built_) {
		return;
	}
	for_each_record([&](const RecordInfo &r) {
		form_id_index_[r.form_id] = r;
	});
	form_id_index_built_ = true;
}

std::optional<RecordInfo> EsmFile::find_record_by_form_id(uint32_t form_id) const {
	ensure_form_id_index();
	auto it = form_id_index_.find(form_id);
	if (it == form_id_index_.end()) {
		return std::nullopt;
	}
	return it->second;
}

std::optional<RecordInfo> EsmFile::find_cell_by_form_id(uint32_t form_id) const {
	auto r = find_record_by_form_id(form_id);
	if (!r || r->type != "CELL") {
		return std::nullopt;
	}
	return r;
}

std::optional<RecordInfo> EsmFile::find_cell_by_editor_id(const std::string &editor_id) const {
	std::optional<RecordInfo> found;
	for_each_record([&](const RecordInfo &r) {
		if (found || r.type != "CELL") {
			return;
		}
		std::vector<uint8_t> data = read_record_data(r);
		std::vector<Subrecord> subs = parse_subrecords(data);
		for (const auto &s : subs) {
			if (s.type == "EDID") {
				if (s.as_string() == editor_id) {
					found = r;
				}
				break;
			}
		}
	});
	return found;
}

std::vector<RecordInfo> EsmFile::get_child_records(const RecordInfo &parent) const {
	std::vector<RecordInfo> out;
	long child_start = parent.data_offset + static_cast<long>(parent.data_size);
	if (child_start + static_cast<long>(kHeaderSize) > file_size_) {
		return out; // no room for a child GRUP — parent is the last thing in the file
	}

	std::vector<uint8_t> hdr = read_at(child_start, kHeaderSize);
	util::ByteReader hr(hdr.data(), hdr.size());
	std::string tag(reinterpret_cast<const char *>(hr.read_bytes(4).data()), 4);
	if (tag != "GRUP") {
		return out; // this record has no child GRUP
	}
	uint32_t group_size = hr.read_u32();
	long content_end = child_start + static_cast<long>(group_size);
	if (group_size < kHeaderSize || content_end > file_size_) {
		throw std::runtime_error("EsmFile: malformed child GRUP size at offset " + std::to_string(child_start));
	}

	walk(child_start, content_end, [&](const RecordInfo &r) {
		out.push_back(r);
	});
	return out;
}

std::vector<ReferencePlacement> EsmFile::get_cell_references(const RecordInfo &cell) const {
	std::vector<ReferencePlacement> out;
	for (const RecordInfo &child : get_child_records(cell)) {
		if (child.type != "REFR") {
			continue; // ACHR/ACRE/etc — actors, not handled in Phase 1
		}

		std::vector<uint8_t> data = read_record_data(child);
		std::vector<Subrecord> subs = parse_subrecords(data);

		uint32_t base_form_id = 0;
		float position[3] = { 0.0f, 0.0f, 0.0f };
		float rotation[3] = { 0.0f, 0.0f, 0.0f };
		float scale = 1.0f;
		bool has_data = false;
		bool has_xtel = false;
		uint32_t dest_refr_form_id = 0;
		float dest_position[3] = { 0.0f, 0.0f, 0.0f };
		float dest_rotation[3] = { 0.0f, 0.0f, 0.0f };

		for (const auto &s : subs) {
			if (s.type == "NAME" && s.size >= 4) {
				util::ByteReader sr(s.data, s.size);
				base_form_id = sr.read_u32();
			} else if (s.type == "DATA" && s.size >= 24) {
				util::ByteReader sr(s.data, s.size);
				// Position, not rotation/scale: Gamebryo units -> meters (units.h).
				position[0] = read_f32(sr) * units::kGamebryoUnitsToMeters;
				position[1] = read_f32(sr) * units::kGamebryoUnitsToMeters;
				position[2] = read_f32(sr) * units::kGamebryoUnitsToMeters;
				rotation[0] = read_f32(sr);
				rotation[1] = read_f32(sr);
				rotation[2] = read_f32(sr);
				has_data = true;
			} else if (s.type == "XSCL" && s.size >= 4) {
				util::ByteReader sr(s.data, s.size);
				scale = read_f32(sr);
			} else if (s.type == "XTEL" && s.size >= 32) {
				util::ByteReader sr(s.data, s.size);
				dest_refr_form_id = sr.read_u32();
				// Same convention as DATA: position in Gamebryo units -> meters,
				// rotation left in radians.
				dest_position[0] = read_f32(sr) * units::kGamebryoUnitsToMeters;
				dest_position[1] = read_f32(sr) * units::kGamebryoUnitsToMeters;
				dest_position[2] = read_f32(sr) * units::kGamebryoUnitsToMeters;
				dest_rotation[0] = read_f32(sr);
				dest_rotation[1] = read_f32(sr);
				dest_rotation[2] = read_f32(sr);
				has_xtel = true;
			}
		}

		if (base_form_id == 0 || !has_data) {
			continue; // malformed or not a plain placed reference — skip
		}

		ReferencePlacement pl;
		pl.refr_form_id = child.form_id;
		pl.base_form_id = base_form_id;
		std::memcpy(pl.position, position, sizeof(position));
		std::memcpy(pl.rotation, rotation, sizeof(rotation));
		pl.scale = scale;
		pl.has_xtel = has_xtel;
		pl.dest_refr_form_id = dest_refr_form_id;
		std::memcpy(pl.dest_position, dest_position, sizeof(dest_position));
		std::memcpy(pl.dest_rotation, dest_rotation, sizeof(dest_rotation));

		if (auto base = find_record_by_form_id(base_form_id)) {
			pl.base_type = base->type;
			std::vector<uint8_t> base_data = read_record_data(*base);
			std::vector<Subrecord> base_subs = parse_subrecords(base_data);
			for (const auto &s : base_subs) {
				if (s.type == "EDID") {
					pl.base_editor_id = s.as_string();
				} else if (s.type == "MODL") {
					pl.model_path = s.as_string();
				}
			}
		}

		out.push_back(std::move(pl));
	}
	return out;
}

std::vector<ReferencePlacement> EsmFile::get_scol_parts(const RecordInfo &scol) const {
	std::vector<ReferencePlacement> out;
	std::vector<uint8_t> data = read_record_data(scol);
	std::vector<Subrecord> subs = parse_subrecords(data);

	uint32_t pending_stat_form_id = 0;
	bool have_pending = false;

	for (const auto &s : subs) {
		if (s.type == "ONAM" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size);
			pending_stat_form_id = sr.read_u32();
			have_pending = true;
		} else if (s.type == "DATA" && have_pending && s.size >= 24) {
			util::ByteReader sr(s.data, s.size);
			ReferencePlacement pl;
			pl.refr_form_id = scol.form_id; // parts have no FormID of their own
			pl.base_form_id = pending_stat_form_id;
			// Position, not rotation/scale: Gamebryo units -> meters (units.h).
			pl.position[0] = read_f32(sr) * units::kGamebryoUnitsToMeters;
			pl.position[1] = read_f32(sr) * units::kGamebryoUnitsToMeters;
			pl.position[2] = read_f32(sr) * units::kGamebryoUnitsToMeters;
			pl.rotation[0] = read_f32(sr);
			pl.rotation[1] = read_f32(sr);
			pl.rotation[2] = read_f32(sr);
			pl.scale = (s.size >= 28) ? read_f32(sr) : 1.0f;

			if (auto base = find_record_by_form_id(pending_stat_form_id)) {
				pl.base_type = base->type;
				std::vector<uint8_t> base_data = read_record_data(*base);
				std::vector<Subrecord> base_subs = parse_subrecords(base_data);
				for (const auto &bs : base_subs) {
					if (bs.type == "EDID") {
						pl.base_editor_id = bs.as_string();
					} else if (bs.type == "MODL") {
						pl.model_path = bs.as_string();
					}
				}
			}

			out.push_back(std::move(pl));
			have_pending = false;
		}
	}
	return out;
}

std::optional<LightData> EsmFile::get_light_data(uint32_t light_form_id) const {
	auto record = find_record_by_form_id(light_form_id);
	if (!record || record->type != "LIGH") {
		return std::nullopt;
	}
	std::vector<uint8_t> data = read_record_data(*record);
	std::vector<Subrecord> subs = parse_subrecords(data);

	for (const auto &s : subs) {
		if (s.type != "DATA" || s.size < 32) {
			continue;
		}
		util::ByteReader sr(s.data, s.size);
		sr.read_u32(); // Time — unused
		uint32_t radius_raw = sr.read_u32();
		LightData light;
		light.radius = static_cast<float>(radius_raw) * units::kGamebryoUnitsToMeters;
		light.color[0] = sr.read_u8();
		light.color[1] = sr.read_u8();
		light.color[2] = sr.read_u8();
		light.color[3] = sr.read_u8();
		light.flags = sr.read_u32();
		light.falloff = read_f32(sr);
		light.fov_degrees = read_f32(sr);
		// Value, Weight follow — unused, not read.
		return light;
	}
	return std::nullopt;
}

std::optional<RecordInfo> EsmFile::find_worldspace_by_editor_id(const std::string &editor_id) const {
	std::optional<RecordInfo> found;
	for_each_record([&](const RecordInfo &r) {
		if (found || r.type != "WRLD") {
			return;
		}
		std::vector<uint8_t> data = read_record_data(r);
		std::vector<Subrecord> subs = parse_subrecords(data);
		for (const auto &s : subs) {
			if (s.type == "EDID") {
				if (s.as_string() == editor_id) {
					found = r;
				}
				break;
			}
		}
	});
	return found;
}

std::optional<RecordInfo> EsmFile::find_exterior_cell(uint32_t wrld_form_id, int32_t x, int32_t y) const {
	auto wrld = find_record_by_form_id(wrld_form_id);
	if (!wrld || wrld->type != "WRLD") {
		return std::nullopt;
	}
	for (const RecordInfo &c : get_child_records(*wrld)) {
		if (c.type != "CELL") {
			continue;
		}
		std::vector<uint8_t> data = read_record_data(c);
		std::vector<Subrecord> subs = parse_subrecords(data);
		for (const auto &s : subs) {
			if (s.type == "XCLC" && s.size >= 8) {
				util::ByteReader sr(s.data, s.size);
				int32_t cx = static_cast<int32_t>(sr.read_u32());
				int32_t cy = static_cast<int32_t>(sr.read_u32());
				if (cx == x && cy == y) {
					return c;
				}
				break;
			}
		}
	}
	return std::nullopt;
}

std::optional<ExteriorCellGrid> EsmFile::get_exterior_cell_grid(uint32_t cell_form_id) const {
	auto cell = find_record_by_form_id(cell_form_id);
	if (!cell || cell->type != "CELL") {
		return std::nullopt;
	}
	std::vector<uint8_t> data = read_record_data(*cell);
	std::vector<Subrecord> subs = parse_subrecords(data);
	for (const auto &s : subs) {
		if (s.type == "XCLC" && s.size >= 8) {
			util::ByteReader sr(s.data, s.size);
			ExteriorCellGrid grid;
			grid.x = static_cast<int32_t>(sr.read_u32());
			grid.y = static_cast<int32_t>(sr.read_u32());
			return grid;
		}
	}
	return std::nullopt; // interior cell — no XCLC
}

std::string EsmFile::get_cell_editor_id(uint32_t cell_form_id) const {
	auto cell = find_record_by_form_id(cell_form_id);
	if (!cell || cell->type != "CELL") {
		return "";
	}
	std::vector<uint8_t> data = read_record_data(*cell);
	std::vector<Subrecord> subs = parse_subrecords(data);
	for (const auto &s : subs) {
		if (s.type == "EDID") {
			return s.as_string();
		}
	}
	return "";
}

std::optional<LandData> EsmFile::get_land_data(const RecordInfo &land) const {
	if (land.type != "LAND") {
		return std::nullopt;
	}
	std::vector<uint8_t> data = read_record_data(land);
	std::vector<Subrecord> subs = parse_subrecords(data);

	LandData out;
	bool have_vhgt = false;
	for (const auto &s : subs) {
		if (s.type == "VHGT" && s.size >= 4 + static_cast<size_t>(kLandGridSize) * kLandGridSize) {
			util::ByteReader sr(s.data, s.size);
			float height_offset = read_f32(sr);
			std::vector<int8_t> deltas(static_cast<size_t>(kLandGridSize) * kLandGridSize);
			for (auto &delta : deltas) {
				delta = static_cast<int8_t>(sr.read_u8());
			}

			// Decode: 2D cumulative scheme, each delta unit = 8 Gamebryo
			// units. See LandData's comment in esm_types.h for the
			// confidence caveat on this decode order.
			//
			// height_offset is ALSO in these *8 units, not bare Gamebryo
			// units — found by numerically comparing decoded terrain height
			// against real REFR.DATA Z values placed in the same cell
			// (phases/1/04-exterior-cell-terrain.md): with offset applied
			// unscaled, decoded ground height came out ~100m below every
			// REFR resting on it (consistent gap, not noise); multiplying
			// offset by the same *8 factor as the deltas closed the gap to
			// well under a meter across multiple sampled REFRs. Same
			// "verify numerically against independently-known-correct data"
			// technique as the kHavokToMeters fix in units.h.
			constexpr float kDeltaUnitsToGamebryo = 8.0f;
			out.heights.resize(deltas.size());
			float col0 = height_offset * kDeltaUnitsToGamebryo;
			for (int row = 0; row < kLandGridSize; ++row) {
				col0 += deltas[static_cast<size_t>(row) * kLandGridSize + 0] * kDeltaUnitsToGamebryo;
				float running = col0;
				out.heights[static_cast<size_t>(row) * kLandGridSize + 0] = running * units::kGamebryoUnitsToMeters;
				for (int col = 1; col < kLandGridSize; ++col) {
					running += deltas[static_cast<size_t>(row) * kLandGridSize + col] * kDeltaUnitsToGamebryo;
					out.heights[static_cast<size_t>(row) * kLandGridSize + col] = running * units::kGamebryoUnitsToMeters;
				}
			}
			have_vhgt = true;
		} else if (s.type == "BTXT" && s.size >= 8) {
			util::ByteReader sr(s.data, s.size);
			uint32_t ltex_id = sr.read_u32();
			uint8_t quadrant = sr.read_u8();
			if (quadrant < kLandQuadrantCount) {
				out.quadrant_base_ltex[quadrant] = ltex_id;
			}
		}
		// ATXT/VTXT (additional blended layers) deliberately not parsed —
		// see LandData's comment in esm_types.h.
	}
	if (!have_vhgt) {
		return std::nullopt;
	}
	return out;
}

std::string EsmFile::resolve_ltex_texture_path(uint32_t ltex_form_id) const {
	auto ltex = find_record_by_form_id(ltex_form_id);
	if (!ltex || ltex->type != "LTEX") {
		return "";
	}
	std::vector<uint8_t> ltex_data = read_record_data(*ltex);
	std::vector<Subrecord> ltex_subs = parse_subrecords(ltex_data);
	uint32_t txst_id = 0;
	for (const auto &s : ltex_subs) {
		if (s.type == "TNAM" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size);
			txst_id = sr.read_u32();
			break;
		}
	}
	if (txst_id == 0) {
		return "";
	}

	auto txst = find_record_by_form_id(txst_id);
	if (!txst || txst->type != "TXST") {
		return "";
	}
	std::vector<uint8_t> txst_data = read_record_data(*txst);
	std::vector<Subrecord> txst_subs = parse_subrecords(txst_data);
	for (const auto &s : txst_subs) {
		if (s.type == "TX00") {
			return s.as_string();
		}
	}
	return "";
}

} // namespace esm
