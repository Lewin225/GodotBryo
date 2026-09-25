// Answers: can a full, non-downsampled navmesh load (every NAVM record in
// every shipped master -- vertices, triangles, in-record triangle adjacency,
// cross-record NVEX links, authored NVGD bounds) fit inside a < 5 second boot
// budget, and which phase dominates?
//
// This deliberately builds the same structures a real loader would, so the
// timing is meaningful rather than a parse-only lower bound. It is a timing
// harness, not the shipping loader.
//
// Subrecord layouts confirmed against enginedocs/xEdit/Core/wbDefinitionsFNV.pas:
//   DATA (24B): Cell FormID u32, Vertex Count u32, Triangle Count u32,
//               Edge Link Count u32, Cover Triangle Count u32, Door Link Count u32
//   NVVX: Vertex Count * Vec3 (12B each)
//   NVTR: Triangle Count * { v0 u16, v1 u16, v2 u16, edge01 s16, edge12 s16,
//                            edge20 s16, flags u16, cover flags u16 } (16B each)
//   NVEX: Edge Link Count * { type u32, navmesh FormID u32, triangle u16 } (10B each)
//   NVGD: divisor u32, max X dist f32, max Y dist f32, bounds min Vec3, bounds max Vec3
//         (authored bounds live at fixed offsets 12..35), then the grid cell array
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <unordered_map>
#include <chrono>
#include "esm/esm_file.h"

struct Vec3 { float x = 0, y = 0, z = 0; };

struct Triangle {
	uint16_t v[3] = {0, 0, 0};
	int16_t edge[3] = {-1, -1, -1}; // in-record neighbor triangle index, -1 = boundary
	uint16_t flags = 0;
	uint16_t cover_flags = 0;
};

struct EdgeLink {
	uint32_t type = 0;
	uint32_t target_navm_form_id = 0;
	uint16_t triangle = 0;
};

struct NavMesh {
	uint32_t form_id = 0;
	uint32_t cell_form_id = 0;
	std::vector<Vec3> vertices;
	std::vector<Triangle> triangles;
	std::vector<EdgeLink> edge_links;
	bool has_bounds = false;
	Vec3 bounds_min, bounds_max;
	Vec3 center; // derived from authored bounds only when has_bounds
};

static uint32_t rd_u32(const uint8_t *d, size_t n, size_t o) {
	if (o + 4 > n) return 0;
	return d[o] | (d[o+1] << 8) | (d[o+2] << 16) | (uint32_t(d[o+3]) << 24);
}
static uint16_t rd_u16(const uint8_t *d, size_t n, size_t o) {
	if (o + 2 > n) return 0;
	return d[o] | (d[o+1] << 8);
}
static int16_t rd_s16(const uint8_t *d, size_t n, size_t o) {
	return (int16_t)rd_u16(d, n, o);
}
static float rd_f32(const uint8_t *d, size_t n, size_t o) {
	if (o + 4 > n) return 0.0f;
	float f;
	std::memcpy(&f, d + o, 4);
	return f;
}
static Vec3 rd_vec3(const uint8_t *d, size_t n, size_t o) {
	return Vec3{ rd_f32(d, n, o), rd_f32(d, n, o + 4), rd_f32(d, n, o + 8) };
}

