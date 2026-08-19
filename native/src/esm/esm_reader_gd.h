#ifndef ESM_READER_GD_H
#define ESM_READER_GD_H

#include "esm_file.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// Thin Godot-facing wrapper around esm::EsmFile. Real parsing logic lives
// in esm_file.{h,cpp} / esm_types.h, which have no Godot dependency.
class EsmReader : public RefCounted {
	GDCLASS(EsmReader, RefCounted)

protected:
	static void _bind_methods();

public:
	bool open(const String &path);
	String get_last_error() const { return last_error_; }

	// { "version": float, "num_records": int, "next_object_id": int, "masters": PackedStringArray }
	Dictionary get_header_info() const;

	// record type (4-char String) -> occurrence count (int)
	Dictionary get_record_type_histogram() const;

	// First STAT record with a non-empty MODL subrecord found in the file:
	// { "form_id": int, "editor_id": String, "model": String }, or an empty
	// Dictionary if none was found (or the file isn't open).
	Dictionary find_first_stat_model() const;

	// Same shape as find_first_stat_model(), but looks up a specific STAT
	// record by its EditorID (case-sensitive, exact match) — used by 0.5's
	// integration tool to resolve a specific known object by name rather
	// than "whichever STAT comes first in the file".
	Dictionary find_stat_by_editor_id(const String &editor_id) const;

	// Finds a CELL record by EditorID or FormID: { "form_id": int }, or an
	// empty Dictionary if not found. Both exist so callers can demonstrate
	// (and this project's Phase 1 acceptance criteria require) that lookup
	// by either identifier finds the same cell — see
	// phases/1/00-interior-cell-loader.md.
	Dictionary find_cell_by_editor_id(const String &editor_id) const;
	Dictionary find_cell_by_form_id(int64_t form_id) const;

	// Resolves every REFR placed directly in the given cell (by FormID) to
	// an Array of Dictionaries, each: { "refr_form_id": int, "base_form_id":
	// int, "base_type": String, "editor_id": String, "model": String,
	// "position": Vector3, "rotation": Vector3, "scale": float }. Generic
	// across every base record type — callers filter to whichever types
	// they currently handle (phases/1/00-interior-cell-loader.md wants
	// "base_type" == "STAT" only; phases/1/01-object-type-registry.md
	// reuses this unfiltered).
	Array get_cell_references(int64_t cell_form_id) const;

	// Same Dictionary shape as get_cell_references(), but resolves a SCOL
	// (Static Collection) record's bundled parts instead of a cell's REFRs
	// — see esm::EsmFile::get_scol_parts(). "refr_form_id" is the SCOL's
	// own FormID (parts have no FormID of their own).
	Array get_scol_parts(int64_t scol_form_id) const;

	// Reads a LIGH record's DATA: { "radius": float (meters), "color":
	// Color, "flags": int, "falloff": float, "fov_degrees": float, "is_spot":
	// bool, "off_by_default": bool }, or an empty Dictionary if the FormID
	// isn't a LIGH record / has no DATA. See esm::LightData.
	Dictionary get_light_data(int64_t light_form_id) const;

	// phases/1/04-exterior-cell-terrain.md additions:

	// { "form_id": int } or {} if not found.
	Dictionary find_worldspace_by_editor_id(const String &editor_id) const;

	// { "form_id": int } or {} if not found.
	Dictionary find_exterior_cell(int64_t wrld_form_id, int32_t x, int32_t y) const;

	// phases/2/07-runtime-cell-loader.md: { "x": int, "y": int }, or {} if
	// cell_form_id isn't a CELL or has no XCLC (an interior cell — a real,
	// valid case, not an error).
	Dictionary get_exterior_cell_grid(int64_t cell_form_id) const;

	// Reads the given cell's LAND child (if any): { "heights":
	// PackedFloat32Array (33*33, row-major, already decoded and in
	// meters — see esm::LandData's confidence caveat on the decode order),
	// "quadrant_base_ltex": PackedInt64Array (4 FormIDs, fopdoc order:
	// 0=BL, 1=BR, 2=TL, 3=TR) }, or {} if the cell has no LAND record.
	Dictionary get_land_data(int64_t cell_form_id) const;

	// LTEX -> TXST -> diffuse path (no "textures\" prefix — see
	// esm::EsmFile::resolve_ltex_texture_path). Empty string if unresolved.
	String resolve_ltex_texture_path(int64_t ltex_form_id) const;

	// phases/1/05-integration.md addition: a cell's full child-record type
	// census (record type -> count), not just the REFR subset
	// get_cell_references() resolves. Lets a caller demonstrate that
	// non-REFR children (ACHR/ACRE actor placements, PGRD, NAVM, ...) are
	// deliberately and silently excluded from get_cell_references() rather
	// than accidentally dropped — see EsmFile::get_cell_references()'s
	// "ACHR/ACRE/etc — actors, not handled in Phase 1" skip.
	Dictionary get_cell_child_type_counts(int64_t cell_form_id) const;

	// phases/2/07-runtime-cell-loader.md: { "dest_cell_form_id": int,
	// "dest_position": Vector3, "dest_rotation": Vector3 }, or {} if
	// refr_form_id isn't a REFR, has no XTEL (a real, valid case — most
	// REFRs don't teleport), or its destination doesn't resolve to a CELL.
	// Generic — not restricted to DOOR placements, XTEL is a REFR-level
	// subrecord. get_door_destination() below is the same thing under the
	// name a door-interaction call site actually reaches for.
	Dictionary resolve_refr_xtel(int64_t refr_form_id) const;
	Dictionary get_door_destination(int64_t door_refr_form_id) const { return resolve_refr_xtel(door_refr_form_id); }

	// First record whose compression flag is set, with its data actually
	// decompressed (proves the zlib path works, not just that the flag
	// parses): { "type": String, "form_id": int, "compressed_size": int,
	// "decompressed_size": int }, or empty if none found / decompression
	// failed / file isn't open.
	Dictionary find_first_compressed_record() const;

private:
	esm::EsmFile file_;
	bool opened_ = false;
	mutable String last_error_;
};

} // namespace godot

#endif // ESM_READER_GD_H
