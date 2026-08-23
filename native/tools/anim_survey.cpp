// anim_survey — throwaway research tool for scoping the animation-data
// extraction work (phases/3/00-door-completion.md). Scans real NIFs for
// NiControllerManager/NiControllerSequence content and reports what's
// ACTUALLY used: which interpolator/controller subtypes, key
// counts/interpolation types, target-node counts per sequence -- so the
// native parser is scoped to real FNV content, not nifly's full (much
// broader) animation class hierarchy.
//
// Usage: anim_survey <DataDir> --list <substr> [max]   # NIFs with a NiControllerManager
//        anim_survey <DataDir> --dump <substr> [max]    # full sequence/track dump

#include "../src/bsa/bsa_archive.h"

#include <Animation.hpp>
#include <NifFile.hpp>
#include <Objects.hpp>

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

static std::string to_lower(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
	return s;
}

struct Archives {
	std::vector<std::unique_ptr<bsa::BsaArchive>> readers;
	std::map<std::string, std::pair<size_t, size_t>> index;

	void open_all(const std::string &data_dir) {
		std::vector<std::string> names;
		for (auto &p : fs::directory_iterator(data_dir))
			if (to_lower(p.path().extension().string()) == ".bsa")
				names.push_back(p.path().filename().string());
		std::vector<std::string> ordered;
		auto take = [&](const std::string &n) {
			auto it = std::find(names.begin(), names.end(), n);
			if (it != names.end()) { ordered.push_back(n); names.erase(it); }
		};
		take("Update.bsa");
		std::vector<std::string> dlc;
		for (auto &n : names)
			if (n.rfind("Fallout - ", 0) != 0) dlc.push_back(n);
		std::sort(dlc.begin(), dlc.end());
		for (auto &n : dlc) take(n);
		std::sort(names.begin(), names.end());
		for (auto &n : names) ordered.push_back(n);

		for (auto &n : ordered) {
			auto r = std::make_unique<bsa::BsaArchive>();
			try { r->open(data_dir + "/" + n); } catch (...) { continue; }
			size_t ri = readers.size();
			const auto &es = r->entries();
			for (size_t ei = 0; ei < es.size(); ++ei) {
				std::string full = to_lower(es[ei].folder + "\\" + es[ei].file);
				if (!index.count(full)) index[full] = { ri, ei };
			}
			readers.push_back(std::move(r));
		}
	}

	std::vector<uint8_t> extract(const std::string &lower_path) {
		auto it = index.find(lower_path);
		if (it == index.end()) return {};
		auto &r = *readers[it->second.first];
		return r.extract(r.entries()[it->second.second]);
	}
};

static const char *key_type_name(nifly::NiKeyType t) {
	switch (t) {
		case nifly::NO_INTERP: return "NO_INTERP";
		case nifly::LINEAR_KEY: return "LINEAR";
		case nifly::QUADRATIC_KEY: return "QUADRATIC";
		case nifly::TBC_KEY: return "TBC";
		case nifly::XYZ_ROTATION_KEY: return "XYZ_ROTATION";
		case nifly::CONST_KEY: return "CONST";
	}
	return "?";
}

static void dump_transform_data(nifly::NifFile &nif, nifly::NiTransformData *td, const std::string &indent) {
	std::cout << indent << "NiTransformData: rotationType=";
	auto rt = td->rotationType;
	std::cout << (int)rt << " (" << key_type_name(rt) << ")";
	std::cout << " quatKeys=" << td->quaternionKeys.size();
	if (!td->quaternionKeys.empty())
		std::cout << " [" << key_type_name(td->quaternionKeys[0].type) << "]";
	std::cout << " xRot=" << td->xRotations.GetNumKeys()
			  << " yRot=" << td->yRotations.GetNumKeys()
			  << " zRot=" << td->zRotations.GetNumKeys()
			  << " translations=" << td->translations.GetNumKeys();
	if (td->translations.GetNumKeys() > 0)
		std::cout << "[" << key_type_name(td->translations.GetInterpolationType()) << "]";
	std::cout << " scales=" << td->scales.GetNumKeys() << "\n";
}

