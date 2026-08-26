#include "esm_file.h"

#include "../common/byte_reader.h"
#include "../common/units.h"

#include <cmath>
#include <cstring>
#include <stdexcept>
#include <unordered_set>
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

std::optional<CellLightingData> parse_lighting_data(const std::vector<Subrecord> &subs, const char *subrecord_name) {
	for (const auto &s : subs) {
		if (s.type != subrecord_name || s.size < 40) continue;
		util::ByteReader sr(s.data, s.size);
		CellLightingData lighting;
		for (int i = 0; i < 4; ++i) lighting.ambient_color[i] = sr.read_u8();
		for (int i = 0; i < 4; ++i) lighting.directional_color[i] = sr.read_u8();
		for (int i = 0; i < 4; ++i) lighting.fog_color[i] = sr.read_u8();
		lighting.fog_near = read_f32(sr);
		lighting.fog_far = read_f32(sr);
		lighting.directional_rotation_xy = static_cast<int32_t>(sr.read_u32());
		lighting.directional_rotation_z = static_cast<int32_t>(sr.read_u32());
		lighting.directional_fade = read_f32(sr);
		lighting.fog_clip_distance = read_f32(sr);
		lighting.fog_power = read_f32(sr);
		return lighting;
	}
	return std::nullopt;
}

constexpr uint32_t kLnamInheritAmbient = 0x001;
constexpr uint32_t kLnamInheritDirectionalColor = 0x002;
constexpr uint32_t kLnamInheritFogColor = 0x004;
constexpr uint32_t kLnamInheritFogNear = 0x008;
constexpr uint32_t kLnamInheritFogFar = 0x010;
constexpr uint32_t kLnamInheritDirectionalRotation = 0x020;
constexpr uint32_t kLnamInheritDirectionalFade = 0x040;
constexpr uint32_t kLnamInheritFogClip = 0x080;
constexpr uint32_t kLnamInheritFogPower = 0x100;

void apply_lighting_inheritance(CellLightingData &out, const CellLightingData &templ, uint32_t fields) {
	if (fields & kLnamInheritAmbient) std::memcpy(out.ambient_color, templ.ambient_color, sizeof(out.ambient_color));
	if (fields & kLnamInheritDirectionalColor) std::memcpy(out.directional_color, templ.directional_color, sizeof(out.directional_color));
	if (fields & kLnamInheritFogColor) std::memcpy(out.fog_color, templ.fog_color, sizeof(out.fog_color));
	if (fields & kLnamInheritFogNear) out.fog_near = templ.fog_near;
	if (fields & kLnamInheritFogFar) out.fog_far = templ.fog_far;
	if (fields & kLnamInheritDirectionalRotation) {
		out.directional_rotation_xy = templ.directional_rotation_xy;
		out.directional_rotation_z = templ.directional_rotation_z;
	}
	if (fields & kLnamInheritDirectionalFade) out.directional_fade = templ.directional_fade;
	if (fields & kLnamInheritFogClip) out.fog_clip_distance = templ.fog_clip_distance;
	if (fields & kLnamInheritFogPower) out.fog_power = templ.fog_power;
}

// phases/2/11-exterior-cell-lookup-index.md: Exterior Cell Block/Sub-Block
// GRUP sizing, confirmed against UESP's Mod File Format docs -- a block is
// 32x32 cells (4x4 sub-blocks of 8x8 cells each).
constexpr int32_t kSubBlockCells = 8;
constexpr int32_t kBlockCells = 32;

// True floor division, not C++'s truncating `/` -- block/sub-block
// coordinates are commonly negative (Goodsprings' own block decodes to
// x=-1), the same lesson CellStreamBuilder's own grid math already
// accounts for.
int32_t floor_div(int32_t a, int32_t b) {
	int32_t q = a / b;
	if ((a % b != 0) && ((a < 0) != (b < 0))) {
		q -= 1;
	}
	return q;
}

