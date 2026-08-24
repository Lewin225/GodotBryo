// Prints the first real ALCH DATA payloads for format verification.
#include "esm/esm_file.h"
#include "common/byte_reader.h"
#include <cstring>
#include <iomanip>
#include <iostream>
static float f32(const uint8_t *p) { float v; std::memcpy(&v, p, 4); return v; }
int main(int argc, char **argv) {
	if (argc != 2) return 2;
	esm::EsmFile esm; esm.open(argv[1]); int n = 0;
	esm.for_each_record([&](const esm::RecordInfo &r) {
		if (r.type != "ALCH" || n++ >= 12) return;
		auto bytes = esm.read_record_data(r);
		std::string edid; const esm::Subrecord *data = nullptr; const esm::Subrecord *enit = nullptr;
		auto subs = esm::EsmFile::parse_subrecords(bytes);
		for (const auto &s : subs) {
			if (s.type == "EDID") edid = s.as_string();
			if (s.type == "DATA") data = &s;
			if (s.type == "ENIT") enit = &s;
		}
		std::cout << edid << " subs:";
		for (const auto &s : subs) { std::cout << ' ' << s.type << '=' << s.size; if (s.type == "DATA" && s.size == 4) std::cout << '(' << f32(s.data) << ')'; }
		std::cout << " DATA=" << (data ? data->size : 0);
		if (data && data->size == 4) std::cout << " DATAf=" << f32(data->data);
		else if (data && data->size >= 8) {
			uint32_t a, b; std::memcpy(&a, data->data, 4); std::memcpy(&b, data->data + 4, 4);
			std::cout << " u32,f32=" << a << ',' << f32(data->data + 4)
				<< " f32,u32=" << f32(data->data) << ',' << b;
		}
		if (enit && enit->size >= 20) { uint32_t a; std::memcpy(&a,enit->data,4); std::cout << " ENIT value=" << a << " f32@16=" << f32(enit->data+16); }
		std::cout << '\n';
	});
}
