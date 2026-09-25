// One-off census: how varied are NPC_.AIDT ("AI Data") field values across
// the real corpus, vs. their documented default/degenerate values.
#include "esm/esm_file.h"
#include <cstdio>
#include <map>
#include <string>
#include <vector>

static uint32_t u32(const uint8_t *p) {
	return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
static int32_t s32(const uint8_t *p) { return static_cast<int32_t>(u32(p)); }

int main(int argc, char **argv) {
	esm::EsmFile file;
	const char *path = argc > 1 ? argv[1] : "fresh_nv_copy/Data/FalloutNV.esm";
	file.open(path);

	int total = 0;
	std::map<int, int> aggression, confidence, energy, responsibility, mood, teaches, max_train, assistance, aggro_behavior;
	std::map<uint32_t, int> services;
	std::map<int32_t, int> aggro_radius;

	file.for_each_record([&](const esm::RecordInfo &record) {
		if (record.type != "NPC_") return;
		std::vector<uint8_t> data = file.read_record_data(record);
		for (const auto &sub : esm::EsmFile::parse_subrecords(data)) {
			if (sub.type != "AIDT" || sub.size < 17) continue;
			total++;
			aggression[sub.data[0]]++;
			confidence[sub.data[1]]++;
			energy[sub.data[2]]++;
			responsibility[sub.data[3]]++;
			mood[sub.data[4]]++;
			services[u32(&sub.data[8])]++;
			teaches[static_cast<int8_t>(sub.data[0xC])]++;
			max_train[sub.data[0xD]]++;
			assistance[static_cast<int8_t>(sub.data[0xE])]++;
			aggro_behavior[sub.data[0xF]]++;
			aggro_radius[s32(&sub.data[0x10])]++;
		}
	});

	auto dump = [](const char *name, const auto &m) {
		std::printf("%s: %zu distinct values\n", name, m.size());
		int shown = 0;
		for (const auto &[value, count] : m) {
			std::printf("  %d = %d\n", static_cast<int>(value), count);
			if (++shown >= 12) { std::printf("  ...\n"); break; }
		}
	};

	std::printf("total NPC_ with AIDT: %d\n\n", total);
	dump("Aggression", aggression);
	dump("Confidence", confidence);
	dump("Energy Level", energy);
	dump("Responsibility", responsibility);
	dump("Mood", mood);
	dump("Teaches", teaches);
	dump("Max Training Level", max_train);
	dump("Assistance", assistance);
	dump("Aggro Radius Behavior", aggro_behavior);
	dump("Aggro Radius", aggro_radius);
	std::printf("Buys/Sells and Services: %zu distinct bitmasks\n", services.size());
	int shown = 0;
	for (const auto &[value, count] : services) {
		std::printf("  0x%08X = %d\n", value, count);
		if (++shown >= 12) { std::printf("  ...\n"); break; }
	}
	return 0;
}
