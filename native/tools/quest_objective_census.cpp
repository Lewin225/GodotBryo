// Census of QUST objectives: every QUST record's subrecords from the first
// QOBJ on (QOBJ, NNAM, QSTA, CTDA and anything else), objective indexes,
// targets, QSTA sizes and flags, target record types and CTDA counts. Then
// every SetObjectiveDisplayed/SetObjectiveCompleted/GetObjectiveDisplayed/
// GetObjectiveCompleted call in the SCTX of SCPT, QUST, INFO, TERM, PACK and
// PERK records: argument counts, flag values, and literal indexes the named
// quest does not define.
// Usage: quest_objective_census [path/to/master.esm] [QUST EDID to dump ...]
// Build from native/:
//   g++ -std=c++17 -O2 -Isrc tools/quest_objective_census.cpp src/esm/esm_file.cpp -lz -o tools/quest_objective_census
#include "esm/esm_file.h"

#include <cstdio>
#include <cctype>
#include <cstring>
#include <sstream>
#include <map>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

using namespace esm;

static uint32_t u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static int32_t i32(const uint8_t *p) { int32_t v; memcpy(&v, p, 4); return v; }

static std::string text(const Subrecord &s) {
	return std::string((const char *)s.data, strnlen((const char *)s.data, s.size));
}

