// kf_root_census: every IDLE in FalloutNV.esm with a KF under characters\_male\,
// and the locomotion KFs: for Bip01 and Bip01 NonAccum, the local translation
// and the rotation about the parent's Z (yaw, degrees) at the clip's start and
// end, read through NifSource (keys, or the interpolator's static pose), plus
// the rotation away from Z-only (tilt). Prints histograms of NonAccum's start
// and end yaw and height by animation group section, Bip01's movement, and every
// clip whose NonAccum yaw changes or whose start differs from the standing
// stance, with its section and IDLE names.
//
//   tools/kf_root_census            (summary)
//   tools/kf_root_census chair      (also every clip whose path contains "chair")
#include "esm/esm_file.h"
#include "nif/nif_source.h"
#include "bsa/bsa_archive.h"
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
#include <cmath>

struct Pose {
	bool present = false;
	float t[3] = { 0, 0, 0 };
	float q[4] = { 0, 0, 0, 1 }; // xyzw
};

// The pose of `ip` at its first key (start) or last key (!start), each channel
// falling back to the static value.
static Pose pose_of(const nifsrc::Interpolator &ip, bool start) {
	Pose p;
	if (!ip.present || ip.kind != "transform") return p;
	p.present = true;
	if (!ip.translation_keys.empty()) {
		const auto &k = start ? ip.translation_keys.front() : ip.translation_keys.back();
		for (int i = 0; i < 3; i++) p.t[i] = k.value[i];
	} else if (ip.has_static_transform && std::fabs(ip.translation[0]) < 1e30f) {
		for (int i = 0; i < 3; i++) p.t[i] = ip.translation[i];
	}
	if (!ip.rotation_keys.empty()) {
		const auto &k = start ? ip.rotation_keys.front() : ip.rotation_keys.back();
		for (int i = 0; i < 4; i++) p.q[i] = k.value[i];
	} else if (ip.has_static_transform && std::fabs(ip.rotation[3]) < 1e30f) {
		for (int i = 0; i < 4; i++) p.q[i] = ip.rotation[i];
	}
	return p;
}

// Yaw about Z of the rotated X axis, degrees.
static float yaw_of(const Pose &p) {
	float x = p.q[0], y = p.q[1], z = p.q[2], w = p.q[3];
	float ax = 1 - 2 * (y * y + z * z);
	float ay = 2 * (x * y + w * z);
	return std::atan2(ay, ax) * 180.0f / 3.14159265f;
}

// Angle between the rotated Z axis and Z, degrees.
static float tilt_of(const Pose &p) {
	float x = p.q[0], y = p.q[1], w = p.q[3];
	float zz = 1 - 2 * (x * x + y * y);
	return std::acos(std::max(-1.0f, std::min(1.0f, zz))) * 180.0f / 3.14159265f;
}

static int round5(float v) { return (int)std::lround(v / 5.0f) * 5; }

static std::string fmt(const Pose &p) {
	if (!p.present) return "(none)";
	char b[128];
	snprintf(b, sizeof b, "yaw %4d tilt %3d (%.2f, %.2f, %.2f)", round5(yaw_of(p)), round5(tilt_of(p)), p.t[0], p.t[1], p.t[2]);
	return b;
}

struct Clip {
	std::string path;
	std::set<int> sections;
	std::vector<std::string> idles;
};

