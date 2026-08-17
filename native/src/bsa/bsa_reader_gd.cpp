#include "bsa_reader_gd.h"

#include <godot_cpp/core/class_db.hpp>

#include <stdexcept>

using namespace godot;

void BsaReader::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open", "path"), &BsaReader::open);
	ClassDB::bind_method(D_METHOD("get_entry_count"), &BsaReader::get_entry_count);
	ClassDB::bind_method(D_METHOD("list_entries"), &BsaReader::list_entries);
	ClassDB::bind_method(D_METHOD("extract", "entry_path"), &BsaReader::extract);
	ClassDB::bind_method(D_METHOD("get_last_error"), &BsaReader::get_last_error);
}

bool BsaReader::open(const String &path) {
	try {
		archive_.open(path.utf8().get_data());
		opened_ = true;
		last_error_ = "";
		return true;
	} catch (const std::exception &e) {
		opened_ = false;
		last_error_ = String(e.what());
		return false;
	}
}

int BsaReader::get_entry_count() const {
	return opened_ ? static_cast<int>(archive_.entries().size()) : 0;
}

PackedStringArray BsaReader::list_entries() const {
	PackedStringArray out;
	if (!opened_) {
		return out;
	}
	out.resize(static_cast<int>(archive_.entries().size()));
	int i = 0;
	for (const auto &e : archive_.entries()) {
		out[i++] = String(e.normalized_path().c_str());
	}
	return out;
}

PackedByteArray BsaReader::extract(const String &entry_path) const {
	PackedByteArray out;
	if (!opened_) {
		return out;
	}
	const bsa::Entry *entry = archive_.find(entry_path.utf8().get_data());
	if (!entry) {
		return out;
	}
	try {
		std::vector<uint8_t> data = archive_.extract(*entry);
		out.resize(static_cast<int>(data.size()));
		if (!data.empty()) {
			std::memcpy(out.ptrw(), data.data(), data.size());
		}
	} catch (const std::exception &) {
		// Extraction failure surfaces as an empty array; callers check size().
	}
	return out;
}
