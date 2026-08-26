#ifndef ESM_FILE_H
#define ESM_FILE_H

#include "esm_types.h"

#include <array>
#include <cstdio>
#include <functional>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace esm {

// Read-only structural reader for Bethesda TES4-family plugin/master files
// (.esm/.esp) — Oblivion/FO3/FNV/Skyrim all share the same 24-byte
// GRUP/record header layout. Not thread-safe (single FILE* with seek+read).
//
// This does NOT decode subrecord semantics for most record types — see
// phases/0/02-esm-parser.md. It walks the GRUP/record tree, exposes each
// record's header (type/size/flags/formID) cheaply without reading its
// data, and decompresses+parses subrecords only on demand for callers that
// ask for a specific record's data.
class EsmFile {
public:
	EsmFile() = default;
	~EsmFile();

	EsmFile(const EsmFile &) = delete;
	EsmFile &operator=(const EsmFile &) = delete;

	// Throws std::runtime_error on structural problems (bad TES4 header,
	// truncated file, etc).
	void open(const std::string &path);

	const FileHeader &header() const { return header_; }

	// Walks every record in the file (all nested GRUPs recursed into),
	// invoking the callback with each record's header. Data is NOT read
	// automatically — call read_record_data() from within the callback if
	// the data is needed. Cheap: only 24-byte headers are read, everything
	// else is skipped via fseek.
	void for_each_record(const std::function<void(const RecordInfo &)> &callback) const;

	// Reads and (if needed) zlib-decompresses a record's data blob.
	std::vector<uint8_t> read_record_data(const RecordInfo &record) const;

	// Splits a decompressed record data buffer into subrecords, handling
	// the XXXX oversize-size marker. The returned Subrecords' data pointers
	// point into `data` — keep `data` alive as long as the result is used.
	static std::vector<Subrecord> parse_subrecords(const std::vector<uint8_t> &data);

	// Convenience: record-type -> occurrence count, over the whole file.
	std::unordered_map<std::string, uint32_t> record_type_histogram() const;

	// Finds any record by FormID, anywhere in the file. Builds (and caches) a
	// FormID -> RecordInfo index on first call — a linear scan per lookup
	// would be too slow once a cell's worth of REFRs are each resolving
	// their base record (phases/1/00-interior-cell-loader.md).
	std::optional<RecordInfo> find_record_by_form_id(uint32_t form_id) const;

	// Finds a CELL record by its EDID (exact match) or FormID. std::nullopt
	// if not found, or if the FormID resolves to a non-CELL record.
	std::optional<RecordInfo> find_cell_by_editor_id(const std::string &editor_id) const;
	std::optional<RecordInfo> find_cell_by_form_id(uint32_t form_id) const;

	// phases/2/07-runtime-cell-loader.md: finds the CELL that directly
	// contains the given REFR (e.g. a door's XTEL destination REFR).
	// std::nullopt if the REFR doesn't exist, or its immediate structural
	// parent isn't a CELL. Every GRUP header carries its own byte size, so
	// this walks toward the target by size-range containment (only
	// descending into whichever nested GRUP's byte range actually contains
	// the target) rather than scanning file content — cheap regardless of
	// how large the file or how many sibling records/cells exist at each
	// level.
	std::optional<RecordInfo> find_cell_containing_ref(uint32_t refr_form_id) const;

	// Resolves any REFR's own XTEL (by FormID — the caller doesn't need to
	// already know which cell it lives in) to its teleport destination:
	// which CELL it leads to, plus the landing position/rotation. Reads the
	// REFR's own XTEL directly rather than requiring the caller to already
	// have called get_cell_references() on its home cell. Not restricted to
	// DOOR placements — XTEL is a REFR-level subrecord and this makes no
	// assumption about the REFR's base type; get_door_destination() below is
	// the DOOR-specific name callers actually reach for.
	// std::nullopt if the FormID isn't a REFR, has no XTEL (a real, valid
	// case — most REFRs don't teleport), or its XTEL destination doesn't
	// resolve to a CELL.
	std::optional<DoorDestination> resolve_refr_xtel(uint32_t refr_form_id) const;

