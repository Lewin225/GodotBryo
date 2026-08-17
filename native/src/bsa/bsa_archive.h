#ifndef BSA_ARCHIVE_H
#define BSA_ARCHIVE_H

#include "bsa_types.h"

#include <cstdio>
#include <string>
#include <unordered_map>
#include <vector>

namespace bsa {

// Read-only reader for Oblivion/FO3/New Vegas BSA archives (version 103/104).
// Not thread-safe (uses a single FILE* with seek+read); open one instance
// per thread if concurrent extraction is ever needed.
class BsaArchive {
public:
	BsaArchive() = default;
	~BsaArchive();

	BsaArchive(const BsaArchive &) = delete;
	BsaArchive &operator=(const BsaArchive &) = delete;

	// Throws std::runtime_error on any structural problem (bad magic,
	// unsupported version, truncated file, etc). Phase 0 tooling is allowed
	// to let this propagate/crash loudly; callers doing real integration
	// (0.5, later phases) should catch and report.
	void open(const std::string &path);

	const Header &header() const { return header_; }
	const std::vector<Entry> &entries() const { return entries_; }

	// Case-insensitive lookup by "folder\file" or "folder/file" (either
	// separator accepted). Returns nullptr if not found.
	const Entry *find(const std::string &path) const;

	// Extracts and (if needed) decompresses a single entry's data.
	std::vector<uint8_t> extract(const Entry &entry) const;

private:
	std::FILE *file_ = nullptr;
	Header header_;
	std::vector<Entry> entries_;
	std::unordered_map<std::string, size_t> path_index_; // normalized_path() -> entries_ index

	std::vector<uint8_t> read_at(size_t offset, size_t size) const;
};

} // namespace bsa

#endif // BSA_ARCHIVE_H
