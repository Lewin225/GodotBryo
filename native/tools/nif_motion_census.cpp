// nif_motion_census: every .nif in the BSAs, each rigid body's motion system
// by the collision object that owns it, the number of models with a moving
// body (motion system 1, 2, 4 or 8), and how many of those also carry a
// keyframed or fixed body.
//
//   tools/nif_motion_census
#include "bsa/bsa_archive.h"
#include <NifFile.hpp>
#include <bhk.hpp>
#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>
namespace fs = std::filesystem;

static std::string to_lower(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(), ::tolower);
	return s;
}

struct Archives {
	std::vector<std::unique_ptr<bsa::BsaArchive>> readers;
	std::map<std::string, std::pair<size_t, size_t>> index;

	void open_all(const std::string &data_dir) {
		std::vector<std::string> names;
		for (auto &p : fs::directory_iterator(data_dir)) {
			if (to_lower(p.path().extension().string()) == ".bsa") {
				names.push_back(p.path().filename().string());
			}
		}
		std::sort(names.begin(), names.end());
		std::stable_partition(names.begin(), names.end(), [](const std::string &n) { return n == "Update.bsa"; });
		for (auto &n : names) {
			auto r = std::make_unique<bsa::BsaArchive>();
			try {
				r->open(data_dir + "/" + n);
			} catch (...) {
				continue;
			}
			size_t ri = readers.size();
			const auto &es = r->entries();
			for (size_t ei = 0; ei < es.size(); ++ei) {
				std::string full = to_lower(es[ei].folder + "\\" + es[ei].file);
				if (!index.count(full)) {
					index[full] = {ri, ei};
				}
			}
			readers.push_back(std::move(r));
		}
	}

	std::vector<uint8_t> extract(const std::string &lower_path) {
		auto it = index.find(lower_path);
		if (it == index.end()) {
			return {};
		}
		auto &r = *readers[it->second.first];
		return r.extract(r.entries()[it->second.second]);
	}
};

static bool is_moving(int motion) {
	return motion == 1 || motion == 2 || motion == 4 || motion == 8;
}

int main() {
	Archives arc;
	arc.open_all("../fresh_nv_copy/Data");
	std::map<std::string, int> by_object_and_motion, folder_of_moving;
	int nifs = 0, failed = 0, with_moving = 0, moving_and_other = 0;
	for (auto &[path, where] : arc.index) {
		if (path.size() < 4 || path.substr(path.size() - 4) != ".nif") {
			continue;
		}
		nifs++;
		auto bytes = arc.extract(path);
		std::string str(bytes.begin(), bytes.end());
		std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) {
			failed++;
			continue;
		}
		auto &header = nif.GetHeader();
		bool moving = false, other = false;
		for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
			auto *co = header.GetBlock<nifly::bhkNiCollisionObject>(i);
			if (!co) {
				continue;
			}
			auto *rb = header.GetBlock<nifly::bhkRigidBody>(co->bodyRef.index);
			if (!rb) {
				continue;
			}
			by_object_and_motion[std::string(co->GetBlockName()) + " motion " + std::to_string(rb->motionSystem)]++;
			if (is_moving(rb->motionSystem)) {
				moving = true;
			} else {
				other = true;
			}
		}
		if (moving) {
			with_moving++;
			if (other) {
				moving_and_other++;
			}
			auto second = path.find('\\', path.find('\\') + 1);
			folder_of_moving[path.substr(0, second)]++;
		}
	}
	printf("nifs %d, failed to load %d, with a moving body %d, of which also a keyframed or fixed body %d\n", nifs, failed, with_moving, moving_and_other);
	printf("bodies by collision object and motion system:\n");
	for (auto &[k, v] : by_object_and_motion) {
		printf("  %7d  %s\n", v, k.c_str());
	}
	printf("models with a moving body, by folder:\n");
	std::vector<std::pair<int, std::string>> sorted;
	for (auto &[k, v] : folder_of_moving) {
		sorted.push_back({v, k});
	}
	std::sort(sorted.rbegin(), sorted.rend());
	for (auto &[v, k] : sorted) {
		printf("  %7d  %s\n", v, k.c_str());
	}
	return 0;
}