	// DOOR-specific convenience name for resolve_refr_xtel() — same thing,
	// clearer at a door-interaction call site. See resolve_refr_xtel() for
	// the actual (generic) implementation and doc comment.
	std::optional<DoorDestination> get_door_destination(uint32_t door_refr_form_id) const {
		return resolve_refr_xtel(door_refr_form_id);
	}

	// Collects every record inside `parent`'s immediately-following child
	// GRUP (if any — per TES4-family convention, a record's child GRUP
	// comes right after its own bytes), recursing into any nested
	// sub-GRUPs. Empty if the record has no child GRUP. Not filtered by
	// type — a CELL's children include REFR, ACHR, PGRD, NAVM, etc.
	std::vector<RecordInfo> get_child_records(const RecordInfo &parent) const;

	// Resolves every REFR directly under `cell` (via get_child_records) to a
	// ReferencePlacement: its transform plus its base record's type/EDID/
	// MODL. Generic across every base record type — see ReferencePlacement's
	// comment in esm_types.h. REFRs with no NAME/DATA subrecord (malformed
	// or a record kind other than plain REFR) are skipped.
	std::vector<ReferencePlacement> get_cell_references(const RecordInfo &cell) const;

	// A Static Collection (SCOL) bundles multiple STAT placements inside its
	// own record body — not via child REFRs. Its subrecords are repeated
	// (ONAM, DATA) pairs: ONAM is the FormID of a STAT, DATA is that part's
	// own local position/rotation/scale (28 bytes: pos+rot+scale; scale
	// defaults to 1.0 if a part's DATA is only 24 bytes, matching REFR's
	// convention where scale is a separate optional field). Returns one
	// ReferencePlacement per part, resolved the same way get_cell_references
	// resolves a REFR's base record — `refr_form_id` is set to the SCOL's
	// own FormID (parts have no FormID of their own) for traceability.
	std::vector<ReferencePlacement> get_scol_parts(const RecordInfo &scol) const;

	// Reads a LIGH record's own DATA subrecord (phases/1/03-light-sources.md).
	// std::nullopt if the FormID doesn't resolve to a LIGH record or has no
	// DATA subrecord.
	std::optional<LightData> get_light_data(uint32_t light_form_id) const;
	std::optional<std::array<uint8_t, 4>> get_emittance_color(uint32_t emittance_form_id) const;
	std::optional<ItemData> get_item_data(uint32_t item_form_id) const;
	std::optional<GrassData> get_grass_data(uint32_t grass_form_id) const;
	// An LTEX can link several grass definitions through repeated GNAM fields.
	// Returns their FormIDs in authored record order, not a single guessed one.
	std::vector<uint32_t> get_ltex_grass_form_ids(uint32_t ltex_form_id) const;
	std::optional<TerminalData> get_terminal_data(uint32_t terminal_form_id) const;
	std::optional<NoteData> get_note_data(uint32_t note_form_id) const;

	// Returns all item candidate identifiers (EditorID, full name, hex FormID) from WEAP, ARMO, AMMO, ALCH, MISC, KEYM, BOOK records.
	std::vector<std::string> get_all_item_candidates() const;

	// Returns all non-empty CELL EditorIDs in the file.
	std::vector<std::string> get_all_cell_candidates() const;

	// phases/1/04-exterior-cell-terrain.md additions:

	// Finds a WRLD (worldspace) record by its EDID (exact match).
	std::optional<RecordInfo> find_worldspace_by_editor_id(const std::string &editor_id) const;

	// Finds the exterior CELL at grid coordinate (x, y) within a worldspace.
	// phases/2/11-exterior-cell-lookup-index.md: navigates directly through
	// the worldspace's own Exterior Cell Block/Sub-Block GRUP structure
	// (Bethesda's own spatial index for this exact lookup) instead of
	// scanning every CELL — see that task doc for the verified label
	// encoding this relies on.
	std::optional<RecordInfo> find_exterior_cell(uint32_t wrld_form_id, int32_t x, int32_t y) const;

