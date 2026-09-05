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

// REFR record flag ("Visible When Distant" in the CK) -- confirmed against
// real WastelandNV data, not just modding-community documentation
// (phases/2/12-distant-object-lod.md / enginedocs/lod.md): some real
// placements (Barracks01/02) have this bit set, others whose base model
// has an equally real _lod.nif companion (NVNellisQuonsetHut01/02,
// CraneStatic01) do not -- the actual per-placement gate for whether the
// game renders a distant-LOD variant of it at all, independent of whether
// one happens to exist on disk.
constexpr uint32_t kRecordFlagVisibleWhenDistant = 0x00008000;

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

	// phases/5/00-script-interpreter-foundation.md: base record's own SCRI
	// subrecord (the attached SCPT's FormID), 0 if the base record has
	// none -- confirmed real and common via a real-data census (e.g. 992 of
	// 1143 real ACTI records carry one). Only read for get_cell_references()
	// (interactive/Dynamic placements); get_scol_parts() leaves this 0 --
	// SCOL parts are always STAT, which can never carry a script.
	uint32_t script_form_id = 0;

	// REFR.XEMI (Emittance): an authored colour source for visual effects.
	// It points to either LIGH or REGN; it is deliberately a reference-level
	// field, not a property of the shared STAT base record.
	uint32_t emittance_form_id = 0;

	float position[3] = { 0.0f, 0.0f, 0.0f };
	float rotation[3] = { 0.0f, 0.0f, 0.0f };
	float scale = 1.0f;

	// phases/2/12-distant-object-lod.md: this REFR's own "Visible When
	// Distant" flag (kRecordFlagVisibleWhenDistant), decoded here rather
	// than exposing the raw flags word -- this is the only bit any current
	// caller needs, and a decoded bool matches this struct's own existing
	// style (has_xtel below) better than a raw bitmask would.
	bool visible_when_distant = false;

	// XTEL, present on teleporting doors (phases/2/07-runtime-cell-loader.md).
	// Confirmed against real data: 32 bytes — dest REFR FormID (4), dest
	// position (12, Gamebryo units, same as DATA's own position), dest
	// rotation (12, radians), flags (4, currently unused/unread). A door
	// that just swings open (no teleport) has no XTEL — has_xtel=false is a
	// real, valid case, not an error.
	bool has_xtel = false;
	uint32_t dest_refr_form_id = 0;
	float dest_position[3] = { 0.0f, 0.0f, 0.0f };
	float dest_rotation[3] = { 0.0f, 0.0f, 0.0f };

	// NPC_-only: RNAM (race FormID) and ACBS flags bit 0 (female) -- only
	// populated by EsmFile::get_cell_actors() when base_type == "NPC_"
	// (issue #52 chunk 5, see the "ESM humanoid assembly structure" finding
	// from chunk 2); 0/false otherwise. CREA also has a subrecord literally
	// tagged RNAM, but it means something unrelated there (impact data
	// set) -- deliberately not reused for CREA to avoid misreading it.
	uint32_t race_form_id = 0;
	bool is_female = false;

	// WHAT THIS IS: REFR.XSRF and REFR.XSRD are both undocumented even in
	// the community's own xEdit/fopdoc reference (confirmed:
	// FalloutNV/Records/REFR.md lists both with unknown name/type/purpose).
	// We do NOT know their real meaning or byte-level layout. This field is
	// only true when the subrecord tag "XSRF" or "XSRD" is present on the
	// REFR at all -- nothing about their payload bytes is read or decoded
	// anywhere in this codebase. Deliberately named after that raw,
	// confirmed fact (presence of these tags), not after an interpretation
	// of it -- see issue #58 for why that distinction matters here.
	//
	// WHAT WE INFER FROM IT (issue #56, empirical correlation only, not a
	// documented spec): presence is a 100%-consistent marker for a class of
	// placement Bethesda used for distant Strip/McCarran skyline dressing --
	// confirmed against a real 4468-ref WastelandNV persistent-cell census,
	// every single "*Imposter*"-named model (215/215) carries XSRF and/or
	// XSRD, zero without it, and the only OTHER refs that carry it are the
	// exact same conceptual category under a different naming scheme
	// (distant-view glow/light-pollution dressing: UltraLuxDome_GlowsWL*,
	// Lucky38Lights*, NVStripLightPollution*, NV_TheTops-Hotel_NeonWL*,
	// GomorrahLights*, ...). These are placed at essentially the SAME
	// coordinates as their real, separately-placed high-detail counterparts,
	// are never VWD-flagged, and have no fade mechanism of their own via
	// the ordinary per-object _lod.nif/VWD pairing -- this is what stayed
	// visible up close no matter how the ordinary LOD0/LOD1 crossover was
	// tuned. The actual near-fade distance applied stays
	// GodotBryoSettings-configured, not decoded from XSRF/XSRD's own bytes.
	bool has_xsrf_or_xsrd = false;
};

