#include "positional_read.h"

#include <cerrno>
#include <cstring>

#ifdef _WIN32
#include <io.h>
#include <windows.h>
#else
#include <unistd.h>
#endif

namespace bsa {

FileHandle handle_of(std::FILE *f) {
	FileHandle out;
	if (f == nullptr) {
		return out;
	}
#ifdef _WIN32
	int fd = _fileno(f);
	if (fd < 0) {
		return out;
	}
	intptr_t raw = _get_osfhandle(fd);
	if (raw == -1) {
		return out;
	}
	out.h = reinterpret_cast<void *>(raw);
#else
	out.fd = ::fileno(f);
#endif
	return out;
}

bool read_exact_at(const FileHandle &handle, uint8_t *dst, size_t size,
		uint64_t offset, std::string &error) {
	if (size == 0) {
		return true;
	}
	if (!handle.valid() || dst == nullptr) {
		error = "invalid file handle";
		return false;
	}

	size_t done = 0;
	while (done < size) {
		const size_t remaining = size - done;
#ifdef _WIN32
		// ReadFile takes a 32-bit count; chunk anything larger.
		const DWORD want = static_cast<DWORD>(
				remaining > 0x7FFFFFFFull ? 0x7FFFFFFFull : remaining);
		OVERLAPPED ov = {};
		const uint64_t at = offset + done;
		ov.Offset = static_cast<DWORD>(at & 0xFFFFFFFFull);
		ov.OffsetHigh = static_cast<DWORD>(at >> 32);
		DWORD got = 0;
		if (!ReadFile(handle.h, dst + done, want, &got, &ov)) {
			const DWORD err = GetLastError();
			if (err == ERROR_HANDLE_EOF) {
				error = "read past end of file at offset " + std::to_string(offset);
				return false;
			}
			error = "ReadFile failed at offset " + std::to_string(at) +
					" (error " + std::to_string(static_cast<unsigned long>(err)) + ")";
			return false;
		}
		if (got == 0) {
			error = "read past end of file at offset " + std::to_string(offset);
			return false;
		}
		done += static_cast<size_t>(got);
#else
		const ssize_t got = ::pread(handle.fd, dst + done, remaining,
				static_cast<off_t>(offset + done));
		if (got < 0) {
			if (errno == EINTR) {
				continue; // interrupted before transferring anything; retry
			}
			error = "pread failed at offset " + std::to_string(offset + done) +
					" (" + std::strerror(errno) + ")";
			return false;
		}
		if (got == 0) {
			error = "read past end of file at offset " + std::to_string(offset);
			return false;
		}
		done += static_cast<size_t>(got);
#endif
	}
	return true;
}

} // namespace bsa
