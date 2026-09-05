#ifndef NV_TRI_READER_GD_H
#define NV_TRI_READER_GD_H
#include "tri_types.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/array.hpp>
namespace godot {
class TriReader : public RefCounted { GDCLASS(TriReader, RefCounted)
protected: static void _bind_methods();
public:
	bool load(const PackedByteArray &bytes, const String &source_path = "");
	String get_last_error() const { return last_error_; }
	String get_source_path() const;
	int get_vertex_count() const; int get_statistical_vertex_count() const;
	PackedFloat32Array get_vertices() const; PackedInt32Array get_triangles() const;
	int get_delta_morph_count() const; String get_delta_morph_name(int) const; PackedFloat32Array get_delta_morph_deltas(int) const;
	int get_statistical_morph_count() const; String get_statistical_morph_name(int) const; PackedInt32Array get_statistical_morph_vertex_indices(int) const;
private: tri::Mesh mesh_; bool loaded_=false; String last_error_;
}; }
#endif
