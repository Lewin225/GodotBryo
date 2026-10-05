// follow_package_census: every FOLLOW package (PKDT Type 1) in FalloutNV.esm:
// its PTDT target type and target, and the PTDT Count / Distance value, with
// histograms, the packages that follow the player, and how many carry PKDT
// General Flags 0x2000 (Always Run), companions' (EditorID starting
// "Followers") against the rest.
//
//   tools/follow_package_census
#include "esm/esm_file.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

using namespace esm;

namespace {

constexpr uint8_t kFollowType = 1;
constexpr uint32_t kPlayerReference = 0x14;

template <typename T>
T read(const Subrecord &s, size_t offset) {
	T value{};
	if (offset + sizeof(T) <= s.size) std::memcpy(&value, s.data + offset, sizeof(T));
	return value;
}

} // namespace

int main() {
	EsmFile file;
	try {
		file.open("../fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		std::fprintf(stderr, "%s\n", e.what());
		return 1;
	}
	int follow = 0, with_target = 0;
	int companion_total = 0, companion_run = 0, other_total = 0, other_run = 0;
	std::vector<std::string> always_run_samples;
	std::map<int, int> target_types, distances;
	std::vector<std::string> follows_player;
	std::map<uint32_t, int> targets;
	file.for_each_record([&](const RecordInfo &r) {
		if (r.type != "PACK") return;
		std::vector<uint8_t> data;
		try {
			data = file.read_record_data(r);
		} catch (...) {
			return;
		}
		std::string editor_id;
		bool is_follow = false;
		uint32_t general_flags = 0;
		bool has_target = false;
		int32_t target_type = -1;
		uint32_t target = 0;
		int32_t distance = 0;
		for (auto &s : EsmFile::parse_subrecords(data)) {
			if (s.type == "EDID") editor_id = (const char *)s.data;
			if (s.type == "PKDT" && s.size >= 5) {
				is_follow = s.data[4] == kFollowType;
				general_flags = read<uint32_t>(s, 0);
			}
			if (s.type == "PTDT" && s.size >= 12 && !has_target) {
				has_target = true;
				target_type = read<int32_t>(s, 0);
				target = read<uint32_t>(s, 4);
				distance = read<int32_t>(s, 8);
			}
		}
		if (!is_follow) return;
		follow++;
		bool companion = editor_id.rfind("Followers", 0) == 0;
		bool always_run = (general_flags & 0x2000) != 0;
		(companion ? companion_total : other_total)++;
		if (always_run) {
			(companion ? companion_run : other_run)++;
			always_run_samples.push_back(editor_id);
		}
		if (!has_target) return;
		with_target++;
		target_types[target_type]++;
		distances[distance]++;
		if (target_type == 0) targets[target]++;
		if (target_type == 0 && target == kPlayerReference) follows_player.push_back(editor_id + " (distance " + std::to_string(distance) + ")");
	});
	std::printf("FOLLOW packages: %d, with PTDT: %d\n", follow, with_target);
	std::printf("target type (0 reference, 1 object ID, 2 object type, 3 linked reference):");
	for (auto &[type, count] : target_types) std::printf(" %d:%d", type, count);
	std::printf("\nCount / Distance values:");
	for (auto &[value, count] : distances) std::printf(" %d:%d", value, count);
	std::printf("\nspecific references followed: %zu distinct\n", targets.size());
	std::printf("Always Run (0x2000): companions %d of %d, others %d of %d; e.g.", companion_run, companion_total, other_run, other_total);
	for (auto &name : always_run_samples) std::printf(" %s", name.c_str());
	std::printf("\n");
	std::printf("following the player (%zu):\n", follows_player.size());
	for (auto &line : follows_player) std::printf("  %s\n", line.c_str());
	return 0;
}
