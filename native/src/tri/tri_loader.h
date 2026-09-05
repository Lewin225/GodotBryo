#ifndef NV_TRI_LOADER_H
#define NV_TRI_LOADER_H

#include "tri_types.h"
#include <cstdint>
#include <vector>

namespace tri {
Mesh load(const std::vector<uint8_t> &bytes, const std::string &source_path);
}

#endif
