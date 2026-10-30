#include "lip_reader_gd.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstring>
#include <stdexcept>

using namespace godot;

void LipReader::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load", "bytes", "source_path"), &LipReader::load, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("get_last_error"), &LipReader::get_last_error);
	ClassDB::bind_method(D_METHOD("get_source_path"), &LipReader::get_source_path);
	ClassDB::bind_method(D_METHOD("get_frame_count"), &LipReader::get_frame_count);
	ClassDB::bind_method(D_METHOD("get_channel_count"), &LipReader::get_channel_count);
	ClassDB::bind_method(D_METHOD("get_header_value"), &LipReader::get_header_value);
	ClassDB::bind_method(D_METHOD("get_frames"), &LipReader::get_frames);
}

bool LipReader::load(const PackedByteArray &bytes, const String &source_path) {
	last_error_ = "";
	animation_ = lip::Animation();
	const std::vector<uint8_t> raw(bytes.ptr(), bytes.ptr() + bytes.size());
	try {
		animation_ = lip::load(raw, source_path.utf8().get_data());
	} catch (const std::exception &error) {
		last_error_ = String(error.what());
		return false;
	}
	return true;
}

String LipReader::get_last_error() const {
	return last_error_;
}

String LipReader::get_source_path() const {
	return String(animation_.source_path.c_str());
}

int LipReader::get_frame_count() const {
	return int(animation_.frame_count);
}

int LipReader::get_channel_count() const {
	return int(lip::CHANNEL_COUNT);
}

int LipReader::get_header_value() const {
	return int(animation_.header_value);
}

PackedFloat32Array LipReader::get_frames() const {
	PackedFloat32Array frames;
	frames.resize(int64_t(animation_.frames.size()));
	std::memcpy(frames.ptrw(), animation_.frames.data(), animation_.frames.size() * sizeof(float));
	return frames;
}
