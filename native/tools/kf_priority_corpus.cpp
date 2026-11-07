// kf_priority_corpus: every .kf in the BSAs, each NiControllerSequence's
// controlled blocks: how many carry a priority, the priority values by
// controller type, and the targets linked more than once in one sequence
// with different priorities (which a per-target priority cannot represent).
//
//   tools/kf_priority_corpus
#include "bsa/bsa_archive.h"
#include <NifFile.hpp>
#include <Animation.hpp>
#include <ExtraData.hpp>
#include <algorithm>
#include <cctype>
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

int main() {
	Archives arc;
	arc.open_all("../fresh_nv_copy/Data");
	std::map<std::string, int> by_ctrl;
	std::map<int, int> values;
	int files = 0, unreadable = 0, sequences = 0, blocks = 0, unnamed = 0, conflicting = 0, conflicting_transform = 0;
	for (auto &[path, where] : arc.index) {
		if (path.size() < 3 || path.substr(path.size() - 3) != ".kf") continue;
		auto bytes = arc.extract(path);
		std::string str(bytes.begin(), bytes.end());
		std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) { unreadable++; continue; }
		files++;
		auto &header = nif.GetHeader();
		for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
			auto *seq = header.GetBlock<nifly::NiControllerSequence>(i);
			if (!seq) continue;
			sequences++;
			std::map<std::string, std::set<int>> per_target, per_target_transform;
			for (auto &cb : seq->controlledBlocks) {
				blocks++;
				std::string node = cb.nodeName.get();
				std::string ctrl = cb.ctrlType.get();
				if (node.empty()) unnamed++;
				values[cb.priority]++;
				by_ctrl[ctrl + " " + std::to_string(cb.priority / 10 * 10) + "s"]++;
				per_target[node].insert(cb.priority);
				if (ctrl == "NiTransformController") per_target_transform[node].insert(cb.priority);
			}
			for (auto &[n, ps] : per_target) if (ps.size() > 1) { conflicting++; if (conflicting <= 5) printf("  differing on %s in %s (%zu values)\n", n.c_str(), path.c_str(), ps.size()); }
			for (auto &[n, ps] : per_target_transform) if (ps.size() > 1) conflicting_transform++;
		}
	}
	printf("kf files %d (unreadable %d), sequences %d, controlled blocks %d (unnamed %d)\n", files, unreadable, sequences, blocks, unnamed);
	printf("targets linked more than once in a sequence with differing priority: %d (transform links only: %d)\n", conflicting, conflicting_transform);
	int lo = 256, hi = -1;
	for (auto &[v, n] : values) { lo = std::min(lo, v); hi = std::max(hi, v); }
	printf("priority range %d..%d, %zu distinct values\n", lo, hi, values.size());
	printf("controller type, priority decade: blocks\n");
	for (auto &[k, n] : by_ctrl) printf("  %7d  %s\n", n, k.c_str());
	return 0;
}
