// Census the shipped Character animation paths and their optional
// AnimationTextData sidecars. This establishes raw archive facts only: where
// KFs live, whether TXT sidecars exist, and whether each TXT basename has a
// matching KF basename in the same actor-animation corpus.
//
// Build from native/:
// g++ -std=c++17 -O2 -Isrc tools/animation_text_data_census.cpp \
//     src/bsa/bsa_archive.cpp src/bsa/positional_read.cpp -lz \
//     -o tools/animation_text_data_census
// Run: tools/animation_text_data_census ../fresh_nv_copy/Data

#include "bsa/bsa_archive.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <iostream>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

std::string lower(std::string value) {
	std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
		return static_cast<char>(std::tolower(c));
	});
	return value;
}

bool begins_with(const std::string& value, const std::string& prefix) {
	return value.compare(0, prefix.size(), prefix) == 0;
}

bool ends_with(const std::string& value, const std::string& suffix) {
	return value.size() >= suffix.size()
		&& value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string strip_extension(const std::string& path) {
	const size_t dot = path.rfind('.');
	return dot == std::string::npos ? path : path.substr(0, dot);
}

} // namespace

int main(int argc, char** argv) {
	if (argc != 2) {
		std::cerr << "usage: animation_text_data_census <DataDir>\n";
		return 2;
	}

	std::vector<fs::path> archives;
	for (const fs::directory_entry& entry : fs::directory_iterator(argv[1])) {
		if (lower(entry.path().extension().string()) == ".bsa")
			archives.push_back(entry.path());
	}
	std::sort(archives.begin(), archives.end());

	const std::string character_root = "meshes\\characters\\";
	const std::string text_root = "meshes\\characters\\_male\\animationtextdata\\";
	std::set<std::string> kf_paths;
	std::set<std::string> text_paths;
	std::map<std::string, int> kf_by_root;
	std::map<std::string, int> text_by_archive;
	for (const fs::path& archive_path : archives) {
		bsa::BsaArchive archive;
		try {
			archive.open(archive_path.string());
		} catch (const std::exception& error) {
			std::cerr << "skipped " << archive_path.filename().string() << ": " << error.what() << "\n";
			continue;
		}
		for (const bsa::Entry& entry : archive.entries()) {
			const std::string path = lower(entry.folder + "\\" + entry.file);
			if (!begins_with(path, character_root))
				continue;
			if (ends_with(path, ".kf")) {
				kf_paths.insert(path);
				const std::string remaining = path.substr(character_root.size());
				const size_t slash = remaining.find('\\');
				kf_by_root[slash == std::string::npos ? "<root>" : remaining.substr(0, slash)]++;
			}
			if (begins_with(path, text_root) && ends_with(path, ".txt")) {
				text_paths.insert(path);
				text_by_archive[archive_path.filename().string()]++;
			}
		}
	}

	std::cout << "character KFs: " << kf_paths.size() << "\n";
	for (const auto& [root, count] : kf_by_root)
		std::cout << "  " << root << ": " << count << "\n";
	std::cout << "_male AnimationTextData TXT files: " << text_paths.size() << "\n";
	for (const auto& [archive, count] : text_by_archive)
		std::cout << "  " << archive << ": " << count << "\n";

	int matching_names = 0;
	int missing_kf = 0;
	std::vector<std::string> missing_examples;
	for (const std::string& text_path : text_paths) {
		const std::string basename = strip_extension(text_path.substr(text_root.size()));
		bool matched = false;
		for (const std::string& kf_path : kf_paths) {
			if (strip_extension(kf_path.substr(kf_path.rfind('\\') + 1)) == basename) {
				matched = true;
				break;
			}
		}
		if (matched) {
			matching_names++;
		} else {
			missing_kf++;
			if (missing_examples.size() < 12)
				missing_examples.push_back(text_path);
		}
	}
	std::cout << "TXT basenames matching a character KF: " << matching_names << "\n";
	std::cout << "TXT basenames without a character KF: " << missing_kf << "\n";
	for (const std::string& path : missing_examples)
		std::cout << "  unmatched: " << path << "\n";
	return 0;
}
