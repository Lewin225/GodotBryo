// Exhaustive Fallout: New Vegas locomotion KF census.
// Reports every resolved .kf sequence's transform targets and key counts.
// This deliberately reads the shipped BSA data directly; it does not infer
// upper/lower layers from filenames.
#include "bsa/bsa_archive.h"

#include <Animation.hpp>
#include <NifFile.hpp>

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

static std::string lower(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
	return s;
}

struct ArchiveIndex {
	std::vector<std::unique_ptr<bsa::BsaArchive>> archives;
	std::map<std::string, std::pair<size_t, size_t>> files;

	void open_all(const std::string &data_dir) {
		std::vector<std::string> names;
		for (const auto &entry : fs::directory_iterator(data_dir))
			if (lower(entry.path().extension().string()) == ".bsa") names.push_back(entry.path().filename().string());
		std::sort(names.begin(), names.end());
		std::stable_sort(names.begin(), names.end(), [](const std::string &a, const std::string &b) {
			return lower(a) == "update.bsa" && lower(b) != "update.bsa";
		});
		for (const auto &name : names) {
			auto archive = std::make_unique<bsa::BsaArchive>();
			try { archive->open(data_dir + "/" + name); } catch (...) { continue; }
			size_t archive_index = archives.size();
			for (size_t i = 0; i < archive->entries().size(); ++i) {
				const auto &e = archive->entries()[i];
				std::string path = lower(e.folder + "\\" + e.file);
				// Earlier archives win, matching the resolver's override behavior.
				files.emplace(path, std::make_pair(archive_index, i));
			}
			archives.push_back(std::move(archive));
		}
	}

	std::vector<uint8_t> extract(const std::string &path) const {
		auto it = files.find(lower(path));
		if (it == files.end()) return {};
		const auto &archive = *archives[it->second.first];
		return archive.extract(archive.entries()[it->second.second]);
	}
};

static std::string category(const std::set<std::string> &s) {
	if (s.empty()) return "none";
	if (s.size() == 1) return *s.begin();
	return "mixed";
}

int main(int argc, char **argv) {
	if (argc < 2) {
		std::cerr << "usage: locomotion_bone_census <DataDir> [path-substring]\n";
		return 1;
	}
	const std::string data_dir = argv[1];
	const std::string filter = argc >= 3 ? lower(argv[2]) : "characters\\_male\\locomotion\\";
	ArchiveIndex index;
	index.open_all(data_dir);

	// Skeleton bone names are the authoritative target set for classification.
	std::set<std::string> bones;
	for (const std::string &skeleton_path : {"meshes\\characters\\_male\\skeleton.nif", "meshes\\characters\\_female\\skeleton.nif"}) {
		auto bytes = index.extract(skeleton_path);
		if (bytes.empty()) continue;
		std::string raw(bytes.begin(), bytes.end());
		std::istringstream stream(raw, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) continue;
		for (uint32_t i = 0; i < nif.GetHeader().GetNumBlocks(); ++i) {
			auto *av = nif.GetHeader().GetBlock<nifly::NiAVObject>(i);
			if (av) bones.insert(lower(av->name.get()));
		}
	}

	std::cout << "file,sequence,duration,controlled_blocks,targets,transform_targets,position_tracks,unknown_targets,root_targets,nonaccum_targets,interpolator_types,target_names\n";
	std::map<std::string, int> file_count, target_count;
	int sequence_count = 0;
	for (const auto &[path, location] : index.files) {
		if (path.size() < 3 || path.substr(path.size() - 3) != ".kf" || path.find(filter) == std::string::npos) continue;
		auto bytes = index.extract(path);
		if (bytes.empty()) continue;
		std::string raw(bytes.begin(), bytes.end());
		std::istringstream stream(raw, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) continue;
		for (uint32_t i = 0; i < nif.GetHeader().GetNumBlocks(); ++i) {
			auto *seq = nif.GetHeader().GetBlock<nifly::NiControllerSequence>(i);
			if (!seq) continue;
			std::set<std::string> targets, unknown, root, nonaccum;
			std::map<std::string, int> interpolator_types;
			int transform = 0, position = 0;
			for (const auto &link : seq->controlledBlocks) {
				std::string target = link.nodeName.get();
				std::string target_lower = lower(target);
				auto *interp = nif.GetHeader().GetBlock<nifly::NiInterpolator>(link.interpolatorRef);
				if (interp) interpolator_types[interp->GetBlockName()]++;
				auto *spline = dynamic_cast<nifly::NiBSplineTransformInterpolator *>(interp);
				if (spline) {
					auto *basis = nif.GetHeader().GetBlock<nifly::NiBSplineBasisData>(spline->basisDataRef);
					if (!basis || basis->numControlPoints == 0) continue;
					targets.insert(target);
					transform++;
					if (spline->translationOffset != 65535) position++;
					if (!bones.empty() && !bones.count(target_lower)) unknown.insert(target);
					if (target_lower == "bip01" || target_lower == "scene root") root.insert(target);
					if (target_lower.find("nonaccum") != std::string::npos) nonaccum.insert(target);
					continue;
				}
				auto *xform = dynamic_cast<nifly::NiTransformInterpolator *>(interp);
				if (!xform) continue;
				auto *data = nif.GetHeader().GetBlock<nifly::NiTransformData>(xform->dataRef);
				if (!data) continue;
				targets.insert(target);
				transform++;
				int pos_keys = data->translations.GetNumKeys();
				if (pos_keys > 0) position++;
				if (!bones.empty() && !bones.count(target_lower)) unknown.insert(target);
				if (target_lower == "bip01" || target_lower == "scene root") root.insert(target);
				if (target_lower.find("nonaccum") != std::string::npos) nonaccum.insert(target);
			}
			if (targets.empty()) continue;
			sequence_count++;
			file_count[path]++;
			for (const auto &target : targets) target_count[target]++;
			std::string target_names;
			for (const auto &target : targets) {
				if (!target_names.empty()) target_names += ';';
				target_names += target;
			}
			std::string interp_names;
			for (const auto &[name, count] : interpolator_types) {
				if (!interp_names.empty()) interp_names += ';';
				interp_names += name + ":" + std::to_string(count);
			}
			std::cout << path << ',' << seq->name.get() << ',' << (seq->stopTime - seq->startTime) << ','
				  << seq->controlledBlocks.size() << ',' << targets.size() << ',' << transform << ',' << position << ','
				  << unknown.size() << ',' << root.size() << ',' << nonaccum.size() << ',' << interp_names << ',' << target_names << '\n';
		}
	}
	std::cerr << "sequences=" << sequence_count << " files=" << file_count.size() << " unique_targets=" << target_count.size() << " skeleton_bones=" << bones.size() << "\n";
	return 0;
}