	// phases/2/07-runtime-cell-loader.md: the reverse of find_exterior_cell()
	// — given a CELL's own FormID, reads its XCLC grid coordinate directly.
	// std::nullopt if the FormID isn't a CELL, or is a CELL with no XCLC (an
	// interior cell — a real, valid case, not an error).
	std::optional<ExteriorCellGrid> get_exterior_cell_grid(uint32_t cell_form_id) const;

	// A CELL's own EDID — the human-readable identifier used throughout
	// this codebase (find_cell_by_editor_id()'s own input, e.g.
	// "GSDocMitchellHouse"), for display purposes (an on-screen "current
	// cell" readout). Empty string if the FormID isn't a CELL, or is a CELL
	// with no EDID — real for some exterior cells, which are commonly
	// unnamed and only identified by their worldspace + grid coordinate.
	std::string get_cell_editor_id(uint32_t cell_form_id) const;

	// phases/2/07-runtime-cell-loader.md's "Known gap" section: a CELL's
	// owning WRLD FormID, or std::nullopt for an interior cell (which has
	// no "World Children" GRUP ancestor). Reuses find_owner_of()'s
	// out_wrld_form_id plumbing against the CELL's own byte offset, same as
	// resolve_refr_xtel() already does for a REFR's offset.
	std::optional<uint32_t> get_cell_worldspace(uint32_t cell_form_id) const;

	// phases/5/00-script-interpreter-foundation.md: reads a SCPT record's
	// real data (source text, locals, referenced FormIDs) -- see
	// ScriptData's own doc comment for why this never touches SCDA.
	// std::nullopt if the FormID isn't a SCPT.
	std::optional<ScriptData> get_script_data(uint32_t scpt_form_id) const;

	// Reads a CELL's own XCLL ("Lighting") subrecord -- per-cell authored
	// ambient/directional/fog data, distinct from the flat global ambient
	// this codebase currently applies via interior_environment.tres.
	// std::nullopt if the FormID isn't a CELL, or is a CELL with no XCLL (a
	// real, common case for exterior cells).
	std::optional<CellLightingData> get_cell_lighting_data(uint32_t cell_form_id) const;

	// A worldspace's own "persistent" cell — the Construction Set's bucket
	// for always-loaded references (quest markers, fast-travel triggers, LOD
	// imposters, and — confirmed directly — every exterior-facing building
	// entrance door) that aren't tied to any real grid location. Structurally
	// the first CELL child of the WRLD's own "World Children" GRUP, filed
	// before the Exterior Cell Block/Sub-Block GRUPs that hold the normal
	// grid tiles — confirmed against real data (WastelandNV: the first CELL
	// returned by get_child_records(wrld) is 0x846EA, the same persistent
	// cell found independently via its 4468-reference/no-LAND signature).
	// std::nullopt if the FormID isn't a WRLD or has no CELL children at all.
	std::optional<RecordInfo> get_worldspace_persistent_cell(uint32_t wrld_form_id) const;

	// Reads a LAND record's heightmap + per-quadrant base texture. See
	// LandData's comment in esm_types.h for what is and isn't parsed.
	std::optional<LandData> get_land_data(const RecordInfo &land) const;

	// Resolves an LTEX FormID to its diffuse texture path, via
	// LTEX.TNAM -> TXST -> TXST.TX00. Unlike MODL paths (relative to
	// Data/Meshes/), TXST paths are relative to Data/Textures/ with no
	// "textures\" prefix stored in the file — confirmed against real data
	// during this task, the caller must prepend it before a BSA lookup, the
	// same way "meshes\" is prepended for MODL. Empty string if the FormID
	// doesn't resolve all the way through.
	std::string resolve_ltex_texture_path(uint32_t ltex_form_id) const;

