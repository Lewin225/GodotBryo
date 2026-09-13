#ifndef NIF_SOURCE_GD_H
#define NIF_SOURCE_GD_H

#include "nif_source.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace godot {

// Godot-facing wrapper over nifsrc::Document. Thin by design: all reading
// lives in nif_source.{h,cpp}, which has no Godot dependency.
//
// Separate from NifReader, which wraps the legacy flattened loader. Both
// coexist; nothing is migrated off NifReader by this class existing.
class NifSource : public RefCounted {
	GDCLASS(NifSource, RefCounted)

protected:
	static void _bind_methods();

public:
	bool load(const PackedByteArray &bytes);
	String get_last_error() const { return last_error_; }
	String get_version() const;
	int get_block_count() const;

	// True when the file's declared bones form a hierarchy within it.
	bool has_bone_hierarchy() const;

	// One entry per NiAVObject, in block order:
	// {name, block_type, parent_index, block_index, transform}
	Array get_nodes() const;

	// One entry per NiDefaultAVObjectPalette: {block_index, entries}.
	Array get_object_palettes() const;

	// One entry per NiControllerSequence, target strings resolved.
	Array get_sequences() const;

	// Flattened collision shapes and the rigid bodies that own them.
	Array get_collision_shapes() const;
	Array get_collision_bodies() const;

private:
	nifsrc::Document doc_;
	bool loaded_ = false;
	String last_error_;
};

} // namespace godot

#endif // NIF_SOURCE_GD_H
