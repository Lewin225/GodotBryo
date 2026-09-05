// Issue #52 chunk 2 (gate): dumps every subrecord of a real NPC_ record and
// its RNAM-referenced RACE record, raw, to find out whether "full humanoid
// assembly" (shared skeleton.nif + separate body/head/hand NIFs) is a
// formally defined structure the ESM itself points to, or just an observed
// file-layout convention this codebase would otherwise be assuming.
// Deliberately dumps every subrecord unfiltered rather than guessing which
// tags matter -- see AGENTS.md's "verify, don't assume" discipline.
#include "esm/esm_file.h"
#include "common/byte_reader.h"

#include <cctype>
#include <cstdio>
#include <string>

using namespace esm;

namespace {

std::string hex_form_id(uint32_t id) {
	char buf[16];
	snprintf(buf, sizeof(buf), "%08X", id);
	return buf;
}

// Renders a subrecord's raw bytes plausibly: as a FormID if it's exactly 4
// bytes and looks like one, as a printable string if it looks like one,
// otherwise as a hex byte dump. No assumption about which interpretation is
// "correct" per-tag -- just print all plausible readings and let a human
// (or a follow-up targeted read) decide.
void dump_subrecord(const Subrecord &s) {
	printf("  %s (%u bytes):", s.type.c_str(), s.size);
	if (s.size == 4) {
		util::ByteReader r(s.data, s.size);
		uint32_t as_u32 = r.read_u32();
		printf(" u32/formid=0x%08X (%u)", as_u32, as_u32);
	}
	bool printable = s.size > 0;
	for (size_t i = 0; i < s.size && printable; ++i) {
		unsigned char c = s.data[i];
		if (c == 0 && i == s.size - 1) continue; // trailing NUL is fine
		if (!std::isprint(c) && c != '\n' && c != '\t') printable = false;
	}
	if (printable && s.size > 0) {
		printf(" str=\"%s\"", s.as_string().c_str());
	}
	if (s.size <= 32) {
		printf(" hex=");
		for (size_t i = 0; i < s.size; ++i) printf("%02X", s.data[i]);
	}
	printf("\n");
}

void dump_record(const EsmFile &esm, const RecordInfo &rec, const char *label) {
	printf("=== %s: %s form_id=%s flags=0x%08X ===\n", label, rec.type.c_str(), hex_form_id(rec.form_id).c_str(), rec.flags);
	std::vector<uint8_t> data = esm.read_record_data(rec);
	for (const auto &s : EsmFile::parse_subrecords(data)) {
		dump_subrecord(s);
	}
}

} // namespace

int main() {
	EsmFile esm;
	try {
		esm.open("fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}

	// Doc Mitchell's real NPC_ base record, resolved by esm_actor_survey.cpp
	// against GSDocMitchellHouse's ACHR: base=00104C0C EDID=DocMitchell.
	uint32_t doc_form_id = 0x00104C0C;
	auto npc = esm.find_record_by_form_id(doc_form_id);
	if (!npc) {
		fprintf(stderr, "DocMitchell NPC_ (0x%08X) not found\n", doc_form_id);
		return 1;
	}
	dump_record(esm, *npc, "NPC_");

	// Pull RNAM (race FormID) out of what we just dumped, to chase it.
	std::vector<uint8_t> npc_data = esm.read_record_data(*npc);
	uint32_t race_form_id = 0;
	for (const auto &s : EsmFile::parse_subrecords(npc_data)) {
		if (s.type == "RNAM" && s.size >= 4) {
			util::ByteReader r(s.data, s.size);
			race_form_id = r.read_u32();
		}
	}
	printf("\nNPC_'s RNAM (race) -> 0x%08X\n\n", race_form_id);

	if (race_form_id != 0) {
		auto race = esm.find_record_by_form_id(race_form_id);
		if (race) {
			dump_record(esm, *race, "RACE");
		} else {
			printf("RACE 0x%08X not found\n", race_form_id);
		}
	}

	return 0;
}
