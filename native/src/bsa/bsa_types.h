#ifndef BSA_TYPES_H
#define BSA_TYPES_H

#include <cstdint>
#include <string>

namespace bsa {

// Fallout 3 / Fallout: New Vegas archives are version 104. Oblivion uses 103
// with an identical record layout (only Skyrim SE's 105 adds a wider
// directory name_offset field, which this reader does not need to support).
constexpr uint32_t kVersionOblivion = 103;
constexpr uint32_t kVersionFO3NV = 104;

constexpr char kMagic[4] = { 'B', 'S', 'A', '\0' };

// archive_flags bits (header).
namespace ArchiveFlag {
constexpr uint32_t DirectoriesNamed = 0x001;
constexpr uint32_t FilesNamed = 0x002;
constexpr uint32_t FilesCompressed = 0x004; // default compression state for all files
constexpr uint32_t Xbox360Archive = 0x040; // byte-swapped; not supported
// If set, each file's data blob is preceded by a BZString repeating its own
// file name before the (optionally compressed) payload, and the file
// record's size field includes those prefix bytes.
constexpr uint32_t FileNamesEmbedded = 0x100;
} // namespace ArchiveFlag

// Per-file-record size field: low 30 bits are the stored size, bit 30 is a
// per-file toggle against the archive's default FilesCompressed state.
constexpr uint32_t kSizeMask = 0x3FFFFFFF;
constexpr uint32_t kCompressedToggleBit = 0x40000000;

struct Header {
	uint32_t version = 0;
	uint32_t directory_offset = 0;
	uint32_t archive_flags = 0;
	uint32_t directory_count = 0;
	uint32_t file_count = 0;
	uint32_t directory_names_length = 0;
	uint32_t file_names_length = 0;
	uint32_t file_flags = 0;

	bool directories_named() const { return archive_flags & ArchiveFlag::DirectoriesNamed; }
	bool files_named() const { return archive_flags & ArchiveFlag::FilesNamed; }
	bool files_compressed_default() const { return archive_flags & ArchiveFlag::FilesCompressed; }
	bool file_names_embedded() const { return archive_flags & ArchiveFlag::FileNamesEmbedded; }
};

// One file entry, resolved to its full folder+file path and ready to
// extract. Not the raw on-disk record — folder/file names have already
// been joined and the record's raw size/offset carried along.
struct Entry {
	std::string folder; // e.g. "meshes\architecture\goodsprings", as stored (backslashes)
	std::string file; // e.g. "gsprings01.nif"
	uint32_t raw_size = 0; // raw size field from the file record (includes compression toggle bit)
	uint32_t offset = 0; // absolute offset into the archive file of this entry's data blob

	bool is_compressed(bool archive_default_compressed) const {
		bool toggled = raw_size & kCompressedToggleBit;
		return archive_default_compressed != toggled;
	}

	uint32_t stored_size() const { return raw_size & kSizeMask; }

	// Lowercase "folder/file" with forward slashes, for case-insensitive
	// path lookups regardless of how the archive stored separators/case.
	std::string normalized_path() const;
};

} // namespace bsa

#endif // BSA_TYPES_H
