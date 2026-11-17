// Answers: is NVTR Flags bit 0x0200 the "water" triangle marking? Compares
// each triangle's height with its CELL's water height: XCLW, else (exterior)
// the worldspace's DNAM default water height; cells with neither are
// skipped. Reports, for triangles with and without the bit in the same cells,
// how many lie below the water surface.
//
//   tools/navm_water_flag_census ../fresh_nv_copy/Data/FalloutNV.esm [...]
#include "esm/esm_file.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <set>
#include <unordered_map>
#include <vector>

static uint32_t rd_u32(const uint8_t *d, size_t n, size_t o) { return o + 4 > n ? 0 : d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (uint32_t(d[o + 3]) << 24); }
static uint16_t rd_u16(const uint8_t *d, size_t n, size_t o) { return o + 2 > n ? 0 : d[o] | (d[o + 1] << 8); }
static float rd_f(const uint8_t *d, size_t n, size_t o) { uint32_t u = rd_u32(d, n, o); float f; memcpy(&f, &u, 4); return f; }

int main(int argc, char **argv) {
	// Pass 1: water heights (Gamebryo units) per CELL.
	std::unordered_map<uint32_t, float> water_by_cell;
	std::unordered_map<uint32_t, float> default_water_by_world;
	for (int i = 1; i < argc; ++i) {
		esm::EsmFile file;
		try { file.open(argv[i]); } catch (...) { continue; }
		uint32_t world = 0;
		file.for_each_record([&](const esm::RecordInfo &rec) {
			if (rec.type != "WRLD" && rec.type != "CELL") return;
			std::vector<uint8_t> raw;
			try { raw = file.read_record_data(rec); } catch (...) { return; }
			std::vector<esm::Subrecord> subs;
			try { subs = esm::EsmFile::parse_subrecords(raw); } catch (...) { return; }
			if (rec.type == "WRLD") {
				world = rec.form_id;
				for (auto &s : subs) if (s.type == "DNAM" && s.size >= 8) default_water_by_world[world] = rd_f(s.data, s.size, 4);
				return;
			}
			bool exterior = false, has_xclw = false;
			float xclw = 0;
			for (auto &s : subs) {
				if (s.type == "XCLC") exterior = true;
				if (s.type == "XCLW" && s.size >= 4) { has_xclw = true; xclw = rd_f(s.data, s.size, 0); }
			}
			if (has_xclw) water_by_cell[rec.form_id] = xclw;
			else if (exterior && default_water_by_world.count(world)) water_by_cell[rec.form_id] = default_water_by_world[world];
		});
	}
	// Pass 2: triangles.
	std::vector<float> depth_bit, depth_other;
	uint64_t with_bit = 0, with_bit_below = 0, with_bit_near = 0, without_bit = 0, without_bit_below = 0, skipped_cells = 0;
	std::set<uint32_t> seen;
	for (int i = 1; i < argc; ++i) {
		esm::EsmFile file;
		try { file.open(argv[i]); } catch (...) { continue; }
		file.for_each_record([&](const esm::RecordInfo &rec) {
			if (rec.type != "NAVM" || !seen.insert(rec.form_id).second) return;
			std::vector<uint8_t> raw;
			try { raw = file.read_record_data(rec); } catch (...) { return; }
			std::vector<esm::Subrecord> subs;
			try { subs = esm::EsmFile::parse_subrecords(raw); } catch (...) { return; }
			uint32_t cell = 0, vc = 0, tc = 0;
			const uint8_t *vx = nullptr, *tr = nullptr;
			size_t vx_size = 0, tr_size = 0;
			for (auto &s : subs) {
				if (s.type == "DATA") { cell = rd_u32(s.data, s.size, 0); vc = rd_u32(s.data, s.size, 4); tc = rd_u32(s.data, s.size, 8); }
				if (s.type == "NVVX") { vx = s.data; vx_size = s.size; }
				if (s.type == "NVTR") { tr = s.data; tr_size = s.size; }
			}
			if (!vx || !tr) return;
			auto water = water_by_cell.find(cell);
			bool any_bit = false;
			for (size_t k = 0; k * 16 + 16 <= tr_size && k < tc; ++k) if (rd_u16(tr, tr_size, k * 16 + 12) & 0x0200) any_bit = true;
			if (!any_bit) return;
			// A huge XCLW / default (FLT_MAX-like) is no water level at all.
			if (water == water_by_cell.end() || std::fabs(water->second) > 1e6f) { ++skipped_cells; return; }
			for (size_t k = 0; k * 16 + 16 <= tr_size && k < tc; ++k) {
				float z = 0;
				bool ok = true;
				for (int j = 0; j < 3; ++j) {
					uint16_t v = rd_u16(tr, tr_size, k * 16 + j * 2);
					if (v >= vc || (size_t)v * 12 + 12 > vx_size) { ok = false; break; }
					z += rd_f(vx, vx_size, v * 12 + 8) / 3.0f;
				}
				if (!ok) continue;
				bool bit = rd_u16(tr, tr_size, k * 16 + 12) & 0x0200;
				bool below = z < water->second;
				(bit ? depth_bit : depth_other).push_back((water->second - z) / 70.0f);
				if (bit) { ++with_bit; if (below) ++with_bit_below; if (std::fabs(z - water->second) < 70.0f) ++with_bit_near; }
				else { ++without_bit; if (below) ++without_bit_below; }
			}
		});
	}
	auto median = [](std::vector<float> &v) { if (v.empty()) return 0.0f; std::sort(v.begin(), v.end()); return v[v.size() / 2]; };
	auto share_over = [](const std::vector<float> &v, float m) { size_t n = 0; for (float d : v) if (d > m) ++n; return v.empty() ? 0.0 : 100.0 * n / v.size(); };
	printf("depth below surface (m): 0x0200 median %.2f, deeper than 1.5 m %.1f%%; others median %.2f, deeper than 1.5 m %.1f%%\n",
			median(depth_bit), share_over(depth_bit, 1.5f), median(depth_other), share_over(depth_other, 1.5f));
	printf("NAVM records with 0x0200 triangles but no usable water height (none, or a sentinel above 1e6): %llu\n", (unsigned long long)skipped_cells);
	printf("0x0200 triangles: %llu; below the water surface %.2f%%; within 1 m of it %.2f%%\n", (unsigned long long)with_bit, 100.0 * with_bit_below / (with_bit ? with_bit : 1), 100.0 * with_bit_near / (with_bit ? with_bit : 1));
	printf("other triangles in those cells: %llu; below the water surface %.2f%%\n", (unsigned long long)without_bit, 100.0 * without_bit_below / (without_bit ? without_bit : 1));
}
