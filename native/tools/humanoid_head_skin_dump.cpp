// One-off Nifly-backed audit for an NPC's authored head-part skinning.
//
// Reads the NPC's real RNAM/ACBS fields, asks EsmFile for the corresponding
// gendered RACE head parts, then reports each mesh's actual skin palette and
// vertex-weight coverage.  This deliberately does not infer that a visual
// hierarchy node is skinned from its name or transform.
#include "bsa/bsa_archive.h"
#include "common/byte_reader.h"
#include "esm/esm_file.h"
#include "nif/nif_loader.h"

#include <cstdio>
#include <exception>
#include <string>
#include <vector>

namespace {

struct NpcAppearance {
	uint32_t race_form_id = 0;
	uint32_t hair_form_id = 0;
	bool female = false;
};

bool read_npc_appearance(const esm::EsmFile &esm, uint32_t npc_form_id, NpcAppearance &out) {
	auto record = esm.find_record_by_form_id(npc_form_id);
	if (!record || record->type != "NPC_") {
		std::fprintf(stderr, "0x%08X is not an NPC_ record\n", npc_form_id);
		return false;
	}
	for (const esm::Subrecord &subrecord : esm::EsmFile::parse_subrecords(esm.read_record_data(*record))) {
		if (subrecord.type == "RNAM" && subrecord.size >= 4) {
			util::ByteReader reader(subrecord.data, subrecord.size);
			out.race_form_id = reader.read_u32();
		} else if (subrecord.type == "HNAM" && subrecord.size >= 4) {
			util::ByteReader reader(subrecord.data, subrecord.size);
			out.hair_form_id = reader.read_u32();
		} else if (subrecord.type == "ACBS" && subrecord.size >= 4) {
			util::ByteReader reader(subrecord.data, subrecord.size);
			out.female = (reader.read_u32() & 1u) != 0;
		}
	}
	return out.race_form_id != 0;
}

std::string model_path_for_record(const esm::EsmFile &esm, uint32_t form_id) {
	auto record = esm.find_record_by_form_id(form_id);
	if (!record) return "";
	for (const esm::Subrecord &subrecord : esm::EsmFile::parse_subrecords(esm.read_record_data(*record))) {
		if (subrecord.type == "MODL") return subrecord.as_string();
	}
	return "";
}

void dump_skin(const nif::SkinData &skin) {
	size_t weighted_vertices = 0;
	size_t total_influences = 0;
	float min_weight_sum = 1.0f;
	float max_weight_sum = 0.0f;
	std::vector<size_t> bone_vertex_counts(skin.bone_names.size());

	for (size_t vertex = 0; vertex < skin.vertex_bone_weights.size(); ++vertex) {
		float sum = 0.0f;
		for (int slot = 0; slot < 4; ++slot) {
			const float weight = skin.vertex_bone_weights[vertex][slot];
			if (weight <= 0.0f) continue;
			sum += weight;
			total_influences++;
			const uint16_t bone_index = skin.vertex_bone_indices[vertex][slot];
			if (bone_index < bone_vertex_counts.size()) bone_vertex_counts[bone_index]++;
		}
		if (sum > 0.0f) {
			weighted_vertices++;
			if (sum < min_weight_sum) min_weight_sum = sum;
			if (sum > max_weight_sum) max_weight_sum = sum;
		}
	}

	const nif::SkinBoneTransform &global_to_skin = skin.skin_to_global_transform;
	std::printf("  shape=%s bones=%zu vertices=%zu weighted=%zu influences=%zu weight_sum=[%.6f, %.6f] global_to_skin_translation=(%.6f, %.6f, %.6f)\n",
			skin.target_node_name.c_str(), skin.bone_names.size(), skin.vertex_bone_weights.size(),
			weighted_vertices, total_influences, min_weight_sum, max_weight_sum,
			global_to_skin.translation[0], global_to_skin.translation[1], global_to_skin.translation[2]);
	for (size_t bone = 0; bone < skin.bone_names.size(); ++bone) {
		const nif::SkinBoneTransform &bind = skin.bone_bind_transforms[bone];
		std::printf("    bone[%02zu] %-28s weighted_vertices=%zu bind_translation=(%.6f, %.6f, %.6f)\n",
				bone, skin.bone_names[bone].c_str(), bone_vertex_counts[bone],
				bind.translation[0], bind.translation[1], bind.translation[2]);
	}
}

int dump_head_part(bsa::BsaArchive &meshes, const esm::RaceBodyPart &part) {
	if (part.model_path.empty()) {
		std::printf("head_part[%u]: no MODL\n", part.index);
		return 0;
	}
	const std::string archive_path = "meshes\\" + part.model_path;
	const bsa::Entry *entry = meshes.find(archive_path);
	if (entry == nullptr) {
		std::printf("head_part[%u]: %s NOT FOUND\n", part.index, archive_path.c_str());
		return 1;
	}

	nif::Mesh mesh;
	try {
		mesh = nif::load_mesh(meshes.extract(*entry));
	} catch (const std::exception &e) {
		std::printf("head_part[%u]: %s LOAD FAILED: %s\n", part.index, archive_path.c_str(), e.what());
		return 1;
	}

	std::printf("head_part[%u]: %s\n", part.index, archive_path.c_str());
	std::printf("  submeshes=%zu skin_shapes=%zu scene_nodes=%zu\n",
			mesh.submeshes.size(), mesh.skin_data.size(), mesh.scene_nodes.size());
	for (const nif::SubMesh &submesh : mesh.submeshes) {
		std::printf("  submesh=%s local_translation=(%.6f, %.6f, %.6f) rotation=[%.3f %.3f %.3f; %.3f %.3f %.3f; %.3f %.3f %.3f]\n", submesh.name.c_str(),
				submesh.translation[0], submesh.translation[1], submesh.translation[2],
				submesh.rotation[0], submesh.rotation[1], submesh.rotation[2],
				submesh.rotation[3], submesh.rotation[4], submesh.rotation[5],
				submesh.rotation[6], submesh.rotation[7], submesh.rotation[8]);
	}
	for (size_t i = 0; i < mesh.scene_nodes.size(); ++i) {
		const nif::SceneNode &node = mesh.scene_nodes[i];
		std::printf("  scene[%zu] name=%s parent=%d local_translation=(%.6f, %.6f, %.6f) rotation=[%.3f %.3f %.3f; %.3f %.3f %.3f; %.3f %.3f %.3f]\n",
				i, node.name.c_str(), node.parent_index,
				node.translation[0], node.translation[1], node.translation[2],
				node.rotation[0], node.rotation[1], node.rotation[2],
				node.rotation[3], node.rotation[4], node.rotation[5],
				node.rotation[6], node.rotation[7], node.rotation[8]);
	}
	if (mesh.skin_data.empty()) {
		std::printf("  RESULT: no Nifly skin data\n");
		return 0;
	}
	for (const nif::SkinData &skin : mesh.skin_data) dump_skin(skin);
	return 0;
}

int dump_hair(bsa::BsaArchive &meshes, const std::string &model_path) {
	if (model_path.empty()) {
		std::printf("hair: no MODL\n");
		return 0;
	}
	const std::string archive_path = "meshes\\" + model_path;
	const bsa::Entry *entry = meshes.find(archive_path);
	if (entry == nullptr) {
		std::printf("hair: %s NOT FOUND\n", archive_path.c_str());
		return 1;
	}
	nif::Mesh mesh;
	try {
		mesh = nif::load_mesh(meshes.extract(*entry));
	} catch (const std::exception &e) {
		std::printf("hair: %s LOAD FAILED: %s\n", archive_path.c_str(), e.what());
		return 1;
	}
	std::printf("hair: %s\n", archive_path.c_str());
	std::printf("  submeshes=%zu skin_shapes=%zu scene_nodes=%zu\n",
			mesh.submeshes.size(), mesh.skin_data.size(), mesh.scene_nodes.size());
	for (const nif::SubMesh &submesh : mesh.submeshes) {
		std::printf("  submesh=%s local_translation=(%.6f, %.6f, %.6f) rotation=[%.3f %.3f %.3f; %.3f %.3f %.3f; %.3f %.3f %.3f]\n", submesh.name.c_str(),
				submesh.translation[0], submesh.translation[1], submesh.translation[2],
				submesh.rotation[0], submesh.rotation[1], submesh.rotation[2],
				submesh.rotation[3], submesh.rotation[4], submesh.rotation[5],
				submesh.rotation[6], submesh.rotation[7], submesh.rotation[8]);
	}
	for (size_t i = 0; i < mesh.scene_nodes.size(); ++i) {
		const nif::SceneNode &node = mesh.scene_nodes[i];
		std::printf("  scene[%zu] name=%s parent=%d local_translation=(%.6f, %.6f, %.6f) rotation=[%.3f %.3f %.3f; %.3f %.3f %.3f; %.3f %.3f %.3f]\n",
				i, node.name.c_str(), node.parent_index,
				node.translation[0], node.translation[1], node.translation[2],
				node.rotation[0], node.rotation[1], node.rotation[2],
				node.rotation[3], node.rotation[4], node.rotation[5],
				node.rotation[6], node.rotation[7], node.rotation[8]);
	}
	return 0;
}

} // namespace

