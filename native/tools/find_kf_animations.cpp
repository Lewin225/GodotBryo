// One-off: find real .kf (keyframe animation) files under characters\_male\
// or similar, to confirm the real file-naming convention for movement
// animations (walk cycles etc.) before wiring anything up.
#include "bsa/bsa_archive.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <string>

static std::string lower(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
	return s;
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s <bsa_path> [needle]\n", argv[0]);
		return 1;
	}
	std::string needle = argc >= 3 ? lower(argv[2]) : "";

	bsa::BsaArchive archive;
	try {
		archive.open(argv[1]);
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}

	int count = 0;
	for (const auto &e : archive.entries()) {
		std::string folder = lower(e.folder);
		std::string file = lower(e.file);
		if (file.size() < 3 || file.substr(file.size() - 3) != ".kf") {
			continue;
		}
		if (!needle.empty() && folder.find(needle) == std::string::npos && file.find(needle) == std::string::npos) {
			continue;
		}
		printf("%s\\%s\n", e.folder.c_str(), e.file.c_str());
		count++;
	}
	fprintf(stderr, "-- %d .kf entries matched in %s\n", count, argv[1]);
	return 0;
}