// A GRUP's label field, for group_type 4 (Exterior Cell Block) and 5
// (Exterior Cell Sub-Block), packs the block/sub-block's own (x, y)
// coordinate as two signed 16-bit halves -- confirmed against 6 real
// WastelandNV cells (see phases/2/11-exterior-cell-lookup-index.md): the
// label's low 16 bits are x, the high 16 bits are y.
struct GrupGridCoord {
	int16_t x;
	int16_t y;
};

GrupGridCoord decode_grup_label(uint32_t label) {
	return { static_cast<int16_t>(label & 0xFFFF), static_cast<int16_t>((label >> 16) & 0xFFFF) };
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
		uint32_t emittance_form_id = 0;
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
			} else if (s.type == "XEMI" && s.size >= 4) {
				util::ByteReader sr(s.data, s.size);
				emittance_form_id = sr.read_u32();
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
		pl.emittance_form_id = emittance_form_id;
		std::memcpy(pl.position, position, sizeof(position));
		std::memcpy(pl.rotation, rotation, sizeof(rotation));
		pl.scale = scale;
		pl.visible_when_distant = (child.flags & kRecordFlagVisibleWhenDistant) != 0;
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
				} else if (s.type == "SCRI" && s.size >= 4) {
					util::ByteReader sr(s.data, s.size);
					pl.script_form_id = sr.read_u32();
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

std::optional<std::array<uint8_t, 4>> EsmFile::get_emittance_color(uint32_t emittance_form_id) const {
	auto record = find_record_by_form_id(emittance_form_id);
	if (!record) return std::nullopt;
	if (record->type == "LIGH") {
		auto light = get_light_data(emittance_form_id);
		if (!light) return std::nullopt;
		return std::array<uint8_t, 4>{light->color[0], light->color[1], light->color[2], light->color[3]};
	}
	if (record->type != "REGN") return std::nullopt;
	const std::vector<uint8_t> data = read_record_data(*record);
	for (const auto &s : parse_subrecords(data)) {
		if (s.type == "RCLR" && s.size >= 4) {
			return std::array<uint8_t, 4>{s.data[0], s.data[1], s.data[2], s.data[3]};
		}
	}
	return std::nullopt;
}

std::optional<ItemData> EsmFile::get_item_data(uint32_t item_form_id) const {
	auto record = find_record_by_form_id(item_form_id);
	if (!record || (record->type != "MISC" && record->type != "KEYM" && record->type != "ALCH" && record->type != "WEAP")) return std::nullopt;
	ItemData item;
	bool have_data = false;
	bool have_alch_weight = false;
	std::vector<uint8_t> data = read_record_data(*record);
	for (const auto &s : parse_subrecords(data)) {
		if (s.type == "FULL") item.full_name = s.as_string();
		else if (s.type == "ICON") item.inventory_icon = s.as_string();
		else if (s.type == "MICO") item.message_icon = s.as_string();
		else if ((record->type == "MISC" || record->type == "KEYM") && s.type == "DATA" && s.size >= 8) {
			util::ByteReader sr(s.data, s.size);
			item.value = static_cast<int32_t>(sr.read_u32());
			item.weight = read_f32(sr);
			have_data = true;
		}
		else if (record->type == "WEAP" && s.type == "DATA" && s.size >= 12) {
			// Real FalloutNV.esm WEAP.DATA is 15 bytes. Its pickup-relevant
			// fields are Value:int32 at offset 0 and Weight:float32 at offset 8;
			// the intervening bytes belong to weapon-specific stats.
			util::ByteReader sr(s.data, s.size);
			item.value = static_cast<int32_t>(sr.read_u32());
			sr.skip(4);
			item.weight = read_f32(sr);
			have_data = true;
		}
		else if (record->type == "ALCH" && !have_alch_weight && s.type == "DATA" && s.size == 4) {
			util::ByteReader sr(s.data, s.size); item.weight = read_f32(sr);
			have_alch_weight = true;
		}
		else if (record->type == "ALCH" && s.type == "ENIT" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size); item.value = static_cast<int32_t>(sr.read_u32()); have_data = true;
		}
	}
	return have_data ? std::optional<ItemData>(std::move(item)) : std::nullopt;
}

