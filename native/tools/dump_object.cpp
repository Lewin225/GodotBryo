// dump_object — Phase 0.5 integration tool.
//
// Ties 0.1 (BSA reader) + 0.2 (ESM parser) + 0.3 (NIF parser) + 0.4 (DDS
// findings) together end-to-end: given an FNV install path and a STAT
// record identifier (FormID or EditorID), resolves its MODL subrecord to a
// NIF, locates that NIF (and every texture it references) across all of
// the install's BSAs, and emits a glTF + copied .dds files + a resolution
// log for manual inspection.
//
// Deliberately has NO dependency on Godot/godot-cpp — everything it calls
// (esm::EsmFile, bsa::BsaArchive, nif::load_mesh, nif::export_gltf) is
// plain C++ already, so this builds as a small standalone executable
// separate from the nv_engine GDExtension. See native/tools/build.sh.
//
// DDS *decoding* (turning compressed pixel data into something a glTF
// viewer can display) is intentionally NOT done here — that's Godot's own
// decoder (Image::load_dds_from_buffer), already exercised end-to-end with
// a real render in 0.4. This tool copies the raw, still-BSA-compressed
// .dds bytes out for inspection instead. See phases/0/05-integration-tool.md.

#include "../src/bsa/bsa_archive.h"
#include "../src/esm/esm_file.h"
#include "../src/nif/gltf_export.h"
#include "../src/nif/nif_loader.h"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

std::string to_lower(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
	return s;
}

std::string backslashes_to_forward(std::string s) {
	std::replace(s.begin(), s.end(), '\\', '/');
	return s;
}

// Not a simulation of the game's real plugin/archive load order (that's a
// Phase 1 problem once multiple masters are loaded) — a pragmatic
// approximation good enough for Phase 0's single-master, no-mod-esp case:
// Update.bsa is the official always-last-applied patch archive (confirmed
// necessary in 0.3 — NVGuardTower01a.nif only exists there), DLC archives
// come next (newest-content-wins is a reasonable default), then the base
// game's own SArchiveList (from Fallout_default.ini) in *reverse* — later
// entries in that list are understood to take priority over earlier ones
// for the Gamebryo archive loader — and finally anything else alphabetically
// as a catch-all.
std::vector<std::string> priority_order(const std::vector<std::string> &all_bsas) {
	std::vector<std::string> order;
	std::vector<std::string> remaining = all_bsas;

	auto take = [&](const std::string &name) {
		for (auto it = remaining.begin(); it != remaining.end(); ++it) {
			if (to_lower(fs::path(*it).filename().string()) == to_lower(name)) {
				order.push_back(*it);
				remaining.erase(it);
				return;
			}
		}
	};

	take("Update.bsa");

	// DLC archives: anything left whose name doesn't start with "Fallout - ".
	std::vector<std::string> dlc;
	for (const auto &p : remaining) {
		std::string fname = fs::path(p).filename().string();
		if (fname.rfind("Fallout - ", 0) != 0) {
			dlc.push_back(p);
		}
	}
	std::sort(dlc.begin(), dlc.end());
	for (const auto &p : dlc) {
		order.push_back(p);
		remaining.erase(std::find(remaining.begin(), remaining.end(), p));
	}

	// Base game SArchiveList, reversed.
	static const char *base_order[] = {
		"Fallout - Misc.bsa",
		"Fallout - Sound.bsa",
		"Fallout - Voices1.bsa",
		"Fallout - Meshes.bsa",
		"Fallout - Textures2.bsa",
		"Fallout - Textures.bsa",
	};
	for (const char *name : base_order) {
		take(name);
	}

	std::sort(remaining.begin(), remaining.end());
	for (const auto &p : remaining) {
		order.push_back(p);
	}
	return order;
}

// Opens BSAs lazily and keeps them open for the lifetime of the run —
// resolving a single object touches its NIF plus several textures, each of
// which needs to be checked against every archive in priority order, so
// reopening archives per-lookup would mean re-parsing the same directory
// tables repeatedly.
class ArchiveCache {
public:
	explicit ArchiveCache(std::vector<std::string> order) :
			order_(std::move(order)) {}

	struct Found {
		std::string bsa_path;
		std::vector<uint8_t> data;
	};

