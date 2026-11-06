// nif_constraint_census: every .nif in the BSAs, each bhk constraint block:
// its type (a malleable or breakable wrapper named with the type it wraps),
// and the motion systems of the bodies it joins. Counts constraints joining
// moving bodies (motion system 1, 2, 4 or 8) apart from ragdoll ones (between
// keyframed bones), the models that carry them by folder, and examples.
//
//   tools/nif_constraint_census
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

static const char *TYPE_NAMES[] = {"BallAndSocket", "Hinge", "LimitedHinge", "?3", "?4", "?5", "Prismatic", "Ragdoll", "StiffSpring", "?9", "?10", "?11", "?12", "Malleable"};

static std::string type_name(int t) {
	if (t >= 0 && t < 14) {
		return TYPE_NAMES[t];
	}
	return "?" + std::to_string(t);
}

static bool is_moving(int motion) {
	return motion == 1 || motion == 2 || motion == 4 || motion == 8;
}

int main() {
	Archives arc;
	arc.open_all("../fresh_nv_copy/Data");
	std::map<std::string, int> by_kind, models_by_folder;
	std::vector<std::string> examples;
	int models_with_moving_constraints = 0;
	for (auto &[path, where] : arc.index) {
		if (path.size() < 4 || path.substr(path.size() - 4) != ".nif") {
			continue;
		}
		auto bytes = arc.extract(path);
		std::string str(bytes.begin(), bytes.end());
		std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) {
			continue;
		}
		auto &header = nif.GetHeader();
		int moving_here = 0;
		std::set<std::string> kinds_here;
		for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
			auto *c = header.GetBlock<nifly::bhkConstraint>(i);
			if (!c) {
				continue;
			}
			std::string kind = c->GetBlockName();
			if (auto *m = dynamic_cast<nifly::bhkMalleableConstraint *>(c)) {
				kind += "(" + type_name(m->subConstraint.type) + ")";
			}
			if (auto *b = dynamic_cast<nifly::bhkBreakableConstraint *>(c)) {
				kind += "(" + type_name(b->subConstraint.type) + ")";
			}
			std::string motions;
			bool moving = false;
			for (auto &ref : c->entityRefs) {
				auto *rb = header.GetBlock<nifly::bhkRigidBody>(ref.index);
				int m = rb ? rb->motionSystem : -1;
				moving = moving || is_moving(m);
				motions += (motions.empty() ? "" : "-") + std::to_string(m);
			}
			std::string label = kind + " joining motion " + motions;
			by_kind[label]++;
			if (moving) {
				moving_here++;
				kinds_here.insert(kind);
			}
		}
		if (moving_here > 0) {
			models_with_moving_constraints++;
			auto second = path.find('\\', path.find('\\') + 1);
			models_by_folder[path.substr(0, second)]++;
			if (examples.size() < 25) {
				std::string k;
				for (auto &x : kinds_here) {
					k += (k.empty() ? "" : ",") + x;
				}
				examples.push_back(path + ": " + std::to_string(moving_here) + " (" + k + ")");
			}
		}
	}
	printf("constraints by kind and the motion systems they join:\n");
	std::vector<std::pair<int, std::string>> sorted;
	for (auto &[k, v] : by_kind) {
		sorted.push_back({v, k});
	}
	std::sort(sorted.rbegin(), sorted.rend());
	for (auto &[v, k] : sorted) {
		printf("  %6d  %s\n", v, k.c_str());
	}
	printf("models with a constraint on a moving body: %d\n", models_with_moving_constraints);
	for (auto &[k, v] : models_by_folder) {
		printf("  %6d  %s\n", v, k.c_str());
	}
	printf("examples:\n");
	for (auto &e : examples) {
		printf("  %s\n", e.c_str());
	}
	return 0;
}
