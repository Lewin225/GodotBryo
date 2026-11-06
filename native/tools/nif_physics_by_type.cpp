// nif_physics_by_type: for each base record type with a model, every distinct
// model's collision objects and rigid bodies: the collision object's block
// type and flags, and each body's motion system, quality type and collision
// filter layer. Counts distinct models per type, so a static and an item can
// be compared on what their NIFs say about physics.
//
//   tools/nif_physics_by_type
#include "bsa/bsa_archive.h"
#include "esm/esm_file.h"
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
using namespace esm;

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

// Each collision object and body of a model, as one line per body:
// "<collision object> flags 0x.. motion N quality N layer N".
static std::vector<std::string> read_model(Archives &arc, const std::string &model_path, std::string &status) {
	std::vector<std::string> out;
	auto bytes = arc.extract(to_lower("meshes\\" + model_path));
	if (bytes.empty()) {
		status = "nif missing";
		return out;
	}
	std::string str(bytes.begin(), bytes.end());
	std::istringstream stream(str, std::ios::binary);
	nifly::NifFile nif;
	if (nif.Load(stream) != 0) {
		status = "nif load failed";
		return out;
	}
	auto &header = nif.GetHeader();
	for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
		auto *co = header.GetBlock<nifly::bhkNiCollisionObject>(i);
		if (!co) {
			continue;
		}
		auto *rb = header.GetBlock<nifly::bhkRigidBody>(co->bodyRef.index);
		char buf[160];
		if (rb) {
			snprintf(buf, sizeof buf, "%s flags 0x%02X motion %d quality %d layer %d", co->GetBlockName(), co->flags, rb->motionSystem, rb->qualityType, rb->collisionFilter.layer);
		} else {
			snprintf(buf, sizeof buf, "%s flags 0x%02X (no rigid body)", co->GetBlockName(), co->flags);
		}
		out.push_back(buf);
	}
	status = out.empty() ? "no collision object" : "ok";
	return out;
}

int main() {
	EsmFile f;
	try {
		f.open("../fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		fprintf(stderr, "%s\n", e.what());
		return 1;
	}
	Archives arc;
	arc.open_all("../fresh_nv_copy/Data");
	const std::set<std::string> types = {"STAT", "MSTT", "FURN", "CONT", "ACTI", "DOOR", "MISC", "ALCH", "AMMO", "KEYM", "WEAP", "ARMO", "BOOK"};
	std::map<std::string, std::set<std::string>> models_by_type;
	f.for_each_record([&](const RecordInfo &r) {
		if (!types.count(r.type)) {
			return;
		}
		std::vector<uint8_t> d;
		try {
			d = f.read_record_data(r);
		} catch (...) {
			return;
		}
		std::string modl, mod2;
		for (auto &s : EsmFile::parse_subrecords(d)) {
			if (s.type == "MODL") {
				modl = (const char *)s.data;
			}
			if (s.type == "MOD2") {
				mod2 = (const char *)s.data;
			}
		}
		std::string model = r.type == "ARMO" ? mod2 : modl;
		if (!model.empty()) {
			models_by_type[r.type].insert(to_lower(model));
		}
	});
	for (auto &[type, models] : models_by_type) {
		std::map<std::string, int> status_count, line_count;
		for (auto &model : models) {
			std::string status;
			auto lines = read_model(arc, model, status);
			status_count[status]++;
			std::set<std::string> distinct(lines.begin(), lines.end());
			for (auto &l : distinct) {
				line_count[l]++;
			}
		}
		printf("%s: %zu models\n", type.c_str(), models.size());
		for (auto &[k, v] : status_count) {
			printf("    %6d  %s\n", v, k.c_str());
		}
		std::vector<std::pair<int, std::string>> sorted;
		for (auto &[k, v] : line_count) {
			sorted.push_back({v, k});
		}
		std::sort(sorted.rbegin(), sorted.rend());
		for (auto &[v, k] : sorted) {
			printf("    %6d  %s\n", v, k.c_str());
		}
	}
	return 0;
}
