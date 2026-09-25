// Answers: how much real NAVM (navmesh) data exists across the shipped
// masters, so we can size a full-load-vs-cache/downsample decision for NPC
// travel bounds-checking. Sums record count, decompressed byte size, and
// real DATA-subrecord vertex/triangle counts (NAVM DATA layout confirmed
// against enginedocs/xEdit/Core/wbDefinitionsFNV.pas: Cell FormID u32,
// Vertex Count u32, Triangle Count u32, Edge Link Count u32,
// Cover Triangle Count u32, Door Link Count u32 -- 24 bytes total,
// NVVX vertex = 12 bytes, NVTR triangle = 16 bytes).
#include <cstdio>
#include <cstdint>
#include <string>
#include "esm/esm_file.h"

struct Totals {
	uint64_t record_count = 0;
	uint64_t decompressed_bytes = 0;
	uint64_t vertex_count = 0;
	uint64_t triangle_count = 0;
	uint64_t edge_link_count = 0;
	uint64_t cover_triangle_count = 0;
	uint64_t door_link_count = 0;
};

static uint32_t read_u32(const std::vector<uint8_t> &data, size_t offset) {
	if (offset + 4 > data.size()) return 0;
	return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (uint32_t(data[offset + 3]) << 24);
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s <esm_path> [esm_path...]\n", argv[0]);
		return 1;
	}
	Totals grand_total;
	for (int i = 1; i < argc; ++i) {
		std::string path = argv[i];
		esm::EsmFile file;
		try {
			file.open(path);
		} catch (const std::exception &e) {
			fprintf(stderr, "failed to open %s: %s\n", path.c_str(), e.what());
			continue;
		}
		Totals file_total;
		file.for_each_record([&](const esm::RecordInfo &record) {
			if (record.type != "NAVM") return;
			file_total.record_count++;
			auto raw = file.read_record_data(record);
			file_total.decompressed_bytes += raw.size();
			auto subrecords = esm::EsmFile::parse_subrecords(raw);
			for (const auto &sub : subrecords) {
				if (sub.type != "DATA") continue;
				std::vector<uint8_t> data(sub.data, sub.data + sub.size);
				file_total.vertex_count += read_u32(data, 4);
				file_total.triangle_count += read_u32(data, 8);
				file_total.edge_link_count += read_u32(data, 12);
				file_total.cover_triangle_count += read_u32(data, 16);
				file_total.door_link_count += read_u32(data, 20);
				break;
			}
		});
		printf("%-28s NAVM=%-6llu decompressed=%8.2f KB  verts=%-8llu tris=%-8llu edge_links=%-7llu cover_tris=%-7llu door_links=%llu\n",
			path.c_str(),
			(unsigned long long)file_total.record_count,
			file_total.decompressed_bytes / 1024.0,
			(unsigned long long)file_total.vertex_count,
			(unsigned long long)file_total.triangle_count,
			(unsigned long long)file_total.edge_link_count,
			(unsigned long long)file_total.cover_triangle_count,
			(unsigned long long)file_total.door_link_count);
		grand_total.record_count += file_total.record_count;
		grand_total.decompressed_bytes += file_total.decompressed_bytes;
		grand_total.vertex_count += file_total.vertex_count;
		grand_total.triangle_count += file_total.triangle_count;
		grand_total.edge_link_count += file_total.edge_link_count;
		grand_total.cover_triangle_count += file_total.cover_triangle_count;
		grand_total.door_link_count += file_total.door_link_count;
	}
	printf("\nTOTAL NAVM=%llu decompressed=%.2f MB verts=%llu tris=%llu edge_links=%llu cover_tris=%llu door_links=%llu\n",
		(unsigned long long)grand_total.record_count,
		grand_total.decompressed_bytes / (1024.0 * 1024.0),
		(unsigned long long)grand_total.vertex_count,
		(unsigned long long)grand_total.triangle_count,
		(unsigned long long)grand_total.edge_link_count,
		(unsigned long long)grand_total.cover_triangle_count,
		(unsigned long long)grand_total.door_link_count);

	// Estimate an in-memory footprint for a straightforward, non-downsampled
	// representation: real vertex Vector3 (12B) + real triangle indices+flags
	// (as authored, 16B) per record, plus a generous 32B/triangle overhead for
	// a runtime spatial index (BVH/grid cell refs) -- a deliberately pessimistic
	// per-triangle multiplier, not a measured structure.
	double raw_geometry_mb = (grand_total.vertex_count * 12.0 + grand_total.triangle_count * 16.0) / (1024.0 * 1024.0);
	double with_index_overhead_mb = raw_geometry_mb + (grand_total.triangle_count * 32.0) / (1024.0 * 1024.0);
	printf("Estimated resident footprint: raw geometry only = %.2f MB, with generous runtime-index overhead = %.2f MB\n",
		raw_geometry_mb, with_index_overhead_mb);
	return 0;
}
