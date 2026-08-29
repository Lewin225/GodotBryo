#include "esm/esm_file.h"
#include <iostream>
#include <iomanip>
#include <vector>
#include <string>
#include <cstring>

using namespace esm;

int main(int argc, char **argv) {
    std::string esm_path = "fresh_nv_copy/Data/FalloutNV.esm";
    if (argc > 1) {
        esm_path = argv[1];
    }

    EsmFile esm;
    try {
        esm.open(esm_path);
    } catch (const std::exception &e) {
        std::cerr << "Failed to open ESM: " << e.what() << "\n";
        return 1;
    }

    std::cout << "=== 1. SURVEY GLOBALS (GLOB) ===\n";
    esm.for_each_record([&](const RecordInfo &rec) {
        if (rec.type == "GLOB") {
            auto data = esm.read_record_data(rec);
            auto subrecords = EsmFile::parse_subrecords(data);
            std::string edid;
            char type_char = '?';
            float val_f = 0.0f;
            short val_s = 0;
            int val_i = 0;
            for (const auto &sub : subrecords) {
                if (sub.type == "EDID") {
                    edid = std::string(reinterpret_cast<const char*>(sub.data), sub.size);
                    if (!edid.empty() && edid.back() == '\0') edid.pop_back();
                } else if (sub.type == "FNAM" && sub.size >= 1) {
                    type_char = *reinterpret_cast<const char*>(sub.data);
                } else if (sub.type == "FLTV" && sub.size >= 4) {
                    val_f = *reinterpret_cast<const float*>(sub.data);
                }
            }
            if (edid.find("Game") != std::string::npos || edid.find("Time") != std::string::npos ||
                edid.find("Hour") != std::string::npos || edid.find("Day") != std::string::npos ||
                edid.find("Sun") != std::string::npos || edid.find("Weather") != std::string::npos) {
                std::cout << "GLOB 0x" << std::hex << rec.form_id << std::dec
                          << " EDID=" << edid << " type=" << type_char << " FLTV=" << val_f << "\n";
            }
        }
    });

    std::cout << "\n=== 2. SURVEY CLIMATES (CLMT) ===\n";
    esm.for_each_record([&](const RecordInfo &rec) {
        if (rec.type == "CLMT") {
            auto data = esm.read_record_data(rec);
            auto subrecords = EsmFile::parse_subrecords(data);
            std::string edid;
            std::cout << "CLMT 0x" << std::hex << rec.form_id << std::dec << " (size " << data.size() << "):\n";
            for (const auto &sub : subrecords) {
                std::cout << "  Subrecord " << sub.type << " size=" << sub.size << "\n";
                if (sub.type == "EDID" || sub.type == "FNAM" || sub.type == "GNAM" || sub.type == "TNAM") {
                    std::string str(reinterpret_cast<const char*>(sub.data), sub.size);
                    if (!str.empty() && str.back() == '\0') str.pop_back();
                    std::cout << "    str = \"" << str << "\"\n";
                } else if (sub.type == "WLST") {
                    // WLST: pairs of (uint32_t weather_form_id, uint32_t chance)
                    size_t count = sub.size / 8;
                    for (size_t i = 0; i < count; ++i) {
                        uint32_t wthr_id = *reinterpret_cast<const uint32_t*>(sub.data + i * 8);
                        uint32_t chance = *reinterpret_cast<const uint32_t*>(sub.data + i * 8 + 4);
                        std::cout << "    weather=0x" << std::hex << wthr_id << std::dec << " chance=" << chance << "%\n";
                    }
                } else if (sub.type == "TMDA" || sub.type == "DATA") {
                    std::cout << "    timing/data raw bytes:";
                    for (size_t i = 0; i < sub.size; ++i) {
                        std::cout << " " << std::hex << (int)sub.data[i] << std::dec;
                    }
                    std::cout << "\n";
                    if (sub.size >= 6) {
                        // Sunrise begin/end, sunset begin/end, etc.
                        std::cout << "    bytes as uint8: sunrise_begin=" << (int)sub.data[0]
                                  << " sunrise_end=" << (int)sub.data[1]
                                  << " sunset_begin=" << (int)sub.data[2]
                                  << " sunset_end=" << (int)sub.data[3]
                                  << " volatility=" << (int)sub.data[4]
                                  << " moon_phase_length=" << (int)sub.data[5] << "\n";
                    }
                }
            }
        }
    });

    std::cout << "\n=== 3. SURVEY WEATHERS (WTHR) ===\n";
    int wthr_count = 0;
    esm.for_each_record([&](const RecordInfo &rec) {
        if (rec.type == "WTHR") {
            wthr_count++;
            auto data = esm.read_record_data(rec);
            auto subrecords = EsmFile::parse_subrecords(data);
            std::string edid;
            for (const auto &sub : subrecords) {
                if (sub.type == "EDID") {
                    edid = std::string(reinterpret_cast<const char*>(sub.data), sub.size);
                    if (!edid.empty() && edid.back() == '\0') edid.pop_back();
                    break;
                }
            }
            std::cout << "WTHR 0x" << std::hex << rec.form_id << std::dec << " EDID=" << edid << " (size " << data.size() << ")\n";
            for (const auto &sub : subrecords) {
                std::cout << "  Subrecord " << sub.type << " size=" << sub.size << "\n";
                if (sub.type == "DNAM" || sub.type == "CNAM" || sub.type == "ANAM" || sub.type == "BNAM" || sub.type == "FNAM" ||
                    sub.type == "00TX" || sub.type == "10TX" || sub.type == "20TX" || sub.type == "30TX" || sub.type == "MODL") {
                    std::string str(reinterpret_cast<const char*>(sub.data), sub.size);
                    if (!str.empty() && str.back() == '\0') str.pop_back();
                    std::cout << "    text = \"" << str << "\"\n";
                }
            }
        }
    });
    std::cout << "Total WTHR records: " << wthr_count << "\n";

    std::cout << "\n=== 4. SURVEY WORLDSPACES (WRLD) CLIMATE LINKS ===\n";
    esm.for_each_record([&](const RecordInfo &rec) {
        if (rec.type == "WRLD") {
            auto data = esm.read_record_data(rec);
            auto subrecords = EsmFile::parse_subrecords(data);
            std::string edid;
            uint32_t cnam_climate = 0;
            uint32_t wnam_water = 0;
            for (const auto &sub : subrecords) {
                if (sub.type == "EDID") {
                    edid = std::string(reinterpret_cast<const char*>(sub.data), sub.size);
                    if (!edid.empty() && edid.back() == '\0') edid.pop_back();
                } else if (sub.type == "CNAM" && sub.size >= 4) {
                    cnam_climate = *reinterpret_cast<const uint32_t*>(sub.data);
                } else if (sub.type == "WNAM" && sub.size >= 4) {
                    wnam_water = *reinterpret_cast<const uint32_t*>(sub.data);
                }
            }
            std::cout << "WRLD 0x" << std::hex << rec.form_id << std::dec << " EDID=" << edid
                      << " Climate(CNAM)=0x" << std::hex << cnam_climate << std::dec << "\n";
        }
    });

    return 0;
}