int main(int argc, char **argv) {
	const char *path = argc > 1 ? argv[1] : "../fresh_nv_copy/Data/FalloutNV.esm";
	std::set<std::string> dump;
	for (int i = 2; i < argc; i++) dump.insert(argv[i]);
	EsmFile esm_file;
	try {
		esm_file.open(path);
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}
	std::unordered_map<uint32_t, std::string> type_of;
	esm_file.for_each_record([&](const RecordInfo &r) { type_of[r.form_id] = r.type; });

	int quests = 0, quests_with_objectives = 0, objectives = 0, objectives_with_targets = 0, targets = 0;
	int quests_duplicate_index = 0, objectives_empty_nnam = 0, objectives_no_nnam = 0;
	int stage_tags_after_qobj = 0, ctda_before_qsta_in_objective = 0, objectives_non_ascending = 0;
	int32_t min_index = INT32_MAX, max_index = INT32_MIN;
	std::map<std::string, int> tag_counts;          // tags seen in the objective section
	std::map<std::string, std::map<size_t, int>> tag_sizes;
	std::map<std::string, int> transitions;         // "A->B" inside the objective section
	std::map<int, int> targets_per_objective, ctda_per_target, objectives_per_quest;
	std::map<int, int> qsta_flags, qsta_unused_nonzero;
	std::map<std::string, int> target_types;
	std::map<int, int> nnam_per_objective;
	std::vector<std::string> examples;

	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "QUST") return;
		quests++;
		auto data = esm_file.read_record_data(r);
		auto subs = EsmFile::parse_subrecords(data);
		std::string edid;
		for (const auto &s : subs)
			if (s.type == "EDID") edid = text(s);
		bool in_objectives = false;
		std::string previous;
		std::set<int32_t> seen;
		bool duplicate = false;
		int quest_objectives = 0;
		int32_t last_index = INT32_MIN;
		int cur_targets = -1, cur_ctda = -1, cur_nnam = 0;
		bool cur_has_nnam = false;
		auto close_target = [&]() { if (cur_ctda >= 0) ctda_per_target[cur_ctda]++; cur_ctda = -1; };
		auto close_objective = [&]() {
			close_target();
			if (cur_targets >= 0) {
				targets_per_objective[cur_targets]++;
				if (cur_targets > 0) objectives_with_targets++;
				nnam_per_objective[cur_nnam]++;
				if (!cur_has_nnam) objectives_no_nnam++;
			}
			cur_targets = -1; cur_nnam = 0; cur_has_nnam = false;
		};
		bool show = dump.count(edid) > 0;
		for (const auto &s : subs) {
			if (s.type == "QOBJ") in_objectives = true;
			if (!in_objectives) continue;
			tag_counts[s.type]++;
			tag_sizes[s.type][s.size]++;
			if (!previous.empty()) transitions[previous + "->" + s.type]++;
			previous = s.type;
			if (s.type == "QOBJ") {
				close_objective();
				int32_t index = i32(s.data);
				if (!seen.insert(index).second) duplicate = true;
				if (index < last_index) objectives_non_ascending++;
				last_index = index;
				min_index = std::min(min_index, index);
				max_index = std::max(max_index, index);
				objectives++;
				quest_objectives++;
				cur_targets = 0;
				if (show) printf("  %s QOBJ %d\n", edid.c_str(), index);
			} else if (s.type == "NNAM") {
				cur_nnam++;
				cur_has_nnam = true;
				if (text(s).empty()) objectives_empty_nnam++;
				if (show) printf("  %s   NNAM \"%s\"\n", edid.c_str(), text(s).c_str());
			} else if (s.type == "QSTA") {
				close_target();
				cur_targets++;
				targets++;
				cur_ctda = 0;
				uint32_t target = u32(s.data);
				auto it = type_of.find(target);
				target_types[it == type_of.end() ? std::string("missing") : it->second]++;
				if (s.size >= 5) qsta_flags[s.data[4]]++;
				if (s.size >= 5 && (s.data[4] & ~0x01)) printf("QSTA flags 0x%02X outside 0x01 in %08X %s, objective %d, target %08X\n", s.data[4], r.form_id, edid.c_str(), last_index, target);
				for (size_t b = 5; b < s.size; b++)
					if (s.data[b] != 0) { qsta_unused_nonzero[(int)b]++; }
				if (show) printf("  %s   QSTA target=%08X (%s) flags=%02X size=%u\n", edid.c_str(), target,
						it == type_of.end() ? "missing" : it->second.c_str(), s.size >= 5 ? s.data[4] : 0, (unsigned)s.size);
			} else if (s.type == "CTDA") {
				if (cur_ctda < 0) ctda_before_qsta_in_objective++;
				else cur_ctda++;
				if (show) printf("  %s     CTDA func=%u size=%u\n", edid.c_str(), s.size >= 10 ? (unsigned)(s.data[8] | (s.data[9] << 8)) : 0u, (unsigned)s.size);
			} else if (s.type == "INDX" || s.type == "QSDT" || s.type == "CNAM" || s.type == "SCTX") {
				stage_tags_after_qobj++;
			}
		}
		close_objective();
		if (quest_objectives > 0) {
			quests_with_objectives++;
			objectives_per_quest[quest_objectives]++;
			if (examples.size() < 400) {
				char line[256];
				snprintf(line, sizeof line, "%08X %s objectives=%d", r.form_id, edid.c_str(), quest_objectives);
				examples.push_back(line);
			}
		}
		if (duplicate) {
			quests_duplicate_index++;
			printf("duplicate objective index in %08X %s\n", r.form_id, edid.c_str());
		}
	});

	printf("QUST records: %d\n", quests);
	printf("quests with objectives: %d, objectives: %d\n", quests_with_objectives, objectives);
	printf("objective index range: %d..%d\n", min_index, max_index);
	printf("quests with a duplicate objective index: %d\n", quests_duplicate_index);
	printf("objectives out of ascending order: %d\n", objectives_non_ascending);
	printf("objectives with targets: %d, targets: %d\n", objectives_with_targets, targets);
	printf("objectives without NNAM: %d, with empty NNAM: %d\n", objectives_no_nnam, objectives_empty_nnam);
	printf("CTDA in objective before any QSTA: %d\n", ctda_before_qsta_in_objective);
	printf("stage tags (INDX/QSDT/CNAM/SCTX) after first QOBJ: %d\n", stage_tags_after_qobj);
	printf("\ntags in objective section:\n");
	for (auto &[tag, n] : tag_counts) {
		printf("  %s x%d sizes:", tag.c_str(), n);
		for (auto &[size, c] : tag_sizes[tag]) printf(" %zu(x%d)", size, c);
		printf("\n");
	}
	printf("\ntransitions:\n");
	for (auto &[t, n] : transitions) printf("  %s x%d\n", t.c_str(), n);
	printf("\nNNAM per objective:");
	for (auto &[k, n] : nnam_per_objective) printf(" %d(x%d)", k, n);
	printf("\nobjectives per quest:");
	for (auto &[k, n] : objectives_per_quest) printf(" %d(x%d)", k, n);
	printf("\ntargets per objective:");
	for (auto &[k, n] : targets_per_objective) printf(" %d(x%d)", k, n);
	printf("\nCTDA per target:");
	for (auto &[k, n] : ctda_per_target) printf(" %d(x%d)", k, n);
	printf("\nQSTA flags byte:");
	for (auto &[k, n] : qsta_flags) printf(" 0x%02X(x%d)", k, n);
	printf("\nQSTA nonzero unused bytes:");
	for (auto &[k, n] : qsta_unused_nonzero) printf(" byte%d(x%d)", k, n);
	printf("\ntarget record types:");
	for (auto &[k, n] : target_types) printf(" %s(x%d)", k.c_str(), n);
	// Calls to the objective functions in every SCTX of every record: argument
	// count and the flag (third argument) values.
	std::map<std::string, std::map<std::string, int>> call_shapes;
	std::map<std::string, int> call_records;
	struct Call { std::string quest, index, where; };
	std::vector<Call> calls;
	const char *names[] = {"setobjectivedisplayed", "setobjectivecompleted", "getobjectivedisplayed", "getobjectivecompleted"};
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "SCPT" && r.type != "QUST" && r.type != "INFO" && r.type != "TERM" && r.type != "PACK" && r.type != "PERK") return;
		std::vector<uint8_t> data;
		try { data = esm_file.read_record_data(r); } catch (const std::exception &) { call_records["unreadable " + r.type]++; return; }
		auto subs = EsmFile::parse_subrecords(data);
		for (const auto &s : subs) {
			if (s.type != "SCTX") continue;
			std::string src((const char *)s.data, s.size);
			std::istringstream lines(src);
			std::string line;
			while (std::getline(lines, line)) {
				auto semi = line.find(';');
				if (semi != std::string::npos) line = line.substr(0, semi);
				std::string lower = line;
				for (auto &c : lower) c = (char)tolower((unsigned char)c);
				for (const char *name : names) {
					size_t at = lower.find(name);
					if (at == std::string::npos) continue;
					std::string rest = line.substr(at + strlen(name));
					for (auto &c : rest) if (c == ',' || c == '\r' || c == '\t') c = ' ';
					std::istringstream words(rest);
					std::vector<std::string> args;
					std::string w;
					while (words >> w) {
						if (w == "==" || w == "!=" || w == "&&" || w == "||" || w == ")" || w == "<" || w == ">" || w == "=" || w == ">=" || w == "<=") break;
						if (w.back() == ')') { w.pop_back(); if (!w.empty()) args.push_back(w); break; }
						args.push_back(w);
					}
					std::string shape = std::to_string(args.size()) + " args";
					bool odd = (name[0] == 'g' && args.size() != 2) || (name[0] == 's' && (args.size() != 3 || (args[2] != "0" && args[2] != "1")));
					if (odd) printf("odd call in %s %08X: %s\n", r.type.c_str(), r.form_id, line.c_str());
					if (args.size() >= 2) calls.push_back({args[0], args[1], std::string(name) + " in " + r.type + " " + std::to_string(r.form_id)});
					if (name[0] == 's') shape += args.size() >= 3 ? ", flag " + args[2] : ", no flag";
					call_shapes[name][shape]++;
					call_records[std::string(name) + " in " + r.type]++;
				}
			}
		}
	});
	printf("\n\nobjective function calls in SCTX:\n");
	for (auto &[name, shapes] : call_shapes) {
		printf("  %s:", name.c_str());
		for (auto &[shape, n] : shapes) printf(" [%s] x%d", shape.c_str(), n);
		printf("\n");
	}
	for (auto &[k, n] : call_records) printf("  %s x%d\n", k.c_str(), n);
	// Calls whose quest is a QUST with a literal index it does not define.
	std::map<std::string, uint32_t> quest_by_edid;
	std::map<uint32_t, std::set<int32_t>> indexes_by_quest;
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "QUST") return;
		auto data = esm_file.read_record_data(r);
		auto subs = EsmFile::parse_subrecords(data);
		for (const auto &s : subs) {
			if (s.type == "EDID") { std::string e = text(s); for (auto &c : e) c = (char)tolower((unsigned char)c); quest_by_edid[e] = r.form_id; }
			if (s.type == "QOBJ") indexes_by_quest[r.form_id].insert(i32(s.data));
		}
	});
	int resolved = 0, undefined = 0, not_literal = 0, unknown_quest = 0;
	for (auto &c : calls) {
		std::string q = c.quest; for (auto &ch : q) ch = (char)tolower((unsigned char)ch);
		auto it = quest_by_edid.find(q);
		if (it == quest_by_edid.end()) { unknown_quest++; continue; }
		char *end = nullptr;
		long idx = strtol(c.index.c_str(), &end, 10);
		if (end == c.index.c_str() || *end) { not_literal++; continue; }
		if (indexes_by_quest[it->second].count((int32_t)idx)) resolved++;
		else { undefined++; printf("undefined objective: %s %s (%s)\n", c.quest.c_str(), c.index.c_str(), c.where.c_str()); }
	}
	printf("objective calls: index defined %d, index undefined %d, index not a literal %d, first argument not a QUST editor ID %d\n", resolved, undefined, not_literal, unknown_quest);
	printf("\n\nquests with objectives:\n");
	for (auto &e : examples) printf("  %s\n", e.c_str());
	return 0;
}
