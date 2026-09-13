#ifndef ARCHIVE_CATALOG_GD_H
#define ARCHIVE_CATALOG_GD_H

#include "bsa_catalog.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

// Thin Godot-facing wrapper around bsa::BsaArchiveCatalog. All catalog,
// priority and index logic lives in bsa_catalog.{h,cpp}, which has no Godot
// dependency. Lifecycle and configuration belong to the ArchiveServer
// autoload, not here.
class ArchiveCatalog : public RefCounted {
	GDCLASS(ArchiveCatalog, RefCounted)

protected:
	static void _bind_methods();

public:
	// One-time initialization. Must complete before any concurrent use.
	bool open_data_dir(const String &data_dir);

	// Thread-safe after open_data_dir(). Returns
	// {found: bool, archive: String, data: PackedByteArray, error: String}.
	Dictionary read(const String &path) const;

	bool contains(const String &path) const;
	String winning_archive(const String &path) const;
	PackedStringArray list_files_with_prefix(const String &prefix) const;

	int get_entry_count() const;
	PackedStringArray get_archive_order() const;
	PackedStringArray get_failed_archives() const;
	String get_last_error() const { return last_error_; }

private:
	bsa::BsaArchiveCatalog catalog_;
	bool opened_ = false;
	String last_error_;
};

} // namespace godot

#endif // ARCHIVE_CATALOG_GD_H
