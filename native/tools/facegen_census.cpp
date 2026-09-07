// Exhaustive census of NPC_ FaceGen payloads in the official masters.
// It reports byte sizes and float plausibility without assigning semantic
// names to the values; raw field identity remains FGGS/FGGA/FGTS.
#include "esm/esm_file.h"
#include "common/byte_reader.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <exception>
#include <string>

static float as_float(const uint8_t *p) {
	uint32_t bits = static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
	float value;
	std::memcpy(&value, &bits, sizeof(value));
	return value;
}

int main() {
	const char *masters[] = {"FalloutNV.esm", "CaravanPack.esm", "ClassicPack.esm", "DeadMoney.esm", "GunRunnersArsenal.esm", "HonestHearts.esm", "LonesomeRoad.esm", "MercenaryPack.esm", "OldWorldBlues.esm", "TribalPack.esm"};
	std::printf("file,form_id,field,bytes,float_count,finite_count,min,max\n");
	for (const char *name : masters) {
		esm::EsmFile file;
		try { file.open(std::string("fresh_nv_copy/Data/") + name); }
		catch (const std::exception &e) { std::fprintf(stderr, "%s: %s\n", name, e.what()); continue; }
		file.for_each_record([&](const esm::RecordInfo &record) {
			if (record.type != "NPC_") return;
			const auto bytes = file.read_record_data(record);
			for (const auto &sub : esm::EsmFile::parse_subrecords(bytes)) {
				if (sub.type != "FGGS" && sub.type != "FGGA" && sub.type != "FGTS") continue;
				const size_t count = sub.size / 4;
				int finite = 0;
				float min_value = 0.0f, max_value = 0.0f;
				for (size_t i = 0; i < count; ++i) {
					float value = as_float(sub.data + i * 4);
					if (!std::isfinite(value)) continue;
					if (finite++ == 0) min_value = max_value = value;
					else { min_value = std::min(min_value, value); max_value = std::max(max_value, value); }
				}
				std::printf("%s,0x%08X,%s,%zu,%zu,%d,%.9g,%.9g\n", name, record.form_id, sub.type.c_str(), sub.size, count, finite, min_value, max_value);
			}
		});
	}
}
