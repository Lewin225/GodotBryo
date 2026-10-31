#include "egt_loader.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>

namespace egt {

namespace {

constexpr size_t kHeaderSize = 64;

uint32_t read_u32(const std::vector<uint8_t> &bytes, size_t offset) {
	uint32_t value = 0;
	std::memcpy(&value, bytes.data() + offset, sizeof(value));
	return value;
}

} // namespace

Basis load(const std::vector<uint8_t> &bytes, const std::string &source_path) {
	if (bytes.size() < kHeaderSize) {
		throw std::runtime_error("EGT header truncated");
	}
	if (std::memcmp(bytes.data(), "FREGT003", 8) != 0) {
		throw std::runtime_error("invalid EGT magic");
	}
	Basis basis;
	basis.source_path = source_path;
	basis.rows = read_u32(bytes, 8);
	basis.columns = read_u32(bytes, 12);
	const uint32_t symmetric_count = read_u32(bytes, 16);
	const uint32_t asymmetric_count = read_u32(bytes, 20);
	basis.basis_version = read_u32(bytes, 24);
	if (basis.rows == 0 || basis.columns == 0) {
		throw std::runtime_error("EGT has no texels");
	}
	if (asymmetric_count != 0) {
		throw std::runtime_error("EGT asymmetric modes are not supported");
	}
	const size_t plane = size_t(basis.rows) * basis.columns;
	const size_t mode_size = sizeof(float) + plane * 3;
	if (bytes.size() != kHeaderSize + size_t(symmetric_count) * mode_size) {
		throw std::runtime_error("EGT size does not match its header");
	}
	size_t offset = kHeaderSize;
	basis.symmetric.resize(symmetric_count);
	for (Mode &mode : basis.symmetric) {
		std::memcpy(&mode.scale, bytes.data() + offset, sizeof(float));
		if (!std::isfinite(mode.scale)) {
			throw std::runtime_error("EGT mode scale is not finite");
		}
		offset += sizeof(float);
		const int8_t *values = reinterpret_cast<const int8_t *>(bytes.data() + offset);
		mode.values.assign(values, values + plane * 3);
		offset += plane * 3;
	}
	return basis;
}

std::vector<float> offsets(const Basis &basis, const float *symmetric, size_t symmetric_count) {
	const size_t plane = size_t(basis.rows) * basis.columns;
	std::vector<float> sums(plane * 3, 0.0f); // planar, file row order
	const size_t count = std::min(basis.symmetric.size(), symmetric_count);
	for (size_t m = 0; m < count; ++m) {
		const float weight = symmetric[m] * basis.symmetric[m].scale;
		if (weight == 0.0f || !std::isfinite(weight)) {
			continue;
		}
		const int8_t *values = basis.symmetric[m].values.data();
		for (size_t i = 0; i < plane * 3; ++i) {
			sums[i] += weight * float(values[i]);
		}
	}
	std::vector<float> out(plane * 3);
	for (uint32_t row = 0; row < basis.rows; ++row) {
		const size_t file_row = basis.rows - 1 - row;
		for (uint32_t column = 0; column < basis.columns; ++column) {
			const size_t source = file_row * basis.columns + column;
			const size_t target = (size_t(row) * basis.columns + column) * 3;
			for (size_t channel = 0; channel < 3; ++channel) {
				out[target + channel] = sums[channel * plane + source];
			}
		}
	}
	return out;
}

} // namespace egt
