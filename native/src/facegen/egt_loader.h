#ifndef NV_EGT_LOADER_H
#define NV_EGT_LOADER_H

#include <cstdint>
#include <string>
#include <vector>

namespace egt {

// One FaceGen texture mode: a scale and three signed 8-bit planes (R, G, B),
// rows x columns each, in the file's row order.
struct Mode {
	float scale = 0.0f;
	std::vector<int8_t> values; // R plane, G plane, B plane
};

// A parsed `FREGT003` file (FaceGen SDK file formats). Every shipped EGT has
// 50 symmetric modes and no asymmetric ones.
struct Basis {
	std::string source_path;
	uint32_t rows = 0;
	uint32_t columns = 0;
	uint32_t basis_version = 0;
	std::vector<Mode> symmetric;
};

// Throws std::runtime_error when the bytes are not a whole EGT.
Basis load(const std::vector<uint8_t> &bytes, const std::string &source_path);

// The texel offsets for the given FGTS coefficients, in 8-bit levels: RGB per
// texel, rows x columns, in texture order (the file's rows are bottom to top,
// so its last row is the texture's first). A texel moves by the sum over modes
// of coefficient x scale x value. Missing coefficients count as zero, extra
// ones are ignored.
std::vector<float> offsets(const Basis &basis, const float *symmetric, size_t symmetric_count);

} // namespace egt

#endif
