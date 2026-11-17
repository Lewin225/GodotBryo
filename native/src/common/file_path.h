#ifndef COMMON_FILE_PATH_H
#define COMMON_FILE_PATH_H

#include <cstdio>
#include <filesystem>
#include <string>

namespace util {

// Paths cross the Godot boundary as UTF-8 (String::utf8()). Windows narrow
// file APIs read a std::string as the ANSI code page instead, so every file
// open goes through these helpers, which decode UTF-8 explicitly.

inline std::filesystem::path path_from_utf8(const std::string &utf8) {
#ifdef __cpp_char8_t
	// C++20 dropped u8path's std::string overload; build from char8_t there.
	return std::filesystem::path(
			std::u8string(reinterpret_cast<const char8_t *>(utf8.data()), utf8.size()));
#else
	return std::filesystem::u8path(utf8);
#endif
}

inline std::string path_to_utf8(const std::filesystem::path &p) {
	const auto u8 = p.u8string();
	return std::string(reinterpret_cast<const char *>(u8.data()), u8.size());
}

// fopen with a UTF-8 path. Binary-mode strings only ("rb", "wb").
inline std::FILE *fopen_utf8(const std::string &utf8_path, const char *mode) {
#ifdef _WIN32
	std::wstring wide_mode;
	for (const char *c = mode; *c; ++c) {
		wide_mode.push_back(static_cast<wchar_t>(*c));
	}
	return _wfopen(path_from_utf8(utf8_path).c_str(), wide_mode.c_str());
#else
	return std::fopen(utf8_path.c_str(), mode);
#endif
}

} // namespace util

#endif // COMMON_FILE_PATH_H
