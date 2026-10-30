#ifndef NV_LIP_READER_GD_H
#define NV_LIP_READER_GD_H

#include "lip_types.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// Decodes a .lip file (lip_loader.cpp) into frames of 33 channel weights.
class LipReader : public RefCounted {
	GDCLASS(LipReader, RefCounted)

protected:
	static void _bind_methods();

public:
	bool load(const PackedByteArray &bytes, const String &source_path = "");
	String get_last_error() const;
	String get_source_path() const;
	int get_frame_count() const;
	int get_channel_count() const;
	int get_header_value() const;
	// Every frame's channels, frame after frame.
	PackedFloat32Array get_frames() const;

private:
	lip::Animation animation_;
	String last_error_;
};

} // namespace godot

#endif
