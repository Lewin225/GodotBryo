#ifndef BSA_CATALOG_H
#define BSA_CATALOG_H

#include "bsa_archive.h"

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace bsa {

// Immutable catalog over every BSA in a Data/ directory.
//
// Built once, single-threaded, in BSA priority order; the first archive to
// claim a normalized path wins. After open_data_dir() returns, the catalog and
// every archive index it owns are read-only, so read()/contains()/list_*() are
// safe to call concurrently from any thread (reads are positional -- see
// positional_read.h).
class BsaArchiveCatalog {
public:
	// Compact index target. Integer pairs rather than entry pointers so
	// ownership stays unambiguous.
	struct Location {
		uint32_t archive_index = 0;
		uint32_t entry_index = 0;
	};

	struct ReadResult {
		bool found = false;
		std::string archive; // winning archive's file name, for diagnostics
		std::vector<uint8_t> data;
		std::string error; // empty on success; set for reject/missing/extract failure
	};

	// Normalizes a Data-relative asset path to lowercase forward-slash form.
	// Returns false and fills `reject_reason` for empty, absolute, "res://"-
	// style, or ".."-traversing paths. Separator/case only: no asset-domain
	// prefix is added or removed here.
	static bool normalize(const std::string &path, std::string &out, std::string &reject_reason);

	// Opens every *.bsa in `data_dir` in priority order and builds the global
	// index. An individual archive that fails to open is recorded and skipped;
	// only an unusable directory is a hard failure.
	bool open_data_dir(const std::string &data_dir, std::string &error);

	bool contains(const std::string &path) const;

	// Winning archive's file name for a path, or empty if not indexed.
	// Index-only: performs no extraction, so a full-corpus priority audit
	// costs nothing but lookups.
	std::string winning_archive(const std::string &path) const;
	ReadResult read(const std::string &path) const;

	// Every normalized path whose prefix matches, deduplicated by the same
	// winner rule read() uses. Prefix is normalized with the same rules.
	std::vector<std::string> list_with_prefix(const std::string &prefix) const;

	size_t entry_count() const { return index_.size(); }
	const std::vector<std::string> &archive_order() const { return archive_names_; }
	const std::vector<std::string> &failed_archives() const { return failed_; }

	// Priority heuristic, carried forward from the existing resolver:
	// Update.bsa, then non-"Fallout - " archives sorted, then the six base
	// archives in fixed order, then anything left over sorted.
	static std::vector<std::string> priority_order(std::vector<std::string> names);

private:
	std::vector<std::unique_ptr<BsaArchive>> archives_;
	std::vector<std::string> archive_names_;
	std::vector<std::string> failed_;
	std::unordered_map<std::string, Location> index_;
};

} // namespace bsa

#endif // BSA_CATALOG_H
