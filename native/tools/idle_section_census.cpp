// idle_section_census: every IDLE in FalloutNV.esm, grouped by its animation
// group section (DATA byte 0, low six bits). For each section, the body
// regions its KF keys (from the bone names of the NiControllerSequence's
// controlled blocks) with the priorities seen per region, and the region
// sets per KF. Regions: lower (pelvis, legs, Bip01, NonAccum), spine, head
// (neck, head), larm, rarm (clavicle to fingers), weapon, other.
//
//   tools/idle_section_census          (summary per section)
//   tools/idle_section_census 2        (also every KF of section 2)
#include "esm/esm_file.h"
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

static std::string region_of(const std::string &bone_mixed) {
	std::string b = to_lower(bone_mixed);
	auto has = [&](const char *s) { return b.find(s) != std::string::npos; };
	if (has("weapon") || has("magazine") || has("shield")) return "weapon";
	if (has("head") || has("neck")) return "head";
	bool arm = has("clavicle") || has("upperarm") || has("forearm") || has("hand") || has("finger") || has("pauldron") || has("arm");
	if (arm && has(" l ")) return "larm";
	if (arm && has(" r ")) return "rarm";
	if (has("spine")) return "spine";
	if (has("thigh") || has("calf") || has("foot") || has("toe") || has("pelvis") || has("nonaccum") || b == "bip01") return "lower";
	return "other";
}

int main(int argc, char **argv) {
	int show_section = argc > 1 ? atoi(argv[1]) : -1;
	Archives arc;
	arc.open_all("../fresh_nv_copy/Data");
	esm::EsmFile esm;
	esm.open("../fresh_nv_copy/Data/FalloutNV.esm");
	struct Stats { int idles = 0, no_kf = 0, kfs = 0; std::map<std::string, std::map<int, int>> region_prio; std::map<std::string, int> region_sets; };
	std::map<int, Stats> sections;
	esm.for_each_record([&](const esm::RecordInfo &rec) {
		if (rec.type != "IDLE") return;
		auto data = esm.read_record_data(rec);
		auto subs = esm::EsmFile::parse_subrecords(data);
		std::string modl, edid; int section = -1;
		for (auto &s : subs) {
			if (s.type == "MODL") modl = s.as_string();
			if (s.type == "EDID") edid = s.as_string();
			if (s.type == "DATA" && s.size > 0) section = s.data[0] & 0x3F;
		}
		Stats &st = sections[section];
		st.idles++;
		if (modl.empty()) { st.no_kf++; return; }
		std::string path = to_lower("meshes\\" + modl);
		auto bytes = arc.extract(path);
		if (bytes.empty()) { st.no_kf++; return; }
		std::string str(bytes.begin(), bytes.end());
		std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) { st.no_kf++; return; }
		st.kfs++;
		std::map<std::string, std::set<int>> here;
		auto &header = nif.GetHeader();
		for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
			auto *seq = header.GetBlock<nifly::NiControllerSequence>(i);
			if (!seq) continue;
			for (auto &cb : seq->controlledBlocks) {
				std::string bone = cb.nodeName.get();
				if (bone.empty()) continue;
				here[region_of(bone)].insert(cb.priority);
			}
		}
		std::string set, line;
		for (auto &[r, ps] : here) {
			set += (set.empty() ? "" : " ") + r;
			std::string pl;
			for (int p : ps) { st.region_prio[r][p]++; pl += (pl.empty() ? "" : ",") + std::to_string(p); }
			line += "  " + r + "{" + pl + "}";
		}
		st.region_sets[set.empty() ? "(none)" : set]++;
		if (section == show_section) printf("  %-40s %s%s\n", edid.c_str(), modl.c_str(), line.c_str());
	});
	for (auto &[sec, st] : sections) {
		printf("\nsection %d: %d IDLEs, %d KFs read, %d without a KF\n", sec, st.idles, st.kfs, st.no_kf);
		std::vector<std::pair<int, std::string>> sets;
		for (auto &[k, v] : st.region_sets) sets.push_back({v, k});
		std::sort(sets.rbegin(), sets.rend());
		for (size_t i = 0; i < sets.size() && i < 8; ++i) printf("  %5d KFs key  %s\n", sets[i].first, sets[i].second.c_str());
		for (auto &[r, pm] : st.region_prio) {
			std::string pl;
			for (auto &[p, n] : pm) pl += " " + std::to_string(p) + "x" + std::to_string(n);
			printf("    %-7s priorities (value x KFs):%s\n", r.c_str(), pl.c_str());
		}
	}
	return 0;
}