// phases/2/07-runtime-cell-loader.md: an exterior CELL's own XCLC grid
// coordinate, read directly from the CELL's FormID (the reverse direction
// from find_exterior_cell(), which goes coordinate -> CELL). Needed so a
// loader given only a cell_form_id (not a known grid range, unlike
// exterior_viewer.gd which iterates a caller-specified range) can still
// position that cell's terrain correctly.
struct ExteriorCellGrid {
	int32_t x = 0;
	int32_t y = 0;
};

// phases/2/07-runtime-cell-loader.md: a door REFR's resolved teleport
// destination — the CELL it leads to (not just the destination REFR's
// FormID) plus the landing transform.
struct DoorDestination {
	uint32_t dest_cell_form_id = 0;
	float dest_position[3] = { 0.0f, 0.0f, 0.0f };
	float dest_rotation[3] = { 0.0f, 0.0f, 0.0f };
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

// Shared basic item fields. MISC.DATA is verified as Value(i32), Weight(f32);
// callers must not assume other item record types use the same DATA layout.
struct ItemData {
	std::string full_name;
	int32_t value = 0;
	float weight = 0.0f;
	std::string inventory_icon;
	std::string message_icon;
};

// GRAS.DATA, verified against all 24 real FalloutNV.esm records and the
// GECK/NVSE trait table.  The record has deliberately retained its compact
// byte fields rather than treating its 32-byte DATA payload as eight floats.
// The unused/padding bytes are not exposed here.
struct GrassData {
	std::string editor_id;
	std::string model_path; // MODL, relative to Data/Meshes/
	uint8_t density = 0;
	uint8_t min_slope = 0;
	uint8_t max_slope = 0;
	uint16_t units_from_water_amount = 0;
	uint32_t units_from_water_type = 0;
	float position_range = 0.0f;
	float height_range = 0.0f;
	float color_range = 0.0f;
	float wave_period = 0.0f;
	uint8_t flags = 0;
};

// TERM's authored menu is an ordered, interleaved subrecord stream rather
// than a separate child record table.  Keep the FormID links and the limited
// condition/script evidence needed by the first browsable-terminal pass;
// evaluating conditions or menu scripts is deliberately a later layer.
struct TerminalMenuItem {
	std::string text; // ITXT
	std::string result_text; // RNAM when it is authored text (empty is valid)
	uint32_t note_form_id = 0; // INAM
	uint32_t submenu_form_id = 0; // TNAM
	uint8_t flags = 0; // ANAM, raw until its bits are verified
	uint32_t condition_count = 0; // CTDA occurrences attached to this item
	std::string script_source; // SCTX, if this item carries an inline script
};

struct TerminalData {
	std::string editor_id; // EDID
	std::string full_name; // FULL
	std::string model_path; // MODL
	std::string welcome_text; // DESC
	uint32_t flags = 0; // DNAM, raw until verified
	std::vector<TerminalMenuItem> items;
};

// NOTE records linked by TERM.INAM.  The placed terminal fixture establishes
// that NOTE.TNAM is the displayed body text; keep the record identity too so
// terminals follow the authored FormID link rather than inferring a note from
// its menu label.
struct NoteData {
	std::string editor_id; // EDID
	std::string full_name; // FULL, optional on the surveyed notes
	std::string text; // TNAM
};

// CELL.XCLL and LGTM.DATA ("Lighting") -- confirmed against the shipped
// GSDocMitchellHouse CELL and its LTMP LGTM: both use this 40-byte layout.
// bytes -- Ambient Color(rgba), Directional Color(rgba), Fog Color(rgba),
// Fog Near(f32), Fog Far(f32), Directional Rotation XY(i32), Directional
// Rotation Z(i32), Directional Fade(f32), Fog Clip Distance(f32), Fog
// Power(f32). Only interior CELLs carry XCLL in practice (exterior cells
// inherit worldspace-level lighting); std::nullopt is the real, common case
// for exterior/unlit cells, not an error. Directional Color/rotation/fade
// and fog fields are read but not currently consumed by the GDScript side
// (ambient is the only piece wired into interior_environment.tres so far).
struct CellLightingData {
	uint8_t ambient_color[4] = { 0, 0, 0, 0 };
	uint8_t directional_color[4] = { 0, 0, 0, 0 };
	uint8_t fog_color[4] = { 0, 0, 0, 0 };
	float fog_near = 0.0f;
	float fog_far = 0.0f;
	int32_t directional_rotation_xy = 0;
	int32_t directional_rotation_z = 0;
	float directional_fade = 0.0f;
	float fog_clip_distance = 0.0f;
	float fog_power = 0.0f;
};

// CELL may inherit individual lighting fields from an LGTM through LTMP and
// LNAM. Keep both the resolved values used by the renderer and the cell's
// literal XCLL for diagnostics; replacing the entire block would be wrong
// because LNAM is explicitly field-granular.
struct ResolvedCellLightingData {
	CellLightingData resolved;
	CellLightingData cell_authored;
	uint32_t template_form_id = 0;
	uint32_t inherited_fields = 0;
};

// DOOR.FNAM (real values confirmed via fopdoc's DOOR page): a uint8, one
// unnamed/unconfirmed bit (0x01) plus these four. NOT the same set as the
// GECK Wiki's DOOR dialog checkboxes -- "Quest Item" and "Random Anim
// Start" are shown there too, but aren't in FNAM at all (almost certainly
// generic record-header flags shared across many record types, not
// DOOR-specific -- unconfirmed bit position, deliberately not guessed;
// see DoorData's own doc comment).
constexpr uint32_t kDoorFlagAutomaticDoor = 0x02;
constexpr uint32_t kDoorFlagHidden = 0x04;
constexpr uint32_t kDoorFlagMinimalUse = 0x08;
constexpr uint32_t kDoorFlagSlidingDoor = 0x10;

// phases/3/00-door-completion.md Part B: DOOR.SNAM/ANAM/BNAM (Open/Close/
// Loop sound, each a SOUN FormID -- confirmed via fopdoc's DOOR page) and
// FNAM (flags). Sound paths are already resolved through SOUN.FNAM (see
// EsmFile::resolve_soun_filename(), a general-purpose lookup, not DOOR-
// specific) to a real Sound/-relative path, or "" if that DOOR record
// doesn't set that particular sound -- a real, common, valid case per
// GECK Wiki's own DOOR page: animated doors typically carry their
// open/close sound baked into the NIF itself via NiTextKeyExtraData
// instead of these ESM fields ("only put Open/Close sounds on a baseform
// that is static... this is a common reason for the double sound bug in
// the vanilla game") -- NOT extracted here (NiTextKeyExtraData parsing is
// unscoped native work), a real, deliberate gap, not a bug, when an
// animated door plays no sound through this path.
struct DoorData {
	std::string open_sound_path;
	std::string close_sound_path;
	std::string loop_sound_path;
	uint32_t flags = 0;

