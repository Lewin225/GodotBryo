// kf_face_census -- which KF sequences drive face morphs: links whose
// controller is a NiGeomMorpherController (skeleton.nif's HeadAnims:0
// morpher). Per sequence: the file, the target node, the morph names
// (interpID) and whether any key is non-zero.
//
// Usage: kf_face_census <DataDir>
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


int main(int argc, char **argv) {
	if (argc < 2) {
		std::cerr << "usage: kf_face_census <DataDir>\n";
		return 1;
	}
	Archives arc;
	arc.open_all(argv[1]);

	int kf_files = 0, kf_with_face = 0, sequences_with_face = 0, nonzero_sequences = 0;
	std::map<std::string, int> morph_names;
	std::map<std::string, int> target_nodes;
	std::map<std::string, int> folders;
	for (auto &kv : arc.index) {
		const std::string &p = kv.first;
		if (p.size() < 4 || p.compare(p.size() - 3, 3, ".kf") != 0)
			continue;
		kf_files++;
		auto bytes = arc.extract(p);
		std::string str(bytes.begin(), bytes.end());
		std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0)
			continue;
		bool file_has_face = false;
		uint32_t num_blocks = nif.GetHeader().GetNumBlocks();
		for (uint32_t i = 0; i < num_blocks; ++i) {
			auto *seq = nif.GetHeader().GetBlock<nifly::NiControllerSequence>(i);
			if (!seq)
				continue;
			std::vector<std::string> names;
			bool nonzero = false;
			for (auto &link : seq->controlledBlocks) {
				if (link.ctrlType.get() != "NiGeomMorpherController")
					continue;
				target_nodes[link.nodeName.get()]++;
				names.push_back(link.interpID.get());
				morph_names[link.interpID.get()]++;
				auto *interp = nif.GetHeader().GetBlock<nifly::NiFloatInterpolator>(link.interpolatorRef);
				if (!interp)
					continue;
				if (interp->floatValue != 0.0f && interp->floatValue != -3.402823466e+38f)
					nonzero = true;
				auto *data = nif.GetHeader().GetBlock<nifly::NiFloatData>(interp->dataRef);
				if (!data)
					continue;
				for (uint32_t k = 0; k < data->data.GetNumKeys(); ++k)
					if (data->data.GetKey(k).value != 0.0f)
						nonzero = true;
			}
			if (names.empty())
				continue;
			file_has_face = true;
			sequences_with_face++;
			if (nonzero)
				nonzero_sequences++;
			std::cout << p << " seq='" << seq->name.get() << "' nonzero=" << nonzero << " morphs=";
			for (auto &n : names)
				std::cout << n << ",";
			std::cout << "\n";
		}
		if (file_has_face) {
			kf_with_face++;
			folders[p.substr(0, p.rfind('\\'))]++;
		}
	}
	std::cout << "\nKF files " << kf_files << ", with face tracks " << kf_with_face
			  << "; sequences with face tracks " << sequences_with_face
			  << ", with a non-zero key " << nonzero_sequences << "\n";
	std::cout << "target nodes:";
	for (auto &kv : target_nodes)
		std::cout << " " << kv.first << "=" << kv.second;
	std::cout << "\nmorph names:";
	for (auto &kv : morph_names)
		std::cout << " " << kv.first << "=" << kv.second;
	std::cout << "\nfolders:\n";
	for (auto &kv : folders)
		std::cout << "  " << kv.first << " " << kv.second << "\n";
	return 0;
}
