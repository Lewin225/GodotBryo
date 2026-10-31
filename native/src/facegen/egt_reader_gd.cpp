#include "egt_reader_gd.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <exception>
#include <vector>

using namespace godot;

void EgtReader::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load", "bytes", "source_path"), &EgtReader::load, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("get_last_error"), &EgtReader::get_last_error);
	ClassDB::bind_method(D_METHOD("get_source_path"), &EgtReader::get_source_path);
	ClassDB::bind_method(D_METHOD("get_rows"), &EgtReader::get_rows);
	ClassDB::bind_method(D_METHOD("get_columns"), &EgtReader::get_columns);
	ClassDB::bind_method(D_METHOD("get_symmetric_mode_count"), &EgtReader::get_symmetric_mode_count);
	ClassDB::bind_method(D_METHOD("get_offsets", "symmetric"), &EgtReader::get_offsets);
	ClassDB::bind_method(D_METHOD("build_offset_image", "symmetric"), &EgtReader::build_offset_image);
}

bool EgtReader::load(const PackedByteArray &bytes, const String &source_path) {
	loaded_ = false;
	last_error_ = "";
	std::vector<uint8_t> raw(bytes.ptr(), bytes.ptr() + bytes.size());
	try {
		basis_ = egt::load(raw, source_path.utf8().get_data());
	} catch (const std::exception &e) {
		last_error_ = String(e.what());
		return false;
	}
	loaded_ = true;
	return true;
}

String EgtReader::get_last_error() const {
	return last_error_;
}

String EgtReader::get_source_path() const {
	return String(basis_.source_path.c_str());
}

int EgtReader::get_rows() const {
	return loaded_ ? int(basis_.rows) : 0;
}

int EgtReader::get_columns() const {
	return loaded_ ? int(basis_.columns) : 0;
}

int EgtReader::get_symmetric_mode_count() const {
	return loaded_ ? int(basis_.symmetric.size()) : 0;
}

PackedFloat32Array EgtReader::get_offsets(const PackedFloat32Array &symmetric) const {
	PackedFloat32Array result;
	if (!loaded_) {
		return result;
	}
	const std::vector<float> offsets = egt::offsets(basis_, symmetric.ptr(), symmetric.size());
	result.resize(int64_t(offsets.size()));
	std::copy(offsets.begin(), offsets.end(), result.ptrw());
	return result;
}

Ref<Image> EgtReader::build_offset_image(const PackedFloat32Array &symmetric) const {
	if (!loaded_) {
		return Ref<Image>();
	}
	const std::vector<float> offsets = egt::offsets(basis_, symmetric.ptr(), symmetric.size());
	PackedByteArray pixels;
	pixels.resize(int64_t(offsets.size()));
	uint8_t *out = pixels.ptrw();
	for (size_t i = 0; i < offsets.size(); ++i) {
		const float level = std::round(128.0f + offsets[i] * 0.5f);
		out[i] = uint8_t(std::clamp(level, 0.0f, 255.0f));
	}
	return Image::create_from_data(int32_t(basis_.columns), int32_t(basis_.rows), false, Image::FORMAT_RGB8, pixels);
}