int main(int argc, char **argv) {
	const uint32_t npc_form_id = argc > 1 ? static_cast<uint32_t>(std::strtoul(argv[1], nullptr, 0)) : 0x00104E84;
	esm::EsmFile esm;
	bsa::BsaArchive meshes;
	try {
		esm.open("fresh_nv_copy/Data/FalloutNV.esm");
		meshes.open("fresh_nv_copy/Data/Fallout - Meshes.bsa");
	} catch (const std::exception &e) {
		std::fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}

	NpcAppearance appearance;
	if (!read_npc_appearance(esm, npc_form_id, appearance)) return 1;
	std::printf("NPC 0x%08X: race=0x%08X hair=0x%08X gender=%s\n", npc_form_id, appearance.race_form_id,
			appearance.hair_form_id, appearance.female ? "female" : "male");

	const std::vector<esm::RaceBodyPart> parts = esm.get_race_head_parts(appearance.race_form_id, appearance.female);
	if (parts.empty()) {
		std::printf("No authored head parts for this race/gender.\n");
		return 0;
	}
	int failures = 0;
	for (const esm::RaceBodyPart &part : parts) failures += dump_head_part(meshes, part);
	if (appearance.hair_form_id != 0) failures += dump_hair(meshes, model_path_for_record(esm, appearance.hair_form_id));
	return failures == 0 ? 0 : 1;
}