std::optional<GrassData> EsmFile::get_grass_data(uint32_t grass_form_id) const {
	auto record = find_record_by_form_id(grass_form_id);
	if (!record || record->type != "GRAS") {
		return std::nullopt;
	}
	GrassData grass;
	bool have_data = false;
	const std::vector<uint8_t> data = read_record_data(*record);
	const std::vector<Subrecord> subs = parse_subrecords(data);
	for (const Subrecord &s : subs) {
		if (s.type == "EDID") grass.editor_id = s.as_string();
		else if (s.type == "MODL") grass.model_path = s.as_string();
		else if (s.type == "DATA" && s.size >= 29) {
			// GRAS.DATA is 32 bytes in every shipped FNV base record.  Its
			// first three traits are bytes, then two water traits with padding;
			// only the later four traits are floats.  See grass_survey.cpp and
			// GetGrassTraitNumeric's verified trait order.
			util::ByteReader sr(s.data, s.size);
			grass.density = sr.read_u8();
			grass.min_slope = sr.read_u8();
			grass.max_slope = sr.read_u8();
			sr.read_u8(); // unknown/padding byte
			grass.units_from_water_amount = sr.read_u16();
			sr.read_u16(); // unknown/padding bytes
			grass.units_from_water_type = sr.read_u32();
			grass.position_range = read_f32(sr);
			grass.height_range = read_f32(sr);
			grass.color_range = read_f32(sr);
			grass.wave_period = read_f32(sr);
			grass.flags = sr.read_u8();
			have_data = true;
		}
	}
	return have_data ? std::optional<GrassData>(std::move(grass)) : std::nullopt;
}

std::vector<uint32_t> EsmFile::get_ltex_grass_form_ids(uint32_t ltex_form_id) const {
	std::vector<uint32_t> out;
	auto record = find_record_by_form_id(ltex_form_id);
	if (!record || record->type != "LTEX") {
		return out;
	}
	const std::vector<uint8_t> data = read_record_data(*record);
	const std::vector<Subrecord> subs = parse_subrecords(data);
	for (const Subrecord &s : subs) {
		if (s.type == "GNAM" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size);
			out.push_back(sr.read_u32());
		}
	}
	return out;
}

std::optional<TerminalData> EsmFile::get_terminal_data(uint32_t terminal_form_id) const {
	auto record = find_record_by_form_id(terminal_form_id);
	if (!record || record->type != "TERM") return std::nullopt;
	TerminalData terminal;
	TerminalMenuItem *current = nullptr;
	// Subrecord views point into this buffer, so it must remain alive for the
	// whole parse rather than being a temporary range-for expression.
	std::vector<uint8_t> data = read_record_data(*record);
	std::vector<Subrecord> subs = parse_subrecords(data);
	for (const auto &s : subs) {
		if (s.type == "EDID") terminal.editor_id = s.as_string();
		else if (s.type == "FULL") terminal.full_name = s.as_string();
		else if (s.type == "MODL") terminal.model_path = s.as_string();
		else if (s.type == "DESC") terminal.welcome_text = s.as_string();
		else if (s.type == "DNAM" && s.size >= 4) {
			util::ByteReader bytes(s.data, s.size);
			terminal.flags = bytes.read_u32();
		}
		else if (s.type == "ITXT") {
			terminal.items.push_back({});
			current = &terminal.items.back();
			current->text = s.as_string();
		}
		else if (current != nullptr && s.type == "RNAM") {
			// Real P04 submenu data has a 4-byte all-zero RNAM for its "No."
			// item: an authored empty result, not printable text. Preserve only
			// text-shaped RNAM here until non-zero 4-byte variants are verified.
			if (s.size != 4) current->result_text = s.as_string();
		}
		else if (current != nullptr && s.type == "ANAM" && s.size >= 1) current->flags = s.data[0];
		else if (current != nullptr && s.type == "INAM" && s.size >= 4) {
			util::ByteReader bytes(s.data, s.size);
			current->note_form_id = bytes.read_u32();
		}
		else if (current != nullptr && s.type == "TNAM" && s.size >= 4) {
			util::ByteReader bytes(s.data, s.size);
			current->submenu_form_id = bytes.read_u32();
		}
		else if (current != nullptr && s.type == "CTDA") ++current->condition_count;
		else if (current != nullptr && s.type == "SCTX") current->script_source = s.as_string();
	}
	return terminal;
}

