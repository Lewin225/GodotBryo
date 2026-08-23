// light_survey — throwaway scratch tool, finds a real NIF containing a
// NiLight-derived block (NiPointLight/NiAmbientLight/NiSpotLight/
// NiDirectionalLight), for picking a real preset path for
// project/nif_viewer.gd rather than guessing one. Same Archives/BSA-scan
// boilerplate as anim_survey.cpp.
//
// Usage: light_survey <DataDir> [substr] [max]

#include "../src/bsa/bsa_archive.h"

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
		for (auto &n : names) {
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
		std::cerr << "usage: light_survey <DataDir> [substr] [max]\n";
		return 1;
	}
	std::string data_dir = argv[1];
	std::string pat = argc > 2 ? to_lower(argv[2]) : "";
	int max_n = argc > 3 ? std::atoi(argv[3]) : 15;

	Archives arc;
	arc.open_all(data_dir);

	int found = 0;
	for (auto &kv : arc.index) {
		const std::string &p = kv.first;
		if (!(p.size() > 4 && p.compare(p.size() - 4, 4, ".nif") == 0)) continue;
		if (!pat.empty() && p.find(pat) == std::string::npos) continue;

		auto bytes = arc.extract(p);
		if (bytes.empty()) continue;
		std::string str(bytes.begin(), bytes.end());
		std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) continue;

		uint32_t num_blocks = nif.GetHeader().GetNumBlocks();
		bool has_light = false;
		std::string light_name, light_type;
		for (uint32_t i = 0; i < num_blocks && !has_light; ++i) {
			if (auto *l = nif.GetHeader().GetBlock<nifly::NiLight>(i)) {
				has_light = true;
				light_name = l->name.get();
				light_type = l->GetBlockName();
			}
		}
		if (!has_light) continue;

		found++;
		std::cout << p << "  [" << light_type << " '" << light_name << "', "
				  << num_blocks << " blocks]\n";
		if (found >= max_n) break;
	}
	std::cout << "\nfound " << found << (pat.empty() ? "" : " matching pattern '" + pat + "'") << "\n";
	return 0;
}