int main(int argc, char **argv) {
	if (argc < 4) {
		std::cerr << "usage: anim_survey <DataDir> --list|--dump <substr> [max]\n";
		return 1;
	}
	std::string data_dir = argv[1], mode = argv[2], pat = to_lower(argv[3]);
	int max_n = argc > 4 ? std::atoi(argv[4]) : 25;

	Archives arc;
	arc.open_all(data_dir);

	std::vector<std::string> matches;
	for (auto &kv : arc.index) {
		const std::string &p = kv.first;
		if (p.size() > 4 && p.compare(p.size() - 4, 4, ".nif") == 0 && p.find(pat) != std::string::npos)
			matches.push_back(p);
	}

	int with_controller = 0, dumped = 0;
	std::map<std::string, int> interpolator_types;
	std::map<std::string, int> key_types_seen;
	int total_sequences = 0, total_links = 0;

	for (auto &p : matches) {
		auto bytes = arc.extract(p);
		if (bytes.empty()) continue;
		std::string str(bytes.begin(), bytes.end());
		std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) continue;

		nifly::NiControllerManager *mgr = nullptr;
		uint32_t num_blocks = nif.GetHeader().GetNumBlocks();
		for (uint32_t i = 0; i < num_blocks; ++i) {
			mgr = nif.GetHeader().GetBlock<nifly::NiControllerManager>(i);
			if (mgr) break;
		}
		if (!mgr) continue;
		with_controller++;

		if (mode == "--list") {
			if (dumped < max_n) std::cout << p << "\n";
			dumped++;
			continue;
		}
		bool verbose = dumped < max_n;
		dumped++;
		if (verbose) {
			std::cout << "\n=== " << p << " ===\n";
			std::cout << "  NiControllerManager: cumulative=" << mgr->cumulative
					  << " sequences=" << mgr->controllerSequenceRefs.GetSize() << "\n";
		}
		for (auto &seq_ref : mgr->controllerSequenceRefs) {
			auto *seq = nif.GetHeader().GetBlock<nifly::NiControllerSequence>(seq_ref);
			if (!seq) continue;
			total_sequences++;
			if (verbose)
				std::cout << "  sequence '" << seq->name.get() << "' cycleType=" << seq->cycleType
						  << " start=" << seq->startTime << " stop=" << seq->stopTime
						  << " links=" << seq->controlledBlocks.size() << "\n";
			for (auto &link : seq->controlledBlocks) {
				total_links++;
				if (verbose)
					std::cout << "    target='" << link.nodeName.get()
							  << "' ctrlType='" << link.ctrlType.get()
							  << "' interpID='" << link.interpID.get() << "'\n";
				auto *interp = nif.GetHeader().GetBlock<nifly::NiInterpolator>(link.interpolatorRef);
				if (!interp) {
					if (verbose) std::cout << "      (no interpolator resolved)\n";
					continue;
				}
				std::string bn = interp->GetBlockName();
				interpolator_types[bn]++;
				if (verbose) std::cout << "      interpolator=" << bn << "\n";
				auto *xform = dynamic_cast<nifly::NiTransformInterpolator *>(interp);
				if (xform) {
					auto *td = nif.GetHeader().GetBlock<nifly::NiTransformData>(xform->dataRef);
					if (td) {
						if (verbose) dump_transform_data(nif, td, "      ");
						key_types_seen[key_type_name(td->rotationType)]++;
						if (!td->quaternionKeys.empty())
							key_types_seen[std::string("quatKey:") + key_type_name(td->quaternionKeys[0].type)]++;
						if (td->translations.GetNumKeys() > 0)
							key_types_seen[std::string("translation:") + key_type_name(td->translations.GetInterpolationType())]++;
						if (td->scales.GetNumKeys() > 0)
							key_types_seen[std::string("scale:") + key_type_name(td->scales.GetInterpolationType())]++;
						if (td->xRotations.GetNumKeys() > 0)
							key_types_seen[std::string("xRot:") + key_type_name(td->xRotations.GetInterpolationType())]++;
					} else if (verbose) {
						std::cout << "      (NiTransformInterpolator with no NiTransformData)\n";
					}
				}
			}
		}
	}

	std::cout << "\n=== SUMMARY (pattern '" << pat << "') ===\n";
	std::cout << "NIFs matching pattern: " << matches.size() << "\n";
	std::cout << "NIFs with a NiControllerManager: " << with_controller << "\n";
	std::cout << "total sequences dumped: " << total_sequences << " total links: " << total_links << "\n";
	std::cout << "interpolator types seen:\n";
	for (auto &kv : interpolator_types) std::cout << "  " << kv.second << "  " << kv.first << "\n";
	std::cout << "key interpolation types seen (rotationType/quatKey/translationKey):\n";
	for (auto &kv : key_types_seen) std::cout << "  " << kv.second << "  " << kv.first << "\n";
	return 0;
}
