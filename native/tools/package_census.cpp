// Exhaustive PACK subrecord census for a TES4-family master/plugin.
//
// This is intentionally a native, parser-only diagnostic. It verifies the
// FNV PACK layout against the exact data the Godot EsmServer will consume,
// rather than extrapolating a record shape from a small hand-picked sample.

#include "esm/esm_file.h"

#include <exception>
#include <iomanip>
#include <iostream>
#include <map>
#include <string>

static uint32_t read_u32(const uint8_t *data) {
	return uint32_t(data[0]) | (uint32_t(data[1]) << 8) | (uint32_t(data[2]) << 16) | (uint32_t(data[3]) << 24);
}

int main(int argc, char **argv) {
	if (argc != 2) {
		std::cerr << "usage: package_census <plugin.esm|plugin.esp>\n";
		return 2;
	}

	try {
		esm::EsmFile esm;
		esm.open(argv[1]);
		uint32_t package_count = 0;
		std::map<std::string, uint32_t> tag_counts;
		std::map<std::string, std::map<size_t, uint32_t>> tag_sizes;
		std::map<uint32_t, uint32_t> travel_location_type_counts;
		uint32_t travel_examples = 0;

		esm.for_each_record([&](const esm::RecordInfo &record) {
			if (record.type != "PACK") {
				return;
			}
			++package_count;
			const auto subrecords = esm::EsmFile::parse_subrecords(esm.read_record_data(record));
			bool is_travel = false;
			std::string editor_id;
			for (const esm::Subrecord &subrecord : subrecords) {
				if (subrecord.type == "PKDT" && subrecord.size >= 5) {
					is_travel = subrecord.data[4] == 6;
				}
				if (subrecord.type == "EDID") {
					editor_id = subrecord.as_string();
				}
				++tag_counts[subrecord.type];
				++tag_sizes[subrecord.type][subrecord.size];
			}
			if (is_travel) {
				for (const esm::Subrecord &subrecord : subrecords) {
					if (subrecord.type != "PLDT" || subrecord.size != 12) {
						continue;
					}
					const uint32_t location_type = read_u32(subrecord.data);
					++travel_location_type_counts[location_type];
					if (travel_examples++ < 20) {
						std::cout << "TRAVEL 0x" << std::hex << std::setw(8) << std::setfill('0') << record.form_id
								<< std::dec << " " << editor_id << " PLDT type=" << location_type
								<< " value=0x" << std::hex << std::setw(8) << read_u32(subrecord.data + 4)
								<< std::dec << " radius=" << static_cast<int32_t>(read_u32(subrecord.data + 8)) << "\n";
					}
				}
			}
		});

		std::cout << "PACK records: " << package_count << "\n";
		for (const auto &[tag, count] : tag_counts) {
			std::cout << tag << " count=" << count << " sizes=";
			bool first = true;
			for (const auto &[size, occurrences] : tag_sizes[tag]) {
				if (!first) {
					std::cout << ',';
				}
				first = false;
				std::cout << size << 'x' << occurrences;
			}
			std::cout << "\n";
		}
		std::cout << "Travel PLDT location types:";
		for (const auto &[type, count] : travel_location_type_counts) {
			std::cout << ' ' << type << '=' << count;
		}
		std::cout << "\n";
	} catch (const std::exception &error) {
		std::cerr << "package_census: " << error.what() << "\n";
		return 1;
	}
	return 0;
}