	bool is_automatic_door() const { return (flags & kDoorFlagAutomaticDoor) != 0; }
	bool is_hidden() const { return (flags & kDoorFlagHidden) != 0; }
	bool is_minimal_use() const { return (flags & kDoorFlagMinimalUse) != 0; }
	bool is_sliding_door() const { return (flags & kDoorFlagSlidingDoor) != 0; }
};

// LAND's heightmap + per-quadrant base ground texture (phases/1/04-exterior-cell-terrain.md).
// VHGT: one float32 offset + a 33x33 row-major grid of int8 deltas, each
// unit = 8 Gamebryo units (per GECK wiki) — NOT pre-converted to meters
// here, since the caller needs the raw grid shape for triangulation before
// scaling. BTXT gives each of the 4 quadrants' base LTEX FormID (0 if a
// quadrant has none, which shouldn't happen in practice but isn't assumed).
//
// ATXT/VTXT (additional per-vertex-blended texture layers on top of the
// base) ARE now parsed — see LandAlphaLayer below and
// phases/2/13-terrain3d-integration.md's real-data census (real worst case:
// 6 additional layers stacked in a single quadrant, 85% of quadrants have
// none at all). Phase 1's GamebryoTerrainBuilder still only consumes BTXT
// (a real, acknowledged scope cut documented in
// phases/1/04-exterior-cell-terrain.md, unchanged by this) — this data is
// for the Terrain3D control-map painting path instead.
constexpr int kLandGridSize = 33; // per axis; 33*33 = 1089 vertices total
constexpr int kLandQuadrantCount = 4; // fopdoc order: 0=BL, 1=BR, 2=TL, 3=TR
constexpr int kLandQuadrantVertsPerSide = 17; // (kLandGridSize+1)/2
constexpr int kLandQuadrantVertCount = kLandQuadrantVertsPerSide * kLandQuadrantVertsPerSide; // 289

// One ATXT+VTXT pair: an additional ground texture layer painted on top of a
// quadrant's BTXT base, with per-vertex opacity over that quadrant's own
// 17x17 sub-grid. VTXT's own "Position" field is a sparse index into that
// 17x17 grid (only vertices with nonzero opacity are present in the file) —
// decoded here as row-major (position = row*17 + col), matching this
// codebase's own convention for the main heightmap grid; this specific
// indexing order is best-available-confidence (consistent with fopdoc's
// field description, not independently byte-verified against a reference
// tool in this environment — same caveat LandData::heights below already
// carries for VHGT's decode order).
struct LandAlphaLayer {
	uint32_t ltex_form_id = 0;
	uint8_t quadrant = 0; // fopdoc order: 0=BL, 1=BR, 2=TL, 3=TR
	int16_t layer_index = 0; // ATXT's own stacking-order field, as authored
	std::vector<float> opacity; // size kLandQuadrantVertCount, row-major, 0 where unpainted
};

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
	std::vector<LandAlphaLayer> alpha_layers; // ATXT/VTXT-derived, empty if the cell has none

