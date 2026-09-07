#include "bsa/bsa_archive.h"

#include <cstdio>
#include <exception>
#include <string>

int main() {
	const char *archives[] = {"Fallout - Meshes.bsa", "Fallout - Textures.bsa"};
	for (const char *name : archives) {
		bsa::BsaArchive archive;
		try { archive.open(std::string("fresh_nv_copy/Data/") + name); }
		catch (const std::exception &e) { std::fprintf(stderr, "%s: %s\n", name, e.what()); continue; }
		std::printf("=== %s ===\n", name);
		for (const auto &entry : archive.entries()) {
			const std::string path = entry.normalized_path();
			if (path.find("head") == std::string::npos && path.find(".tri") == std::string::npos && path.find(".egm") == std::string::npos && path.find(".egt") == std::string::npos) continue;
			std::printf("%s\n", path.c_str());
		}
	}
}
