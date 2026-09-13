#include "archive_catalog_gd.h"

#include <cstring>

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void ArchiveCatalog::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open_data_dir", "data_dir"), &ArchiveCatalog::open_data_dir);
	ClassDB::bind_method(D_METHOD("read", "path"), &ArchiveCatalog::read);
	ClassDB::bind_method(D_METHOD("contains", "path"), &ArchiveCatalog::contains);
	ClassDB::bind_method(D_METHOD("winning_archive", "path"), &ArchiveCatalog::winning_archive);
	ClassDB::bind_method(D_METHOD("list_files_with_prefix", "prefix"), &ArchiveCatalog::list_files_with_prefix);
	ClassDB::bind_method(D_METHOD("get_entry_count"), &ArchiveCatalog::get_entry_count);
	ClassDB::bind_method(D_METHOD("get_archive_order"), &ArchiveCatalog::get_archive_order);
	ClassDB::bind_method(D_METHOD("get_failed_archives"), &ArchiveCatalog::get_failed_archives);
	ClassDB::bind_method(D_METHOD("get_last_error"), &ArchiveCatalog::get_last_error);
}

bool ArchiveCatalog::open_data_dir(const String &data_dir) {
	std::string error;
	opened_ = catalog_.open_data_dir(std::string(data_dir.utf8().get_data()), error);
	last_error_ = String(error.c_str());
	return opened_;
}

Dictionary ArchiveCatalog::read(const String &path) const {
	Dictionary out;
	if (!opened_) {
		out["found"] = false;
		out["archive"] = String();
		out["data"] = PackedByteArray();
		out["error"] = String("catalog not initialized");
		return out;
	}
	const auto result = catalog_.read(std::string(path.utf8().get_data()));
	PackedByteArray data;
	if (!result.data.empty()) {
		data.resize(static_cast<int64_t>(result.data.size()));
		std::memcpy(data.ptrw(), result.data.data(), result.data.size());
	}
	out["found"] = result.found;
	out["archive"] = String(result.archive.c_str());
	out["data"] = data;
	out["error"] = String(result.error.c_str());
	return out;
}

bool ArchiveCatalog::contains(const String &path) const {
	return opened_ && catalog_.contains(std::string(path.utf8().get_data()));
}

String ArchiveCatalog::winning_archive(const String &path) const {
	if (!opened_) {
		return String();
	}
	return String(catalog_.winning_archive(std::string(path.utf8().get_data())).c_str());
}

PackedStringArray ArchiveCatalog::list_files_with_prefix(const String &prefix) const {
	PackedStringArray out;
	if (!opened_) {
		return out;
	}
	for (const auto &p : catalog_.list_with_prefix(std::string(prefix.utf8().get_data()))) {
		out.push_back(String(p.c_str()));
	}
	return out;
}

int ArchiveCatalog::get_entry_count() const {
	return opened_ ? static_cast<int>(catalog_.entry_count()) : 0;
}

PackedStringArray ArchiveCatalog::get_archive_order() const {
	PackedStringArray out;
	if (opened_) {
		for (const auto &n : catalog_.archive_order()) {
			out.push_back(String(n.c_str()));
		}
	}
	return out;
}

PackedStringArray ArchiveCatalog::get_failed_archives() const {
	PackedStringArray out;
	for (const auto &n : catalog_.failed_archives()) {
		out.push_back(String(n.c_str()));
	}
	return out;
}
