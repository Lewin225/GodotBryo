#include "egm_reader_gd.h"

#include <godot_cpp/core/class_db.hpp>

#include <exception>
#include <vector>

using namespace godot;

void EgmReader::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load", "bytes", "source_path"), &EgmReader::load, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("get_last_error"), &EgmReader::get_last_error);
	ClassDB::bind_method(D_METHOD("get_source_path"), &EgmReader::get_source_path);
	ClassDB::bind_method(D_METHOD("get_vertex_count"), &EgmReader::get_vertex_count);
	ClassDB::bind_method(D_METHOD("get_symmetric_mode_count"), &EgmReader::get_symmetric_mode_count);
	ClassDB::bind_method(D_METHOD("get_asymmetric_mode_count"), &EgmReader::get_asymmetric_mode_count);
	ClassDB::bind_method(D_METHOD("morph", "positions", "symmetric", "asymmetric"), &EgmReader::morph);
	ClassDB::bind_method(D_METHOD("get_offsets", "first", "count", "symmetric", "asymmetric"), &EgmReader::get_offsets);
}

bool EgmReader::load(const PackedByteArray &bytes, const String &source_path) {
	loaded_ = false;
	last_error_ = "";
	std::vector<uint8_t> raw(bytes.ptr(), bytes.ptr() + bytes.size());
	try {
		basis_ = egm::load(raw, source_path.utf8().get_data());
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return false;
	}
	loaded_ = true;
	return true;
}

String EgmReader::get_last_error() const {
	return last_error_;
}

String EgmReader::get_source_path() const {
	return String(basis_.source_path.c_str());
}

int EgmReader::get_vertex_count() const {
	return loaded_ ? int(basis_.vertex_count) : 0;
}

int EgmReader::get_symmetric_mode_count() const {
	return loaded_ ? int(basis_.symmetric.size()) : 0;
}

int EgmReader::get_asymmetric_mode_count() const {
	return loaded_ ? int(basis_.asymmetric.size()) : 0;
}

PackedVector3Array EgmReader::morph(const PackedVector3Array &positions, const PackedFloat32Array &symmetric,
		const PackedFloat32Array &asymmetric) const {
	PackedVector3Array result;
	const int count = positions.size();
	if (!loaded_ || count > int(basis_.vertex_count)) {
		return result;
	}
	std::vector<float> offsets(size_t(count) * 3, 0.0f);
	egm::add_offsets(basis_, symmetric.ptr(), symmetric.size(), asymmetric.ptr(), asymmetric.size(), 0,
			uint32_t(count), offsets.data());
	result.resize(count);
	for (int i = 0; i < count; ++i) {
		const Vector3 offset(offsets[i * 3], offsets[i * 3 + 1], offsets[i * 3 + 2]);
		result.set(i, positions[i] + offset);
	}
	return result;
}

PackedVector3Array EgmReader::get_offsets(int first, int count, const PackedFloat32Array &symmetric,
		const PackedFloat32Array &asymmetric) const {
	PackedVector3Array result;
	if (!loaded_ || first < 0 || count < 0 || first + count > int(basis_.vertex_count)) {
		return result;
	}
	std::vector<float> offsets(size_t(count) * 3, 0.0f);
	egm::add_offsets(basis_, symmetric.ptr(), symmetric.size(), asymmetric.ptr(), asymmetric.size(), uint32_t(first),
			uint32_t(count), offsets.data());
	result.resize(count);
	for (int i = 0; i < count; ++i) {
		result.set(i, Vector3(offsets[i * 3], offsets[i * 3 + 1], offsets[i * 3 + 2]));
	}
	return result;
}
