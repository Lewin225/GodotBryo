// item_physics_census: every placed REFR of an item base (MISC, ALCH, AMMO,
// KEYM, WEAP, ARMO, BOOK, CCRD, CMNY) in FalloutNV.esm, with its world model's
// bhkRigidBody data: motion system, quality, layer, mass, friction,
// restitution, damping, deactivator type, solver deactivation, shape kinds, and the REFR's "Don't Havok Settle"
// record flag (0x20000000). Histograms per item type and overall.
//
//   tools/item_physics_census
#include "bsa/bsa_archive.h"
#include "esm/esm_file.h"
#include <NifFile.hpp>
#include <bhk.hpp>
#include <algorithm>
#include <cmath>
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

static const uint32_t DONT_HAVOK_SETTLE = 0x20000000;

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

// One rigid body of a world model.
struct Body {
	int motion_system = 0;
	int quality = 0;
	int layer = 0;
	int response = 0;
	int deactivator = 0;
	int solver_deactivation = 0;
	float mass = 0;
	float friction = 0;
	float restitution = 0;
	float linear_damping = 0;
	float angular_damping = 0;
	std::string block;
	std::string shape;
};

// A world model's bodies, or why it has none.
struct Model {
	std::string status;
	std::vector<Body> bodies;
};

// The shape block's name and, for wrappers and lists, the names under it.
static std::string shape_kind(nifly::NiHeader &header, uint32_t index, int depth) {
	auto *shape = header.GetBlock<nifly::bhkShape>(index);
	if (!shape) {
		return "none";
	}
	std::string name = shape->GetBlockName();
	if (depth > 3) {
		return name;
	}
	std::set<nifly::NiRef *> refs;
	shape->GetChildRefs(refs);
	std::set<std::string> children;
	for (auto *ref : refs) {
		if (ref->IsEmpty()) {
			continue;
		}
		auto *child = header.GetBlock<nifly::bhkShape>(ref->index);
		if (child) {
			children.insert(shape_kind(header, ref->index, depth + 1));
		}
	}
	if (children.empty()) {
		return name;
	}
	std::string joined;
	for (auto &c : children) {
		joined += (joined.empty() ? "" : ",") + c;
	}
	return name + "(" + joined + ")";
}

static Model read_model(Archives &arc, const std::string &model_path) {
	Model m;
	if (model_path.empty()) {
		m.status = "no model";
		return m;
	}
	auto bytes = arc.extract(to_lower("meshes\\" + model_path));
	if (bytes.empty()) {
		m.status = "nif missing";
		return m;
	}
	std::string str(bytes.begin(), bytes.end());
	std::istringstream stream(str, std::ios::binary);
	nifly::NifFile nif;
	if (nif.Load(stream) != 0) {
		m.status = "nif load failed";
		return m;
	}
	auto &header = nif.GetHeader();
	for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
		auto *rb = header.GetBlock<nifly::bhkRigidBody>(i);
		if (!rb) {
			continue;
		}
		Body b;
		b.motion_system = rb->motionSystem;
		b.quality = rb->qualityType;
		b.layer = rb->collisionFilter.layer;
		b.response = rb->collisionResponse;
		b.deactivator = rb->deactivatorType;
		b.solver_deactivation = rb->solverDeactivation;
		b.mass = rb->mass;
		b.friction = rb->friction;
		b.restitution = rb->restitution;
		b.linear_damping = rb->linearDamping;
		b.angular_damping = rb->angularDamping;
		b.block = rb->GetBlockName();
		b.shape = shape_kind(header, rb->shapeRef.index, 0);
		m.bodies.push_back(b);
	}
	m.status = m.bodies.empty() ? "no rigid body" : "ok";
	return m;
}

// Bucket label for a float histogram.
static std::string bucket(float value, float step) {
	char buf[32];
	snprintf(buf, sizeof buf, "%.2f", std::floor(value / step) * step);
	return buf;
}

