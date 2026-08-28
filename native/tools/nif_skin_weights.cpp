// Issue #46 Phase D: promoted from throwaway research tooling (originally
// read NiSkinPartition.numWeightsPerVertex directly, to check whether any
// real FNV vertex needs more than 4 bone influences before committing to
// SkinData's fixed-4-wide extraction shape -- see nif_types.h's own doc
// comment). Now exercises the real nif::load_mesh()/Mesh::skin_data path
// end-to-end and asserts on it directly, rather than re-deriving weights
// from NiSkinPartition by hand a second time.
#include "bsa/bsa_archive.h"
#include "nif/nif_loader.h"

#include <cstdio>
#include <sstream>
#include <string>

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
	printf("  submeshes=%zu skin_data=%zu\n", mesh.submeshes.size(), mesh.skin_data.size());
	if (mesh.skin_data.empty()) {
		printf("  FAIL: expected real skinning data, found none\n");
		return 1;
	}

	int failures = 0;
	for (const nif::SkinData &skin : mesh.skin_data) {
		int bad_weight_sum = 0;
		int bad_bone_index = 0;
		int unweighted_verts = 0;
		for (size_t v = 0; v < skin.vertex_bone_weights.size(); ++v) {
			float sum = 0.0f;
			for (int i = 0; i < 4; ++i) {
				sum += skin.vertex_bone_weights[v][i];
				if (skin.vertex_bone_weights[v][i] > 0.0f &&
						skin.vertex_bone_indices[v][i] >= skin.bone_names.size()) {
					bad_bone_index++;
				}
			}
			if (sum < 0.001f) {
				unweighted_verts++;
			} else if (sum < 0.8f || sum > 1.2f) {
				bad_weight_sum++;
			}
		}
		printf("  target=%-24s bones=%2zu verts=%5zu bad_weight_sum=%d bad_bone_index=%d unweighted=%d body_part_ids=%zu\n",
				skin.target_node_name.c_str(), skin.bone_names.size(), skin.vertex_bone_weights.size(),
				bad_weight_sum, bad_bone_index, unweighted_verts, skin.partition_body_part_ids.size());
		failures += bad_weight_sum + bad_bone_index + unweighted_verts;
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

	// Deliberately not just upperbody.nif: a creature (nvcazadores, wing
	// bones with no simple parent-bone chain) and a small standalone-skinned
	// prop (the flag -- plain NiSkinInstance, not BSDismemberSkinInstance,
	// real hierarchy fully self-contained unlike the body-part files) --
	// see issue #46's own research artifact for why these three were chosen
	// to catch variety, not just one file.
	const char *files[] = {
		"characters\\_male\\upperbody.nif",
		"creatures\\nvcazadores\\nvcazadores.nif",
		"creatures\\brahmin\\brahmin.nif",
		"clutter\\flags\\nv_ncr_flag.nif",
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
