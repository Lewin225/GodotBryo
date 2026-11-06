#ifndef NV_EGT_READER_GD_H
#define NV_EGT_READER_GD_H

#include "egt_loader.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// A FaceGen texture basis (`.egt`). After load() it is read-only, so one
// instance can be shared by worker threads.
class EgtReader : public RefCounted {
	GDCLASS(EgtReader, RefCounted)

protected:
	static void _bind_methods();

public:
	bool load(const PackedByteArray &bytes, const String &source_path = "");
	String get_last_error() const;
	String get_source_path() const;
	int get_rows() const;
	int get_columns() const;
	int get_symmetric_mode_count() const;

	// The texel offsets for the FGTS coefficients, in 8-bit levels: RGB per
	// texel, rows x columns, in texture order. Empty before a load.
	PackedFloat32Array get_offsets(const PackedFloat32Array &symmetric) const;

	// The offsets as an RGB8 image in a facemod's encoding: 128 + offset / 2,
	// clamped to 0..255. Null before a load.
	Ref<Image> build_offset_image(const PackedFloat32Array &symmetric) const;

private:
	egt::Basis basis_;
	bool loaded_ = false;
	String last_error_;
};

} // namespace godot

#endif
