#ifndef BYTE_READER_H
#define BYTE_READER_H

#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace util {

// All Bethesda formats used here (BSA/ESM/NIF) are little-endian throughout.
// This reader is intentionally minimal: bounds-checked, exceptions on
// truncated/malformed data, no ownership of the underlying buffer.
class ByteReader {
public:
	ByteReader(const uint8_t *data, size_t size) :
			data_(data), size_(size), pos_(0) {}

	size_t position() const { return pos_; }
	size_t size() const { return size_; }
	bool at_end() const { return pos_ >= size_; }

	void seek(size_t offset) {
		if (offset > size_) {
			throw std::runtime_error("ByteReader: seek past end of buffer");
		}
		pos_ = offset;
	}

	void skip(size_t n) { seek(pos_ + n); }

	void require(size_t n) const {
		if (pos_ + n > size_) {
			throw std::runtime_error("ByteReader: read past end of buffer");
		}
	}

	uint8_t read_u8() {
		require(1);
		return data_[pos_++];
	}

	uint16_t read_u16() {
		require(2);
		uint16_t v;
		std::memcpy(&v, data_ + pos_, 2);
		pos_ += 2;
		return v; // host is little-endian (x86_64); no byteswap needed.
	}

	uint32_t read_u32() {
		require(4);
		uint32_t v;
		std::memcpy(&v, data_ + pos_, 4);
		pos_ += 4;
		return v;
	}

	uint64_t read_u64() {
		require(8);
		uint64_t v;
		std::memcpy(&v, data_ + pos_, 8);
		pos_ += 8;
		return v;
	}

	// Reads n raw bytes into a vector.
	std::vector<uint8_t> read_bytes(size_t n) {
		require(n);
		std::vector<uint8_t> out(data_ + pos_, data_ + pos_ + n);
		pos_ += n;
		return out;
	}

	// BZString: 1-byte length prefix (length INCLUDES the trailing null),
	// followed by that many bytes, the last of which is '\0'. Used for
	// folder/file name prefixes in BSA archives.
	std::string read_bzstring() {
		uint8_t len = read_u8();
		if (len == 0) {
			return std::string();
		}
		require(len);
		// Exclude the trailing null from the returned string content.
		std::string s(reinterpret_cast<const char *>(data_ + pos_), len - 1);
		pos_ += len;
		return s;
	}

	// Null-terminated string, e.g. entries in a BSA file-names block.
	std::string read_cstring() {
		size_t start = pos_;
		while (pos_ < size_ && data_[pos_] != 0) {
			++pos_;
		}
		if (pos_ >= size_) {
			throw std::runtime_error("ByteReader: unterminated cstring");
		}
		std::string s(reinterpret_cast<const char *>(data_ + start), pos_ - start);
		++pos_; // consume the null terminator
		return s;
	}

	const uint8_t *ptr_at(size_t offset) const {
		if (offset > size_) {
			throw std::runtime_error("ByteReader: ptr_at past end of buffer");
		}
		return data_ + offset;
	}

private:
	const uint8_t *data_;
	size_t size_;
	size_t pos_;
};

} // namespace util

#endif // BYTE_READER_H
