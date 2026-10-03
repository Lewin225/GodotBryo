// furniture_census: every FURN record's MNAM marker flags and its NIF's
// furniture markers (BSFurnitureMarker / BSFurnitureMarkerNode positions),
// with histograms, how MNAM's bits line up with the markers, and full detail
// for named placed references.
//
//   tools/furniture_census [EditorID of a placed REFR ...]
#include "bsa/bsa_archive.h"
#include "esm/esm_file.h"
#include <NifFile.hpp>
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

struct Marker { float x, y, z; uint16_t orientation; uint8_t ref1, ref2; std::string block; };

static std::vector<Marker> nif_markers(Archives &arc, const std::string &model, std::string &status) {
	std::vector<Marker> out;
	auto bytes = arc.extract(to_lower("meshes\\" + model));
	if (bytes.empty()) { status = "nif missing"; return out; }
	std::string str(bytes.begin(), bytes.end());
	std::istringstream stream(str, std::ios::binary);
	nifly::NifFile nif;
	if (nif.Load(stream) != 0) { status = "nif load failed"; return out; }
	auto &header = nif.GetHeader();
	for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
		auto *fm = header.GetBlock<nifly::BSFurnitureMarker>(i);
		if (!fm) continue;
		for (auto &p : fm->positions) {
			Marker m;
			m.x = p.offset.x; m.y = p.offset.y; m.z = p.offset.z;
			m.orientation = p.orientation; m.ref1 = p.posRef1; m.ref2 = p.posRef2;
			m.block = fm->GetBlockName();
			out.push_back(m);
		}
	}
	status = "ok";
	return out;
}