std::optional<NoteData> EsmFile::get_note_data(uint32_t note_form_id) const {
	auto record = find_record_by_form_id(note_form_id);
	if (!record || record->type != "NOTE") return std::nullopt;
	NoteData note;
	std::vector<uint8_t> data = read_record_data(*record);
	std::vector<Subrecord> subs = parse_subrecords(data);
	for (const auto &s : subs) {
		if (s.type == "EDID") note.editor_id = s.as_string();
		else if (s.type == "FULL") note.full_name = s.as_string();
		else if (s.type == "TNAM") note.text = s.as_string();
	}
	return note;
}

std::optional<ResolvedCellLightingData> EsmFile::get_cell_lighting_data(uint32_t cell_form_id) const {
	auto record = find_record_by_form_id(cell_form_id);
	if (!record || record->type != "CELL") {
		return std::nullopt;
	}
	std::vector<uint8_t> data = read_record_data(*record);
	std::vector<Subrecord> subs = parse_subrecords(data);

	auto authored = parse_lighting_data(subs, "XCLL");
	if (!authored) return std::nullopt;
	ResolvedCellLightingData result;
	result.cell_authored = *authored;
	result.resolved = *authored;
	for (const auto &s : subs) {
		if (s.type == "LTMP" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size);
			result.template_form_id = sr.read_u32();
		} else if (s.type == "LNAM" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size);
			result.inherited_fields = sr.read_u32();
		}
	}
	if (result.template_form_id != 0 && result.inherited_fields != 0) {
		auto template_record = find_record_by_form_id(result.template_form_id);
		if (template_record && template_record->type == "LGTM") {
			auto template_lighting = parse_lighting_data(parse_subrecords(read_record_data(*template_record)), "DATA");
			if (template_lighting) apply_lighting_inheritance(result.resolved, *template_lighting, result.inherited_fields);
		}
	}
	return result;
}

std::optional<ScriptData> EsmFile::get_script_data(uint32_t scpt_form_id) const {
	auto record = find_record_by_form_id(scpt_form_id);
	if (!record || record->type != "SCPT") {
		return std::nullopt;
	}
	std::vector<uint8_t> data = read_record_data(*record);
	std::vector<Subrecord> subs = parse_subrecords(data);

	ScriptData script;
	// SLSD/SCVR arrive as real adjacent pairs (confirmed against real data:
	// every SLSD is immediately followed by its own SCVR) -- read the
	// pending SLSD's index and pair it with the next SCVR encountered.
	bool have_pending_slsd = false;
	uint32_t pending_slsd_index = 0;

	for (const auto &s : subs) {
		if (s.type == "EDID") {
			script.editor_id = s.as_string();
		} else if (s.type == "SCHR" && s.size >= 20) {
			util::ByteReader sr(s.data, s.size);
			sr.skip(4); // Unused
			sr.read_u32(); // RefCount -- unused, describes SCDA
			sr.read_u32(); // CompiledSize -- unused, describes SCDA
			sr.read_u32(); // VariableCount -- unused, re-derived from real SLSD/SCVR pairs instead
			script.script_type = sr.read_u16();
			// Flags -- unused, describes SCDA
		} else if (s.type == "SCTX") {
			script.source_text = s.as_string();
		} else if (s.type == "SLSD" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size);
			pending_slsd_index = sr.read_u32();
			have_pending_slsd = true;
		} else if (s.type == "SCVR") {
			ScriptLocalVar var;
			var.name = s.as_string();
			var.index = have_pending_slsd ? pending_slsd_index : 0;
			script.locals.push_back(std::move(var));
			have_pending_slsd = false;
		} else if (s.type == "SCRO" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size);
			script.referenced_form_ids.push_back(sr.read_u32());
		}
	}
	return script;
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

