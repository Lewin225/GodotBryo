#ifndef BSA_READER_GD_H
#define BSA_READER_GD_H

#include "bsa_archive.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

// Thin Godot-facing wrapper around bsa::BsaArchive. Kept deliberately
// small: all real parsing logic lives in bsa_archive.{h,cpp}, which has no
// Godot dependency and can be exercised by plain C++ tests too.
class BsaReader : public RefCounted {
	GDCLASS(BsaReader, RefCounted)

protected:
	static void _bind_methods();

public:
	bool open(const String &path);
	int get_entry_count() const;
	PackedStringArray list_entries() const;
	PackedByteArray extract(const String &entry_path) const;
	String get_last_error() const { return last_error_; }

private:
	bsa::BsaArchive archive_;
	bool opened_ = false;
	String last_error_;
};

} // namespace godot

#endif // BSA_READER_GD_H
