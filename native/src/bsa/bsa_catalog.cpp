#include "bsa_catalog.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <stdexcept>

namespace bsa {

namespace {

std::string lower(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(),
			[](unsigned char c) { return static_cast<char>(std::tolower(c)); });
	return s;
}

bool ends_with_ci(const std::string &s, const std::string &suffix) {
	if (s.size() < suffix.size()) {
		return false;
	}
	return lower(s.substr(s.size() - suffix.size())) == suffix;
}

} // namespace

bool BsaArchiveCatalog::normalize(const std::string &path, std::string &out,
		std::string &reject_reason) {
	out.clear();
	reject_reason.clear();

	if (path.empty()) {
		reject_reason = "empty path";
		return false;
	}
	if (path.find("://") != std::string::npos) {
		reject_reason = "scheme-qualified path (expected a Data-relative path)";
		return false;
	}

	std::string s = path;
	std::replace(s.begin(), s.end(), '\\', '/');
	s = lower(s);

	if (s[0] == '/' || (s.size() > 1 && s[1] == ':')) {
		reject_reason = "absolute path (expected a Data-relative path)";
		return false;
	}

	// Reject traversal on segment boundaries, not substrings: a file legally
	// named "..foo" is not traversal.
	size_t start = 0;
	while (start <= s.size()) {
		const size_t slash = s.find('/', start);
		const std::string seg = s.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
		if (seg == "..") {
			reject_reason = "path traversal ('..')";
			return false;
		}
		if (slash == std::string::npos) {
			break;
		}
		start = slash + 1;
	}

	out = s;
	return true;
}

std::vector<std::string> BsaArchiveCatalog::priority_order(std::vector<std::string> names) {
	std::vector<std::string> ordered;
	auto take = [&](const std::string &wanted) {
		auto it = std::find(names.begin(), names.end(), wanted);
		if (it != names.end()) {
			ordered.push_back(*it);
			names.erase(it);
			return true;
		}
		return false;
	};

	take("Update.bsa");

	std::vector<std::string> dlc;
	for (const auto &n : names) {
		if (n.rfind("Fallout - ", 0) != 0) {
			dlc.push_back(n);
		}
	}
	std::sort(dlc.begin(), dlc.end());
	for (const auto &n : dlc) {
		take(n);
	}

	static const char *kBase[] = { "Fallout - Misc.bsa", "Fallout - Sound.bsa",
		"Fallout - Voices1.bsa", "Fallout - Meshes.bsa", "Fallout - Textures2.bsa",
		"Fallout - Textures.bsa" };
	for (const char *n : kBase) {
		take(n);
	}

	std::sort(names.begin(), names.end());
	for (const auto &n : names) {
		ordered.push_back(n);
	}
	return ordered;
}

bool BsaArchiveCatalog::open_data_dir(const std::string &data_dir, std::string &error) {
	error.clear();
	archives_.clear();
	archive_names_.clear();
	failed_.clear();
	index_.clear();

	std::error_code ec;
	if (!std::filesystem::is_directory(data_dir, ec)) {
		error = "not a directory: " + data_dir;
		return false;
	}

	std::vector<std::string> names;
	for (const auto &de : std::filesystem::directory_iterator(data_dir, ec)) {
		if (ec) {
			error = "could not enumerate: " + data_dir;
			return false;
		}
		const std::string fname = de.path().filename().string();
		if (ends_with_ci(fname, ".bsa")) {
			names.push_back(fname);
		}
	}
	if (names.empty()) {
		error = "no .bsa archives found in: " + data_dir;
		return false;
	}

	const std::filesystem::path root(data_dir);
	for (const auto &fname : priority_order(std::move(names))) {
		auto archive = std::make_unique<BsaArchive>();
		try {
			archive->open((root / fname).string());
		} catch (const std::exception &e) {
			failed_.push_back(fname + ": " + e.what());
			continue;
		}
		const uint32_t ai = static_cast<uint32_t>(archives_.size());
		const auto &entries = archive->entries();
		for (uint32_t ei = 0; ei < entries.size(); ++ei) {
			// First archive in priority order wins; later duplicates are
			// indexed nowhere but remain reachable through their own archive.
			index_.emplace(entries[ei].normalized_path(), Location{ ai, ei });
		}
		archives_.push_back(std::move(archive));
		archive_names_.push_back(fname);
	}

	if (archives_.empty()) {
		error = "every archive failed to open in: " + data_dir;
		return false;
	}
	return true;
}

bool BsaArchiveCatalog::contains(const std::string &path) const {
	std::string key, reject;
	if (!normalize(path, key, reject)) {
		return false;
	}
	return index_.find(key) != index_.end();
}

std::string BsaArchiveCatalog::winning_archive(const std::string &path) const {
	std::string key, reject;
	if (!normalize(path, key, reject)) {
		return std::string();
	}
	const auto it = index_.find(key);
	if (it == index_.end()) {
		return std::string();
	}
	return archive_names_[it->second.archive_index];
}

BsaArchiveCatalog::ReadResult BsaArchiveCatalog::read(const std::string &path) const {
	ReadResult out;
	std::string key, reject;
	if (!normalize(path, key, reject)) {
		out.error = "rejected: " + reject;
		return out;
	}
	const auto it = index_.find(key);
	if (it == index_.end()) {
		out.error = "not found in any archive";
		return out;
	}
	const Location &loc = it->second;
	out.archive = archive_names_[loc.archive_index];
	try {
		out.data = archives_[loc.archive_index]->extract(
				archives_[loc.archive_index]->entries()[loc.entry_index]);
	} catch (const std::exception &e) {
		// Extraction failure is distinct from "not found": the entry exists.
		out.error = std::string("extraction failed: ") + e.what();
		return out;
	}
	out.found = true; // may legitimately carry zero bytes
	return out;
}

std::vector<std::string> BsaArchiveCatalog::list_with_prefix(const std::string &prefix) const {
	std::vector<std::string> out;
	std::string key, reject;
	if (prefix.empty()) {
		key = "";
	} else if (!normalize(prefix, key, reject)) {
		return out;
	}
	for (const auto &kv : index_) {
		if (kv.first.rfind(key, 0) == 0) {
			out.push_back(kv.first);
		}
	}
	std::sort(out.begin(), out.end());
	return out;
}

} // namespace bsa
