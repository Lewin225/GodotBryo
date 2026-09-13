#ifndef BSA_POSITIONAL_READ_H
#define BSA_POSITIONAL_READ_H

#include <cstdint>
#include <cstdio>
#include <string>

namespace bsa {

// Native file handle derived from an already-open FILE*. Borrowed, not owned:
// closing the FILE* invalidates it, and nothing here closes anything.
struct FileHandle {
#ifdef _WIN32
	void *h = nullptr; // HANDLE
	bool valid() const { return h != nullptr && h != reinterpret_cast<void *>(-1); }
#else
	int fd = -1;
	bool valid() const { return fd >= 0; }
#endif
};

// Derives the native handle for an open stdio stream. Returns an invalid
// handle if `f` is null or has no underlying descriptor.
FileHandle handle_of(std::FILE *f);

// Reads exactly `size` bytes from absolute `offset` into `dst`.
//
// Positional: uses pread() / ReadFile with an OVERLAPPED offset, so it never
// touches the stream's shared cursor and any number of threads may call it
// concurrently on the same handle. Short reads are retried; EINTR is retried.
// Returns false and fills `error` on a real failure, including a read that
// runs past end of file.
bool read_exact_at(const FileHandle &handle, uint8_t *dst, size_t size,
		uint64_t offset, std::string &error);

} // namespace bsa

#endif // BSA_POSITIONAL_READ_H