// phases/2/11-exterior-cell-lookup-index.md: navigates directly through
// Bethesda's own Exterior Cell Block/Sub-Block GRUP structure instead of
// scanning every CELL in the worldspace -- confirmed against real
// WastelandNV data (see that task doc for the verified label encoding and
// block/sub-block sizing). Reads only 24-byte GRUP/record headers down one
// branch of the tree, decompressing/subrecord-parsing only the (usually
// very few, at most 64) CELL records actually inside the target sub-block.
//
// The worldspace's own persistent cell (structurally the first CELL under
// World Children, before any Block GRUP) is deliberately never considered
// a candidate here, even though it can carry its own placeholder XCLC —
// confirmed directly against real data: WastelandNV's persistent cell
// (form_id 0x846EA) has an XCLC of (0,0), which coincides with a genuine
// grid tile also at (0,0) (form_id 0xDDF5B, with real terrain). The old
// linear-scan implementation hit the persistent cell first (file order)
// and silently returned it instead of the real tile for every (0,0)
// lookup -- a real correctness bug, not just a performance one, fixed as
// a side effect of this rewrite by construction (the persistent cell was
// never part of the Block/Sub-Block structure to begin with).
std::optional<RecordInfo> EsmFile::find_exterior_cell(uint32_t wrld_form_id, int32_t x, int32_t y) const {
	auto wrld = find_record_by_form_id(wrld_form_id);
	if (!wrld || wrld->type != "WRLD") {
		return std::nullopt;
	}

	// The World Children GRUP is `wrld`'s own immediately-following child
	// GRUP (kHeaderSize is defined at file scope above, reused here).
	long wc_header_start = wrld->data_offset + static_cast<long>(wrld->data_size);
	std::vector<uint8_t> wc_hdr = read_at(wc_header_start, kHeaderSize);
	util::ByteReader wc_hr(wc_hdr.data(), wc_hdr.size());
	std::string wc_tag(reinterpret_cast<const char *>(wc_hr.read_bytes(4).data()), 4);
	if (wc_tag != "GRUP") {
		return std::nullopt; // no exterior cells in this worldspace at all -- real, valid case
	}
	uint32_t wc_size = wc_hr.read_u32();
	wc_hr.read_u32(); // label -- the WRLD's own form_id for group_type 1, already known
	wc_hr.read_u32(); // group_type -- already known to be 1 (World Children)
	long wc_start = wc_header_start + static_cast<long>(kHeaderSize);
	long wc_end = wc_header_start + static_cast<long>(wc_size);

	// Confirmed by direct cross-reference against multiple real blocks
	// (phases/2/11-exterior-cell-lookup-index.md) -- the GRUP label's own
	// (x, y) halves are swapped relative to our own ExteriorCellGrid's (x,
	// y) fields: the label's low-16 half tracks `y`, the high-16 half
	// tracks `x`. Caught directly by real data (block (0,0)'s own cells
	// are all x==y, symmetric, which hid this until a different block was
	// checked) -- not assumed from UESP's own ambiguous "note the reverse
	// order" wording.
	int32_t target_block_x = floor_div(y, kBlockCells);
	int32_t target_block_y = floor_div(x, kBlockCells);
	int32_t target_sub_x = floor_div(y, kSubBlockCells);
	int32_t target_sub_y = floor_div(x, kSubBlockCells);

	// Level 1: the Exterior Cell Block GRUP (group_type 4) matching the
	// target block coordinate. Non-GRUP tokens at this level (the
	// persistent CELL) and non-matching/non-Block GRUPs (the persistent
	// CELL's own type-6 Cell Children GRUP, or a Block for a different
	// coordinate) are skipped by their own declared byte size -- never
	// descended into.
	long pos = wc_start;
	while (pos < wc_end) {
		std::vector<uint8_t> h = read_at(pos, kHeaderSize);
		util::ByteReader r(h.data(), h.size());
		std::string t(reinterpret_cast<const char *>(r.read_bytes(4).data()), 4);
		if (t != "GRUP") {
			uint32_t dsize = r.read_u32();
			pos += static_cast<long>(kHeaderSize) + static_cast<long>(dsize);
			continue;
		}
		uint32_t gsize = r.read_u32();
		uint32_t label = r.read_u32();
		uint32_t gtype = r.read_u32();
		long cstart = pos + static_cast<long>(kHeaderSize);
		long cend = pos + static_cast<long>(gsize);
		if (gtype != 4) {
			pos = cend;
			continue;
		}
		GrupGridCoord block = decode_grup_label(label);
		if (block.x != target_block_x || block.y != target_block_y) {
			pos = cend;
			continue;
		}

		// Level 2: the Exterior Cell Sub-Block GRUP (group_type 5) within
		// this block matching the target sub-block coordinate.
		long p2 = cstart;
		while (p2 < cend) {
			std::vector<uint8_t> h2 = read_at(p2, kHeaderSize);
			util::ByteReader r2(h2.data(), h2.size());
			std::string t2(reinterpret_cast<const char *>(r2.read_bytes(4).data()), 4);
			if (t2 != "GRUP") {
				uint32_t dsize2 = r2.read_u32();
				p2 += static_cast<long>(kHeaderSize) + static_cast<long>(dsize2);
				continue;
			}
			uint32_t gsize2 = r2.read_u32();
			uint32_t label2 = r2.read_u32();
			uint32_t gtype2 = r2.read_u32();
			long c2s = p2 + static_cast<long>(kHeaderSize);
			long c2e = p2 + static_cast<long>(gsize2);
			if (gtype2 != 5) {
				p2 = c2e;
				continue;
			}
			GrupGridCoord sub = decode_grup_label(label2);
			if (sub.x != target_sub_x || sub.y != target_sub_y) {
				p2 = c2e;
				continue;
			}

			// Level 3: scan the (at most 64) CELL records directly in this
			// sub-block for an exact XCLC match. Each CELL's own trailing
			// Cell Children GRUP (its REFRs etc) is skipped whole by its
			// declared size, never descended into.
			long p3 = c2s;
			while (p3 < c2e) {
				std::vector<uint8_t> h3 = read_at(p3, kHeaderSize);
				util::ByteReader r3(h3.data(), h3.size());
				std::string t3(reinterpret_cast<const char *>(r3.read_bytes(4).data()), 4);
				if (t3 == "GRUP") {
					uint32_t gsize3 = r3.read_u32();
					p3 += static_cast<long>(gsize3);
					continue;
				}
				RecordInfo info;
				info.type = t3;
				info.data_size = r3.read_u32();
				info.flags = r3.read_u32();
				info.form_id = r3.read_u32();
				info.data_offset = p3 + static_cast<long>(kHeaderSize);
				if (info.type == "CELL") {
					auto grid = get_exterior_cell_grid(info.form_id);
					if (grid && grid->x == x && grid->y == y) {
						return info;
					}
				}
				p3 = info.data_offset + static_cast<long>(info.data_size);
			}
			return std::nullopt; // sub-block found, no exact match inside it -- a real, valid case
		}
		return std::nullopt; // block found, no matching sub-block -- a real, valid case (sparse worldspace)
	}
	return std::nullopt; // no matching block at all -- a real worldspace-edge case
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

std::optional<uint32_t> EsmFile::get_cell_worldspace(uint32_t cell_form_id) const {
	auto cell = find_record_by_form_id(cell_form_id);
	if (!cell || cell->type != "CELL") {
		return std::nullopt;
	}
	long header_offset = cell->data_offset - static_cast<long>(kHeaderSize);
	uint32_t wrld_form_id = 0;
	find_owner_of(0, file_size_, header_offset, &wrld_form_id);
	if (wrld_form_id == 0) {
		return std::nullopt; // interior cell — no "World Children" ancestor
	}
	return wrld_form_id;
}

std::optional<RecordInfo> EsmFile::get_worldspace_persistent_cell(uint32_t wrld_form_id) const {
	auto wrld = find_record_by_form_id(wrld_form_id);
	if (!wrld || wrld->type != "WRLD") {
		return std::nullopt;
	}
	for (const RecordInfo &c : get_child_records(*wrld)) {
		if (c.type == "CELL") {
			return c; // the first CELL child — see this method's own header comment
		}
	}
	return std::nullopt;
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
		} else if (s.type == "ATXT" && s.size >= 8) {
			// fopdoc ATXT: FormID texture(4) + quadrant(1) + unused(1) + layer int16(2).
			util::ByteReader sr(s.data, s.size);
			LandAlphaLayer layer;
			layer.ltex_form_id = sr.read_u32();
			layer.quadrant = sr.read_u8();
			sr.read_u8(); // unused
			layer.layer_index = static_cast<int16_t>(sr.read_u16());
			layer.opacity.assign(kLandQuadrantVertCount, 0.0f);
			out.alpha_layers.push_back(std::move(layer));
		} else if (s.type == "VTXT" && !out.alpha_layers.empty()) {
			// fopdoc VTXT: array of {position uint16(2), unused byte[2], opacity float32(4)}
			// = 8 bytes/entry, sparse (only nonzero-opacity vertices present).
			// Always immediately follows its own ATXT per fopdoc's LAND field
			// order, so it fills in the layer just pushed above.
			LandAlphaLayer &layer = out.alpha_layers.back();
			util::ByteReader sr(s.data, s.size);
			size_t entry_count = s.size / 8;
			for (size_t i = 0; i < entry_count; ++i) {
				uint16_t position = sr.read_u16();
				sr.read_u8();
				sr.read_u8(); // unused
				float opacity = read_f32(sr);
				if (position < kLandQuadrantVertCount) {
					layer.opacity[position] = opacity;
				}
			}
		} else if (s.type == "VCLR" && s.size >= static_cast<size_t>(kLandGridSize) * kLandGridSize * 3) {
			out.vertex_colors.assign(s.data, s.data + static_cast<size_t>(kLandGridSize) * kLandGridSize * 3);
		} else if (s.type == "VNML" && s.size >= static_cast<size_t>(kLandGridSize) * kLandGridSize * 3) {
			out.vertex_normals_raw.assign(s.data, s.data + static_cast<size_t>(kLandGridSize) * kLandGridSize * 3);
		}
	}
	if (!have_vhgt) {
		return std::nullopt;
	}
	return out;
}

