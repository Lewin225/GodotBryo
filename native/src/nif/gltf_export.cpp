#include "gltf_export.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <limits>
#include <sstream>
#include <stdexcept>

namespace nif {

namespace {

std::string base64_encode(const std::vector<uint8_t> &data) {
	static const char table[] =
			"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	std::string out;
	out.reserve(((data.size() + 2) / 3) * 4);

	size_t i = 0;
	while (i + 3 <= data.size()) {
		uint32_t n = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
		out.push_back(table[(n >> 18) & 0x3F]);
		out.push_back(table[(n >> 12) & 0x3F]);
		out.push_back(table[(n >> 6) & 0x3F]);
		out.push_back(table[n & 0x3F]);
		i += 3;
	}
	size_t remaining = data.size() - i;
	if (remaining == 1) {
		uint32_t n = data[i] << 16;
		out.push_back(table[(n >> 18) & 0x3F]);
		out.push_back(table[(n >> 12) & 0x3F]);
		out.push_back('=');
		out.push_back('=');
	} else if (remaining == 2) {
		uint32_t n = (data[i] << 16) | (data[i + 1] << 8);
		out.push_back(table[(n >> 18) & 0x3F]);
		out.push_back(table[(n >> 12) & 0x3F]);
		out.push_back(table[(n >> 6) & 0x3F]);
		out.push_back('=');
	}
	return out;
}

// Appends raw bytes to `buffer`, padding to a 4-byte boundary (glTF
// recommendation for bufferView alignment), and returns {byteOffset,
// byteLength} of the unpadded region.
struct Region {
	size_t byte_offset;
	size_t byte_length;
};

Region append(std::vector<uint8_t> &buffer, const void *data, size_t byte_length) {
	Region r{ buffer.size(), byte_length };
	const uint8_t *bytes = reinterpret_cast<const uint8_t *>(data);
	buffer.insert(buffer.end(), bytes, bytes + byte_length);
	while (buffer.size() % 4 != 0) {
		buffer.push_back(0);
	}
	return r;
}

std::string json_escape(const std::string &s) {
	std::string out;
	out.reserve(s.size());
	for (char c : s) {
		if (c == '\\' || c == '"') {
			out.push_back('\\');
			out.push_back(c);
		} else if (c == '\n') {
			out += "\\n";
		} else {
			out.push_back(c);
		}
	}
	return out;
}

} // namespace

void export_gltf(const Mesh &mesh, const std::string &path) {
	std::vector<uint8_t> buffer;
	std::ostringstream views; // bufferViews array entries
	std::ostringstream accessors; // accessors array entries
	std::ostringstream meshes; // meshes array entries
	std::ostringstream nodes; // node array entries (index 0 is the root; one child node per submesh)
	std::ostringstream materials; // materials array entries

	std::ostringstream root_children;
	bool first_child = true;

	int view_index = 0;
	int accessor_index = 0;

	for (size_t si = 0; si < mesh.submeshes.size(); ++si) {
		const SubMesh &sub = mesh.submeshes[si];
		size_t vertex_count = sub.positions.size() / 3;

		if (si > 0) {
			meshes << ",";
		}

		std::ostringstream attributes;
		bool first_attr = true;

		auto add_vec_accessor = [&](const char *attr_name, const std::vector<float> &data,
											 int components, bool with_bounds) {
			if (data.empty()) {
				return;
			}
			Region r = append(buffer, data.data(), data.size() * sizeof(float));
			if (view_index > 0) {
				views << ",";
			}
			views << "{\"buffer\":0,\"byteOffset\":" << r.byte_offset
				  << ",\"byteLength\":" << r.byte_length << "}";

			if (accessor_index > 0) {
				accessors << ",";
			}
			const char *type = components == 3 ? "VEC3" : "VEC2";
			accessors << "{\"bufferView\":" << view_index << ",\"componentType\":5126"
					  << ",\"count\":" << (data.size() / components)
					  << ",\"type\":\"" << type << "\"";
			if (with_bounds) {
				float mn[3] = { std::numeric_limits<float>::max(), std::numeric_limits<float>::max(), std::numeric_limits<float>::max() };
				float mx[3] = { -std::numeric_limits<float>::max(), -std::numeric_limits<float>::max(), -std::numeric_limits<float>::max() };
				for (size_t i = 0; i + 2 < data.size(); i += 3) {
					for (int c = 0; c < 3; ++c) {
						mn[c] = std::min(mn[c], data[i + c]);
						mx[c] = std::max(mx[c], data[i + c]);
					}
				}
				accessors << ",\"min\":[" << mn[0] << "," << mn[1] << "," << mn[2] << "]"
						  << ",\"max\":[" << mx[0] << "," << mx[1] << "," << mx[2] << "]";
			}
			accessors << "}";

			if (!first_attr) {
				attributes << ",";
			}
			attributes << "\"" << attr_name << "\":" << accessor_index;
			first_attr = false;

			++view_index;
			++accessor_index;
		};

		add_vec_accessor("POSITION", sub.positions, 3, true);
		add_vec_accessor("NORMAL", sub.normals, 3, false);
		add_vec_accessor("TEXCOORD_0", sub.uvs, 2, false);

		// Indices (UNSIGNED_INT — simplest, avoids a 16-bit overflow check
		// since some FNV meshes exceed 65535 vertices across all submeshes
		// combined, even though any single submesh here is well under that).
		int indices_accessor = -1;
		if (!sub.indices.empty()) {
			Region r = append(buffer, sub.indices.data(), sub.indices.size() * sizeof(uint32_t));
			views << ",{\"buffer\":0,\"byteOffset\":" << r.byte_offset
				  << ",\"byteLength\":" << r.byte_length << "}";
			accessors << ",{\"bufferView\":" << view_index << ",\"componentType\":5125"
					  << ",\"count\":" << sub.indices.size() << ",\"type\":\"SCALAR\"}";
			indices_accessor = accessor_index;
			++view_index;
			++accessor_index;
		}

		int material_index = static_cast<int>(si);
		if (si > 0) {
			materials << ",";
		}
		materials << "{\"name\":\"" << json_escape(sub.name) << "_mat\""
				  << ",\"extras\":{\"texture_path\":\"" << json_escape(sub.texture_path) << "\"}}";

		meshes << "{\"name\":\"" << json_escape(sub.name) << "\",\"primitives\":[{"
			   << "\"attributes\":{" << attributes.str() << "}"
			   << ",\"material\":" << material_index;
		if (indices_accessor >= 0) {
			meshes << ",\"indices\":" << indices_accessor;
		}
		meshes << "}]}";

		// Node: glTF matrices are column-major. sub.rotation is row-major
		// 3x3 (see nif_types.h); flatten to a 4x4 with translation/scale
		// baked in, matching nifly's MatTransform::ToMatrix() convention.
		const float *r = sub.rotation;
		const float *t = sub.translation;
		float s = sub.scale;
		float m[16] = {
			r[0] * s, r[3] * s, r[6] * s, 0.0f,
			r[1] * s, r[4] * s, r[7] * s, 0.0f,
			r[2] * s, r[5] * s, r[8] * s, 0.0f,
			t[0], t[1], t[2], 1.0f
		};

		if (!first_child) {
			root_children << ",";
		}
		root_children << (1 + si);
		first_child = false;

		nodes << ",{\"name\":\"" << json_escape(sub.name) << "\",\"mesh\":" << si << ",\"matrix\":[";
		for (int i = 0; i < 16; ++i) {
			if (i > 0) {
				nodes << ",";
			}
			nodes << m[i];
		}
		nodes << "]}";
	}

	std::string b64 = base64_encode(buffer);

	std::ostringstream json;
	json << "{"
		 << "\"asset\":{\"version\":\"2.0\",\"generator\":\"nv-engine nif_loader (Phase 0.3)\"},"
		 << "\"scene\":0,"
		 << "\"scenes\":[{\"nodes\":[0]}],"
		 << "\"nodes\":[{\"name\":\"root\",\"children\":[" << root_children.str() << "]}" << nodes.str() << "],"
		 << "\"meshes\":[" << meshes.str() << "],"
		 << "\"materials\":[" << materials.str() << "],"
		 << "\"accessors\":[" << accessors.str() << "],"
		 << "\"bufferViews\":[" << views.str() << "],"
		 << "\"buffers\":[{\"byteLength\":" << buffer.size()
		 << ",\"uri\":\"data:application/octet-stream;base64," << b64 << "\"}]"
		 << "}";

	std::ofstream out(path, std::ios::binary);
	if (!out) {
		throw std::runtime_error("nif::export_gltf: could not open output path: " + path);
	}
	std::string s = json.str();
	out.write(s.data(), static_cast<std::streamsize>(s.size()));
}

} // namespace nif