int main(int argc, char **argv) {
	std::string show = argc > 1 ? to_lower(argv[1]) : "";
	Archives arc;
	arc.open_all("../fresh_nv_copy/Data");
	esm::EsmFile esm;
	esm.open("../fresh_nv_copy/Data/FalloutNV.esm");
	std::map<std::string, Clip> clips;
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
		std::string path = to_lower("meshes\\" + modl);
		if (modl.empty() || path.rfind("meshes\\characters\\_male\\", 0) != 0) return;
		auto &c = clips[path];
		c.path = path;
		c.sections.insert(section);
		c.idles.push_back(edid);
	});
	for (auto &[path, where] : arc.index) {
		if (path.rfind("meshes\\characters\\_male\\locomotion\\", 0) == 0 && path.size() > 3 && path.substr(path.size() - 3) == ".kf") {
			auto &c = clips[path];
			c.path = path;
			c.sections.insert(1);
		}
	}
	std::map<std::string, int> na_start, na_end, na_height, bip_move, turning_by_section, keyed;
	int read = 0, missing = 0, turning = 0;
	std::vector<std::string> turn_lines, show_lines;
	for (auto &[path, clip] : clips) {
		auto bytes = arc.extract(path);
		if (bytes.empty()) { missing++; continue; }
		nifsrc::Document doc;
		try { doc = nifsrc::load(bytes); } catch (...) { missing++; continue; }
		if (doc.sequences.empty()) { missing++; continue; }
		read++;
		const auto &seq = doc.sequences.front();
		Pose b0, b1, n0, n1;
		for (const auto &cb : seq.controlled_blocks) {
			if (cb.node_name == "Bip01") { b0 = pose_of(cb.interpolator, true); b1 = pose_of(cb.interpolator, false); }
			if (cb.node_name == "Bip01 NonAccum") { n0 = pose_of(cb.interpolator, true); n1 = pose_of(cb.interpolator, false); }
		}
		std::string sec;
		for (int s : clip.sections) sec += (sec.empty() ? "" : ",") + std::to_string(s);
		keyed[std::string("section ") + sec + ": Bip01 " + (b0.present ? "keyed" : "not keyed") + ", NonAccum " + (n0.present ? "keyed" : "not keyed")]++;
		if (n0.present) {
			na_start["section " + sec + " start yaw " + std::to_string(round5(yaw_of(n0)))]++;
			na_end["section " + sec + " end yaw " + std::to_string(round5(yaw_of(n1)))]++;
			char h[64]; snprintf(h, sizeof h, "start %.1f end %.1f m", n0.t[2], n1.t[2]);
			na_height["section " + sec + " " + h]++;
			float d = yaw_of(n1) - yaw_of(n0);
			while (d > 180) d -= 360;
			while (d < -180) d += 360;
			if (std::fabs(d) > 10.0f) {
				turning++;
				turning_by_section["section " + sec]++;
				std::string names;
				for (size_t i = 0; i < clip.idles.size() && i < 3; i++) names += (i ? "," : "") + clip.idles[i];
				turn_lines.push_back(std::to_string(round5(d)) + "  " + path.substr(24) + " [" + sec + "] " + names + "\n      NonAccum start " + fmt(n0) + "\n      NonAccum end   " + fmt(n1) + "\n      Bip01    start " + fmt(b0) + "\n      Bip01    end   " + fmt(b1));
			}
		}
		if (b0.present) {
			float dx = b1.t[0] - b0.t[0], dy = b1.t[1] - b0.t[1];
			char m[96]; snprintf(m, sizeof m, "section %s: moves %.1f m, yaw %d -> %d", sec.c_str(), std::sqrt(dx * dx + dy * dy), round5(yaw_of(b0)), round5(yaw_of(b1)));
			bip_move[m]++;
		}
		if (!show.empty() && path.find(show) != std::string::npos) {
			show_lines.push_back(path.substr(24) + " [" + sec + "]\n      NonAccum start " + fmt(n0) + "\n      NonAccum end   " + fmt(n1) + "\n      Bip01    start " + fmt(b0) + "\n      Bip01    end   " + fmt(b1));
		}
	}
	printf("clips %zu, read %d, missing or unreadable %d\n", clips.size(), read, missing);
	auto dump = [](const char *title, std::map<std::string, int> &h) {
		printf("\n%s:\n", title);
		for (auto &[k, v] : h) printf("  %6d  %s\n", v, k.c_str());
	};
	dump("root bones keyed", keyed);
	dump("NonAccum start yaw", na_start);
	dump("NonAccum end yaw", na_end);
	dump("NonAccum height", na_height);
	dump("Bip01 movement, start to end", bip_move);
	printf("\nclips whose NonAccum yaw changes by more than 10 degrees: %d\n", turning);
	dump("by section", turning_by_section);
	for (auto &l : turn_lines) printf("  %s\n", l.c_str());
	for (auto &l : show_lines) printf("  %s\n", l.c_str());
	return 0;
}