namespace {
// Shared by resolve_ltex_texture_path()/resolve_ltex_normal_texture_path():
// LTEX -> TNAM -> TXST -> the requested texture-slot subrecord (TX00 diffuse,
// TX01 normal, ...). Returns "" if any step doesn't resolve.
std::string resolve_ltex_txst_slot(const EsmFile &f, uint32_t ltex_form_id, const char *txst_slot) {
	auto ltex = f.find_record_by_form_id(ltex_form_id);
	if (!ltex || ltex->type != "LTEX") {
		return "";
	}
	std::vector<uint8_t> ltex_data = f.read_record_data(*ltex);
	std::vector<Subrecord> ltex_subs = EsmFile::parse_subrecords(ltex_data);
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

	auto txst = f.find_record_by_form_id(txst_id);
	if (!txst || txst->type != "TXST") {
		return "";
	}
	std::vector<uint8_t> txst_data = f.read_record_data(*txst);
	std::vector<Subrecord> txst_subs = EsmFile::parse_subrecords(txst_data);
	for (const auto &s : txst_subs) {
		if (s.type == txst_slot) {
			return s.as_string();
		}
	}
	return "";
}
} // namespace

std::string EsmFile::resolve_ltex_texture_path(uint32_t ltex_form_id) const {
	return resolve_ltex_txst_slot(*this, ltex_form_id, "TX00");
}

