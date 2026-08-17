#include "bsa_archive.h"

#include "../common/byte_reader.h"

#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <zlib.h>

namespace bsa {

namespace {

std::string normalize(const std::string &folder, const std::string &file) {
	std::string s = folder.empty() ? file : folder + "/" + file;
	std::replace(s.begin(), s.end(), '\\', '/');
	std::transform(s.begin(), s.end(), s.begin(),
			[](unsigned char c) { return std::tolower(c); });
	return s;
}

} // namespace

std::string Entry::normalized_path() const {
	return normalize(folder, file);
}

BsaArchive::~BsaArchive() {
	if (file_) {
		std::fclose(file_);
	}
}

void BsaArchive::open(const std::string &path) {
	file_ = std::fopen(path.c_str(), "rb");
	if (!file_) {
		throw std::runtime_error("BsaArchive: could not open file: " + path);
	}

	// Header is a fixed 36 bytes; read it directly rather than the whole
	// file (archives can exceed 1GB and we only need small metadata here —
	// actual mesh/texture payloads are read on demand in extract()).
	uint8_t header_bytes[36];
	if (std::fread(header_bytes, 1, sizeof(header_bytes), file_) != sizeof(header_bytes)) {
		throw std::runtime_error("BsaArchive: file too small to contain a BSA header: " + path);
	}

	util::ByteReader hr(header_bytes, sizeof(header_bytes));
	auto magic = hr.read_bytes(4);
	if (std::memcmp(magic.data(), kMagic, 4) != 0) {
		throw std::runtime_error("BsaArchive: bad magic (not a BSA file): " + path);
	}

	header_.version = hr.read_u32();
	if (header_.version != kVersionOblivion && header_.version != kVersionFO3NV) {
		throw std::runtime_error(
				"BsaArchive: unsupported version " + std::to_string(header_.version) +
				" (only Oblivion/103 and FO3-FNV/104 are supported): " + path);
	}
	header_.directory_offset = hr.read_u32();
	header_.archive_flags = hr.read_u32();
	header_.directory_count = hr.read_u32();
	header_.file_count = hr.read_u32();
	header_.directory_names_length = hr.read_u32();
	header_.file_names_length = hr.read_u32();
	header_.file_flags = hr.read_u32();

	if (header_.archive_flags & ArchiveFlag::Xbox360Archive) {
		throw std::runtime_error("BsaArchive: Xbox 360 (byte-swapped) archives are not supported: " + path);
	}

	// Directory records + per-folder blocks (name + file records) + the
	// trailing file-names block are all small relative to archive payload
	// data (tens of KB to a few MB even for the largest base-game
	// archives) — read this whole metadata region into memory in one go.
	//
	// Directory records: 16 bytes each (hash:8, file_count:4, name_offset:4).
	size_t dir_records_size = static_cast<size_t>(header_.directory_count) * 16;

	std::vector<uint8_t> meta(dir_records_size);
	if (std::fread(meta.data(), 1, meta.size(), file_) != meta.size()) {
		throw std::runtime_error("BsaArchive: truncated directory record table: " + path);
	}
	util::ByteReader dr(meta.data(), meta.size());

	struct DirRecord {
		uint32_t file_count;
	};
	std::vector<DirRecord> dir_records;
	dir_records.reserve(header_.directory_count);
	for (uint32_t i = 0; i < header_.directory_count; ++i) {
		dr.read_u64(); // hash — unused; we resolve paths by sequential layout, not lookup.
		uint32_t file_count = dr.read_u32();
		dr.read_u32(); // name_offset — informational; blocks are read sequentially below.
		dir_records.push_back({ file_count });
	}

	// Remaining metadata (folder name/file-record blocks, then the file
	// names block) has variable size we can't precompute exactly without
	// walking it, so read the rest of the file's metadata region
	// incrementally with buffered fread calls directly (no need to
	// preload it all at once).
	entries_.reserve(header_.file_count);

	for (uint32_t fi = 0; fi < header_.directory_count; ++fi) {
		std::string folder_name;
		if (header_.directories_named()) {
			uint8_t len;
			if (std::fread(&len, 1, 1, file_) != 1) {
				throw std::runtime_error("BsaArchive: truncated folder name block: " + path);
			}
			if (len > 0) {
				std::vector<char> buf(len);
				if (std::fread(buf.data(), 1, len, file_) != len) {
					throw std::runtime_error("BsaArchive: truncated folder name: " + path);
				}
				// buf includes the trailing null; drop it.
				folder_name.assign(buf.data(), len - 1);
			}
		}

		uint32_t count = dir_records[fi].file_count;
		std::vector<uint8_t> file_records_raw(static_cast<size_t>(count) * 16);
		if (std::fread(file_records_raw.data(), 1, file_records_raw.size(), file_) != file_records_raw.size()) {
			throw std::runtime_error("BsaArchive: truncated file record block: " + path);
		}
		util::ByteReader fr(file_records_raw.data(), file_records_raw.size());
		for (uint32_t i = 0; i < count; ++i) {
			fr.read_u64(); // hash — unused, see above.
			uint32_t raw_size = fr.read_u32();
			uint32_t offset = fr.read_u32();
			Entry e;
			e.folder = folder_name;
			e.raw_size = raw_size;
			e.offset = offset;
			entries_.push_back(std::move(e));
		}
	}

	if (header_.files_named()) {
		for (auto &e : entries_) {
			std::string name;
			char c;
			while (true) {
				if (std::fread(&c, 1, 1, file_) != 1) {
					throw std::runtime_error("BsaArchive: truncated file names block: " + path);
				}
				if (c == '\0') {
					break;
				}
				name.push_back(c);
			}
			e.file = std::move(name);
		}
	}

	path_index_.reserve(entries_.size());
	for (size_t i = 0; i < entries_.size(); ++i) {
		path_index_[entries_[i].normalized_path()] = i;
	}
}

const Entry *BsaArchive::find(const std::string &path) const {
	std::string norm = path;
	std::replace(norm.begin(), norm.end(), '\\', '/');
	std::transform(norm.begin(), norm.end(), norm.begin(),
			[](unsigned char c) { return std::tolower(c); });
	auto it = path_index_.find(norm);
	if (it == path_index_.end()) {
		return nullptr;
	}
	return &entries_[it->second];
}

std::vector<uint8_t> BsaArchive::read_at(size_t offset, size_t size) const {
	if (std::fseek(file_, static_cast<long>(offset), SEEK_SET) != 0) {
		throw std::runtime_error("BsaArchive: seek failed");
	}
	std::vector<uint8_t> buf(size);
	if (size > 0 && std::fread(buf.data(), 1, size, file_) != size) {
		throw std::runtime_error("BsaArchive: read past end of file at offset " + std::to_string(offset));
	}
	return buf;
}

std::vector<uint8_t> BsaArchive::extract(const Entry &entry) const {
	size_t offset = entry.offset;
	size_t size = entry.stored_size();

	std::string embedded_name_discard;
	if (header_.file_names_embedded()) {
		// Peek the BZString name prefix to find its byte length, then skip it.
		uint8_t len_byte;
		{
			auto probe = read_at(offset, 1);
			len_byte = probe[0];
		}
		size_t prefix_len = 1 + len_byte;
		offset += prefix_len;
		size -= prefix_len;
	}

	bool compressed = entry.is_compressed(header_.files_compressed_default());
	if (!compressed) {
		return read_at(offset, size);
	}

	std::vector<uint8_t> raw = read_at(offset, size);
	if (raw.size() < 4) {
		throw std::runtime_error("BsaArchive: compressed entry too small to contain size prefix");
	}
	util::ByteReader rr(raw.data(), raw.size());
	uint32_t original_size = rr.read_u32();

	std::vector<uint8_t> out(original_size);
	uLongf dest_len = original_size;
	int rc = uncompress(out.data(), &dest_len, raw.data() + 4, static_cast<uLong>(raw.size() - 4));
	if (rc != Z_OK) {
		throw std::runtime_error("BsaArchive: zlib decompression failed, code " + std::to_string(rc));
	}
	if (dest_len != original_size) {
		out.resize(dest_len);
	}
	return out;
}

} // namespace bsa
