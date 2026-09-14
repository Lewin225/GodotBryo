// object_lod_census -- exhaustive REFR/VWD/_lod coverage for one exterior
// worldspace, using the same FalloutNV.esm and BSA-priority rules as runtime.
//
// Usage:
//   native/tools/object_lod_census fresh_nv_copy/Data [WastelandNV]
//
// This intentionally measures the live pipeline's source population rather
// than treating the global count of *_lod.nif assets as placement coverage.

#include "esm/esm_file.h"
#include "bsa/bsa_catalog.h"
#include "nif/nif_source.h"

#include <NifFile.hpp>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <set>
#include <sstream>
#include <map>
#include <string>
#include <vector>

namespace {

struct Counts {
	uint64_t references = 0;
	uint64_t vwd = 0;
	uint64_t vwd_without_model = 0;
	uint64_t vwd_non_nif_model = 0;
	uint64_t vwd_nif_model = 0;
	uint64_t vwd_with_lod = 0;
	uint64_t vwd_without_lod = 0;
	std::set<std::string> vwd_nif_models;
	std::set<std::string> vwd_models_with_lod;
};

std::string lower_slashes(std::string value);

struct ParseAudit {
	std::map<std::string, bool> result_by_lod_path;
	std::vector<std::string> failures;
	uint64_t files_with_lod_named_block = 0;
	std::map<std::string, uint64_t> root_block_types;
	std::map<std::string, uint64_t> lod_named_block_types;

	bool parse(const std::string &lod_path, const bsa::BsaArchiveCatalog &catalog) {
		auto cached = result_by_lod_path.find(lod_path);
		if (cached != result_by_lod_path.end()) {
			return cached->second;
		}
		bool success = false;
		try {
			auto bytes = catalog.read("meshes/" + lod_path);
			if (bytes.found) {
				nifsrc::load(bytes.data);
				success = true;
				// `_lod` can be a filename convention or a real in-NIF LOD
				// switch. Inspect raw block identities rather than guessing.
				std::string source(reinterpret_cast<const char *>(bytes.data.data()), bytes.data.size());
				std::istringstream stream(source, std::ios::binary);
				nifly::NifFile raw;
				if (raw.Load(stream) == 0) {
					auto &header = raw.GetHeader();
					if (auto *root = raw.GetRootNode()) {
						root_block_types[header.GetBlockTypeStringById(raw.GetBlockID(root))]++;
					}
					bool has_lod_named_block = false;
					for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
						const std::string type = header.GetBlockTypeStringById(i);
						if (lower_slashes(type).find("lod") != std::string::npos) {
							has_lod_named_block = true;
							lod_named_block_types[type]++;
						}
					}
					if (has_lod_named_block) {
						files_with_lod_named_block++;
					}
				}
			}
		} catch (const std::exception &) {
			success = false;
		}
		result_by_lod_path[lod_path] = success;
		if (!success) {
			failures.push_back(lod_path);
		}
		return success;
	}
};

std::string lower_slashes(std::string value) {
	std::replace(value.begin(), value.end(), '\\', '/');
	std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
		return static_cast<char>(std::tolower(c));
	});
	return value;
}

std::string lod_companion(const std::string &model_path) {
	const std::string normalized = lower_slashes(model_path);
	if (normalized.size() < 4 || normalized.substr(normalized.size() - 4) != ".nif") {
		return "";
	}
	return normalized.substr(0, normalized.size() - 4) + "_lod.nif";
}

void count(const esm::ReferencePlacement &placement, const bsa::BsaArchiveCatalog &catalog,
		Counts &counts, std::map<std::string, Counts> &by_type,
		ParseAudit &parse_audit, std::vector<std::string> &lod_examples,
		std::vector<std::string> &no_lod_examples) {
	counts.references++;
	by_type[placement.base_type].references++;
	if (!placement.visible_when_distant) {
		return;
	}

	auto apply = [&](Counts &target) {
		target.vwd++;
		if (placement.model_path.empty()) {
			target.vwd_without_model++;
			return;
		}
		const std::string model = lower_slashes(placement.model_path);
		const std::string lod = lod_companion(model);
		if (lod.empty()) {
			target.vwd_non_nif_model++;
			return;
		}
		target.vwd_nif_model++;
		target.vwd_nif_models.insert(model);
		if (catalog.contains("meshes/" + lod)) {
			parse_audit.parse(lod, catalog);
			target.vwd_with_lod++;
			target.vwd_models_with_lod.insert(model);
			if (lod_examples.size() < 8) {
				lod_examples.push_back(model + " -> " + lod);
			}
		} else {
			target.vwd_without_lod++;
			if (no_lod_examples.size() < 8) {
				no_lod_examples.push_back(model);
			}
		}
	};
	apply(counts);
	apply(by_type[placement.base_type]);
}

