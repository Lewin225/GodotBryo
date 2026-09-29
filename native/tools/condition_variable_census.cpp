// GetQuestVariable (79) and GetScriptVariable (53) conditions in FalloutNV.esm:
// does parameter 2, an SLSD index, name a variable the right script declares?
// 79: parameter 1 is a QUST, its SCRI the script. 53: parameter 1 is a placed
// reference; its base's SCRI the script.
#include "esm/esm_file.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>

using namespace esm;

static uint32_t u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint16_t u16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }

int main() {
	EsmFile esm_file;
	try { esm_file.open("../fresh_nv_copy/Data/FalloutNV.esm"); } catch (const std::exception &e) { fprintf(stderr, "%s\n", e.what()); return 1; }
	std::map<uint32_t, std::set<uint32_t>> script_vars; // SCPT -> SLSD indices with an SCVR
	std::map<uint32_t, uint32_t> scri;                  // any record -> SCRI
	std::map<uint32_t, uint32_t> base_of;               // REFR/ACHR/ACRE -> NAME
	std::map<uint32_t, std::string> type_of;
	struct Use { std::string owner; uint32_t fn, p1, p2; };
	std::vector<Use> uses;
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type == "GRUP") return;
		type_of[r.form_id] = r.type;
		std::vector<uint8_t> data;
		try { data = esm_file.read_record_data(r); } catch (...) { return; }
		int pending = -1;
		for (const auto &s : EsmFile::parse_subrecords(data)) {
			if (r.type == "SCPT" && s.type == "SLSD" && s.size >= 4) pending = (int)u32(s.data);
			else if (r.type == "SCPT" && s.type == "SCVR") { if (pending >= 0) script_vars[r.form_id].insert((uint32_t)pending); pending = -1; }
			else if (s.type == "SCRI" && s.size >= 4) scri[r.form_id] = u32(s.data);
			else if (s.type == "NAME" && s.size >= 4 && (r.type == "REFR" || r.type == "ACHR" || r.type == "ACRE")) base_of[r.form_id] = u32(s.data);
			else if (s.type == "CTDA" && s.size >= 20) {
				uint16_t fn = u16(s.data + 8);
				if (fn == 79 || fn == 53) uses.push_back({r.type, fn, u32(s.data + 12), u32(s.data + 16)});
			}
		}
	});
	std::map<std::string, int> result;
	int shown = 0;
	for (const auto &u : uses) {
		uint32_t owner = u.p1;
		if (u.fn == 53) owner = base_of.count(u.p1) ? base_of[u.p1] : 0;
		uint32_t script = scri.count(owner) ? scri[owner] : 0;
		std::string key = (u.fn == 79 ? "GetQuestVariable " : "GetScriptVariable ");
		if (!script) {
			std::string why = u.fn == 53 && u.p1 == 0x14 ? "the player (0x14)" : (type_of.count(u.p1) ? type_of[u.p1] + (u.fn == 53 && !base_of.count(u.p1) ? " not a placed reference" : " without SCRI") : "missing record");
			result[key + "no script: " + why]++;
			continue;
		}
		if (script_vars[script].count(u.p2)) result[key + "ok"]++;
		else {
			result[key + "index not declared"]++;
			if (shown++ < 5) printf("undeclared: %s on %s param1 %08X (%s) script %08X index %u\n", key.c_str(), u.owner.c_str(), u.p1, type_of[u.p1].c_str(), script, u.p2);
		}
	}
	for (auto &[k, v] : result) printf("%s: %d\n", k.c_str(), v);
	return 0;
}