	// VCLR: real per-vertex color, raw RGB bytes as stored (no decode needed --
	// already plain 0-255 unsigned per channel). Size kLandGridSize*kLandGridSize*3,
	// row-major, empty if the cell has none (phases/2/13's own census: only 29,681
	// of 42,474 real LAND records have it).
	std::vector<uint8_t> vertex_colors;

	// VNML: real per-vertex authored normal, raw bytes as stored (NOT yet decoded --
	// decode is signed-byte, Bethesda's own (X,Z,Y) file axis order, verified
	// numerically against 128,000 real samples in phases/2/14's own research:
	//   component = int8_t(byte) / 127.0
	//   world = (component[0], component[2], -component[1])
	// Left raw here rather than pre-decoded so callers can choose their own world
	// convention without baking an assumption into this shared parser -- same
	// reasoning as heights being pre-decoded (a single, unambiguous scale) vs this
	// being a caller-specific axis remap. Size kLandGridSize*kLandGridSize*3,
	// row-major, empty if the cell has none.
	std::vector<uint8_t> vertex_normals_raw;
};

// phases/5/00-script-interpreter-foundation.md: a SCPT record's real data.
// enginedocs/nv_script_interpreter_design.md's central finding (verified
// against a full scan of all 11,483 real SCPT records in FalloutNV.esm):
// SCTX (the original, human-readable GECK source text) is present and
// complete on every single one -- this project parses/interprets SCTX
// directly and never decodes SCDA (the compiled bytecode), a deliberate
// choice, not a gap.
//
// SCHR layout confirmed via fopdoc's SCHR page, cross-checked against real
// bytes (VMS18CompanionFreezerExitSCRIPT's own SCHR/SCDA: compiled_size
// field reads 0x9c/156, which matches that same record's real SCDA
// subrecord size exactly): Unused(4), RefCount(u32), CompiledSize(u32),
// VariableCount(u32), Type(u16), Flags(u16) -- 20 bytes. Only `script_type`
// (Type) is kept; RefCount/CompiledSize/VariableCount/Flags describe the
// SCDA bytecode this project deliberately never touches.
//
// script_type real values: 0 = Object (confirmed directly against real
// data -- every sampled OnTriggerEnter/OnActivate-style script reads 0).
// Quest/Effect's real values aren't yet confirmed against data since this
// milestone only exercises Object scripts -- left as the raw uint16 rather
// than guessed, decode the rest when Quest/Effect scripts are actually
// needed.
struct ScriptLocalVar {
	std::string name; // SCVR
	uint32_t index = 0; // SLSD's own Index field -- this local's slot number
};

