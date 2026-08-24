// grass_survey -- real-data reconnaissance for issue #12 (exterior GRAS).
//
// Prints every FalloutNV.esm GRAS record's exact DATA words in integer and
// float forms, then maps LTEX.GNAM links to those GRAS records.  This keeps
// the first renderer from guessing either the GRAS DATA layout or which land
// textures actually request grass.
//
// Usage: grass_survey <FalloutNV.esm>

#include "../src/esm/esm_file.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <string>

using namespace esm;

namespace {

uint32_t read_u32(const uint8_t *data) {
	uint32_t value;
	std::memcpy(&value, data, sizeof(value));
	return value;
}

float as_float(uint32_t value) {
	float result;
	std::memcpy(&result, &value, sizeof(result));
	return result;
}

std::string string_subrecord(const std::vector<Subrecord> &subs, const char *tag) {
	for (const Subrecord &sub : subs) {
		if (sub.type == tag) {
			return std::string(reinterpret_cast<const char *>(sub.data), sub.size);
		}
	}
	return "";
}

} // namespace

int main(int argc, char **argv) {
	if (argc != 2) {
		std::fprintf(stderr, "usage: %s FalloutNV.esm\n", argv[0]);
		return 1;
	}

	EsmFile esm;
	try {
		esm.open(argv[1]);
	} catch (const std::exception &e) {
		std::fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}

	std::map<uint32_t, std::string> grass_names;
	std::printf("--- GRAS records ---\n");
	esm.for_each_record([&](const RecordInfo &record) {
		if (record.type != "GRAS") {
			return;
		}
		const std::vector<uint8_t> data = esm.read_record_data(record);
		const std::vector<Subrecord> subs = EsmFile::parse_subrecords(data);
		const std::string edid = string_subrecord(subs, "EDID");
		const std::string modl = string_subrecord(subs, "MODL");
		grass_names[record.form_id] = edid;
		std::printf("%08X  %-34s MODL=%s\n", record.form_id, edid.c_str(), modl.c_str());
		for (const Subrecord &sub : subs) {
			if (sub.type != "DATA") {
				continue;
			}
			std::printf("  DATA (%zu bytes)", sub.size);
			for (size_t offset = 0; offset + 4 <= sub.size; offset += 4) {
				const uint32_t word = read_u32(sub.data + offset);
				std::printf("  [%zu] 0x%08X / %11d / % .6g", offset, word,
						static_cast<int32_t>(word), as_float(word));
			}
			std::printf("\n");
		}
	});

	std::printf("\n--- LTEX.GNAM grass links ---\n");
	esm.for_each_record([&](const RecordInfo &record) {
		if (record.type != "LTEX") {
			return;
		}
		const std::vector<uint8_t> data = esm.read_record_data(record);
		const std::vector<Subrecord> subs = EsmFile::parse_subrecords(data);
		const std::string edid = string_subrecord(subs, "EDID");
		for (const Subrecord &sub : subs) {
			if (sub.type == "GNAM" && sub.size >= 4) {
				const uint32_t grass_id = read_u32(sub.data);
				std::printf("%08X  %-38s -> %08X  %s\n", record.form_id,
						edid.c_str(), grass_id, grass_names[grass_id].c_str());
			}
		}
	});
	return 0;
}
