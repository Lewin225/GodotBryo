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

    auto wthr_info = esm.find_record_by_form_id(0x64609); // WastelandClear
    if (wthr_info) {
        auto data = esm.read_record_data(*wthr_info);
        auto subs = EsmFile::parse_subrecords(data);
        for (const auto &sub : subs) {
            if (sub.type == "NAM0") {
                std::cout << "NAM0 size = " << sub.size << " bytes\n";
                // Let's print as 10 groups of 6 or 6 groups of 10
                for (int i = 0; i < sub.size; i += 4) {
                    int idx = i / 4;
                    uint8_t r = sub.data[i];
                    uint8_t g = sub.data[i+1];
                    uint8_t b = sub.data[i+2];
                    uint8_t a = sub.data[i+3];
                    std::cout << "Color " << std::setw(2) << idx << ": R=" << std::setw(3) << (int)r
                              << " G=" << std::setw(3) << (int)g << " B=" << std::setw(3) << (int)b
                              << " A=" << std::setw(3) << (int)a << "\n";
                }
            }
        }
    }

    return 0;
}
