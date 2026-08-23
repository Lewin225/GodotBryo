// alpha_survey — throwaway research tool for the "black-background decals"
// investigation (road line markers, chip/concrete damage decals, cactus LOD
// billboards). Dumps, for every NIF whose path matches a given substring,
// each shape's shader block type + raw shaderFlags1/2, texture slot 0, and
// the FULL raw NiAlphaProperty flags word with the src/dst blend-function
// bits (1-4 / 5-8) decoded — the part phases/2/01-material-pipeline.md
// deliberately skipped. Also reports the diffuse texture's DDS FourCC so we
// can see whether the texture even has an alpha channel (BC1 vs BC3).
//
// Usage:
//   alpha_survey <DataDir> --list <substr>     # just list matching nif paths
//   alpha_survey <DataDir> --dump <substr> [max]

#include "../src/bsa/bsa_archive.h"

#include <NifFile.hpp>

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

static std::string to_lower(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
	return s;
}

static const char *blend_mode_name(unsigned m) {
	static const char *names[] = { "ONE", "ZERO", "SRC_COLOR", "INV_SRC_COLOR", "DST_COLOR",
		"INV_DST_COLOR", "SRC_ALPHA", "INV_SRC_ALPHA", "DST_ALPHA", "INV_DST_ALPHA", "SRC_ALPHA_SATURATE" };
	return m < 11 ? names[m] : "??";
}

static const char *test_func_name(unsigned f) {
	static const char *names[] = { "ALWAYS", "LESS", "EQUAL", "LEQUAL", "GREATER", "NOTEQUAL", "GEQUAL", "NEVER" };
	return f < 8 ? names[f] : "??";
}

struct Archives {
	std::vector<std::unique_ptr<bsa::BsaArchive>> readers;
	// path (lowercased, backslashes) -> (reader index, entry index); first
	// archive opened wins, so open in priority order.
	std::map<std::string, std::pair<size_t, size_t>> index;

	void open_all(const std::string &data_dir) {
		std::vector<std::string> names;
		for (auto &p : fs::directory_iterator(data_dir))
			if (to_lower(p.path().extension().string()) == ".bsa")
				names.push_back(p.path().filename().string());
		// Same priority approximation as mesh_resolver.gd: Update, DLC, base.
		std::vector<std::string> ordered;
		auto take = [&](const std::string &n) {
			auto it = std::find(names.begin(), names.end(), n);
			if (it != names.end()) { ordered.push_back(n); names.erase(it); }
		};
		take("Update.bsa");
		std::vector<std::string> dlc;
		for (auto &n : names)
			if (n.rfind("Fallout - ", 0) != 0) dlc.push_back(n);
		std::sort(dlc.begin(), dlc.end());
		for (auto &n : dlc) { take(n); }
		std::sort(names.begin(), names.end());
		for (auto &n : names) ordered.push_back(n);

		for (auto &n : ordered) {
			auto r = std::make_unique<bsa::BsaArchive>();
			try { r->open(data_dir + "/" + n); } catch (...) { continue; }
			size_t ri = readers.size();
			const auto &es = r->entries();
			for (size_t ei = 0; ei < es.size(); ++ei) {
				std::string full = to_lower(es[ei].folder + "\\" + es[ei].file);
				if (!index.count(full)) index[full] = { ri, ei };
			}
			readers.push_back(std::move(r));
		}
	}

	std::vector<uint8_t> extract(const std::string &lower_path) {
		auto it = index.find(lower_path);
		if (it == index.end()) return {};
		auto &r = *readers[it->second.first];
		return r.extract(r.entries()[it->second.second]);
	}
};

static std::string dds_fourcc(const std::vector<uint8_t> &d) {
	if (d.size() < 128) return "(too small)";
	// DDS_PIXELFORMAT at offset 76; dwFlags at 80, dwFourCC at 84.
	uint32_t pf_flags = *reinterpret_cast<const uint32_t *>(&d[80]);
	if (pf_flags & 0x4) { // DDPF_FOURCC
		return std::string(reinterpret_cast<const char *>(&d[84]), 4);
	}
	uint32_t rgb = pf_flags & 0x40, alpha = pf_flags & 0x1;
	return rgb ? (alpha ? "RGBA (uncompressed)" : "RGB (uncompressed)") : "(no fourcc)";
}

int main(int argc, char **argv) {
	if (argc < 4) {
		std::cerr << "usage: alpha_survey <DataDir> --list|--dump <substr> [max]\n";
		return 1;
	}
	std::string data_dir = argv[1], mode = argv[2], pat = to_lower(argv[3]);
	int max_n = argc > 4 ? std::atoi(argv[4]) : 25;

	Archives arc;
	arc.open_all(data_dir);

	std::vector<std::string> matches;
	for (auto &kv : arc.index) {
		const std::string &p = kv.first;
		if (p.size() > 4 && p.compare(p.size() - 4, 4, ".nif") == 0 && p.find(pat) != std::string::npos)
			matches.push_back(p);
	}
	std::cout << matches.size() << " NIFs match '" << pat << "'\n";
	if (mode == "--list") {
		for (int i = 0; i < (int)matches.size() && i < max_n; ++i)
			std::cout << "  " << matches[i] << "\n";
		return 0;
	}

	int dumped = 0;
	for (auto &p : matches) {
		if (dumped >= max_n) break;
		auto bytes = arc.extract(p);
		if (bytes.empty()) continue;
		std::string str(bytes.begin(), bytes.end());
		std::istringstream stream(str, std::ios::binary);
		nifly::NifFile nif;
		if (nif.Load(stream) != 0) { std::cout << p << ": LOAD FAILED\n"; continue; }
		std::cout << "\n=== " << p << " ===\n";
		for (auto *shape : nif.GetShapes()) {
			std::cout << "  shape '" << shape->name.get() << "'";
			nifly::NiShader *shader = nif.GetShader(shape);
			if (shader) {
				std::cout << " shader=" << shader->GetBlockName();
				if (auto *bs = dynamic_cast<nifly::BSShaderProperty *>(shader))
					std::cout << " flags1=0x" << std::hex << bs->shaderFlags1
							  << " flags2=0x" << bs->shaderFlags2 << std::dec;
			} else {
				std::cout << " shader=(none)";
			}
			std::cout << "\n";
			std::string tex;
			nif.GetTextureSlot(shape, tex, 0);
			if (!tex.empty()) {
				auto tex_bytes = arc.extract(to_lower(tex));
				std::cout << "    diffuse: " << tex << "  [" << (tex_bytes.empty() ? "NOT FOUND" : dds_fourcc(tex_bytes)) << "]\n";
			}
			if (nifly::NiAlphaProperty *a = nif.GetAlphaProperty(shape)) {
				unsigned f = a->flags;
				std::cout << "    alpha flags=0x" << std::hex << f << std::dec
						  << " blend=" << (f & 1)
						  << " src=" << blend_mode_name((f >> 1) & 0xF)
						  << " dst=" << blend_mode_name((f >> 5) & 0xF)
						  << " test=" << ((f >> 9) & 1)
						  << " func=" << test_func_name((f >> 10) & 0x7)
						  << " noSorter=" << ((f >> 13) & 1)
						  << " threshold=" << (int)a->threshold << "\n";
			} else {
				std::cout << "    alpha: (none)\n";
			}
		}
		++dumped;
	}
	return 0;
}
