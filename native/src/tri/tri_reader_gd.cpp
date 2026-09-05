#include "tri_reader_gd.h"
#include "tri_loader.h"
#include <godot_cpp/core/class_db.hpp>
#include <cstring>

using namespace godot;
void TriReader::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load", "bytes", "source_path"), &TriReader::load, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("get_last_error"), &TriReader::get_last_error);
	ClassDB::bind_method(D_METHOD("get_source_path"), &TriReader::get_source_path);
	ClassDB::bind_method(D_METHOD("get_vertex_count"), &TriReader::get_vertex_count);
	ClassDB::bind_method(D_METHOD("get_statistical_vertex_count"), &TriReader::get_statistical_vertex_count);
	ClassDB::bind_method(D_METHOD("get_vertices"), &TriReader::get_vertices);
	ClassDB::bind_method(D_METHOD("get_triangles"), &TriReader::get_triangles);
	ClassDB::bind_method(D_METHOD("get_delta_morph_count"), &TriReader::get_delta_morph_count);
	ClassDB::bind_method(D_METHOD("get_delta_morph_name", "index"), &TriReader::get_delta_morph_name);
	ClassDB::bind_method(D_METHOD("get_delta_morph_deltas", "index"), &TriReader::get_delta_morph_deltas);
	ClassDB::bind_method(D_METHOD("get_statistical_morph_count"), &TriReader::get_statistical_morph_count);
	ClassDB::bind_method(D_METHOD("get_statistical_morph_name", "index"), &TriReader::get_statistical_morph_name);
	ClassDB::bind_method(D_METHOD("get_statistical_morph_vertex_indices", "index"), &TriReader::get_statistical_morph_vertex_indices);
}
bool TriReader::load(const PackedByteArray &bytes, const String &source_path) {
	loaded_=false; last_error_=""; std::vector<uint8_t> raw(bytes.ptr(), bytes.ptr()+bytes.size());
	try { mesh_=tri::load(raw, source_path.utf8().get_data()); loaded_=true; return true; }
	catch (const std::exception &e) { last_error_=String(e.what()); return false; }
}
String TriReader::get_source_path() const { return String(mesh_.source_path.c_str()); }
int TriReader::get_vertex_count() const { return int(mesh_.vertex_count); }
int TriReader::get_statistical_vertex_count() const { return int(mesh_.statistical_vertex_count); }
PackedFloat32Array TriReader::get_vertices() const { PackedFloat32Array a; for(float v:mesh_.vertices)a.push_back(v); return a; }
PackedInt32Array TriReader::get_triangles() const { PackedInt32Array a; for(uint32_t v:mesh_.triangles)a.push_back(int32_t(v)); return a; }
int TriReader::get_delta_morph_count() const { return int(mesh_.delta_morphs.size()); }
String TriReader::get_delta_morph_name(int i) const { return i>=0&&i<int(mesh_.delta_morphs.size())?String(mesh_.delta_morphs[i].name.c_str()):String(); }
PackedFloat32Array TriReader::get_delta_morph_deltas(int i) const { PackedFloat32Array a; if(i>=0&&i<int(mesh_.delta_morphs.size()))for(float v:mesh_.delta_morphs[i].deltas)a.push_back(v); return a; }
int TriReader::get_statistical_morph_count() const { return int(mesh_.statistical_morphs.size()); }
String TriReader::get_statistical_morph_name(int i) const { return i>=0&&i<int(mesh_.statistical_morphs.size())?String(mesh_.statistical_morphs[i].name.c_str()):String(); }
PackedInt32Array TriReader::get_statistical_morph_vertex_indices(int i) const { PackedInt32Array a; if(i>=0&&i<int(mesh_.statistical_morphs.size()))for(uint32_t v:mesh_.statistical_morphs[i].vertex_indices)a.push_back(int32_t(v)); return a; }
