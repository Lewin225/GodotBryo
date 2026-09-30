// DIAL/INFO census over FalloutNV.esm for the dialogue plan: topic types,
// flags and priorities; INFO placement in each topic's child GRUP; PNAM
// (previous INFO) order against file order; INFO DATA types and flags;
// responses, conditions, scripts, links and speakers per INFO; QSTI use; and
// the topics and INFOs that name a given NPC_ by GetIsID or ANAM.
// Usage: dialogue_census [NPC_ EditorID ...]
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
static float f32(const uint8_t *p) { float v; memcpy(&v, p, 4); return v; }
static std::string str(const Subrecord &s) { return std::string((const char *)s.data, strnlen((const char *)s.data, s.size)); }

struct Topic {
	RecordInfo info;
	std::string edid;
	int type = -1, flags = -1;
	float priority = -1;
	std::vector<uint32_t> infos; // file order
	std::set<uint32_t> quests; // QSTI
};

int main(int argc, char **argv) {
	EsmFile esm_file;
	try { esm_file.open("../fresh_nv_copy/Data/FalloutNV.esm"); } catch (const std::exception &e) { fprintf(stderr, "%s\n", e.what()); return 1; }

	std::map<std::string, uint32_t> npc_by_edid;
	std::map<uint32_t, std::string> edid_of;
	std::vector<Topic> topics;
	std::map<uint32_t, size_t> topic_of_info;
	std::map<uint32_t, uint32_t> previous_of; // INFO -> PNAM
	int info_outside_topic = 0;
	std::map<int, int> info_types, info_flags1_bits, info_flags2_bits, info_data_sizes, responses_per_info, conditions_per_info;
	std::map<std::string, int> subrecord_presence; // INFO subrecord tag -> INFOs having it
	int info_total = 0, info_type_mismatch = 0, info_qsti_not_topic_quest = 0, begin_scripts = 0, end_scripts = 0, both_scripts = 0;
	int anam_speakers = 0, with_getisid = 0, with_voicetype = 0;
	int anam_with_getisid = 0, anam_matches_getisid = 0, anam_without_getisid = 0;
	std::map<std::string, int> anam_target_types;
	std::map<uint32_t, uint32_t> anam_of; // INFO -> ANAM
	std::map<uint32_t, std::set<uint32_t>> getisid_of; // INFO -> GetIsID parameters, run on subject
	std::map<std::string, std::string> type_of_form; // filled below
	std::map<uint32_t, std::vector<std::pair<uint32_t, int>>> infos_naming_npc; // NPC_ -> (INFO, via 0 GetIsID / 1 ANAM)
	std::map<uint32_t, uint32_t> info_quest;
	std::map<std::string, int> run_on_by_function; // "GetIsID run on N"

	std::string last_type;
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type == "GRUP") return;
		std::vector<uint8_t> data;
		std::vector<Subrecord> subs;
		if (r.type == "NPC_" || r.type == "DIAL" || r.type == "INFO" || r.type == "QUST" || r.type == "CREA") {
			data = esm_file.read_record_data(r);
			subs = EsmFile::parse_subrecords(data);
			for (auto &s : subs) if (s.type == "EDID") { edid_of[r.form_id] = str(s); if (r.type == "NPC_") npc_by_edid[str(s)] = r.form_id; }
		}
		if (r.type == "DIAL") {
			Topic t; t.info = r;
			bool seen_qsti = false;
			for (auto &s : subs) {
				if (s.type == "EDID") t.edid = str(s);
				else if (s.type == "QSTI") { t.quests.insert(u32(s.data)); seen_qsti = true; }
				else if (s.type == "PNAM" && s.size >= 4) t.priority = f32(s.data);
				else if (s.type == "DATA") { if (s.size >= 1) t.type = s.data[0]; if (s.size >= 2) t.flags = s.data[1]; }
			}
			(void)seen_qsti;
			topics.push_back(t);
		} else if (r.type == "INFO") {
			info_total++;
			if (topics.empty() || (last_type != "DIAL" && last_type != "INFO")) info_outside_topic++;
			if (!topics.empty()) { topics.back().infos.push_back(r.form_id); topic_of_info[r.form_id] = topics.size() - 1; }
			int responses = 0, conditions = 0;
			bool after_next = false, begin = false, end = false, getisid = false, voice = false;
			std::set<std::string> tags;
			for (auto &s : subs) {
				tags.insert(s.type);
				if (s.type == "DATA") {
					info_data_sizes[(int)s.size]++;
					if (s.size >= 1) { info_types[s.data[0]]++; if (!topics.empty() && s.data[0] != topics.back().type) info_type_mismatch++; }
					if (s.size >= 3) for (int b = 0; b < 8; b++) if (s.data[2] & (1 << b)) info_flags1_bits[b]++;
					if (s.size >= 4) for (int b = 0; b < 8; b++) if (s.data[3] & (1 << b)) info_flags2_bits[b]++;
				} else if (s.type == "QSTI") {
					info_quest[r.form_id] = u32(s.data);
					if (!topics.empty() && !topics.back().quests.count(u32(s.data))) info_qsti_not_topic_quest++;
				} else if (s.type == "PNAM") previous_of[r.form_id] = u32(s.data);
				else if (s.type == "TRDT") responses++;
				else if (s.type == "CTDA" && s.size >= 24) {
					conditions++;
					uint16_t fn = u16(s.data + 8);
					uint32_t run_on = u32(s.data + 20);
					if (fn == 72) { // GetIsID
						getisid = true;
						infos_naming_npc[u32(s.data + 12)].push_back({r.form_id, 0});
						if (run_on == 0) getisid_of[r.form_id].insert(u32(s.data + 12));
						run_on_by_function["GetIsID run on " + std::to_string(run_on)]++;
					}
					if (fn == 427) { voice = true; run_on_by_function["GetIsVoiceType run on " + std::to_string(run_on)]++; }
				}
				else if (s.type == "NEXT") after_next = true;
				else if (s.type == "SCTX" && s.size > 1) { if (after_next) end = true; else begin = true; }
				else if (s.type == "ANAM") { anam_speakers++; anam_of[r.form_id] = u32(s.data); infos_naming_npc[u32(s.data)].push_back({r.form_id, 1}); }
			}
			for (auto &t : tags) subrecord_presence[t]++;
			responses_per_info[responses]++;
			conditions_per_info[std::min(conditions, 10)]++;
			begin_scripts += begin; end_scripts += end; both_scripts += begin && end;
			with_getisid += getisid; with_voicetype += voice;
		}
		last_type = r.type;
	});

	for (auto &[info, speaker] : anam_of) {
		auto it = getisid_of.find(info);
		if (it == getisid_of.end()) anam_without_getisid++;
		else { anam_with_getisid++; if (it->second.count(speaker)) anam_matches_getisid++; }
		auto rec = esm_file.find_record_by_form_id(speaker);
		anam_target_types[rec ? rec->type : (speaker == 0 ? "0" : "missing")]++;
	}
	// Child GRUP membership, against file-order assignment.
	int child_mismatch = 0, child_total = 0;
	for (size_t i = 0; i < topics.size(); i++) {
		std::vector<uint32_t> children;
		for (auto &c : esm_file.get_child_records(topics[i].info)) if (c.type == "INFO") children.push_back(c.form_id);
		child_total += children.size();
		if (children != topics[i].infos && child_mismatch++ < 5) printf("CHILD MISMATCH DIAL %08X %s: %zu children, %zu by file order\n", topics[i].info.form_id, topics[i].edid.c_str(), children.size(), topics[i].infos.size());
	}

	// PNAM against file order: is each INFO's PNAM the INFO before it in its topic?
	int pnam_present = 0, pnam_is_previous = 0, pnam_zero_first = 0, pnam_other = 0, first_without_pnam = 0, pnam_other_topic = 0;
	for (auto &t : topics) {
		for (size_t i = 0; i < t.infos.size(); i++) {
			auto it = previous_of.find(t.infos[i]);
			if (it == previous_of.end()) { if (i == 0) first_without_pnam++; continue; }
			pnam_present++;
			uint32_t prev = it->second;
			if (i > 0 && prev == t.infos[i - 1]) pnam_is_previous++;
			else if (i == 0 && prev == 0) pnam_zero_first++;
			else {
				pnam_other++;
				if (prev != 0 && topic_of_info.count(prev) && topic_of_info[prev] != topic_of_info[t.infos[i]]) pnam_other_topic++;
			}
		}
	}

	std::map<int, int> topic_types, topic_flags, infos_per_topic_bucket;
	std::map<float, int> priorities;
	int topics_without_infos = 0, topics_multi_quest = 0;
	for (auto &t : topics) {
		topic_types[t.type]++; topic_flags[t.flags]++; priorities[t.priority]++;
		if (t.infos.empty()) topics_without_infos++;
		if (t.quests.size() > 1) topics_multi_quest++;
		int n = t.infos.size(); infos_per_topic_bucket[n == 0 ? 0 : n == 1 ? 1 : n <= 5 ? 5 : n <= 20 ? 20 : n <= 100 ? 100 : 1000]++;
	}

	printf("DIAL %zu (without INFO %d, naming more than one QSTI %d)\n", topics.size(), topics_without_infos, topics_multi_quest);
	printf("DIAL type:"); for (auto &[k, v] : topic_types) printf(" %d:x%d", k, v); printf("\n");
	printf("DIAL flags:"); for (auto &[k, v] : topic_flags) printf(" %d:x%d", k, v); printf("\n");
	printf("DIAL priority:"); for (auto &[k, v] : priorities) printf(" %g:x%d", k, v); printf("\n");
	printf("DIAL INFO count buckets (<=):"); for (auto &[k, v] : infos_per_topic_bucket) printf(" %d:x%d", k, v); printf("\n");
	printf("INFO %d; outside a topic's child GRUP by file order %d; child GRUP check: %d mismatched topics, %d children\n", info_total, info_outside_topic, child_mismatch, child_total);
	printf("INFO DATA sizes:"); for (auto &[k, v] : info_data_sizes) printf(" %d:x%d", k, v); printf("\n");
	printf("INFO DATA type:"); for (auto &[k, v] : info_types) printf(" %d:x%d", k, v); printf("; differs from topic type %d\n", info_type_mismatch);
	printf("INFO flags1 bits:"); for (auto &[k, v] : info_flags1_bits) printf(" %d:x%d", k, v); printf("\n");
	printf("INFO flags2 bits:"); for (auto &[k, v] : info_flags2_bits) printf(" %d:x%d", k, v); printf("\n");
	printf("INFO QSTI not among its topic's QSTI: %d\n", info_qsti_not_topic_quest);
	printf("INFO PNAM present %d: previous INFO in file order %d, 0 on first %d, other %d (in another topic %d); first INFO without PNAM %d\n", pnam_present, pnam_is_previous, pnam_zero_first, pnam_other, pnam_other_topic, first_without_pnam);
	printf("INFO responses (TRDT) per INFO:"); for (auto &[k, v] : responses_per_info) printf(" %d:x%d", k, v); printf("\n");
	printf("INFO conditions per INFO (10 = 10+):"); for (auto &[k, v] : conditions_per_info) printf(" %d:x%d", k, v); printf("\n");
	printf("INFO scripts: begin %d, end %d, both %d\n", begin_scripts, end_scripts, both_scripts);
	printf("INFO speakers: ANAM %d, GetIsID condition %d, GetIsVoiceType condition %d\n", anam_speakers, with_getisid, with_voicetype);
	printf("ANAM: with a subject GetIsID %d (naming the ANAM speaker %d), without %d; targets:", anam_with_getisid, anam_matches_getisid, anam_without_getisid);
	for (auto &[k, v] : anam_target_types) printf(" %s:x%d", k.c_str(), v); printf("\n");
	for (auto &[k, v] : run_on_by_function) printf("RUN ON %s x%d\n", k.c_str(), v);
	printf("INFO subrecords present:"); for (auto &[k, v] : subrecord_presence) printf(" %s:%d", k.c_str(), v); printf("\n");

	for (int a = 1; a < argc; a++) {
		auto npc = npc_by_edid.find(argv[a]);
		if (npc == npc_by_edid.end()) { printf("NPC %s not found\n", argv[a]); continue; }
		std::map<std::string, int> by_topic;
		std::set<uint32_t> quests;
		for (auto &[info, via] : infos_naming_npc[npc->second]) {
			auto &t = topics[topic_of_info[info]];
			by_topic[t.edid + " (type " + std::to_string(t.type) + (via ? ", ANAM" : "") + ")"]++;
			quests.insert(info_quest[info]);
		}
		printf("NPC %s %08X: %zu INFOs name it, in %zu topics, from %zu quests\n", argv[a], npc->second, infos_naming_npc[npc->second].size(), by_topic.size(), quests.size());
		for (auto &[k, v] : by_topic) printf("   %s x%d\n", k.c_str(), v);
		printf("   quests:"); for (auto q : quests) printf(" %s", edid_of[q].c_str()); printf("\n");
	}
	return 0;
}
