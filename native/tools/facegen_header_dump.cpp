#include "bsa/bsa_archive.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

static uint32_t u32(const std::vector<uint8_t> &b, size_t o) {
	return o + 4 <= b.size() ? static_cast<uint32_t>(b[o]) | (static_cast<uint32_t>(b[o + 1]) << 8) | (static_cast<uint32_t>(b[o + 2]) << 16) | (static_cast<uint32_t>(b[o + 3]) << 24) : 0;
}

int main() {
	bsa::BsaArchive archive;
	try { archive.open("fresh_nv_copy/Data/Fallout - Meshes.bsa"); }
	catch (const std::exception &e) { std::fprintf(stderr, "%s\n", e.what()); return 1; }
	for (const char *path : {"meshes\\characters\\head\\headhuman.tri", "meshes\\characters\\head\\headhuman.egm", "meshes\\characters\\head\\headghoul.tri", "meshes\\characters\\head\\headghoul.egm"}) {
		const auto *entry = archive.find(path);
		if (!entry) { std::printf("%s NOT_FOUND\n", path); continue; }
		auto b = archive.extract(*entry);
		std::printf("%s bytes=%zu magic=", path, b.size());
		for (size_t i = 0; i < 8 && i < b.size(); ++i) std::printf("%c", b[i] >= 32 && b[i] < 127 ? b[i] : '.');
		if (b.size() >= 48) std::printf(" u32[1..10]=%u,%u,%u,%u,%u,%u,%u,%u,%u,%u", u32(b, 8), u32(b, 12), u32(b, 16), u32(b, 20), u32(b, 24), u32(b, 28), u32(b, 32), u32(b, 36), u32(b, 40), u32(b, 44));
		if (b.size() >= 64 && std::string(path).find(".egm") != std::string::npos) {
			float scale = 0.0f;
			std::memcpy(&scale, b.data() + 64, sizeof(scale));
			std::printf(" first_scale=%g", scale);
		}
		std::printf("\n");
	}
}
