// kf_static_pose_census: every NiTransformInterpolator / NiBSpline*TransformInterpolator
// linked from a NiControllerSequence in a .kf: whether it has key data, and, for the
// channels without keys (translation, rotation, scale), whether the interpolator's own
// static value is set (not the -FLT_MAX "unset" marker). Counts links pinned wholly by
// a static value, and links whose keys cover only some channels.
//
//   tools/kf_static_pose_census
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
#include <Keys.hpp>
#include <cfloat>

static bool set(float v) { return v > -1.0e30f && v < 1.0e30f; }

int main() {
	Archives arc;
	arc.open_all("../fresh_nv_copy/Data");
	int files = 0, links = 0, no_data = 0, no_data_static = 0, no_data_nothing = 0, bspline = 0;
	int partial_translation = 0, partial_rotation = 0;
	std::set<std::string> files_with_static;
	std::map<std::string, int> static_bones;
	for (auto &[path, where] : arc.index) {
		if (path.size() < 3 || path.substr(path.size() - 3) != ".kf") continue;
		auto bytes = arc.extract(path);
		std::string str(bytes.begin(), bytes.end());
		std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) continue;
		files++;
		auto &header = nif.GetHeader();
		for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
			auto *seq = header.GetBlock<nifly::NiControllerSequence>(i);
			if (!seq) continue;
			for (auto &cb : seq->controlledBlocks) {
				if (cb.interpolatorRef.IsEmpty()) continue;
				if (header.GetBlock<nifly::NiBSplineTransformInterpolator>(cb.interpolatorRef.index)) { bspline++; continue; }
				auto *ti = header.GetBlock<nifly::NiTransformInterpolator>(cb.interpolatorRef.index);
				if (!ti) continue;
				links++;
				auto *t = ti;
				bool st = set(t->translation.x), sr = set(t->rotation.w), ss = set(t->scale);
				auto *data = header.GetBlock<nifly::NiTransformData>(ti->dataRef.index);
				if (!data) {
					no_data++;
					if (st || sr || ss) {
						no_data_static++;
						files_with_static.insert(path);
						static_bones[cb.nodeName.get()]++;
					} else {
						no_data_nothing++;
					}
					continue;
				}
				bool has_t = data->translations.GetNumKeys() > 0;
				bool has_r = data->quaternionKeys.size() > 0 || data->xRotations.GetNumKeys() > 0 || data->yRotations.GetNumKeys() > 0 || data->zRotations.GetNumKeys() > 0;
				if (!has_t && st) partial_translation++;
				if (!has_r && sr) partial_rotation++;
			}
		}
	}
	printf("kf files %d; NiTransformInterpolator links %d (B-spline links %d, not counted)\n", files, links, bspline);
	printf("no NiTransformData: %d; with a static value: %d in %zu files; with nothing set: %d\n", no_data, no_data_static, files_with_static.size(), no_data_nothing);
	printf("with data but no translation keys and a static translation: %d\n", partial_translation);
	printf("with data but no rotation keys and a static rotation: %d\n", partial_rotation);
	printf("bones pinned by a static value (links):\n");
	std::vector<std::pair<int, std::string>> sorted;
	for (auto &[b, n] : static_bones) sorted.push_back({n, b});
	std::sort(sorted.rbegin(), sorted.rend());
	for (size_t i = 0; i < sorted.size() && i < 20; ++i) printf("  %6d  %s\n", sorted[i].first, sorted[i].second.c_str());
	return 0;
}
