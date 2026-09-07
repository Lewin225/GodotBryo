#include "bsa/bsa_archive.h"
#include "nif/nif_loader.h"
#include <cstdio>
#include <exception>

int main() {
	bsa::BsaArchive archive;
	try { archive.open("fresh_nv_copy/Data/Fallout - Meshes.bsa"); }
	catch (const std::exception &e) { std::fprintf(stderr, "%s\n", e.what()); return 1; }
	const bsa::Entry *entry = archive.find("meshes\\characters\\_male\\upperbody.nif");
	if (!entry) return 1;
	nif::Mesh mesh = nif::load_mesh(archive.extract(*entry));
	for (size_t i = 0; i < mesh.submeshes.size(); ++i)
		std::printf("submesh=%zu name=%s texture=%s\n", i, mesh.submeshes[i].name.c_str(), mesh.submeshes[i].texture_path.c_str());
	for (const auto &skin : mesh.skin_data) {
		std::printf("skin target=%s partitions=", skin.target_node_name.c_str());
		for (auto id : skin.partition_body_part_ids) std::printf("%u,", id);
		std::printf("\n");
	}
}
