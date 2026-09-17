// Exhaustive official equipment/nude-body Nifly partition census.
//
// Reads the committed equipment_nifs.csv population, resolves every referenced
// NIF through the installed official BSAs, and reports only partition metadata
// and triangle assignments. No game asset data is written back out.
#include "bsa/bsa_archive.h"
#include "NifFile.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

enum class Family { Base, SectionCap, TorsoCap, TorsoSection, Other };

static Family family(uint16_t id) {
	if (id <= 13) return Family::Base;
	if (id >= 101 && id <= 113) return Family::SectionCap;
	if (id >= 201 && id <= 213) return Family::TorsoCap;
	if (id >= 1000 && id <= 13000 && id % 1000 == 0) return Family::TorsoSection;
	return Family::Other;
}

static const char *family_name(Family value) {
	switch (value) {
	case Family::Base: return "base";
	case Family::SectionCap: return "section_cap";
	case Family::TorsoCap: return "torso_cap";
	case Family::TorsoSection: return "torso_section";
	case Family::Other: return "other";
	}
	return "unknown";
}

static std::string first_csv_field(const std::string &line) {
	if (line.size() < 3 || line.front() != '"') return {};
	const size_t end = line.find('"', 1);
	return end == std::string::npos ? std::string{} : line.substr(1, end - 1);
}

int main() {
	std::ifstream input("enginedocs/equipment_census/equipment_nifs.csv");
	if (!input) {
		std::fprintf(stderr, "could not open equipment_nifs.csv\n");
		return 1;
	}
	std::set<std::string> paths;
	std::string line;
	std::getline(input, line); // CSV header
	while (std::getline(input, line)) {
		const std::string path = first_csv_field(line);
		if (!path.empty()) paths.insert(path);
	}

	std::vector<std::unique_ptr<bsa::BsaArchive>> archives;
	std::vector<fs::path> archive_paths;
	for (const auto &entry : fs::directory_iterator("fresh_nv_copy/Data")) {
		if (entry.path().extension() == ".bsa") archive_paths.push_back(entry.path());
	}
	std::sort(archive_paths.begin(), archive_paths.end());
	for (const fs::path &path : archive_paths) {
		auto archive = std::make_unique<bsa::BsaArchive>();
		try {
			archive->open(path.string());
			archives.push_back(std::move(archive));
		} catch (const std::exception &error) {
			std::fprintf(stderr, "warning: %s: %s\n", path.string().c_str(), error.what());
		}
	}

	struct Stats {
		size_t shapes = 0;
		size_t records = 0;
		size_t triangles = 0;
		size_t visible_records = 0;
		size_t start_boneset_records = 0;
		size_t visible_triangles = 0;
		size_t hidden_triangles = 0;
	};
	std::map<Family, Stats> stats;
	std::map<uint16_t, std::set<uint16_t>> flags_by_id;
	std::map<Family, size_t> visible_exceptions;
	size_t loaded = 0, missing = 0, parse_errors = 0, skinned_shapes = 0;
	size_t bad_parallel = 0, unassigned_triangles = 0, mixed_visibility_shapes = 0;
	std::vector<std::string> mixed_details;

	for (const std::string &relative : paths) {
		const bsa::Entry *entry = nullptr;
		bsa::BsaArchive *owner = nullptr;
		const std::string archive_path = "meshes\\" + relative;
		for (const auto &archive : archives) {
			entry = archive->find(archive_path);
			if (entry != nullptr) { owner = archive.get(); break; }
		}
		if (owner == nullptr) { missing++; continue; }
		const std::vector<uint8_t> bytes = owner->extract(*entry);
		std::stringstream stream(std::string(reinterpret_cast<const char *>(bytes.data()), bytes.size()));
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) { parse_errors++; continue; }
		loaded++;
		for (nifly::NiShape *shape : nif.GetShapes()) {
			nifly::NiVector<nifly::BSDismemberSkinInstance::PartitionInfo> partitions;
			std::vector<int> triangle_partitions;
			if (!nif.GetShapePartitions(shape, partitions, triangle_partitions)) continue;
			skinned_shapes++;
			std::vector<nifly::Triangle> triangles;
			shape->GetTriangles(triangles);
			if (triangles.size() != triangle_partitions.size()) bad_parallel++;
			bool saw_visible = false, saw_hidden = false;
			for (size_t index = 0; index < partitions.size(); ++index) {
				const auto &partition = partitions[index];
				const bool visible = (partition.flags & nifly::PF_EDITOR_VISIBLE) != 0;
				const Family group = family(partition.partID);
				Stats &out = stats[group];
				out.records++;
				if (visible) out.visible_records++;
				if ((partition.flags & nifly::PF_START_NET_BONESET) != 0) out.start_boneset_records++;
				flags_by_id[partition.partID].insert(partition.flags);
				saw_visible = saw_visible || visible;
				saw_hidden = saw_hidden || !visible;
			}
			if (saw_visible && saw_hidden) {
				mixed_visibility_shapes++;
				std::ostringstream detail;
				detail << relative << " :: " << shape->name.get() << " ::";
				for (const auto &partition : partitions) {
					detail << ' ' << partition.partID << "(0x" << std::hex << partition.flags << std::dec << ')';
				}
				mixed_details.push_back(detail.str());
			}
			for (int partition_index : triangle_partitions) {
				if (partition_index < 0 || partition_index >= static_cast<int>(partitions.size())) {
					unassigned_triangles++;
					continue;
				}
				const auto &partition = partitions[partition_index];
				Stats &out = stats[family(partition.partID)];
				out.triangles++;
				if ((partition.flags & nifly::PF_EDITOR_VISIBLE) != 0) out.visible_triangles++;
				else out.hidden_triangles++;
			}
			for (Family group : {Family::Base, Family::SectionCap, Family::TorsoCap, Family::TorsoSection}) {
				// Count records that violate the family-level visibility pattern,
				// rather than assuming the examples represent all shipped content.
				for (const auto &partition : partitions) {
					if (family(partition.partID) != group) continue;
					const bool visible = (partition.flags & nifly::PF_EDITOR_VISIBLE) != 0;
					if ((group == Family::SectionCap || group == Family::TorsoCap) ? visible : !visible)
						visible_exceptions[group]++;
				}
			}
		}
	}

	std::printf("paths=%zu loaded=%zu missing=%zu parse_errors=%zu\n", paths.size(), loaded, missing, parse_errors);
	std::printf("skinned_shapes=%zu bad_parallel=%zu unassigned_triangles=%zu mixed_visibility_shapes=%zu\n",
		skinned_shapes, bad_parallel, unassigned_triangles, mixed_visibility_shapes);
	for (Family group : {Family::Base, Family::SectionCap, Family::TorsoCap, Family::TorsoSection, Family::Other}) {
		const Stats &out = stats[group];
		std::printf("%s: records=%zu visible_records=%zu start_boneset=%zu triangles=%zu visible_triangles=%zu hidden_triangles=%zu visibility_exceptions=%zu\n",
			family_name(group), out.records, out.visible_records, out.start_boneset_records, out.triangles,
			out.visible_triangles, out.hidden_triangles, visible_exceptions[group]);
	}
	for (const auto &[id, values] : flags_by_id) {
		std::printf("id=%u family=%s flags=", static_cast<unsigned>(id), family_name(family(id)));
		bool first = true;
		for (uint16_t value : values) {
			std::printf("%s0x%04x", first ? "" : "|", static_cast<unsigned>(value));
			first = false;
		}
		std::printf("\n");
	}
	for (const std::string &detail : mixed_details) std::printf("mixed=%s\n", detail.c_str());
	return 0;
}
