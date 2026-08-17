#ifndef ESM_TYPES_H
#define ESM_TYPES_H

#include <cstdint>
#include <string>
#include <vector>

namespace esm {

// Record/GRUP header flag & layout constants shared by all TES4-family
// plugin files (Oblivion/FO3/FNV/Skyrim use the same 24-byte headers).

// Record flags (Record::flags), bit for "this record's data is zlib
// compressed, prefixed with a 4-byte little-endian uncompressed size".
constexpr uint32_t kRecordFlagCompressed = 0x00040000;

// Subrecord size field is 16-bit; a size of 0xFFFF means the real size is
// carried in a preceding 4-byte "XXXX" subrecord instead (for subrecords
// larger than 65535 bytes, e.g. some big VMAD/large model lists).
constexpr uint16_t kSubrecordOversizeMarker = 0xFFFF;

// A record as seen while walking the file: header fields plus where its
// (possibly still-compressed) data lives, without having read the data yet.
struct RecordInfo {
	std::string type; // 4-char tag, e.g. "STAT", "TES4"
	uint32_t data_size = 0; // size of the data blob that follows the header
	uint32_t flags = 0;
	uint32_t form_id = 0;
	long data_offset = 0; // absolute file offset of the data blob

	bool is_compressed() const { return (flags & kRecordFlagCompressed) != 0; }
};

// A subrecord within a record's (decompressed) data: a 4-char tag plus a
// view into the record data buffer it was parsed from.
struct Subrecord {
	std::string type;
	const uint8_t *data = nullptr;
	size_t size = 0;

	// Many Bethesda string subrecords (EDID, MODL, FULL, ICON, ...) are
	// null-terminated *within* their declared size — i.e. size includes the
	// trailing '\0' — rather than the size being the string's logical
	// length. Found via 0.5's integration tool: resolving a MODL path
	// against the BSA index failed 100% of the time because the untrimmed
	// trailing '\0' made every lookup miss, even though the string
	// "looked" correct when printed (terminals render an embedded null as
	// blank) or passed through a C-string API (which silently truncates at
	// the first '\0' — the exact byte this trims). Strip it if present so
	// callers get the same content whether they compare byte-for-byte or
	// via a C-string API.
	std::string as_string() const {
		size_t len = size;
		if (len > 0 && data[len - 1] == '\0') {
			--len;
		}
		return std::string(reinterpret_cast<const char *>(data), len);
	}
};

// Parsed TES4 file header (the very first record in any master/plugin).
struct FileHeader {
	float version = 0.0f;
	uint32_t num_records = 0; // NUMR field: total record count in the file (excludes TES4 itself, per format convention)
	uint32_t next_object_id = 0;
	std::vector<std::string> masters; // MAST subrecord values, in load order
};

// One REFR resolved to its placement transform plus its base record's identity.
// Deliberately generic across every base record type (not just STAT) — filtering
// to a specific type set is the caller's job (see phases/1/00-interior-cell-loader.md,
// which only wants STAT for now, and phases/1/01-object-type-registry.md, which
// reuses this unchanged for the broader type set).
struct ReferencePlacement {
	uint32_t refr_form_id = 0;
	uint32_t base_form_id = 0;
	std::string base_type; // 4-char tag of the NAME-referenced record, e.g. "STAT"
	std::string base_editor_id; // base record's EDID, if present
	std::string model_path; // base record's MODL, relative to Data/Meshes/ (no "meshes\" prefix); empty if none
	float position[3] = { 0.0f, 0.0f, 0.0f };
	float rotation[3] = { 0.0f, 0.0f, 0.0f };
	float scale = 1.0f;
};

// LIGH's DATA subrecord — confirmed layout (phases/1/03-light-sources.md):
// Time(int32), Radius(uint32), Color(rgba), Flags(uint32), Falloff
// Exponent(float32), FOV(float32), Value(uint32), Weight(float32). Time/
// Value/Weight aren't needed for rendering and are dropped here.
constexpr uint32_t kLightFlagSpot = 0x00000200; // unset = point/omni light
constexpr uint32_t kLightFlagOffByDefault = 0x00000020;

struct LightData {
	float radius = 0.0f; // Gamebryo units -> meters already applied (units.h)
	uint8_t color[4] = { 255, 255, 255, 255 }; // r, g, b, a (a usually unused)
	uint32_t flags = 0;
	float falloff = 1.0f;
	float fov_degrees = 90.0f;

	bool is_spot() const { return (flags & kLightFlagSpot) != 0; }
	bool off_by_default() const { return (flags & kLightFlagOffByDefault) != 0; }
};

// LAND's heightmap + per-quadrant base ground texture (phases/1/04-exterior-cell-terrain.md).
// VHGT: one float32 offset + a 33x33 row-major grid of int8 deltas, each
// unit = 8 Gamebryo units (per GECK wiki) — NOT pre-converted to meters
// here, since the caller needs the raw grid shape for triangulation before
// scaling. BTXT gives each of the 4 quadrants' base LTEX FormID (0 if a
// quadrant has none, which shouldn't happen in practice but isn't assumed).
//
// Scope note: ATXT/VTXT (additional per-vertex-blended texture layers on
// top of the base) are NOT parsed — this task only resolves each
// quadrant's single base texture, not full multi-layer alpha blending. A
// real, sourced format detail (BTXT/ATXT/VTXT all confirmed present and
// counted in real Goodsprings terrain data), just deliberately not fully
// consumed yet. See phases/1/04-exterior-cell-terrain.md for the reasoning.
constexpr int kLandGridSize = 33; // per axis; 33*33 = 1089 vertices total
constexpr int kLandQuadrantCount = 4; // fopdoc order: 0=BL, 1=BR, 2=TL, 3=TR

struct LandData {
	// Decoded, accumulated, and scaled to meters already (units.h) — NOT
	// the raw offset+delta encoding. VHGT stores a float offset plus a
	// 33x33 grid of int8 deltas, both in the same *8-Gamebryo-units scale;
	// decoding is a 2D cumulative scheme (the leftmost column of each row
	// accumulates downward from the row above, then each row accumulates
	// rightward from its own column-0 value). Decode order is still only
	// best-available-confidence (consistent secondary-source description,
	// no reference-tool byte verification available in this environment),
	// but the offset's *8 scale (initially missed — offset was applied
	// unscaled) IS numerically verified: decoded terrain height compared
	// against real REFR.DATA Z values resting on it in the same cell,
	// closing a consistent ~100m gap to well under a meter. See
	// phases/1/04-exterior-cell-terrain.md and esm_file.cpp's
	// get_land_data().
	std::vector<float> heights; // size kLandGridSize*kLandGridSize, row-major, meters
	uint32_t quadrant_base_ltex[kLandQuadrantCount] = { 0, 0, 0, 0 };
};

} // namespace esm

#endif // ESM_TYPES_H