std::string EsmFile::resolve_ltex_normal_texture_path(uint32_t ltex_form_id) const {
	return resolve_ltex_txst_slot(*this, ltex_form_id, "TX01");
}

std::string EsmFile::resolve_soun_filename(uint32_t soun_form_id) const {
	if (soun_form_id == 0) {
		return "";
	}
	auto soun = find_record_by_form_id(soun_form_id);
	if (!soun || soun->type != "SOUN") {
		return "";
	}
	std::vector<uint8_t> data = read_record_data(*soun);
	std::vector<Subrecord> subs = parse_subrecords(data);
	for (const auto &s : subs) {
		if (s.type == "FNAM") {
			return s.as_string();
		}
	}
	return "";
}

std::optional<DoorData> EsmFile::get_door_data(uint32_t door_form_id) const {
	auto record = find_record_by_form_id(door_form_id);
	if (!record || record->type != "DOOR") {
		return std::nullopt;
	}
	std::vector<uint8_t> data = read_record_data(*record);
	std::vector<Subrecord> subs = parse_subrecords(data);

	uint32_t snam = 0, anam = 0, bnam = 0;
	DoorData door;
	for (const auto &s : subs) {
		if (s.type == "SNAM" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size);
			snam = sr.read_u32();
		} else if (s.type == "ANAM" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size);
			anam = sr.read_u32();
		} else if (s.type == "BNAM" && s.size >= 4) {
			util::ByteReader sr(s.data, s.size);
			bnam = sr.read_u32();
		} else if (s.type == "FNAM" && s.size >= 1) {
			door.flags = s.data[0];
		}
	}
	door.open_sound_path = resolve_soun_filename(snam);
	door.close_sound_path = resolve_soun_filename(anam);
	door.loop_sound_path = resolve_soun_filename(bnam);
	return door;
}

