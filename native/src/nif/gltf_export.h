#ifndef GLTF_EXPORT_H
#define GLTF_EXPORT_H

#include "nif_types.h"

#include <string>

namespace nif {

// Writes a self-contained glTF 2.0 file (.gltf, JSON with the binary buffer
// embedded as a base64 data URI — no separate .bin sidecar) for inspection
// in an off-the-shelf glTF viewer. This is a Phase 0 debugging aid, not the
// Godot-native import path (that's 0.5) — geometry only, no material
// textures embedded (texture paths are carried as material "extras" only).
//
// Throws std::runtime_error if the file can't be written.
void export_gltf(const Mesh &mesh, const std::string &path);

} // namespace nif

#endif // GLTF_EXPORT_H
