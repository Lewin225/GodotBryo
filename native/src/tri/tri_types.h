#ifndef NV_TRI_TYPES_H
#define NV_TRI_TYPES_H

#include <cstdint>
#include <string>
#include <vector>

namespace tri {

struct DeltaMorph {
	std::string name;
	std::vector<float> deltas; // xyz, meters, V entries
};

struct StatisticalMorph {
	std::string name;
	std::vector<uint32_t> vertex_indices; // indices into the V+K vertex list
};

struct Mesh {
	std::string source_path;
	uint32_t vertex_count = 0;
	uint32_t triangle_count = 0;
	uint32_t quad_count = 0;
	uint32_t statistical_vertex_count = 0;
	std::vector<float> vertices; // xyz, meters, V+K entries
	std::vector<uint32_t> triangles; // three indices per triangle
	std::vector<uint32_t> quads; // four indices per quad
	std::vector<DeltaMorph> delta_morphs;
	std::vector<StatisticalMorph> statistical_morphs;
};

Mesh load(const std::vector<uint8_t> &bytes, const std::string &source_path = {});

} // namespace tri

#endif
