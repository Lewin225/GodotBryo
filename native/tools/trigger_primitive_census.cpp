// Census of placed-reference primitives (XPRM) and collision layers (XTRI)
// in FalloutNV.esm: counts by primitive type and base record type, XPRM size,
// bounds range, XTRI values, and which bases carry a script with an
// OnTrigger/OnTriggerEnter/OnTriggerLeave block.
#include "esm/esm_file.h"

#include <algorithm>
#include <cctype>
#include <cfloat>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>

using namespace esm;

static uint32_t u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static float f32(const uint8_t *p) { float v; memcpy(&v, p, 4); return v; }

int main() {
	EsmFile esm_file;
	try {
		esm_file.open("../fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}
	// Scripts with an OnTrigger* block, and each base's SCRI and type.
	std::set<uint32_t> trigger_scripts;
	std::map<uint32_t, std::pair<std::string, uint32_t>> base_info; // base -> (type, SCRI)
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type == "GRUP" || r.type == "REFR" || r.type == "ACHR" || r.type == "ACRE" || r.type == "LAND" || r.type == "NAVM") return;
		std::vector<uint8_t> data;
		try { data = esm_file.read_record_data(r); } catch (...) { return; }
		for (const auto &s : EsmFile::parse_subrecords(data)) {
			if (r.type == "SCPT" && s.type == "SCTX") {
				std::string src((const char *)s.data, s.size);
				std::string lower = src;
				std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
				size_t pos = 0;
				while ((pos = lower.find("ontrigger", pos)) != std::string::npos) {
					size_t line_start = lower.rfind('\n', pos);
					std::string line = lower.substr(line_start == std::string::npos ? 0 : line_start + 1, pos - (line_start == std::string::npos ? 0 : line_start + 1));
					if (line.find(';') == std::string::npos && line.find("begin") != std::string::npos) { trigger_scripts.insert(r.form_id); break; }
					pos += 9;
				}
			}
			if (s.type == "SCRI" && s.size >= 4) base_info[r.form_id] = {r.type, u32(s.data)};
		}
		if (!base_info.count(r.form_id)) base_info[r.form_id] = {r.type, 0};
	});
	std::map<std::string, int> counts;
	std::map<size_t, int> xprm_sizes;
	std::map<uint32_t, int> xtri_values;
	float min_b = FLT_MAX, max_b = 0;
	int shown = 0;
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "REFR") return;
		std::vector<uint8_t> data;
		try { data = esm_file.read_record_data(r); } catch (...) { return; }
		const Subrecord *xprm = nullptr, *name = nullptr, *xtri = nullptr;
		auto subs = EsmFile::parse_subrecords(data);
		for (const auto &s : subs) {
			if (s.type == "XPRM") xprm = &s;
			else if (s.type == "NAME") name = &s;
			else if (s.type == "XTRI") xtri = &s;
		}
		if (xtri && xtri->size >= 4) xtri_values[u32(xtri->data)]++;
		if (!xprm) { if (xtri) counts["XTRI without XPRM"]++; return; }
		xprm_sizes[xprm->size]++;
		uint32_t base = name ? u32(name->data) : 0;
		auto info = base_info.count(base) ? base_info[base] : std::make_pair(std::string("?"), 0u);
		if (info.first == "?" && counts["unknown shown"]++ < 3) {
			auto rec = esm_file.find_record_by_form_id(base);
			printf("unclassified base %08X: %s\n", base, rec ? rec->type.c_str() : "no record");
		}
		uint32_t type = xprm->size >= 32 ? u32(xprm->data + 28) : 99;
		counts["XPRM type " + std::to_string(type)]++;
		counts["XPRM base " + info.first]++;
		bool trig = trigger_scripts.count(info.second) > 0;
		if (trig) counts["XPRM base with OnTrigger script"]++;
		if (info.second && !trig) counts["XPRM base with other script"]++;
		if (!info.second) counts["XPRM base without script"]++;
		for (int i = 0; i < 3; i++) { float v = f32(xprm->data + i * 4); min_b = std::min(min_b, v); max_b = std::max(max_b, v); }
		if (info.second == 0x00104C02)
			printf("VCG01 trigger REFR %08X base %08X bounds %.1f %.1f %.1f type %u\n", r.form_id, base,
					f32(xprm->data), f32(xprm->data + 4), f32(xprm->data + 8), type);
		if (shown < 3 && trig) { shown++; printf("sample trigger REFR %08X base %s %08X type %u bounds %.1f %.1f %.1f\n", r.form_id, info.first.c_str(), base, type, f32(xprm->data), f32(xprm->data + 4), f32(xprm->data + 8)); }
	});
	int bases_with_trigger_script = 0;
	for (auto &[b, info] : base_info) if (info.second && trigger_scripts.count(info.second)) bases_with_trigger_script++;
	printf("scripts with an OnTrigger* block: %zu; bases using them: %d\n", trigger_scripts.size(), bases_with_trigger_script);
	for (auto &[k, v] : counts) printf("%s: %d\n", k.c_str(), v);
	for (auto &[k, v] : xprm_sizes) printf("XPRM size %zu x%d\n", k, v);
	for (auto &[k, v] : xtri_values) printf("XTRI %u x%d\n", k, v);
	printf("bounds range %.2f .. %.2f\n", min_b, max_b);
	return 0;
}