struct ScriptData {
	std::string editor_id;
	std::string source_text; // SCTX, verbatim
	uint16_t script_type = 0; // SCHR's Type field; 0 = Object, confirmed
	std::vector<ScriptLocalVar> locals; // SLSD+SCVR pairs, in file order

	// SCRO: FormIDs the compiler already resolved for every named
	// reference/quest/global the script text mentions -- Bethesda's own
	// pre-resolved symbol table (nv_script_interpreter_design.md's
	// "load-bearing finding"), real and present, but SCRV (which of these
	// maps to which local `ref` slot) is a real, deliberate gap: real data
	// shows SCRV's own count doesn't always match SCRO's 1:1 (one real
	// sample carried a single SCRV against eight SCRO entries), so the
	// exact pairing rule isn't confirmed and isn't guessed here. The
	// interpreter falls back to resolving identifiers against a live
	// editor-ID lookup instead (this project already has that machinery --
	// find_cell_by_editor_id() and friends), same as
	// nv_script_interpreter_design.md's own pipeline note allows for names
	// "the compiler's own table didn't cover."
	std::vector<uint32_t> referenced_form_ids; // SCRO, in file order
};

// day-night / weather types ---------------------------------------------------
// Verified against real FalloutNV.esm via tools/time_weather_survey.cpp and
// tools/wthr_detail_dump.cpp / tools/nam0_dump.cpp.

// GLOB record: global variable (e.g. GameHour, GameDay, TimeScale).
struct GlobalVariableData {
	uint32_t form_id = 0;
	std::string editor_id;
	char type = 'f'; // 's' (short), 'f' (float), 'l' (long)
	float value = 0.0f;
};

// One entry in a CLMT's WLST (weighted weather list).
// 12 bytes per entry: uint32 weather_form_id, uint32 chance, uint32 global_form_id.
struct WeatherChance {
	uint32_t weather_form_id = 0;
	uint32_t chance = 0; // 0‒100
	uint32_t global_form_id = 0;
};

// Parsed CLMT (Climate) record.
// TNAM encodes sunrise/sunset boundaries as 10-minute units (value×10 = minutes
// from midnight), confirmed against real NVDefaultClimate TNAM bytes: 0x24=36
// → 36×10 = 360 min = 6 h (sunrise begin), 0x30=48 → 480 = 8 h (sunrise end),
// 0x6c=108 → 1080 = 18 h (sunset begin), 0x78=120 → 1200 = 20 h (sunset end).
struct ClimateData {
	uint32_t form_id = 0;
	std::string editor_id;
	std::string sun_texture_path;       // FNAM — e.g. "Sky\Sun.dds"
	std::string sun_glare_texture_path; // GNAM — e.g. "sky\NV_sunglare.dds"
	std::string night_sky_model_path;   // MODL — e.g. "Sky\Stars.nif"
	// Sunrise/sunset hours decoded from TNAM bytes×10÷60:
	float sunrise_begin = 6.0f;  // hours [0, 24)
	float sunrise_end   = 8.0f;
	float sunset_begin  = 18.0f;
	float sunset_end    = 20.0f;
	uint8_t volatility = 0;        // TNAM byte 4 — weather-change frequency
	uint8_t moon_phase_length = 0; // TNAM byte 5
	std::vector<WeatherChance> weather_chances; // WLST
};

