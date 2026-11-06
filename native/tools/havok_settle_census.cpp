// havok_settle_census: in each ESM named on the command line, every REFR with
// record flag 0x20000000 ("Don't Havok Settle"), counted by its base's record
// type (resolved within the same file, then FalloutNV.esm), with up to five
// FormIDs per type, and the motion systems of the flagged bases' models.
//
//   tools/havok_settle_census ../fresh_nv_copy/Data/FalloutNV.esm ...
#include "bsa/bsa_archive.h"
#include "esm/esm_file.h"
#include <NifFile.hpp>
#include <bhk.hpp>
#include <algorithm>
#include <filesystem>
#include <memory>
#include <set>
#include <sstream>
#include <cstdio>
#include <map>
#include <string>
#include <vector>
using namespace esm;
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

// The motion systems of a model's rigid bodies, as "4,7"; "none" or why not.
static std::string motions(Archives &arc, const std::string &model) {
	if (model.empty()) {
		return "no model";
	}
	auto bytes = arc.extract(to_lower("meshes\\" + model));
	if (bytes.empty()) {
		return "nif missing";
	}
	std::string str(bytes.begin(), bytes.end());
	std::istringstream stream(str, std::ios::binary);
	nifly::NifFile nif;
	if (nif.Load(stream) != 0) {
		return "nif load failed";
	}
	std::set<int> found;
	auto &header = nif.GetHeader();
	for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
		if (auto *rb = header.GetBlock<nifly::bhkRigidBody>(i)) {
			found.insert(rb->motionSystem);
		}
	}
	if (found.empty()) {
		return "none";
	}
	std::string out;
	for (int m : found) {
		out += (out.empty() ? "" : ",") + std::to_string(m);
	}
	return out;
}

struct Base {
	std::string type, edid, model;
};

// Every non-REFR record of `f`: type, EDID and MODL by FormID.
static void read_bases(EsmFile &f, std::map<uint32_t, Base> &bases) {
	f.for_each_record([&](const RecordInfo &r) {
		if (r.type == "REFR" || bases.count(r.form_id)) {
			return;
		}
		Base b;
		b.type = r.type;
		if (r.type == "STAT" || r.type == "MSTT") {
			std::vector<uint8_t> d;
			try {
				d = f.read_record_data(r);
			} catch (...) {
				return;
			}
			for (auto &s : EsmFile::parse_subrecords(d)) {
				if (s.type == "EDID") {
					b.edid = (const char *)s.data;
				}
				if (s.type == "MODL") {
					b.model = (const char *)s.data;
				}
			}
		}
		bases[r.form_id] = b;
	});
}

static const uint32_t DONT_HAVOK_SETTLE = 0x20000000;

int main(int argc, char **argv) {
	Archives arc;
	arc.open_all("../fresh_nv_copy/Data");
	std::map<uint32_t, Base> master_bases;
	{
		EsmFile master;
		master.open("../fresh_nv_copy/Data/FalloutNV.esm");
		read_bases(master, master_bases);
	}
	for (int a = 1; a < argc; ++a) {
		EsmFile f;
		try {
			f.open(argv[a]);
		} catch (const std::exception &e) {
			fprintf(stderr, "%s: %s\n", argv[a], e.what());
			continue;
		}
		std::map<uint32_t, Base> bases;
		read_bases(f, bases);
		std::vector<std::pair<uint32_t, uint32_t>> flagged; // REFR, base
		int refrs = 0;
		f.for_each_record([&](const RecordInfo &r) {
			if (r.type != "REFR") {
				return;
			}
			refrs++;
			if ((r.flags & DONT_HAVOK_SETTLE) == 0) {
				return;
			}
			std::vector<uint8_t> d;
			try {
				d = f.read_record_data(r);
			} catch (...) {
				return;
			}
			for (auto &s : EsmFile::parse_subrecords(d)) {
				if (s.type == "NAME" && s.size >= 4) {
					flagged.push_back({r.form_id, *(const uint32_t *)s.data});
				}
			}
		});
		std::map<std::string, std::vector<uint32_t>> by_type;
		std::map<std::string, int> by_motion;
		for (auto &[refr, base_id] : flagged) {
			const Base *b = nullptr;
			// A DLC refers to its own records with load index 01, to FalloutNV.esm's with 00.
			if ((base_id >> 24) == 0 && master_bases.count(base_id)) {
				b = &master_bases[base_id];
			} else if (bases.count(base_id)) {
				b = &bases[base_id];
			}
			by_type[b ? b->type : "(unresolved)"].push_back(refr);
			if (b) {
				by_motion[b->type + " motion " + motions(arc, b->model)]++;
			}
		}
		printf("%s: %d REFRs, %zu with Don't Havok Settle\n", argv[a], refrs, flagged.size());
		for (auto &[type, ids] : by_type) {
			printf("  %6zu  %s:", ids.size(), type.c_str());
			for (size_t i = 0; i < ids.size() && i < 5; ++i) {
				printf(" %08X", ids[i]);
			}
			printf("\n");
		}
		for (auto &[k, v] : by_motion) {
			printf("  %6d  %s\n", v, k.c_str());
		}
	}
	return 0;
}
