#include "lip_types.h"

#include <cstring>
#include <stdexcept>

// A .lip file: u32 1, u32 S, u32 1, then a body from offset 12 in which a 0x00
// byte and the u16 after it stand for that many zero bytes and any other byte
// stands for itself. The decoded body is S - 16 bytes: u32 frame count, i32
// (meaning not known), then the frames, 33 floats each.

namespace lip {

namespace {

constexpr size_t BODY_OFFSET = 12;
constexpr size_t DECODED_HEADER_SIZE = 8;
constexpr size_t SIZE_FIELD_OVERHEAD = 16;

uint32_t read_u32(const std::vector<uint8_t> &bytes, size_t offset) {
	uint32_t value = 0;
	std::memcpy(&value, bytes.data() + offset, sizeof(value));
	return value;
}

std::vector<uint8_t> decode_body(const std::vector<uint8_t> &bytes, size_t decoded_size) {
	std::vector<uint8_t> decoded;
	decoded.reserve(decoded_size);
	size_t offset = BODY_OFFSET;
	while (offset < bytes.size()) {
		const uint8_t byte = bytes[offset];
		if (byte != 0) {
			decoded.push_back(byte);
			offset += 1;
			continue;
		}
		if (offset + 3 > bytes.size()) {
			throw std::runtime_error("LIP: zero run cut off at the end of the file");
		}
		const uint16_t run = uint16_t(bytes[offset + 1] | (bytes[offset + 2] << 8));
		decoded.insert(decoded.end(), run, 0);
		offset += 3;
	}
	return decoded;
}

} // namespace

Animation load(const std::vector<uint8_t> &bytes, const std::string &source_path) {
	if (bytes.size() < BODY_OFFSET) {
		throw std::runtime_error("LIP: file shorter than its header");
	}
	const uint32_t size_field = read_u32(bytes, 4);
	if (size_field < SIZE_FIELD_OVERHEAD + DECODED_HEADER_SIZE) {
		throw std::runtime_error("LIP: size field too small");
	}
	const std::vector<uint8_t> decoded = decode_body(bytes, size_field - SIZE_FIELD_OVERHEAD);
	if (decoded.size() != size_field - SIZE_FIELD_OVERHEAD) {
		throw std::runtime_error("LIP: decoded body is not the size the header gives");
	}
	Animation animation;
	animation.source_path = source_path;
	std::memcpy(&animation.frame_count, decoded.data(), sizeof(uint32_t));
	std::memcpy(&animation.header_value, decoded.data() + 4, sizeof(int32_t));
	const size_t float_count = size_t(animation.frame_count) * CHANNEL_COUNT;
	if (DECODED_HEADER_SIZE + float_count * sizeof(float) != decoded.size()) {
		throw std::runtime_error("LIP: frame count does not match the decoded size");
	}
	animation.frames.resize(float_count);
	std::memcpy(animation.frames.data(), decoded.data() + DECODED_HEADER_SIZE, float_count * sizeof(float));
	return animation;
}

} // namespace lip
