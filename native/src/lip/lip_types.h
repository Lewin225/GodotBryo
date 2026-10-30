#ifndef NV_LIP_TYPES_H
#define NV_LIP_TYPES_H

#include <cstdint>
#include <string>
#include <vector>

namespace lip {

// Floats in each frame: FaceGen's 16 phonemes, then 17 modifiers.
constexpr uint32_t CHANNEL_COUNT = 33;

struct Animation {
	std::string source_path;
	uint32_t frame_count = 0;
	// The i32 after the frame count in the decoded body, 0 to -9 over every
	// shipped file; its meaning is not known.
	int32_t header_value = 0;
	// CHANNEL_COUNT floats per frame, frame after frame.
	std::vector<float> frames;
};

Animation load(const std::vector<uint8_t> &bytes, const std::string &source_path = {});

} // namespace lip

#endif
