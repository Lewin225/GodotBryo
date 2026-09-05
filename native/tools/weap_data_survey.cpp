// Surveys real WEAP subrecords to establish the pickup-relevant DATA layout.
#include "esm/esm_file.h"

#include <cstring>
#include <iomanip>
#include <iostream>

static uint32_t u32(const uint8_t *p) {
	uint32_t value;
	std::memcpy(&value, p, sizeof(value));
	return value;
}

static float f32(const uint8_t *p) {
	float value;
	std::memcpy(&value, p, sizeof(value));
	return value;
}

static uint16_t u16(const uint8_t *p) {
	uint16_t value;
	std::memcpy(&value, p, sizeof(value));
	return value;
}

static unsigned u8(const uint8_t *p) {
	return *p;
}

int main(int argc, char **argv) {
	if (argc != 2) return 2;
	esm::EsmFile esm;
	esm.open(argv[1]);
	esm.for_each_record([&](const esm::RecordInfo &record) {
		if (record.type != "WEAP") return;
		auto bytes = esm.read_record_data(record);
		auto subs = esm::EsmFile::parse_subrecords(bytes);
		std::string edid;
		for (const auto &sub : subs) if (sub.type == "EDID") edid = sub.as_string();
		std::cout << std::hex << std::setfill('0') << "0x" << std::setw(8) << record.form_id
			<< std::dec << ' ' << edid << ':';
		for (const auto &sub : subs) {
			std::cout << ' ' << sub.type << '=' << sub.size;
			if (sub.type == "DATA" && sub.size >= 15) {
				std::cout << " [value@0=" << static_cast<int32_t>(u32(sub.data))
					<< ",health@4=" << static_cast<int32_t>(u32(sub.data + 4))
					<< ",weight@8=" << f32(sub.data + 8)
					<< ",damage@12=" << u16(sub.data + 12)
					<< ",clip@14=" << static_cast<unsigned>(sub.data[14]) << ']';
			}
			if (sub.type == "DNAM" && sub.size >= 57) {
				std::cout << " [animation_type@0=" << u32(sub.data)
					<< ",flags1@12=" << u8(sub.data + 12)
					<< ",grip@13=" << u8(sub.data + 13)
					<< ",ammo_use@14=" << u8(sub.data + 14)
					<< ",reload@15=" << u8(sub.data + 15)
					<< ",attack@41=" << u8(sub.data + 41)
					<< ",flags2@56=" << u32(sub.data + 56) << ']';
			}
		}
		std::cout << '\n';
	});
}
