#include "esm/esm_file.h"
#include <iostream>
#include <vector>
#include <string>

int main() {
    try {
        esm::EsmFile file;
        file.open("../fresh_nv_copy/Data/FalloutNV.esm");
        int count = 0;
        file.for_each_record([&](const esm::RecordInfo &r) {
            if (r.type != "SCPT") return;
            std::vector<uint8_t> data = file.read_record_data(r);
            std::vector<esm::Subrecord> subs = esm::EsmFile::parse_subrecords(data);
            std::string edid, sctx;
            for (const auto &s : subs) {
                if (s.type == "EDID") edid = s.as_string();
                else if (s.type == "SCTX") sctx = s.as_string();
            }
            if (sctx.find("GetButtonPressed") != std::string::npos || sctx.find("getbuttonpressed") != std::string::npos) {
                count++;
                if (count <= 3) {
                    std::cout << "=== Script: " << edid << " (FormID: 0x" << std::hex << r.form_id << std::dec << ") ===" << std::endl;
                    std::cout << sctx << std::endl;
                    std::cout << "==========================================" << std::endl;
                }
            }
        });
        std::cout << "Total scripts referencing ShowMessage/GetButtonPressed: " << count << std::endl;
    } catch (const std::exception &e) {
        std::cerr << "Error: " << e.what() << std::endl;
    }
    return 0;
}
