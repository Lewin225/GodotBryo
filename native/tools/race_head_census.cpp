// Exhaustive official-master census for RACE gendered head/body parts.
// This deliberately reports every descriptor, including icon-only entries,
// so missing MODL values cannot disappear into a convenient mesh-only API.
#include "esm/esm_file.h"
#include <cstdio>
#include <exception>
#include <string>

int main() {
	const char *masters[] = {"FalloutNV.esm", "CaravanPack.esm", "ClassicPack.esm", "DeadMoney.esm", "GunRunnersArsenal.esm", "HonestHearts.esm", "LonesomeRoad.esm", "MercenaryPack.esm", "OldWorldBlues.esm", "TribalPack.esm"};
	std::printf("file,form_id,gender,head_index,head_model,head_icon,body_count\n");
	for (const char *name : masters) {
		esm::EsmFile file;
		try { file.open(std::string("fresh_nv_copy/Data/") + name); }
		catch (const std::exception &e) { std::fprintf(stderr, "%s: %s\n", name, e.what()); continue; }
		file.for_each_record([&](const esm::RecordInfo &record) {
			if (record.type != "RACE") return;
			if (record.form_id != 0x00003B3E) return;
			for (bool female : {false, true}) {
				auto heads = file.get_race_head_parts(record.form_id, female);
				auto bodies = file.get_race_body_parts(record.form_id, female);
				if (record.form_id == 0x00003B3E && !female) {
					for (const auto &body : bodies) std::fprintf(stderr, "ghoul body %u model=%s icon=%s\n", body.index, body.model_path.c_str(), body.icon_path.c_str());
				}
				if (heads.empty()) {
					std::printf("%s,0x%08X,%s,,,,%zu\n", name, record.form_id, female ? "female" : "male", bodies.size());
				}
				for (const auto &head : heads) {
					std::printf("%s,0x%08X,%s,%u,%s,%s,%zu\n", name, record.form_id, female ? "female" : "male", head.index, head.model_path.c_str(), head.icon_path.c_str(), bodies.size());
				}
			}
		});
	}
	return 0;
}