	std::optional<Found> resolve(const std::string &rel_path) {
		std::string norm = backslashes_to_forward(rel_path);
		for (const auto &bsa_path : order_) {
			bsa::BsaArchive *archive = get(bsa_path);
			if (!archive) {
				continue;
			}
			const bsa::Entry *entry = archive->find(norm);
			if (entry) {
				return Found{ bsa_path, archive->extract(*entry) };
			}
		}
		return std::nullopt;
	}

private:
	std::vector<std::string> order_;
	std::map<std::string, std::unique_ptr<bsa::BsaArchive>> opened_;
	std::map<std::string, bool> failed_;

	bsa::BsaArchive *get(const std::string &path) {
		auto it = opened_.find(path);
		if (it != opened_.end()) {
			return it->second.get();
		}
		if (failed_.count(path)) {
			return nullptr;
		}
		auto archive = std::make_unique<bsa::BsaArchive>();
		try {
			archive->open(path);
		} catch (const std::exception &e) {
			std::cerr << "  (warning: could not open " << path << ": " << e.what() << ")\n";
			failed_[path] = true;
			return nullptr;
		}
		bsa::BsaArchive *ptr = archive.get();
		opened_[path] = std::move(archive);
		return ptr;
	}
};

struct StatCandidate {
	uint32_t form_id;
	std::string edid;
	std::string model_path;
};

std::vector<StatCandidate> collect_stat_candidates(const esm::EsmFile &esm_file) {
	std::vector<StatCandidate> out;
	esm_file.for_each_record([&](const esm::RecordInfo &r) {
		if (r.type != "STAT") {
			return;
		}
		std::vector<uint8_t> data = esm_file.read_record_data(r);
		std::vector<esm::Subrecord> subs = esm::EsmFile::parse_subrecords(data);
		std::string edid, model;
		for (const auto &s : subs) {
			if (s.type == "EDID") {
				edid = s.as_string();
			} else if (s.type == "MODL") {
				model = s.as_string();
			}
		}
		if (!model.empty()) {
			out.push_back({ r.form_id, edid, model });
		}
	});
	return out;
}

struct TextureResult {
	std::string texture_path;
	std::string bsa_path; // empty if not found
	size_t bytes = 0;
	std::string dds_variant; // FourCC (DXT1/DXT3/DXT5) or "(uncompressed)"/"?"
};

// Reads the DDS pixel-format FourCC at the fixed header offset (byte 84).
// See phases/0/04-dds-texture-import.md's format survey — this is the same
// check used there, repeated here so each dump_object run's log records
// which BC variant it actually saw for that specific texture.
std::string dds_fourcc(const std::vector<uint8_t> &data) {
	if (data.size() < 88) {
		return "?";
	}
	std::string s(reinterpret_cast<const char *>(data.data() + 84), 4);
	bool printable = true;
	for (char c : s) {
		if (c < 32 || c > 126) {
			printable = false;
			break;
		}
	}
	return printable ? s : "(uncompressed)";
}

struct ObjectResult {
	StatCandidate candidate;
	std::string mesh_bsa;
	std::string nif_version;
	int submesh_count = 0;
	std::vector<TextureResult> textures;
	std::vector<std::string> warnings;
	fs::path output_dir;
};

std::string sanitize_filename(const std::string &s) {
	std::string out;
	for (char c : s) {
		bool keep = std::isalnum(static_cast<unsigned char>(c)) || c == '.';
		out.push_back(keep ? c : '_');
	}
	return out.empty() ? "unnamed" : out;
}

