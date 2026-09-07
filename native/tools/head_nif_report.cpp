#include "bsa/bsa_archive.h"
#include "nif/nif_loader.h"

#include <cstdio>
#include <exception>

int main() {
	bsa::BsaArchive archive;
	try { archive.open("fresh_nv_copy/Data/Fallout - Meshes.bsa"); }
	catch (const std::exception &e) { std::fprintf(stderr, "%s\n", e.what()); return 1; }
	for (const char *path : {"meshes\\characters\\head\\headhuman.nif", "meshes\\characters\\head\\headghoul.nif"}) {
		const auto *entry = archive.find(path);
		if (!entry) { std::printf("%s NOT_FOUND\n", path); continue; }
		try {
			nif::Mesh mesh = nif::load_mesh(archive.extract(*entry));
			std::printf("%s submeshes=%zu\n", path, mesh.submeshes.size());
			for (size_t i = 0; i < mesh.submeshes.size(); ++i) std::printf("  %zu name=%s vertices=%zu\n", i, mesh.submeshes[i].name.c_str(), mesh.submeshes[i].positions.size() / 3);
		} catch (const std::exception &e) { std::printf("%s ERROR %s\n", path, e.what()); }
	}
}