void print_counts(const char *label, const Counts &counts) {
	const double placement_coverage = counts.vwd_nif_model == 0 ? 0.0
		: 100.0 * static_cast<double>(counts.vwd_with_lod) / counts.vwd_nif_model;
	const double model_coverage = counts.vwd_nif_models.empty() ? 0.0
		: 100.0 * static_cast<double>(counts.vwd_models_with_lod.size()) / counts.vwd_nif_models.size();
	std::printf("%s\n", label);
	std::printf("  REFR placements: %llu; VWD: %llu (%.2f%% of REFR)\n",
		static_cast<unsigned long long>(counts.references),
		static_cast<unsigned long long>(counts.vwd),
		counts.references == 0 ? 0.0 : 100.0 * static_cast<double>(counts.vwd) / counts.references);
	std::printf("  VWD: no model=%llu; non-NIF model=%llu; NIF model=%llu\n",
		static_cast<unsigned long long>(counts.vwd_without_model),
		static_cast<unsigned long long>(counts.vwd_non_nif_model),
		static_cast<unsigned long long>(counts.vwd_nif_model));
	std::printf("  VWD NIF placements: companion=%llu; absent=%llu; coverage=%.2f%%\n",
		static_cast<unsigned long long>(counts.vwd_with_lod),
		static_cast<unsigned long long>(counts.vwd_without_lod), placement_coverage);
	std::printf("  Unique VWD NIF models: %zu; with companion=%zu; coverage=%.2f%%\n",
		counts.vwd_nif_models.size(), counts.vwd_models_with_lod.size(), model_coverage);
}

} // namespace

int main(int argc, char **argv) {
	const std::string data_dir = argc >= 2 ? argv[1] : "fresh_nv_copy/Data";
	const std::string world_editor_id = argc >= 3 ? argv[2] : "WastelandNV";

	esm::EsmFile esm;
	bsa::BsaArchiveCatalog catalog;
	try {
		esm.open(data_dir + "/FalloutNV.esm");
	} catch (const std::exception &error) {
		std::fprintf(stderr, "could not open FalloutNV.esm: %s\n", error.what());
		return 1;
	}
	std::string catalog_error;
	if (!catalog.open_data_dir(data_dir, catalog_error)) {
		std::fprintf(stderr, "could not open BSA catalog: %s\n", catalog_error.c_str());
		return 1;
	}
	auto world = esm.find_worldspace_by_editor_id(world_editor_id);
	if (!world) {
		std::fprintf(stderr, "worldspace not found: %s\n", world_editor_id.c_str());
		return 1;
	}

	Counts exterior;
	Counts persistent;
	std::map<std::string, Counts> by_type;
	std::set<uint32_t> exterior_cell_ids;
	std::vector<std::string> lod_examples;
	std::vector<std::string> no_lod_examples;
	ParseAudit parse_audit;

	// A CELL with XCLC is not necessarily an exterior grid tile: the WRLD
	// persistent cell can carry a placeholder (0,0). Verify it through the
	// world's actual Block/Sub-Block lookup before including it.
	esm.for_each_record([&](const esm::RecordInfo &record) {
		if (record.type != "CELL") {
			return;
		}
		auto owner = esm.get_cell_worldspace(record.form_id);
		auto grid = esm.get_exterior_cell_grid(record.form_id);
		if (!owner || !grid || *owner != world->form_id) {
			return;
		}
		auto indexed = esm.find_exterior_cell(*owner, grid->x, grid->y);
		if (!indexed || indexed->form_id != record.form_id || !exterior_cell_ids.insert(record.form_id).second) {
			return;
		}
		for (const auto &placement : esm.get_cell_references(record)) {
			count(placement, catalog, exterior, by_type, parse_audit, lod_examples, no_lod_examples);
		}
	});

	if (auto persistent_cell = esm.get_worldspace_persistent_cell(world->form_id)) {
		for (const auto &placement : esm.get_cell_references(*persistent_cell)) {
			count(placement, catalog, persistent, by_type, parse_audit, lod_examples, no_lod_examples);
		}
	}

	std::printf("=== %s (0x%08X), archive priority matches ArchiveServer ===\n",
		world_editor_id.c_str(), world->form_id);
	std::printf("Exterior grid CELLs: %zu\n", exterior_cell_ids.size());
	print_counts("Exterior grid references", exterior);
	print_counts("Persistent-cell references", persistent);
	std::printf("NifServer source parser: %zu / %zu unique referenced _lod files parse successfully\n",
		parse_audit.result_by_lod_path.size() - parse_audit.failures.size(), parse_audit.result_by_lod_path.size());
	for (const auto &failure : parse_audit.failures) {
		std::printf("  parser failure: %s\n", failure.c_str());
	}
	std::printf("Raw NIF LOD markers: %llu / %zu files contain a block type with 'LOD' in its name\n",
		static_cast<unsigned long long>(parse_audit.files_with_lod_named_block), parse_audit.result_by_lod_path.size());
	std::printf("Root block types:\n");
	for (const auto &[type, count] : parse_audit.root_block_types) {
		std::printf("  %s: %llu\n", type.c_str(), static_cast<unsigned long long>(count));
	}
	if (!parse_audit.lod_named_block_types.empty()) {
		std::printf("LOD-named block types:\n");
		for (const auto &[type, count] : parse_audit.lod_named_block_types) {
			std::printf("  %s: %llu\n", type.c_str(), static_cast<unsigned long long>(count));
		}
	}

	std::printf("By base record type (VWD NIF placements with companion / VWD NIF placements):\n");
	for (const auto &[type, counts] : by_type) {
		if (counts.vwd_nif_model == 0) {
			continue;
		}
		std::printf("  %-4s %llu / %llu (%.2f%%)\n", type.c_str(),
			static_cast<unsigned long long>(counts.vwd_with_lod),
			static_cast<unsigned long long>(counts.vwd_nif_model),
			100.0 * static_cast<double>(counts.vwd_with_lod) / counts.vwd_nif_model);
	}
	std::printf("Examples with companion:\n");
	for (const auto &example : lod_examples) {
		std::printf("  %s\n", example.c_str());
	}
	std::printf("Examples without companion:\n");
	for (const auto &example : no_lod_examples) {
		std::printf("  %s\n", example.c_str());
	}
	return 0;
}