int main(int argc, char **argv) {
	EsmFile f;
	try { f.open("../fresh_nv_copy/Data/FalloutNV.esm"); } catch (const std::exception &e) { fprintf(stderr, "%s\n", e.what()); return 1; }
	Archives arc; arc.open_all("../fresh_nv_copy/Data");
	std::set<std::string> wanted; for (int i = 1; i < argc; ++i) wanted.insert(to_lower(argv[i]));

	struct Furn { std::string edid, model; std::vector<uint8_t> mnam; uint32_t script = 0; std::vector<Marker> markers; std::string status; };
	std::map<uint32_t, Furn> furns;
	std::map<std::string, uint32_t> wanted_refs; // ref edid -> base
	f.for_each_record([&](const RecordInfo &r) {
		if (r.type != "FURN" && !(r.type == "REFR" && !wanted.empty())) return;
		std::vector<uint8_t> d; try { d = f.read_record_data(r); } catch (...) { return; }
		if (r.type == "REFR") {
			std::string edid; uint32_t base = 0;
			for (auto &s : EsmFile::parse_subrecords(d)) {
				if (s.type == "EDID") edid = (const char *)s.data;
				if (s.type == "NAME" && s.size >= 4) base = *(const uint32_t *)s.data;
			}
			if (wanted.count(to_lower(edid))) wanted_refs[edid] = base;
			return;
		}
		Furn fu;
		for (auto &s : EsmFile::parse_subrecords(d)) {
			if (s.type == "EDID") fu.edid = (const char *)s.data;
			if (s.type == "MODL") fu.model = (const char *)s.data;
			if (s.type == "MNAM") fu.mnam.assign(s.data, s.data + s.size);
			if (s.type == "SCRI" && s.size >= 4) fu.script = *(const uint32_t *)s.data;
		}
		furns[r.form_id] = fu;
	});

	std::map<std::string, int> status_count, mnam_size, block_names;
	std::map<int, int> marker_count, ref1_hist, ref2_hist, orient_hist;
	int bits_eq_markers = 0, bits_ne_markers = 0, with_markers = 0;
	std::vector<std::string> mismatches;
	for (auto &[id, fu] : furns) {
		fu.markers = nif_markers(arc, fu.model, fu.status);
		status_count[fu.status]++;
		mnam_size[std::to_string(fu.mnam.size())]++;
		marker_count[(int)fu.markers.size()]++;
		if (!fu.markers.empty()) with_markers++;
		for (auto &m : fu.markers) {
			ref1_hist[m.ref1]++; ref2_hist[m.ref2]++; block_names[m.block]++;
			orient_hist[(int)std::lround(m.orientation / 1000.0) * 1000]++;
		}
		uint32_t bits = 0; for (size_t i = 0; i < fu.mnam.size() && i < 4; ++i) bits |= uint32_t(fu.mnam[i]) << (8 * i);
		int popcount = __builtin_popcount(bits);
		if (fu.status == "ok") {
			if (popcount == (int)fu.markers.size()) bits_eq_markers++;
			else { bits_ne_markers++; if (mismatches.size() < 12) mismatches.push_back(fu.edid + " MNAM 0x" + [&]{ char b[16]; snprintf(b, 16, "%X", bits); return std::string(b); }() + " markers " + std::to_string(fu.markers.size())); }
		}
	}
	// Bit i of MNAM's low 30 bits enabling NIF marker i: every set bit must
	// index an existing marker. Bits 30 and 31 are counted apart.
	int within = 0, beyond = 0, bit30 = 0, bit31 = 0, no_low_bits = 0;
	std::vector<std::string> beyond_samples;
	for (auto &[id, fu] : furns) {
		if (fu.status != "ok") continue;
		uint32_t bits = 0; for (size_t i = 0; i < fu.mnam.size() && i < 4; ++i) bits |= uint32_t(fu.mnam[i]) << (8 * i);
		bit30 += (bits >> 30) & 1; bit31 += (bits >> 31) & 1;
		uint32_t low = bits & 0x3FFFFFFF;
		if (low == 0) no_low_bits++;
		bool ok = true; for (int b = 0; b < 30; ++b) if ((low >> b) & 1 && b >= (int)fu.markers.size()) ok = false;
		if (ok) within++; else { beyond++; if (beyond_samples.size() < 10) { char buf[160]; snprintf(buf, sizeof buf, "%s MNAM 0x%08X markers %zu", fu.edid.c_str(), bits, fu.markers.size()); beyond_samples.push_back(buf); } }
	}
	{
		std::map<int, int> bit_count;
		for (auto &[id, fu] : furns) {
			uint32_t bits = 0; for (size_t i = 0; i < fu.mnam.size() && i < 4; ++i) bits |= uint32_t(fu.mnam[i]) << (8 * i);
			for (int b = 0; b < 32; ++b) if ((bits >> b) & 1) bit_count[b]++;
		}
		printf("MNAM bits set (bit=FURN count):"); for (auto &[b, n] : bit_count) printf(" %d=%d", b, n); printf("\n");
	}
	printf("MNAM low bits all index an existing marker: %d; some beyond: %d; no low bits: %d; bit 30 set: %d; bit 31 set: %d\n", within, beyond, no_low_bits, bit30, bit31);
	for (auto &b : beyond_samples) printf("  %s\n", b.c_str());
	std::map<int, std::vector<std::string>> by_ref; int same = 0, differ = 0;
	std::map<int, std::map<int, int>> ref_orient;
	for (auto &[id, fu] : furns) for (auto &m : fu.markers) {
		(m.ref1 == m.ref2 ? same : differ)++;
		if (by_ref[m.ref1].size() < 6 && std::find(by_ref[m.ref1].begin(), by_ref[m.ref1].end(), fu.edid) == by_ref[m.ref1].end()) by_ref[m.ref1].push_back(fu.edid);
		ref_orient[m.ref1][m.orientation]++;
	}
	printf("posRef1 == posRef2 on %d markers, differs on %d\n", same, differ);
	for (auto &[r, names] : by_ref) {
		printf("  posRef %d:", r); for (auto &n : names) printf(" %s", n.c_str());
		printf("  | orientations:"); for (auto &[o, n] : ref_orient[r]) printf(" %u=%d", o, n); printf("\n");
	}
	printf("FURN %zu; NIF:", furns.size()); for (auto &[k, v] : status_count) printf(" %s %d", k.c_str(), v);
	printf("\nMNAM size:"); for (auto &[k, v] : mnam_size) printf(" %s=%d", k.c_str(), v);
	printf("\nmarkers per NIF:"); for (auto &[k, v] : marker_count) printf(" %d=%d", k, v);
	printf("\nmarker blocks:"); for (auto &[k, v] : block_names) printf(" %s=%d", k.c_str(), v);
	printf("\nposRef1:"); for (auto &[k, v] : ref1_hist) printf(" %d=%d", k, v);
	printf("\nposRef2:"); for (auto &[k, v] : ref2_hist) printf(" %d=%d", k, v);
	printf("\norientation (rounded to 1000):"); for (auto &[k, v] : orient_hist) printf(" %d=%d", k, v);
	printf("\nMNAM set bits == marker count: %d; differ: %d\n", bits_eq_markers, bits_ne_markers);
	for (auto &m : mismatches) printf("  %s\n", m.c_str());

	for (auto &[ref, base] : wanted_refs) {
		auto it = furns.find(base);
		if (it == furns.end()) { printf("\n%s: base %08X is not a FURN\n", ref.c_str(), base); continue; }
		auto &fu = it->second;
		printf("\n%s -> FURN %08X %s, model %s, script %08X, MNAM", ref.c_str(), base, fu.edid.c_str(), fu.model.c_str(), fu.script);
		for (auto b : fu.mnam) printf(" %02X", b);
		printf("\n");
		for (size_t i = 0; i < fu.markers.size(); ++i) {
			auto &m = fu.markers[i];
			printf("  marker %zu (%s): offset %.1f %.1f %.1f, orientation %u, posRef1 %u, posRef2 %u\n", i, m.block.c_str(), m.x, m.y, m.z, m.orientation, m.ref1, m.ref2);
		}
	}
}
