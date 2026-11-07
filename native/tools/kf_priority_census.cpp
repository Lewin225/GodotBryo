// kf_priority_census: every KF under meshes\\characters\\_male\\, each
// NiControllerSequence: the priority byte of each controlled block (one per
// animated bone), the sequence weight and cycle type, and its text keys.
// Prints histograms of priority values, of priority per bone across all
// clips, of the priority sets per folder, of text key names, and the full
// per-bone priorities of the KFs named on the command line.
//
//   tools/kf_priority_census mtforward.kf idleanims\\talk_gesture...kf
//   tools/kf_priority_census ?sit       (lists the KF paths containing "sit")
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

// A text key without the digits and spaces that carry a frame or a count,
// so keys group by kind ("start", "sound: ...", "blend").
static std::string key_kind(std::string key) {
	key = to_lower(key);
	auto colon = key.find(':');
	if (colon != std::string::npos) {
		return key.substr(0, colon + 1);
	}
	return key;
}

static void print_histogram(const char *title, const std::map<std::string, int> &h, size_t limit = 60) {
	printf("%s:\n", title);
	std::vector<std::pair<int, std::string>> sorted;
	for (auto &[k, v] : h) {
		sorted.push_back({v, k});
	}
	std::sort(sorted.rbegin(), sorted.rend());
	for (size_t i = 0; i < sorted.size() && i < limit; ++i) {
		printf("  %7d  %s\n", sorted[i].first, sorted[i].second.c_str());
	}
}

int main(int argc, char **argv) {
	std::set<std::string> wanted;
	for (int i = 1; i < argc; ++i) {
		wanted.insert(to_lower(argv[i]));
	}
	Archives arc;
	arc.open_all("../fresh_nv_copy/Data");
	const std::string prefix = "meshes\\characters\\_male\\";
	std::map<std::string, int> priority_values, bone_priority, folder_priorities, text_keys, weights, cycles;
	int files = 0, sequences = 0;
	for (auto &[path, where] : arc.index) {
		if (path.rfind(prefix, 0) != 0 || path.size() < 3 || path.substr(path.size() - 3) != ".kf") {
			continue;
		}
		auto bytes = arc.extract(path);
		std::string str(bytes.begin(), bytes.end());
		std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) {
			continue;
		}
		files++;
		std::string rel = path.substr(prefix.size());
		for (auto &w : wanted) {
			if (w[0] == '?' && rel.find(w.substr(1)) != std::string::npos) {
				printf("path %s\n", rel.c_str());
			}
		}
		auto slash = rel.rfind('\\');
		std::string folder = slash == std::string::npos ? "(root)" : rel.substr(0, slash);
		bool show = false;
		for (auto &w : wanted) {
			if (rel.size() >= w.size() && rel.compare(rel.size() - w.size(), w.size(), w) == 0) {
				show = true;
			}
		}
		auto &header = nif.GetHeader();
		for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
			auto *seq = header.GetBlock<nifly::NiControllerSequence>(i);
			if (!seq) {
				continue;
			}
			sequences++;
			char wbuf[32];
			snprintf(wbuf, sizeof wbuf, "%.2f", seq->weight);
			weights[wbuf]++;
			cycles[std::to_string(seq->cycleType)]++;
			std::set<int> here;
			if (show) {
				printf("== %s  sequence %s  weight %.2f cycle %d  %.2f-%.2f s  accum %s\n", rel.c_str(), seq->name.get().c_str(), seq->weight, seq->cycleType, seq->startTime, seq->stopTime, seq->accumRootName.get().c_str());
			}
			for (auto &cb : seq->controlledBlocks) {
				std::string bone = cb.nodeName.get();
				int p = cb.priority;
				priority_values[std::to_string(p)]++;
				bone_priority[bone + " = " + std::to_string(p)]++;
				here.insert(p);
				if (show) {
					printf("     %3d  %s (%s)\n", p, bone.c_str(), cb.ctrlType.get().c_str());
				}
			}
			std::string set;
			for (int p : here) {
				set += (set.empty() ? "" : ",") + std::to_string(p);
			}
			folder_priorities[folder + " {" + set + "}"]++;
			if (auto *tk = header.GetBlock<nifly::NiTextKeyExtraData>(seq->textKeyRef.index)) {
				for (auto &key : tk->textKeys) {
					text_keys[key_kind(key.value.get())]++;
					if (show) {
						printf("     key %.2f  %s\n", key.time, key.value.get().c_str());
					}
				}
			}
		}
	}
	printf("files %d, sequences %d\n", files, sequences);
	print_histogram("controlled block priority values", priority_values);
	print_histogram("sequence weight", weights);
	print_histogram("cycle type", cycles);
	print_histogram("priority sets per folder (sequences)", folder_priorities, 80);
	print_histogram("bone = priority (controlled blocks)", bone_priority, 80);
	print_histogram("text key kinds", text_keys, 60);
	return 0;
}
