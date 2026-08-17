#ifndef NIF_LOADER_H
#define NIF_LOADER_H

#include "nif_types.h"

#include <cstdint>
#include <vector>

namespace nif {

// Loads a NIF file's static geometry using the vendored nifly library
// (native/nifly/, see native/README.md for why we integrate rather than
// reimplement). Skeleton/skinning/animation data is intentionally not
// extracted here — see phases/0/03-nif-parser.md non-goals.
//
// Throws std::runtime_error on load failure (bad magic, unsupported/corrupt
// stream, etc).
Mesh load_mesh(const std::vector<uint8_t> &bytes);

} // namespace nif

#endif // NIF_LOADER_H
