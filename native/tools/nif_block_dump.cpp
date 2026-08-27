// One-off: dump every block's type name in a NIF pulled from a BSA, to check
// whether a given prop (e.g. the Goodsprings saloon hanging sign) is built
// from a skinned bone hierarchy (NiSkinInstance/BSDismemberSkinInstance) or
// a plain NiNode chain driven by havok rigid bodies/constraints (bhk*).
#include "bsa/bsa_archive.h"
#include "NifFile.hpp"
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s <meshes-relative-nif-path>\n", argv[0]);
		return 1;
	}
	std::string rel_path = argv[1];
	bsa::BsaArchive archive;
	try {
		archive.open("fresh_nv_copy/Data/Fallout - Meshes.bsa");
	} catch (const std::exception &e) {
		fprintf(stderr, "failed to open Meshes BSA: %s\n", e.what());
		return 1;
	}
	const bsa::Entry *entry = archive.find("meshes\\" + rel_path);
	if (entry == nullptr) {
		fprintf(stderr, "not found in BSA: %s\n", rel_path.c_str());
		return 1;
	}
	std::vector<uint8_t> bytes = archive.extract(*entry);
	std::stringstream ss(std::string(reinterpret_cast<char *>(bytes.data()), bytes.size()));
	nifly::NifFile nif;
	if (nif.Load(ss) != 0) {
		fprintf(stderr, "nifly failed to parse\n");
		return 1;
	}
	auto &hdr = nif.GetHeader();
	std::map<std::string, int> counts;
	for (uint32_t i = 0; i < hdr.GetNumBlocks(); ++i)
		counts[hdr.GetBlockTypeStringById(i)]++;
	for (auto &[type, count] : counts)
		printf("%4d  %s\n", count, type.c_str());
	return 0;
}