	// Same LTEX -> TXST resolution as resolve_ltex_texture_path(), but reads
	// TX01 (real normal/bump map path) instead of TX00 (diffuse). Bethesda's
	// own TXST texture-set convention (TX00=diffuse, TX01=normal, TX02=glow,
	// TX03=height, TX04=environment, TX05=environment mask -- see
	// phases/0/04-dds-texture-import.md's own real-format census, which
	// already confirmed real normal maps in this game are BC3/DXT5). Empty
	// string if the FormID doesn't resolve, or the real TXST has no TX01.
	std::string resolve_ltex_normal_texture_path(uint32_t ltex_form_id) const;

	// General-purpose, not tied to any one caller (DOOR's own SNAM/ANAM/
	// BNAM today, deliberately kept generic for future callers -- ambient
	// sound markers, weapon/footstep sound sets, anything else that
	// references a SOUN record by FormID). Resolves via SOUN.FNAM, the
	// subrecord confirmed via fopdoc to hold the actual filename. Path is
	// relative to Data/Sound/ with no "sound\" prefix stored in the file —
	// same convention as MODL/LTEX texture paths, caller prepends it before
	// a BSA lookup. Empty string if the FormID doesn't resolve to a SOUN
	// record, or that SOUN has no FNAM.
	std::string resolve_soun_filename(uint32_t soun_form_id) const;

	// phases/3/00-door-completion.md Part B: DOOR.SNAM/ANAM/BNAM (each
	// already resolved through resolve_soun_filename() above) + FNAM
	// (flags) — see DoorData's own doc comment in esm_types.h for what
	// each field means and the real, deliberate gap for animated-door
	// sound (baked into the NIF, not read here). std::nullopt if the
	// FormID doesn't resolve to a DOOR record; a real DOOR record always
	// returns a value (all-default fields if it genuinely has none of
	// these subrecords — a real, valid, common case, not the same as "not
	// found").
	std::optional<DoorData> get_door_data(uint32_t door_form_id) const;

private:
	std::FILE *file_ = nullptr;
	long file_size_ = 0;
	FileHeader header_;
	RecordInfo tes4_record_; // the first record in the file

	mutable std::unordered_map<uint32_t, RecordInfo> form_id_index_;
	mutable bool form_id_index_built_ = false;
	void ensure_form_id_index() const;

	mutable std::vector<std::string> item_candidates_cache_;
	mutable bool item_candidates_cached_ = false;
	mutable std::vector<std::string> cell_candidates_cache_;
	mutable bool cell_candidates_cached_ = false;

	std::vector<uint8_t> read_at(long offset, size_t size) const;

	// Recursive walk helper: [start, end) is a byte range containing a
	// sequence of sibling GRUPs/records (either the whole file, or one
	// GRUP's inner content).
	void walk(long start, long end, const std::function<void(const RecordInfo &)> &callback) const;

	// Recursive helper for find_cell_containing_ref(): within [start, end),
	// finds the record immediately preceding whichever nested GRUP's byte
	// range contains target_header_offset (the target record's own header
	// start, i.e. RecordInfo::data_offset - kHeaderSize). std::nullopt if
	// target_header_offset isn't inside any GRUP within this range.
	//
	// out_wrld_form_id (optional): if the found record's ancestor chain
	// passes through a GRUP type 1 ("World Children" — standard TES4 GRUP
	// convention, label = the owning WRLD's own FormID), that FormID is
	// written here. Left untouched (caller should zero-init) for an
	// interior cell, which never has a World Children ancestor. Needed by
	// resolve_refr_xtel()'s persistent-cell handling — see its own comment.
	std::optional<RecordInfo> find_owner_of(long start, long end, long target_header_offset, uint32_t *out_wrld_form_id = nullptr) const;

	// find_cell_containing_ref() variant that also reports the owning
	// worldspace's FormID (0 if the cell is interior) — see find_owner_of()'s
	// out_wrld_form_id.
	std::optional<RecordInfo> find_cell_containing_ref(uint32_t refr_form_id, uint32_t *out_wrld_form_id) const;
};

} // namespace esm

#endif // ESM_FILE_H
