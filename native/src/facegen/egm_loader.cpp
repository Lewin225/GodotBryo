#include "egm_loader.h"
#include "../common/units.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>

namespace egm {

namespace {

constexpr size_t kHeaderSize = 64;

uint32_t read_u32(const std::vector<uint8_t> &bytes, size_t offset) {
	uint32_t value = 0;
	std::memcpy(&value, bytes.data() + offset, sizeof(value));
	return value;
}

void read_modes(const std::vector<uint8_t> &bytes, size_t &offset, uint32_t mode_count, uint32_t vertex_count,
		std::vector<Mode> &out) {
	const size_t value_count = size_t(vertex_count) * 3;
	out.resize(mode_count);
	for (Mode &mode : out) {
		std::memcpy(&mode.scale, bytes.data() + offset, sizeof(float));
		if (!std::isfinite(mode.scale)) {
			throw std::runtime_error("EGM mode scale is not finite");
		}
		offset += sizeof(float);
		mode.values.resize(value_count);
		std::memcpy(mode.values.data(), bytes.data() + offset, value_count * sizeof(int16_t));
		offset += value_count * sizeof(int16_t);
	}
}

void add_mode_offsets(const std::vector<Mode> &modes, const float *coefficients, size_t coefficient_count,
		uint32_t first, uint32_t out_count, float *out) {
	const size_t count = std::min(modes.size(), coefficient_count);
	for (size_t m = 0; m < count; ++m) {
		const float weight = coefficients[m] * modes[m].scale * units::kGamebryoUnitsToMeters;
		if (weight == 0.0f || !std::isfinite(weight)) {
			continue;
		}
		const int16_t *values = modes[m].values.data() + size_t(first) * 3;
		const size_t value_count = size_t(out_count) * 3;
		for (size_t i = 0; i < value_count; ++i) {
			out[i] += weight * float(values[i]);
		}
	}
}

} // namespace

Basis load(const std::vector<uint8_t> &bytes, const std::string &source_path) {
	if (bytes.size() < kHeaderSize) {
		throw std::runtime_error("EGM header truncated");
	}
	if (std::memcmp(bytes.data(), "FREGM002", 8) != 0) {
		throw std::runtime_error("invalid EGM magic");
	}
	Basis basis;
	basis.source_path = source_path;
	basis.vertex_count = read_u32(bytes, 8);
	const uint32_t symmetric_count = read_u32(bytes, 12);
	const uint32_t asymmetric_count = read_u32(bytes, 16);
	basis.basis_version = read_u32(bytes, 20);
	if (basis.vertex_count == 0) {
		throw std::runtime_error("EGM has no vertices");
	}
	const size_t mode_size = sizeof(float) + size_t(basis.vertex_count) * 3 * sizeof(int16_t);
	const size_t expected = kHeaderSize + (size_t(symmetric_count) + asymmetric_count) * mode_size;
	if (bytes.size() != expected) {
		throw std::runtime_error("EGM size does not match its header");
	}
	size_t offset = kHeaderSize;
	read_modes(bytes, offset, symmetric_count, basis.vertex_count, basis.symmetric);
	read_modes(bytes, offset, asymmetric_count, basis.vertex_count, basis.asymmetric);
	return basis;
}

void add_offsets(const Basis &basis, const float *symmetric, size_t symmetric_count, const float *asymmetric,
		size_t asymmetric_count, uint32_t first, uint32_t out_count, float *out) {
	if (first > basis.vertex_count || out_count > basis.vertex_count - first) {
		throw std::runtime_error("EGM vertex range out of bounds");
	}
	add_mode_offsets(basis.symmetric, symmetric, symmetric_count, first, out_count, out);
	add_mode_offsets(basis.asymmetric, asymmetric, asymmetric_count, first, out_count, out);
}

} // namespace egm
