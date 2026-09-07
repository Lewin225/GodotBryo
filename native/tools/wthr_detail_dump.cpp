#include "esm/esm_file.h"
#include <iostream>
#include <iomanip>
#include <vector>
#include <string>

using namespace esm;

int main(int argc, char **argv) {
    std::string esm_path = argc > 1 ? argv[1] : "../fresh_nv_copy/Data/FalloutNV.esm";
    EsmFile esm;
    try {
        esm.open(esm_path);
    } catch (const std::exception &e) {
        std::cerr << "Failed to open: " << e.what() << "\n";
        return 1;
    }

    // Inspect WastelandNV climate: CLMT 0x8809b
    auto clmt_info = esm.find_record_by_form_id(0x8809b);
    if (clmt_info) {
        auto data = esm.read_record_data(*clmt_info);
        auto subs = EsmFile::parse_subrecords(data);
        std::cout << "CLMT 0x8809b (WastelandNV Climate) Subrecords:\n";
        for (const auto &sub : subs) {
            std::cout << "  " << sub.type << " (" << sub.size << " bytes):";
            for (size_t i = 0; i < sub.size; ++i) {
                if (i < 32) std::cout << " " << std::hex << std::setw(2) << std::setfill('0') << (int)sub.data[i];
            }
            std::cout << std::dec << "\n";
        }
    }

    // Inspect WastelandClear: WTHR 0x64609 or NVClear: 0x173564
    uint32_t wthr_ids[] = {0x64609, 0x173564, 0x15e};
    for (uint32_t wid : wthr_ids) {
        auto wthr_info = esm.find_record_by_form_id(wid);
        if (wthr_info) {
            auto data = esm.read_record_data(*wthr_info);
            auto subs = EsmFile::parse_subrecords(data);
            std::cout << "\nWTHR 0x" << std::hex << wid << std::dec << " Subrecords:\n";
            for (const auto &sub : subs) {
                std::cout << "  " << sub.type << " (" << sub.size << " bytes): ";
                if (sub.type == "EDID" || sub.type == "DNAM" || sub.type == "CNAM" || sub.type == "ANAM" || sub.type == "BNAM") {
                    std::string s(reinterpret_cast<const char*>(sub.data), sub.size);
                    std::cout << "\"" << s << "\"";
                } else if (sub.type == "NAM0") {
                    // Weather colors table (10 color types * 6 times of day * 4 bytes RGBA = 240 bytes)
                    // Or let's see how NAM0 is laid out!
                    std::cout << "Colors table (240 bytes = 60 uint32 or 10 types x 6 times of day)";
                } else if (sub.type == "FNAM") {
                    // Fog distances: Day/Night near/far/power, etc. (6 floats = 24 bytes)
                    if (sub.size == 24) {
                        const float *f = reinterpret_cast<const float*>(sub.data);
                        std::cout << "Fog: DayNear=" << f[0] << " DayFar=" << f[1]
                                  << " NightNear=" << f[2] << " NightFar=" << f[3]
                                  << " DayPower=" << f[4] << " NightPower=" << f[5];
                    }
                } else if (sub.type == "DATA") {
                    // Wind / cloud speeds / sun parameters
                    std::cout << "DATA bytes:";
                    for (size_t i = 0; i < sub.size; ++i) {
                        std::cout << " " << std::hex << (int)sub.data[i] << std::dec;
                    }
                }
                std::cout << "\n";
            }
        }
    }

    return 0;
}
