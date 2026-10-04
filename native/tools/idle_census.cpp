// idle_census: every IDLE record (model, conditions, ANAM parent/previous,
// DATA), counts over the whole file, and for named IDLEs the full record plus
// its KF: found in the BSAs, sequence name, cycle type, length, accum root and
// how many controlled blocks (bones) it drives.
//
//   tools/idle_census [IDLE EditorID ...]
#include "bsa/bsa_archive.h"
#include "esm/esm_file.h"
#include <NifFile.hpp>
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
using namespace esm;

static std::string to_lower(std::string s) { std::transform(s.begin(), s.end(), s.begin(), ::tolower); return s; }

struct Archives {
	std::vector<std::unique_ptr<bsa::BsaArchive>> readers;
	std::map<std::string, std::pair<size_t, size_t>> index;
	void open_all(const std::string &data_dir) {
		std::vector<std::string> names;
		for (auto &p : fs::directory_iterator(data_dir))
			if (to_lower(p.path().extension().string()) == ".bsa") names.push_back(p.path().filename().string());
		std::sort(names.begin(), names.end());
		std::stable_partition(names.begin(), names.end(), [](const std::string &n) { return n == "Update.bsa"; });
		for (auto &n : names) {
			auto r = std::make_unique<bsa::BsaArchive>();
			try { r->open(data_dir + "/" + n); } catch (...) { continue; }
			size_t ri = readers.size();
			const auto &es = r->entries();
			for (size_t ei = 0; ei < es.size(); ++ei) {
				std::string full = to_lower(es[ei].folder + "\\" + es[ei].file);
				if (!index.count(full)) index[full] = {ri, ei};
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


struct Idle { std::string edid, model; int conditions = 0; uint32_t parent = 0, previous = 0; std::vector<uint8_t> data; };

int main(int argc, char **argv) {
	EsmFile f;
	try { f.open("../fresh_nv_copy/Data/FalloutNV.esm"); } catch (const std::exception &e) { fprintf(stderr, "%s\n", e.what()); return 1; }
	Archives arc; arc.open_all("../fresh_nv_copy/Data");
	std::map<uint32_t, Idle> idles;
	f.for_each_record([&](const RecordInfo &r) {
		if (r.type != "IDLE") return;
		std::vector<uint8_t> d; try { d = f.read_record_data(r); } catch (...) { return; }
		Idle i;
		for (auto &s : EsmFile::parse_subrecords(d)) {
			if (s.type == "EDID") i.edid = (const char *)s.data;
			if (s.type == "MODL") i.model = (const char *)s.data;
			if (s.type == "CTDA") i.conditions++;
			if (s.type == "ANAM" && s.size >= 8) { i.parent = *(const uint32_t *)s.data; i.previous = *(const uint32_t *)(s.data + 4); }
			if (s.type == "DATA") i.data.assign(s.data, s.data + s.size);
		}
		idles[r.form_id] = i;
	});
	int with_model = 0, with_conditions = 0, roots = 0, model_found = 0;
	std::map<int, int> section_hist;
	for (auto &[id, i] : idles) {
		with_model += !i.model.empty(); with_conditions += i.conditions > 0; roots += i.parent == 0;
		if (!i.model.empty() && !arc.extract(to_lower("meshes\\" + i.model)).empty()) model_found++;
		if (!i.data.empty()) section_hist[i.data[0]]++;
	}
	{
		int missing_roots = 0, missing_with_children = 0; std::set<uint32_t> parents; std::vector<std::string> samples;
		for (auto &[id, i] : idles) if (i.parent) parents.insert(i.parent);
		for (auto &[id, i] : idles) {
			if (i.model.empty() || !arc.extract(to_lower("meshes\\" + i.model)).empty()) continue;
			missing_roots += i.parent == 0; missing_with_children += parents.count(id) > 0;
			if (samples.size() < 8) samples.push_back(i.edid + " (" + i.model + ")");
		}
		printf("KF not found: roots %d, with children %d; e.g.", missing_roots, missing_with_children);
		for (auto &x : samples) printf(" %s;", x.c_str()); printf("\n");
	}
	printf("IDLE %zu: with MODL %d (KF found in BSAs %d), with conditions %d, no parent (tree roots) %d\n", idles.size(), with_model, model_found, with_conditions, roots);
	printf("DATA animation group section:"); for (auto &[k, v] : section_hist) printf(" %d=%d", k, v); printf("\n");

	std::map<std::string, uint32_t> by_edid; for (auto &[id, i] : idles) by_edid[to_lower(i.edid)] = id;
	auto edid_of = [&](uint32_t id) { auto it = idles.find(id); return it == idles.end() ? std::string(id ? "?" : "-") : it->second.edid; };
	for (int a = 1; a < argc; ++a) {
		auto it = by_edid.find(to_lower(argv[a]));
		if (it == by_edid.end()) { printf("\n%s: no IDLE\n", argv[a]); continue; }
		Idle &i = idles[it->second];
		printf("\n%08X %s: model %s, conditions %d, parent %s, previous %s, DATA", it->second, i.edid.c_str(), i.model.c_str(), i.conditions, edid_of(i.parent).c_str(), edid_of(i.previous).c_str());
		for (auto b : i.data) printf(" %02X", b);
		printf("\n");
		// Ancestry up to the root.
		printf("   path:"); uint32_t p = i.parent; int guard = 0; while (p && guard++ < 12) { printf(" <- %s", edid_of(p).c_str()); p = idles.count(p) ? idles[p].parent : 0; } printf("\n");
		if (i.model.empty()) continue;
		auto bytes = arc.extract(to_lower("meshes\\" + i.model));
		if (bytes.empty()) { printf("   KF not in the BSAs\n"); continue; }
		std::string str(bytes.begin(), bytes.end()); std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif; if (nif.Load(stream) != 0) { printf("   KF load failed\n"); continue; }
		auto &h = nif.GetHeader();
		for (uint32_t b = 0; b < h.GetNumBlocks(); ++b) {
			auto *seq = h.GetBlock<nifly::NiControllerSequence>(b);
			if (!seq) continue;
			printf("   sequence %s: cycle %d, %.2f-%.2f s, accum root %s, %zu controlled blocks\n", seq->name.get().c_str(), (int)seq->cycleType, seq->startTime, seq->stopTime, seq->accumRootName.get().c_str(), seq->controlledBlocks.size());
		}
	}
}
