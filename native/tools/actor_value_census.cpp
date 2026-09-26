// Census of the authored inputs to actor values: every NPC_'s ACBS/DATA/DNAM
// and TPLT, every CREA's DATA/ACBS, and the fAVD*/iAVD* game settings.
#include "esm/esm_file.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <string>

using namespace esm;

static uint16_t u16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }
static uint32_t u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static int32_t i32(const uint8_t *p) { int32_t v; memcpy(&v, p, 4); return v; }
static int16_t i16(const uint8_t *p) { int16_t v; memcpy(&v, p, 2); return v; }
static float f32(const uint8_t *p) { float v; memcpy(&v, p, 4); return v; }

int main(int argc, char **argv) {
	EsmFile esm_file;
	try {
		esm_file.open("../fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}
	std::map<std::string, int> counts;
	std::map<size_t, int> data_sizes, dnam_sizes, crea_data_sizes;
	esm_file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "NPC_" && r.type != "CREA" && r.type != "GMST") return;
		auto data = esm_file.read_record_data(r);
		auto subs = EsmFile::parse_subrecords(data);
		std::string edid;
		const Subrecord *acbs = nullptr, *dat = nullptr, *dnam = nullptr, *tplt = nullptr, *cnam = nullptr;
		for (const auto &s : subs) {
			if (s.type == "EDID") edid = std::string((const char *)s.data, strnlen((const char *)s.data, s.size));
			else if (s.type == "ACBS") acbs = &s;
			else if (s.type == "DATA") dat = &s;
			else if (s.type == "DNAM") dnam = &s;
			else if (s.type == "TPLT") tplt = &s;
			else if (s.type == "CNAM") cnam = &s;
		}
		if (r.type == "GMST") {
			if ((edid.rfind("fAVD", 0) == 0 || edid.rfind("iAVD", 0) == 0 || edid == "fNPCAttributeHealthMult" || edid == "fLowLevelNPCBaseHealthMult") && dat) {
				if (edid[0] == 'f') printf("GMST %s = %g\n", edid.c_str(), f32(dat->data));
				else printf("GMST %s = %d\n", edid.c_str(), i32(dat->data));
			}
			return;
		}
		counts[r.type]++;
		uint32_t flags = acbs ? u32(acbs->data) : 0;
		uint16_t tflags = acbs && acbs->size >= 24 ? u16(acbs->data + 22) : 0;
		uint16_t level = acbs ? u16(acbs->data + 8) : 0;
		if (flags & 0x10) counts[r.type + " autocalc"]++;
		if (flags & 0x80) counts[r.type + " pc_level_mult"]++;
		if (tplt) counts[r.type + " has_tplt"]++;
		if (tplt && (tflags & 0x02)) {
			counts[r.type + " tplt_use_stats"]++;
			auto target = esm_file.find_record_by_form_id(u32(tplt->data));
			counts[r.type + " tplt_use_stats -> " + (target ? target->type : std::string("missing"))]++;
		}
		if (r.type == "NPC_") {
			if (dat) data_sizes[dat->size]++;
			if (dnam) dnam_sizes[dnam->size]++; else counts["NPC_ no_dnam"]++;
			bool show = edid == "Player" || edid == "DocMitchell" || edid == "GSSunnySmiles" || edid == "VMS47Easy" || r.form_id == 7;
			if (show && dat) {
				printf("NPC_ %08X %s flags=%08X tflags=%04X level=%u calc=%u..%u speed=%u fatigue=%u karma=%g health=%d SPECIAL=",
						r.form_id, edid.c_str(), flags, tflags, level, u16(acbs->data + 10), u16(acbs->data + 12),
						u16(acbs->data + 14), u16(acbs->data + 4), f32(acbs->data + 16), i32(dat->data));
				for (int i = 0; i < 7 && 4 + i < (int)dat->size; i++) printf("%u ", dat->data[4 + i]);
				printf("class=%08X skills=", cnam ? u32(cnam->data) : 0);
				for (size_t i = 0; dnam && i < dnam->size; i++) printf("%u%s", dnam->data[i], i == 13 ? " | " : " ");
				printf("\n");
			}
		} else {
			if (dat) crea_data_sizes[dat->size]++;
			if (edid == "GSGecko" || edid == "Rex" || edid == "VMS47Rex" || edid.find("CrGecko") == 0) {
				if (dat && dat->size >= 17)
					printf("CREA %08X %s flags=%08X level=%u health=%d damage=%d combat=%u SPECIAL=%u %u %u %u %u %u %u\n",
							r.form_id, edid.c_str(), flags, level, i16(dat->data + 4), i16(dat->data + 8), dat->data[1],
							dat->data[10], dat->data[11], dat->data[12], dat->data[13], dat->data[14], dat->data[15], dat->data[16]);
			}
		}
	});
	for (auto &[k, v] : counts) printf("count %s = %d\n", k.c_str(), v);
	for (auto &[k, v] : data_sizes) printf("NPC_ DATA size %zu x%d\n", k, v);
	for (auto &[k, v] : dnam_sizes) printf("NPC_ DNAM size %zu x%d\n", k, v);
	for (auto &[k, v] : crea_data_sizes) printf("CREA DATA size %zu x%d\n", k, v);
	return 0;
}
