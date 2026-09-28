// CTDA layout census over FalloutNV.esm for Plans/Conditions/conditions.md
// stage A: type byte (top 3 bits / low 5 bits), Use Global against GLOB
// comparison FormIDs, Run On and Reference per record type, the short forms,
// function index use, and Or runs within each list of consecutive CTDAs.
// Prints "FN <index> <count>" lines for mapping to names outside.
#include "esm/esm_file.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

using namespace esm;

static uint32_t u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint16_t u16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }

int main() {
	EsmFile esm_file;
	try { esm_file.open("../fresh_nv_copy/Data/FalloutNV.esm"); } catch (const std::exception &e) { fprintf(stderr, "%s\n", e.what()); return 1; }
	std::map<uint32_t, std::string> record_type; // FormID -> type, for GLOB / reference checks
	esm_file.for_each_record([&](const RecordInfo &r) { if (r.type != "GRUP") record_type[r.form_id] = r.type; });

	std::map<int, int> top_bits, low_bits, type_bytes;
	int global_flag = 0, global_is_glob = 0, no_global_value_is_glob = 0;
	std::map<std::string, std::map<uint32_t, int>> run_on_by_type;
	std::map<std::string, int> reference_used, reference_types;
	int counts_shown = 0;
	int run_on_2 = 0, run_on_2_with_reference = 0, reference_without_run_on_2 = 0;
	int flag02 = 0, flag02_run_on_1 = 0, run_on_1 = 0;
	std::map<std::string, int> short_forms;
	std::map<uint16_t, int> functions;
	std::map<std::string, int> or_patterns;
	int lists = 0, lists_with_or = 0, trailing_or = 0;

	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type == "GRUP") return;
		std::vector<uint8_t> data;
		try { data = esm_file.read_record_data(r); } catch (...) { return; }
		auto subs = EsmFile::parse_subrecords(data);
		std::vector<uint8_t> current_or; // Or flags of the current run of CTDAs
		auto close_list = [&]() {
			if (current_or.empty()) return;
			lists++;
			bool any = false; std::string pattern;
			for (uint8_t f : current_or) { pattern += f ? 'O' : 'A'; any = any || f; }
			if (any) { lists_with_or++; if (current_or.back()) trailing_or++; if (pattern.size() <= 8) or_patterns[pattern]++; }
			current_or.clear();
		};
		for (const auto &s : subs) {
			if (s.type != "CTDA") { close_list(); continue; }
			const uint8_t *d = s.data;
			uint8_t type = d[0];
			type_bytes[type]++;
			top_bits[type >> 5]++;
			low_bits[type & 0x1F]++;
			current_or.push_back(type & 0x01);
			uint32_t value_word = u32(d + 4);
			bool value_is_glob = record_type.count(value_word) && record_type[value_word] == "GLOB";
			if (type & 0x04) { global_flag++; if (value_is_glob) global_is_glob++; }
			else if (value_is_glob) no_global_value_is_glob++;
			if (s.size >= 12) functions[u16(d + 8)]++;
			if (s.size < 28) {
				short_forms[r.type + " size " + std::to_string(s.size) + " fn " + std::to_string(u16(d + 8))]++;
				continue;
			}
			uint32_t run_on = u32(d + 20), reference = u32(d + 24);
			run_on_by_type[r.type][run_on]++;
			if (type & 0x02) { flag02++; if (run_on == 1) flag02_run_on_1++; }
			if (run_on == 1) run_on_1++;
			if (r.type != "IDLE" && run_on == 2) { run_on_2++; if (reference) run_on_2_with_reference++; }
			if (reference) {
				reference_used[r.type]++;
				if (r.type != "IDLE" && run_on != 2) reference_without_run_on_2++;
				reference_types[record_type.count(reference) ? record_type[reference] : (reference == 0x14 ? "player 0x14" : "missing")]++;
				if (!record_type.count(reference) && reference != 0x14 && counts_shown++ < 5) printf("MISSING reference %08X in %s %08X run on %u\n", reference, r.type.c_str(), r.form_id, run_on);
			}
		}
		close_list();
	});
	printf("TYPE top 3 bits:"); for (auto &[k, v] : top_bits) printf(" %d:x%d", k, v); printf("\n");
	printf("TYPE low 5 bits:"); for (auto &[k, v] : low_bits) printf(" 0x%02X:x%d", k, v); printf("\n");
	printf("USE GLOBAL flag 0x04: %d, of which comparison word is a GLOB: %d; GLOB-valued without the flag: %d\n", global_flag, global_is_glob, no_global_value_is_glob);
	printf("FLAG 0x02: %d, of which Run On = 1: %d; Run On = 1 total: %d\n", flag02, flag02_run_on_1, run_on_1);
	printf("RUN ON = 2 (non-IDLE): %d, with a Reference: %d; Reference set without Run On 2: %d\n", run_on_2, run_on_2_with_reference, reference_without_run_on_2);
	for (auto &[t, m] : run_on_by_type) { printf("RUN ON %s:", t.c_str()); for (auto &[k, v] : m) printf(" %u:x%d", k, v); printf("\n"); }
	printf("REFERENCE targets:"); for (auto &[k, v] : reference_types) printf(" %s:x%d", k.c_str(), v); printf("\n");
	for (auto &[k, v] : short_forms) printf("SHORT %s x%d\n", k.c_str(), v);
	printf("LISTS %d, with Or %d, ending in Or %d\n", lists, lists_with_or, trailing_or);
	for (auto &[k, v] : or_patterns) printf("OR PATTERN %s x%d\n", k.c_str(), v);
	for (auto &[k, v] : functions) printf("FN %u %d\n", k, v);
	return 0;
}