std::vector<std::string> EsmFile::get_all_item_candidates() const {
	if (item_candidates_cached_) {
		return item_candidates_cache_;
	}
	std::vector<std::string> out;
	std::unordered_set<std::string> seen;

	for_each_record([&](const RecordInfo &r) {
		if (r.type == "WEAP" || r.type == "ARMO" || r.type == "AMMO" ||
		    r.type == "ALCH" || r.type == "MISC" || r.type == "KEYM" || r.type == "BOOK") {
			char hex_buf[16];
			std::snprintf(hex_buf, sizeof(hex_buf), "0x%08X", r.form_id);
			std::string hex_str(hex_buf);
			if (seen.insert(hex_str).second) {
				out.push_back(hex_str);
			}

			std::vector<uint8_t> data = read_record_data(r);
			for (const auto &s : parse_subrecords(data)) {
				if (s.type == "EDID") {
					std::string edid = s.as_string();
					if (!edid.empty() && seen.insert(edid).second) {
						out.push_back(edid);
					}
				} else if (s.type == "FULL") {
					std::string full = s.as_string();
					if (!full.empty() && seen.insert(full).second) {
						out.push_back(full);
					}
				}
			}
		}
	});

	item_candidates_cache_ = out;
	item_candidates_cached_ = true;
	return item_candidates_cache_;
}

std::vector<std::string> EsmFile::get_all_cell_candidates() const {
	if (cell_candidates_cached_) {
		return cell_candidates_cache_;
	}
	std::vector<std::string> out;
	std::unordered_set<std::string> seen;

	for_each_record([&](const RecordInfo &r) {
		if (r.type == "CELL") {
			std::vector<uint8_t> data = read_record_data(r);
			for (const auto &s : parse_subrecords(data)) {
				if (s.type == "EDID") {
					std::string edid = s.as_string();
					if (!edid.empty() && seen.insert(edid).second) {
						out.push_back(edid);
					}
					break;
				}
			}
		}
	});

	cell_candidates_cache_ = out;
	cell_candidates_cached_ = true;
	return cell_candidates_cache_;
}

} // namespace esm
