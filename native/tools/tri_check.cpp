// Real-data TRI census for the two vanilla NPC head animation assets.
#include "bsa/bsa_archive.h"
#include "tri/tri_loader.h"
#include <cstdio>
#include <exception>

int main() {
	bsa::BsaArchive archive;
	try { archive.open("fresh_nv_copy/Data/Fallout - Meshes.bsa"); }
	catch (const std::exception &e) { std::fprintf(stderr, "%s\n", e.what()); return 1; }
	int failures = 0;
	for (const char *path : {"meshes\\characters\\head\\headhuman.tri", "meshes\\characters\\head\\headghoul.tri"}) {
		const auto *entry = archive.find(path);
		if (!entry) { std::printf("%s NOT_FOUND\n", path); ++failures; continue; }
		try {
			tri::Mesh mesh = tri::load(archive.extract(*entry), path);
			bool ok = mesh.vertex_count == 1211 && mesh.triangles.size() % 3 == 0 &&
				mesh.delta_morphs.size() == 38 && mesh.statistical_morphs.size() == 8 &&
				mesh.statistical_vertex_count == 238;
			std::printf("%s vertices=%u triangles=%u deltas=%zu stats=%zu stat_vertices=%u %s\n",
				path, mesh.vertex_count, mesh.triangle_count, mesh.delta_morphs.size(),
				mesh.statistical_morphs.size(), mesh.statistical_vertex_count, ok ? "OK" : "FAIL");
			if (!ok) ++failures;
		} catch (const std::exception &e) { std::printf("%s ERROR %s\n", path, e.what()); ++failures; }
	}
	return failures ? 1 : 0;
}
