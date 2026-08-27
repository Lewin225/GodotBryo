// One-off: dump NiControllerManager.flags (inherited from NiTimeController,
// currently NOT extracted into AnimationSequence/nif_types.h at all) for a
// real NIF, plus each owned NiControllerSequence's own cycleType/frequency/
// startTime/stopTime/playBackwards -- checking whether there's a real,
// currently-unread autoplay-style signal distinguishing an ambient/idle
// animated prop (windmill, saloon sign) from a trigger-only one (a door).
#include "bsa/bsa_archive.h"
#include "NifFile.hpp"
#include "Animation.hpp"
#include <bitset>
#include <cstdio>
#include <sstream>
#include <string>

static void dump(const std::string &rel_path) {
	bsa::BsaArchive archive;
	try {
		archive.open("fresh_nv_copy/Data/Fallout - Meshes.bsa");
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return;
	}
	const bsa::Entry *entry = archive.find("meshes\\" + rel_path);
	if (entry == nullptr) {
		printf("=== %s === NOT FOUND\n", rel_path.c_str());
		return;
	}
	std::vector<uint8_t> bytes = archive.extract(*entry);
	std::stringstream ss(std::string(reinterpret_cast<char *>(bytes.data()), bytes.size()));
	nifly::NifFile nif;
	if (nif.Load(ss) != 0) {
		printf("=== %s === parse failed\n", rel_path.c_str());
		return;
	}
	auto &hdr = nif.GetHeader();
	printf("=== %s ===\n", rel_path.c_str());
	for (uint32_t i = 0; i < hdr.GetNumBlocks(); ++i) {
		auto *manager = hdr.GetBlock<nifly::NiControllerManager>(i);
		if (!manager) continue;
		printf("  NiControllerManager flags=0x%04X (%s) cumulative=%d\n",
				manager->flags, std::bitset<16>(manager->flags).to_string().c_str(), manager->cumulative);
		for (auto &seq_ref : manager->controllerSequenceRefs) {
			auto *seq = hdr.GetBlock<nifly::NiControllerSequence>(seq_ref);
			if (!seq) continue;
			printf("    seq name=%s cycleType=%d freq=%.3f phase=%.3f start=%.3f stop=%.3f playBackwards=%d weight=%.3f\n",
					seq->name.get().c_str(), int(seq->cycleType), seq->frequency, seq->phase,
					seq->startTime, seq->stopTime, seq->playBackwards, seq->weight);
		}
	}
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s <meshes-relative-nif-path> [more...]\n", argv[0]);
		return 1;
	}
	for (int i = 1; i < argc; ++i) dump(argv[i]);
	return 0;
}
