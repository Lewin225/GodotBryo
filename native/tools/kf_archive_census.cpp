// Counts .kf entries under meshes/ in every FalloutNV Data BSA: per archive,
// in total, and as distinct paths across archives.
#include "bsa/bsa_archive.h"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <map>
#include <set>
#include <string>

int main() {
	std::set<std::string> distinct;
	std::map<std::string, int> path_archives;
	int total = 0;
	for (const auto &f : std::filesystem::directory_iterator("../fresh_nv_copy/Data")) {
		if (f.path().extension() != ".bsa") continue;
		bsa::BsaArchive a;
		try { a.open(f.path().string()); } catch (const std::exception &e) {
			printf("%s: open failed %s\n", f.path().filename().c_str(), e.what());
			continue;
		}
		int n = 0;
		for (const auto &e : a.entries()) {
			std::string p = e.folder + "/" + e.file;
			std::transform(p.begin(), p.end(), p.begin(), ::tolower);
			std::replace(p.begin(), p.end(), '\\', '/');
			if (p.rfind("meshes/", 0) != 0 || p.size() < 3 || p.substr(p.size() - 3) != ".kf") continue;
			n++;
			distinct.insert(p);
			path_archives[p]++;
		}
		total += n;
		if (n) printf("%s: %d\n", f.path().filename().c_str(), n);
	}
	int shared = 0;
	for (auto &[p, c] : path_archives) if (c > 1) shared++;
	printf("total .kf entries: %d\ndistinct .kf paths: %d\npaths in more than one archive: %d\n", total, (int)distinct.size(), shared);
	return 0;
}
