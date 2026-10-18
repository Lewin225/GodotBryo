#ifndef NV_EGM_LOADER_H
#define NV_EGM_LOADER_H

#include <cstdint>
#include <string>
#include <vector>

namespace egm {

// One FaceGen geometry mode: a scale and, per vertex, three signed 16-bit
// values. A vertex moves by coefficient x scale x value along each axis.
struct Mode {
	float scale = 0.0f;
	std::vector<int16_t> values; // xyz per vertex, vertex_count x 3
};

// A parsed `FREGM002` file (FaceGen SDK file formats): its vertex count is the
// paired TRI's V + K, the first V vertices in the NIF shape's own order.
struct Basis {
	std::string source_path;
	uint32_t vertex_count = 0;
	uint32_t basis_version = 0;
	std::vector<Mode> symmetric;
	std::vector<Mode> asymmetric;
};

// Throws std::runtime_error when the bytes are not a whole EGM.
Basis load(const std::vector<uint8_t> &bytes, const std::string &source_path);

// Adds the offsets of vertices [first, first + out_count) to `out` (xyz per
// vertex), in metres in the file's own axes: the sum over modes of
// coefficient x scale x value / 70. Missing coefficients count as zero, extra
// ones are ignored.
void add_offsets(const Basis &basis, const float *symmetric, size_t symmetric_count, const float *asymmetric,
		size_t asymmetric_count, uint32_t first, uint32_t out_count, float *out);

} // namespace egm

#endif