// NAM0 colour table layout (240 bytes = 10 colour types × 6 time-of-day slots
// × 4 bytes RGBA). The six slots are Sunrise, Day, Sunset, Night, plus two
// transition slots (indices 4 and 5). Index mapping from Creation Kit docs:
//   0 SkyUpper  1 Fog  2 CloudsLower  3 CloudsUpper  4 SkyLower  5 Horizon
//   6 Sun       7 SunLight  8 Stars/Ambient  9 SkyStatics
//
// Each colour is stored RGBA (one byte per channel, A always 0 in real data).
constexpr int kWthrColorTypes = 10;
constexpr int kWthrColorTimes = 6;  // Sunrise=0 Day=1 Sunset=2 Night=3 +2

struct WeatherColor {
	uint8_t r = 0, g = 0, b = 0, a = 0;
};

// Fog parameters from FNAM (6 floats, 24 bytes):
// DayNear, DayFar, NightNear, NightFar, DayPower, NightPower.
struct WeatherFogParams {
	float day_near   = 1000.0f;
	float day_far    = 250000.0f;
	float night_near = 1000.0f;
	float night_far  = 200000.0f;
	float day_power  = 0.4f;
	float night_power = 0.4f;
};

// Parsed WTHR (Weather) record.
// DATA (15 bytes): wind_speed, cloud_speed_lower, cloud_speed_upper,
//   trans_delta (transition speed), sun_glare, sun_damage,
//   precipitation_begin, precipitation_end, thunder_lightning_begin,
//   thunder_lightning_end, thunder_lightning_freq, classification,
//   red_lightning_pct, small_precipitation_pct, unknown.
struct WeatherData {
	uint32_t form_id = 0;
	std::string editor_id;
	// Cloud/sky texture paths (DNAM=upper, CNAM=horizon, ANAM=lower1, BNAM=lower2)
	std::string cloud_texture_upper;   // DNAM
	std::string cloud_texture_horizon; // CNAM
	std::string cloud_texture_lower1;  // ANAM
	std::string cloud_texture_lower2;  // BNAM
	// Color table: [type][time]
	WeatherColor colors[kWthrColorTypes][kWthrColorTimes] = {};
	WeatherFogParams fog;
	// DATA fields
	uint8_t wind_speed = 0;
	uint8_t cloud_speed_lower = 0;
	uint8_t cloud_speed_upper = 0;
	uint8_t classification = 0; // 0=None 1=Precipitous 2=Snow
	uint8_t flags = 0;          // DATA[11]
};

// Issue #52 chunk 5: a RACE record's per-gender body part MODLs, resolved
// by EsmFile::get_race_body_parts() -- see that function's own doc comment
// for the real, confirmed marker-delimited layout this parses (NAM0/NAM1
// open a Head/Body block, MNAM/FNAM switch gender within whichever block is
// currently open). One entry per real INDX+MODL pair found; INDX values
// with no MODL (e.g. Ears, which only ever carries an ICON in real data) or
// a non-.nif MODL (e.g. the ".egt" texture-only entry at the end of the
// body block) are skipped -- only real mesh parts are kept.
struct RaceBodyPart {
	uint32_t index = 0; // the RACE record's own INDX value (0=UpperBody, 1=LeftHand, 2=RightHand for the body block)
	std::string model_path;
	std::string icon_path;
};

} // namespace esm

#endif // ESM_TYPES_H