std::optional<ObjectResult> process_object(const StatCandidate &cand, ArchiveCache &cache, const fs::path &out_root) {
	ObjectResult result;
	result.candidate = cand;

	// MODL subrecords store paths relative to Data/Meshes/ (no "meshes\"
	// prefix) — BSA entries store the full "meshes/..." path. Discovered by
	// this integration tool: 0.2 never actually resolved a MODL path
	// through the BSA reader, and 0.3's tests used hand-written "meshes/..."
	// paths rather than ones sourced from an ESM record, so this mismatch
	// slipped through both sub-tasks individually. See phases/0/results.md.
	std::string mesh_lookup = "meshes\\" + cand.model_path;
	auto mesh_found = cache.resolve(mesh_lookup);
	if (!mesh_found) {
		std::cerr << "  SKIP " << cand.edid << " (0x" << std::hex << cand.form_id << std::dec
				  << "): NIF not found in any BSA: " << mesh_lookup << "\n";
		return std::nullopt;
	}
	result.mesh_bsa = mesh_found->bsa_path;

	nif::Mesh mesh;
	try {
		mesh = nif::load_mesh(mesh_found->data);
	} catch (const std::exception &e) {
		std::cerr << "  SKIP " << cand.edid << ": NIF parse failed: " << e.what() << "\n";
		return std::nullopt;
	}
	if (mesh.submeshes.empty()) {
		std::cerr << "  SKIP " << cand.edid << ": NIF parsed but has no renderable submeshes\n";
		return std::nullopt;
	}
	result.nif_version = mesh.nif_version;
	result.submesh_count = static_cast<int>(mesh.submeshes.size());

	std::string dirname = sanitize_filename(cand.edid.empty() ? cand.model_path : cand.edid);
	fs::path out_dir = out_root / dirname;
	fs::create_directories(out_dir / "textures");
	result.output_dir = out_dir;

	std::map<std::string, bool> texture_seen;
	int textures_found = 0;
	for (const auto &sub : mesh.submeshes) {
		if (sub.texture_path.empty() || texture_seen.count(sub.texture_path)) {
			continue;
		}
		texture_seen[sub.texture_path] = true;

		TextureResult tr;
		tr.texture_path = sub.texture_path;
		auto tex_found = cache.resolve(sub.texture_path);
		if (tex_found) {
			tr.bsa_path = tex_found->bsa_path;
			tr.bytes = tex_found->data.size();
			tr.dds_variant = dds_fourcc(tex_found->data);
			std::string tex_filename = sanitize_filename(fs::path(backslashes_to_forward(sub.texture_path)).filename().string());
			std::ofstream f(out_dir / "textures" / tex_filename, std::ios::binary);
			f.write(reinterpret_cast<const char *>(tex_found->data.data()), static_cast<std::streamsize>(tex_found->data.size()));
			++textures_found;
		} else {
			result.warnings.push_back("texture not found in any BSA: " + sub.texture_path);
		}
		result.textures.push_back(tr);
	}
	if (textures_found == 0) {
		result.warnings.push_back("no textures resolved for this object (geometry-only glTF)");
	}

	try {
		nif::export_gltf(mesh, (out_dir / "model.gltf").string());
	} catch (const std::exception &e) {
		std::cerr << "  SKIP " << cand.edid << ": glTF export failed: " << e.what() << "\n";
		return std::nullopt;
	}

	std::ofstream log(out_dir / "resolution_log.txt");
	log << "EditorID: " << cand.edid << "\n";
	log << "FormID: 0x" << std::hex << cand.form_id << std::dec << "\n";
	log << "MODL (raw): " << cand.model_path << "\n";
	log << "NIF resolved from: " << result.mesh_bsa << "\n";
	log << "NIF version: " << result.nif_version << "\n";
	log << "Submesh count: " << result.submesh_count << "\n";
	log << "Textures:\n";
	for (const auto &t : result.textures) {
		log << "  " << t.texture_path << " -> "
			<< (t.bsa_path.empty() ? std::string("NOT FOUND")
									: (t.bsa_path + " (" + std::to_string(t.bytes) + " bytes, " + t.dds_variant + ")"))
			<< "\n";
	}
	if (!result.warnings.empty()) {
		log << "Warnings:\n";
		for (const auto &w : result.warnings) {
			log << "  - " << w << "\n";
		}
	}

	std::cout << "  OK   " << cand.edid << "  (0x" << std::hex << cand.form_id << std::dec << ")  "
			  << result.submesh_count << " submesh(es), " << textures_found << "/" << result.textures.size()
			  << " textures resolved, from " << fs::path(result.mesh_bsa).filename().string() << "\n";

	return result;
}

} // namespace

