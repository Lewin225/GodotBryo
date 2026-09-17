// Dumps every NIF block and every object-net reference in the shipped human
// skeletons. This answers one narrow reverse-engineering question: where, if
// anywhere, does skeleton.nif name or otherwise link its external animation
// assets? It deliberately reports the raw block/reference facts rather than
// inferring a folder convention from them.
//
// Build from native/:
// g++ -std=c++17 -O2 -Isrc -Inifly/include -Inifly/external \
//     tools/skeleton_animation_link_dump.cpp src/bsa/bsa_archive.cpp \
//     nifly/src/*.cpp -lz -o tools/skeleton_animation_link_dump
// Run: tools/skeleton_animation_link_dump ../fresh_nv_copy/Data

#include "bsa/bsa_archive.h"

#include <ExtraData.hpp>
#include <NifFile.hpp>
#include <Objects.hpp>

#include <filesystem>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

std::vector<uint8_t> extract_skeleton(const std::string& data_dir, const std::string& path) {
	// Update is searched first, matching the runtime archive precedence. The
	// base Meshes archive supplies the skeleton on a vanilla installation.
	for (const char* archive_name : {"Update.bsa", "Fallout - Meshes.bsa"}) {
		const fs::path archive_path = fs::path(data_dir) / archive_name;
		if (!fs::exists(archive_path))
			continue;
		bsa::BsaArchive archive;
		archive.open(archive_path.string());
		if (const bsa::Entry* entry = archive.find(path))
			return archive.extract(*entry);
	}
	return {};
}

void print_extra(const nifly::NiHeader& header, uint32_t index) {
	auto* extra = header.GetBlock<nifly::NiExtraData>(index);
	if (extra == nullptr) {
		std::cout << "#" << index << " <invalid extra-data reference>\n";
		return;
	}
	std::cout << "#" << index << " " << extra->GetBlockName()
			  << " name='" << extra->name.get() << "'";
	if (auto* string_extra = dynamic_cast<nifly::NiStringExtraData*>(extra))
		std::cout << " value='" << string_extra->stringData.get() << "'";
	if (auto* strings_extra = dynamic_cast<nifly::NiStringsExtraData*>(extra)) {
		std::cout << " values=[";
		for (size_t i = 0; i < strings_extra->stringsData.size(); ++i) {
			if (i != 0)
				std::cout << ", ";
			std::cout << "'" << strings_extra->stringsData[i].get() << "'";
		}
		std::cout << "]";
	}
	std::cout << "\n";
}

void dump_skeleton(const std::string& data_dir, const std::string& path) {
	const std::vector<uint8_t> bytes = extract_skeleton(data_dir, path);
	if (bytes.empty()) {
		std::cerr << path << ": not found\n";
		return;
	}
	std::istringstream stream(std::string(bytes.begin(), bytes.end()), std::ios::binary);
	nifly::NifFile nif;
	if (nif.Load(stream) != 0) {
		std::cerr << path << ": Nifly failed to parse\n";
		return;
	}

	const nifly::NiHeader& header = nif.GetHeader();
	std::cout << "=== " << path << " ===\n";
	std::cout << "creator: " << header.GetCreatorInfo() << "\n";
	std::cout << "export: " << header.GetExportInfo() << "\n";
	std::cout << "blocks: " << header.GetNumBlocks() << "\n";
	for (uint32_t i = 0; i < header.GetNumBlocks(); ++i) {
		auto* object = header.GetBlock<nifly::NiObject>(i);
		std::cout << "#" << i << " " << (object != nullptr ? object->GetBlockName() : "<missing>");
		if (auto* net = dynamic_cast<nifly::NiObjectNET*>(object)) {
			std::cout << " name='" << net->name.get() << "'"
					  << " controller=#" << net->controllerRef.index;
			if (net->extraDataRef.index != nifly::NIF_NPOS)
				std::cout << " extra_head=#" << net->extraDataRef.index;
			if (net->extraDataRefs.GetSize() != 0) {
				std::cout << " extra_refs=[";
				for (uint32_t ref = 0; ref < net->extraDataRefs.GetSize(); ++ref) {
					if (ref != 0)
						std::cout << ", ";
					std::cout << "#" << net->extraDataRefs.GetBlockRef(ref);
				}
				std::cout << "]";
			}
		}
		std::cout << "\n";
		if (dynamic_cast<nifly::NiExtraData*>(object) != nullptr)
			print_extra(header, i);
	}
	std::cout << "\n";
}

} // namespace

int main(int argc, char** argv) {
	if (argc != 2) {
		std::cerr << "usage: skeleton_animation_link_dump <DataDir>\n";
		return 2;
	}
	try {
		dump_skeleton(argv[1], "meshes\\characters\\_male\\skeleton.nif");
		dump_skeleton(argv[1], "meshes\\characters\\_female\\skeleton.nif");
	} catch (const std::exception& error) {
		std::cerr << "error: " << error.what() << "\n";
		return 1;
	}
	return 0;
}
