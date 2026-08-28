// Issue #47 Phase E: real-data verification for vertex morph target
// extraction (nif::Mesh::morph_data -- NiGeomMorpherController + NiMorphData
// + weight-animation tracks). Exercises nif::load_mesh() directly and
// asserts on it, mirroring native/tools/nif_skin_weights.cpp's own
// promoted-diagnostic shape.
#include "bsa/bsa_archive.h"
#include "nif/nif_loader.h"

#include <cmath>
#include <cstdio>

namespace {

int check_one(bsa::BsaArchive &archive, const std::string &rel_path) {
	const bsa::Entry *entry = archive.find("meshes\\" + rel_path);
	if (entry == nullptr) {
		printf("=== %s === NOT FOUND\n", rel_path.c_str());
		return 1;
	}
	std::vector<uint8_t> bytes = archive.extract(*entry);
	nif::Mesh mesh;
	try {
		mesh = nif::load_mesh(bytes);
	} catch (const std::exception &e) {
		printf("=== %s === load_mesh failed: %s\n", rel_path.c_str(), e.what());
		return 1;
	}

	printf("=== %s ===\n", rel_path.c_str());
	printf("  submeshes=%zu morph_data=%zu\n", mesh.submeshes.size(), mesh.morph_data.size());
	if (mesh.morph_data.empty()) {
		printf("  FAIL: expected real morph data, found none\n");
		return 1;
	}

	int failures = 0;
	for (const nif::MorphData &morph : mesh.morph_data) {
		int bad_target_size = 0;
		float base_maxlen = 0.0f;
		float delta_maxlen = 0.0f;
		for (size_t i = 0; i < morph.targets.size(); ++i) {
			const nif::MorphTarget &target = morph.targets[i];
			if (target.vertex_deltas.size() % 3 != 0) {
				bad_target_size++;
				continue;
			}
			float maxlen = 0.0f;
			for (size_t v = 0; v + 2 < target.vertex_deltas.size(); v += 3) {
				float x = target.vertex_deltas[v], y = target.vertex_deltas[v + 1], z = target.vertex_deltas[v + 2];
				float len = std::sqrt(x * x + y * y + z * z);
				maxlen = std::max(maxlen, len);
			}
			if (i == 0) {
				base_maxlen = std::max(base_maxlen, maxlen); // index 0 == the base shape's own copy (large magnitude), not a real target -- see nif_types.h's MorphTarget doc comment
			} else {
				delta_maxlen = std::max(delta_maxlen, maxlen); // real targets 1..N -- small ripple deltas
			}
		}
		int unresolved_weight_tracks = static_cast<int>(morph.targets.size()) - static_cast<int>(morph.weight_tracks.size());
		printf("  target=%-24s targets=%2zu weight_tracks=%2zu bad_target_size=%d base_maxlen(m)=%.3f delta_maxlen(m)=%.3f cycle=%d start=%.3f stop=%.3f\n",
				morph.target_node_name.c_str(), morph.targets.size(), morph.weight_tracks.size(),
				bad_target_size, base_maxlen, delta_maxlen, static_cast<int>(morph.cycle_type), morph.start_time, morph.stop_time);
		// Real data confirmed (see nif_types.h's own doc comment): index 0's
		// magnitude is the raw geometry scale (large), real targets are small
		// ripple offsets -- assert that relationship holds rather than just
		// printing it, so a future real-data regression actually fails loud.
		bool base_dominates = morph.targets.size() < 2 || base_maxlen > delta_maxlen;
		if (bad_target_size > 0 || unresolved_weight_tracks < 0 || !base_dominates) {
			failures++;
		}
	}

	if (failures > 0) {
		printf("  FAIL: %d anomalies\n", failures);
		return 1;
	}
	printf("  PASS\n");
	return 0;
}

} // namespace

int main() {
	bsa::BsaArchive archive;
	try {
		archive.open("fresh_nv_copy/Data/Fallout - Meshes.bsa");
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}

	// The Goodsprings Nevada flag -- the one real asset issue #47 was filed
	// against (a combined bone-rig-plus-cloth-ripple setup, see the issue's
	// own "Real evidence" section).
	const char *files[] = {
		"clutter\\flags\\nv_nevadaflag.nif",
	};

	int failures = 0;
	for (const char *f : files) {
		failures += check_one(archive, f);
	}

	if (failures > 0) {
		printf("\n%d file(s) failed\n", failures);
		return 1;
	}
	printf("\nall files passed\n");
	return 0;
}