using Clock = std::chrono::steady_clock;
static double ms_since(Clock::time_point t) {
	return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s <esm_path> [esm_path...]\n", argv[0]);
		return 1;
	}

	auto total_start = Clock::now();
	double open_ms = 0, walk_ms = 0, read_ms = 0, parse_ms = 0, index_ms = 0;

	std::vector<NavMesh> meshes;
	meshes.reserve(8192);
	// Collected first, indexed after, so the cross-record link resolve is timed
	// separately from per-record parsing.
	std::unordered_map<uint32_t, size_t> navm_by_form_id;

	for (int i = 1; i < argc; ++i) {
		auto t_open = Clock::now();
		esm::EsmFile file;
		try {
			file.open(argv[i]);
		} catch (const std::exception &e) {
			fprintf(stderr, "failed to open %s: %s\n", argv[i], e.what());
			continue;
		}
		open_ms += ms_since(t_open);

		// Phase 1: header walk to collect NAVM RecordInfos (no data read).
		auto t_walk = Clock::now();
		std::vector<esm::RecordInfo> navm_records;
		file.for_each_record([&](const esm::RecordInfo &record) {
			if (record.type == "NAVM") navm_records.push_back(record);
		});
		walk_ms += ms_since(t_walk);

		// Phase 2+3: read/decompress each record, then parse into structures.
		for (const auto &record : navm_records) {
			auto t_read = Clock::now();
			std::vector<uint8_t> raw = file.read_record_data(record);
			read_ms += ms_since(t_read);

			auto t_parse = Clock::now();
			auto subs = esm::EsmFile::parse_subrecords(raw);
			NavMesh mesh;
			mesh.form_id = record.form_id;
			uint32_t vertex_count = 0, triangle_count = 0, edge_link_count = 0;
			for (const auto &sub : subs) {
				const uint8_t *d = sub.data;
				size_t n = sub.size;
				if (sub.type == "DATA") {
					mesh.cell_form_id = rd_u32(d, n, 0);
					vertex_count = rd_u32(d, n, 4);
					triangle_count = rd_u32(d, n, 8);
					edge_link_count = rd_u32(d, n, 12);
				} else if (sub.type == "NVVX") {
					size_t count = vertex_count ? vertex_count : n / 12;
					mesh.vertices.resize(count);
					for (size_t k = 0; k < count; ++k) mesh.vertices[k] = rd_vec3(d, n, k * 12);
				} else if (sub.type == "NVTR") {
					size_t count = triangle_count ? triangle_count : n / 16;
					mesh.triangles.resize(count);
					for (size_t k = 0; k < count; ++k) {
						size_t o = k * 16;
						Triangle &t = mesh.triangles[k];
						t.v[0] = rd_u16(d, n, o + 0);
						t.v[1] = rd_u16(d, n, o + 2);
						t.v[2] = rd_u16(d, n, o + 4);
						t.edge[0] = rd_s16(d, n, o + 6);
						t.edge[1] = rd_s16(d, n, o + 8);
						t.edge[2] = rd_s16(d, n, o + 10);
						t.flags = rd_u16(d, n, o + 12);
						t.cover_flags = rd_u16(d, n, o + 14);
					}
				} else if (sub.type == "NVEX") {
					size_t count = edge_link_count ? edge_link_count : n / 10;
					mesh.edge_links.resize(count);
					for (size_t k = 0; k < count; ++k) {
						size_t o = k * 10;
						mesh.edge_links[k].type = rd_u32(d, n, o + 0);
						mesh.edge_links[k].target_navm_form_id = rd_u32(d, n, o + 4);
						mesh.edge_links[k].triangle = rd_u16(d, n, o + 8);
					}
				} else if (sub.type == "NVGD") {
					if (n >= 36) {
						mesh.has_bounds = true;
						mesh.bounds_min = rd_vec3(d, n, 12);
						mesh.bounds_max = rd_vec3(d, n, 24);
						mesh.center = Vec3{
							(mesh.bounds_min.x + mesh.bounds_max.x) * 0.5f,
							(mesh.bounds_min.y + mesh.bounds_max.y) * 0.5f,
							(mesh.bounds_min.z + mesh.bounds_max.z) * 0.5f
						};
					}
				}
			}
			parse_ms += ms_since(t_parse);
			meshes.push_back(std::move(mesh));
		}
	}

	// Phase 4: build the FormID index and resolve every cross-record NVEX link
	// to a real mesh index -- the coarse-graph build.
	auto t_index = Clock::now();
	for (size_t k = 0; k < meshes.size(); ++k) navm_by_form_id[meshes[k].form_id] = k;
	size_t resolved_links = 0, dangling_links = 0;
	std::vector<std::vector<uint32_t>> coarse_adjacency(meshes.size());
	for (size_t k = 0; k < meshes.size(); ++k) {
		for (const auto &link : meshes[k].edge_links) {
			auto it = navm_by_form_id.find(link.target_navm_form_id);
			if (it == navm_by_form_id.end()) { dangling_links++; continue; }
			resolved_links++;
			coarse_adjacency[k].push_back((uint32_t)it->second);
		}
	}
	index_ms += ms_since(t_index);

	double total_ms = ms_since(total_start);

	size_t total_verts = 0, total_tris = 0, with_bounds = 0;
	size_t bytes = 0;
	for (const auto &m : meshes) {
		total_verts += m.vertices.size();
		total_tris += m.triangles.size();
		if (m.has_bounds) with_bounds++;
		bytes += m.vertices.size() * sizeof(Vec3)
			+ m.triangles.size() * sizeof(Triangle)
			+ m.edge_links.size() * sizeof(EdgeLink)
			+ sizeof(NavMesh);
	}
	for (const auto &adj : coarse_adjacency) bytes += adj.size() * sizeof(uint32_t);

	printf("NAVM records loaded: %zu\n", meshes.size());
	printf("Vertices: %zu | Triangles: %zu\n", total_verts, total_tris);
	printf("NAVM records with authored NVGD bounds: %zu / %zu\n", with_bounds, meshes.size());
	printf("Cross-record NVEX links resolved: %zu | dangling (target not in loaded set): %zu\n",
		resolved_links, dangling_links);
	printf("Actual resident structure size: %.2f MB\n", bytes / (1024.0 * 1024.0));
	printf("\n--- timing ---\n");
	printf("open            : %8.1f ms\n", open_ms);
	printf("header walk     : %8.1f ms\n", walk_ms);
	printf("read+decompress : %8.1f ms\n", read_ms);
	printf("parse->structs  : %8.1f ms\n", parse_ms);
	printf("index+coarse gr : %8.1f ms\n", index_ms);
	printf("TOTAL           : %8.1f ms  (%.2f s)\n", total_ms, total_ms / 1000.0);
	return 0;
}