int main(int argc, char **argv) {
	// Hardcoded default per phases/0/05-integration-tool.md: "Hardcode this
	// path as the default for Phase 0 tooling rather than requiring it be
	// passed every run — it's a fixed reference copy, not a variable input
	// yet." Overridable via argv[1] for portability.
	std::string install_path = argc > 1 ? argv[1] : "fresh_nv_copy";
	std::string out_dir_arg = argc > 2 ? argv[2] : "dump_object_output";
	int target_count = argc > 3 ? std::atoi(argv[3]) : 10;

	fs::path data_dir = fs::path(install_path) / "Data";
	fs::path out_root = out_dir_arg;
	fs::create_directories(out_root);

	std::cout << "dump_object: install=" << install_path << "  out=" << out_root << "\n";

	std::vector<std::string> all_bsas;
	for (const auto &entry : fs::directory_iterator(data_dir)) {
		if (to_lower(entry.path().extension().string()) == ".bsa") {
			all_bsas.push_back(entry.path().string());
		}
	}
	std::cout << "Found " << all_bsas.size() << " BSA archives in " << data_dir << "\n";

	std::vector<std::string> order = priority_order(all_bsas);
	std::cout << "Search priority order:\n";
	for (const auto &p : order) {
		std::cout << "  " << fs::path(p).filename().string() << "\n";
	}

	esm::EsmFile esm_file;
	esm_file.open((data_dir / "FalloutNV.esm").string());
	std::cout << "Opened FalloutNV.esm, version " << esm_file.header().version << "\n";

	std::vector<StatCandidate> candidates = collect_stat_candidates(esm_file);
	std::cout << "Found " << candidates.size() << " STAT records with a MODL subrecord\n";

	ArchiveCache cache(order);

	std::vector<ObjectResult> results;
	std::vector<std::string> skipped_notes;

	// Seed with the NVGuardTower01a object carried through 0.2/0.3/0.4 for
	// continuity, then fill out the rest with a spread across the file
	// (STAT records are grouped near other content from the same area, so
	// spreading the starting index gives area/BSA/texture-format variety
	// "for free" without hand-picking specific objects).
	std::vector<size_t> tried;
	auto try_index = [&](size_t idx) {
		if (idx >= candidates.size() || static_cast<int>(results.size()) >= target_count) {
			return;
		}
		for (size_t t : tried) {
			if (t == idx) {
				return;
			}
		}
		tried.push_back(idx);
		auto r = process_object(candidates[idx], cache, out_root);
		if (r) {
			results.push_back(std::move(*r));
		}
	};

	for (size_t i = 0; i < candidates.size(); ++i) {
		if (candidates[i].form_id == 0x0017B7B5) {
			try_index(i);
			break;
		}
	}

	if (!candidates.empty()) {
		size_t stride = std::max<size_t>(1, candidates.size() / (target_count * 3));
		for (size_t idx = 0; idx < candidates.size() && static_cast<int>(results.size()) < target_count; idx += stride) {
			try_index(idx);
		}
	}
	// If the spread pass didn't reach target_count (some picks fail to
	// resolve), fall back to a dense forward scan to fill the rest.
	for (size_t idx = 0; idx < candidates.size() && static_cast<int>(results.size()) < target_count; ++idx) {
		try_index(idx);
	}

	std::cout << "\n=======================\n";
	std::cout << results.size() << "/" << target_count << " objects resolved successfully "
			  << "(" << tried.size() << " candidates attempted)\n";
	int multi_submesh = 0;
	std::map<std::string, int> bsa_source_counts;
	std::map<std::string, int> tex_bsa_counts;
	std::map<std::string, int> dds_variant_counts;
	for (const auto &r : results) {
		if (r.submesh_count > 1) {
			++multi_submesh;
		}
		bsa_source_counts[fs::path(r.mesh_bsa).filename().string()]++;
		for (const auto &t : r.textures) {
			if (!t.bsa_path.empty()) {
				tex_bsa_counts[fs::path(t.bsa_path).filename().string()]++;
				dds_variant_counts[t.dds_variant]++;
			}
		}
	}
	std::cout << multi_submesh << "/" << results.size() << " are multi-submesh\n";
	std::cout << "Mesh BSA sources: ";
	for (const auto &[name, count] : bsa_source_counts) {
		std::cout << name << "=" << count << " ";
	}
	std::cout << "\nTexture BSA sources: ";
	for (const auto &[name, count] : tex_bsa_counts) {
		std::cout << name << "=" << count << " ";
	}
	std::cout << "\nDDS variants seen: ";
	for (const auto &[name, count] : dds_variant_counts) {
		std::cout << name << "=" << count << " ";
	}
	std::cout << "\n";

	return results.empty() ? 1 : 0;
}
