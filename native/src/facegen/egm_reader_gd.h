#ifndef NV_EGM_READER_GD_H
#define NV_EGM_READER_GD_H

#include "egm_loader.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// A FaceGen geometry basis (`.egm`). After load() it is read-only, so one
// instance can be shared by worker threads.
class EgmReader : public RefCounted {
	GDCLASS(EgmReader, RefCounted)

protected:
	static void _bind_methods();

public:
	bool load(const PackedByteArray &bytes, const String &source_path = "");
	String get_last_error() const;
	String get_source_path() const;
	int get_vertex_count() const;
	int get_symmetric_mode_count() const;
	int get_asymmetric_mode_count() const;

	// `positions` (the first positions.size() EGM vertices, in metres) plus
	// their FaceGen offsets for the given coefficients. Empty when there are
	// more positions than EGM vertices.
	PackedVector3Array morph(const PackedVector3Array &positions, const PackedFloat32Array &symmetric,
			const PackedFloat32Array &asymmetric) const;

	// The offsets alone of EGM vertices [first, first + count), in metres.
	// Empty when the range is outside the EGM.
	PackedVector3Array get_offsets(int first, int count, const PackedFloat32Array &symmetric,
			const PackedFloat32Array &asymmetric) const;

private:
	egm::Basis basis_;
	bool loaded_ = false;
	String last_error_;
};

} // namespace godot

#endif
