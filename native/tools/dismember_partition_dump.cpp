// One-off Nifly diagnostic: report the actual BSDismemberSkinInstance
// partition-to-triangle relationship for one official mesh-BSA NIF.
//
// This deliberately uses NifFile::GetShapePartitions(), not NifSource, so it
// can prove what Nifly exposes before engine representation is designed.
#include "bsa/bsa_archive.h"
#include "NifFile.hpp"

#include <cstdint>
#include <cstdio>
#include <map>
#include <sstream>
#include <string>
#include <vector>

int main(int argc, char **argv) {
	if (argc != 2) {
		std::fprintf(stderr, "usage: %s <meshes-relative-nif-path>\n", argv[0]);
		return 1;
	}

	bsa::BsaArchive archive;
	try {
		archive.open("fresh_nv_copy/Data/Fallout - Meshes.bsa");
	} catch (const std::exception &error) {
		std::fprintf(stderr, "open Meshes BSA failed: %s\n", error.what());
		return 1;
	}
	const std::string path = "meshes\\" + std::string(argv[1]);
	const bsa::Entry *entry = archive.find(path);
	if (entry == nullptr) {
		std::fprintf(stderr, "not found: %s\n", path.c_str());
		return 1;
	}
	const std::vector<uint8_t> bytes = archive.extract(*entry);
	std::stringstream stream(std::string(reinterpret_cast<const char *>(bytes.data()), bytes.size()));
	nifly::NifFile nif;
	if (nif.Load(stream) != 0) {
		std::fprintf(stderr, "Nifly could not load: %s\n", path.c_str());
		return 1;
	}

	std::printf("%s\n", path.c_str());
	for (nifly::NiShape *shape : nif.GetShapes()) {
		std::vector<nifly::Triangle> triangles;
		shape->GetTriangles(triangles);
		nifly::NiVector<nifly::BSDismemberSkinInstance::PartitionInfo> partitions;
		std::vector<int> triangle_partitions;
		if (!nif.GetShapePartitions(shape, partitions, triangle_partitions)) {
			std::printf("  %s: no skin partitions (%zu triangles)\n", shape->name.get().c_str(), triangles.size());
			continue;
		}

		std::map<int, size_t> triangle_counts;
		for (const int partition : triangle_partitions) triangle_counts[partition]++;
		std::vector<size_t> partition_vertex_counts(partitions.size());
		std::map<uint16_t, size_t> vertex_partition_uses;
		if (auto *skin = nif.GetHeader().GetBlock<nifly::NiSkinInstance>(shape->SkinInstanceRef())) {
			if (auto *skin_partition = nif.GetHeader().GetBlock(skin->skinPartitionRef)) {
				for (size_t index = 0; index < skin_partition->partitions.size() && index < partitions.size(); ++index) {
					const auto &vertex_map = skin_partition->partitions[index].vertexMap;
					partition_vertex_counts[index] = vertex_map.size();
					for (const uint16_t vertex : vertex_map) vertex_partition_uses[vertex]++;
				}
			}
		}
		size_t shared_vertices = 0;
		for (const auto &[vertex, uses] : vertex_partition_uses) if (uses > 1) shared_vertices++;
		std::printf("  %s: %zu triangles, %zu partition records, %zu triangle assignments\n",
			shape->name.get().c_str(), triangles.size(), partitions.size(), triangle_partitions.size());
		for (size_t index = 0; index < partitions.size(); ++index) {
			const auto &partition = partitions[index];
			std::printf("    [%zu] id=%u flags=0x%04x triangles=%zu mapped_vertices=%zu\n", index,
				static_cast<unsigned>(partition.partID), static_cast<unsigned>(partition.flags), triangle_counts[static_cast<int>(index)], partition_vertex_counts[index]);
		}
		std::printf("    partition vertex-map union=%zu, shared by partitions=%zu\n", vertex_partition_uses.size(), shared_vertices);
		if (const auto unassigned = triangle_counts.find(-1); unassigned != triangle_counts.end()) {
			std::printf("    unassigned triangles=%zu\n", unassigned->second);
		}
	}
	return 0;
}