static void print_histogram(const char *title, const std::map<std::string, int> &h) {
	printf("  %s:\n", title);
	std::vector<std::pair<int, std::string>> sorted;
	for (auto &[k, v] : h) {
		sorted.push_back({v, k});
	}
	std::sort(sorted.rbegin(), sorted.rend());
	for (auto &[v, k] : sorted) {
		printf("    %7d  %s\n", v, k.c_str());
	}
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

	const std::set<std::string> item_types = {"MISC", "ALCH", "AMMO", "KEYM", "WEAP", "ARMO", "BOOK", "CCRD", "CMNY"};
	struct Base {
		std::string type, edid, model;
	};
	std::map<uint32_t, Base> bases;
	struct Ref {
		uint32_t form_id, base, flags;
	};
	std::vector<Ref> refs;
	f.for_each_record([&](const RecordInfo &r) {
		bool is_item = item_types.count(r.type) > 0;
		if (!is_item && r.type != "REFR") {
			return;
		}
		std::vector<uint8_t> d;
		try {
			d = f.read_record_data(r);
		} catch (...) {
			return;
		}
		if (r.type == "REFR") {
			for (auto &s : EsmFile::parse_subrecords(d)) {
				if (s.type == "NAME" && s.size >= 4) {
					refs.push_back({r.form_id, *(const uint32_t *)s.data, r.flags});
				}
			}
			return;
		}
		Base b;
		b.type = r.type;
		std::string modl, mod2;
		for (auto &s : EsmFile::parse_subrecords(d)) {
			if (s.type == "EDID") {
				b.edid = (const char *)s.data;
			}
			if (s.type == "MODL") {
				modl = (const char *)s.data;
			}
			if (s.type == "MOD2") {
				mod2 = (const char *)s.data;
			}
		}
		// ARMO's MODL is the male biped model; MOD2 is its male world model.
		b.model = r.type == "ARMO" ? mod2 : modl;
		bases[r.form_id] = b;
	});

	std::map<std::string, Model> models;
	std::map<std::string, std::map<std::string, int>> per_type_status;
	std::map<std::string, int> type_count, status_all, motion, quality, layer, response, deactivator, solver, motion_mass0, shape, mass, friction, restitution, lin_damp, ang_damp, bodies_per_model, settle;
	std::map<std::string, int> settle_by_type;
	std::vector<std::string> samples;
	int placed = 0;
	for (auto &ref : refs) {
		auto it = bases.find(ref.base);
		if (it == bases.end()) {
			continue;
		}
		const Base &b = it->second;
		placed++;
		type_count[b.type]++;
		bool dont_settle = (ref.flags & DONT_HAVOK_SETTLE) != 0;
		settle[dont_settle ? "Don't Havok Settle" : "settles"]++;
		if (dont_settle) {
			settle_by_type[b.type]++;
		}
		if (!models.count(b.model)) {
			models[b.model] = read_model(arc, b.model);
		}
		const Model &m = models[b.model];
		status_all[m.status]++;
		per_type_status[b.type][m.status]++;
		bodies_per_model[std::to_string(m.bodies.size())]++;
		for (auto &body : m.bodies) {
			motion[std::to_string(body.motion_system)]++;
			quality[std::to_string(body.quality)]++;
			layer[std::to_string(body.layer)]++;
			response[std::to_string(body.response)]++;
			deactivator[std::to_string(body.deactivator)]++;
			solver[std::to_string(body.solver_deactivation)]++;
			if (body.mass == 0) {
				motion_mass0["motion " + std::to_string(body.motion_system) + " " + b.type]++;
			}
			shape[body.shape]++;
			mass[bucket(body.mass, body.mass < 1 ? 0.1f : 1.0f)]++;
			friction[bucket(body.friction, 0.1f)]++;
			restitution[bucket(body.restitution, 0.1f)]++;
			lin_damp[bucket(body.linear_damping, 0.1f)]++;
			ang_damp[bucket(body.angular_damping, 0.1f)]++;
		}
		if (m.status != "ok" && samples.size() < 15) {
			char buf[256];
			snprintf(buf, sizeof buf, "%08X %s %s %s: %s", ref.form_id, b.type.c_str(), b.edid.c_str(), b.model.c_str(), m.status.c_str());
			samples.push_back(buf);
		}
	}

	printf("placed item references: %d (distinct models %zu)\n", placed, models.size());
	print_histogram("by type", type_count);
	print_histogram("model status", status_all);
	for (auto &[type, h] : per_type_status) {
		print_histogram((type + " model status").c_str(), h);
	}
	print_histogram("REFR flag 0x20000000", settle);
	print_histogram("Don't Havok Settle by type", settle_by_type);
	print_histogram("rigid bodies per model (per reference)", bodies_per_model);
	print_histogram("motion system (per body, per reference)", motion);
	print_histogram("quality type", quality);
	print_histogram("collision filter layer", layer);
	print_histogram("collision response", response);
	print_histogram("deactivator type", deactivator);
	print_histogram("solver deactivation", solver);
	print_histogram("mass 0: motion system and type", motion_mass0);
	print_histogram("shape kind", shape);
	print_histogram("mass (kg buckets)", mass);
	print_histogram("friction", friction);
	print_histogram("restitution", restitution);
	print_histogram("linear damping", lin_damp);
	print_histogram("angular damping", ang_damp);
	printf("  samples without a rigid body:\n");
	for (auto &s : samples) {
		printf("    %s\n", s.c_str());
	}
	return 0;
}
