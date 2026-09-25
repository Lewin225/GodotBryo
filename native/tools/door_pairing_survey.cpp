// One-off diagnostic for Plans/Navigation/npc_server.md: confirms that a
// door REFR's own XTEL subrecord alone is sufficient to resolve door-to-door
// pairing (no NAVI/NVCI cross-reference needed), and that two doors placed
// in the SAME interior CELL have directly-comparable raw positions.
//
// Build: g++ -std=c++17 -O2 -Isrc tools/door_pairing_survey.cpp src/esm/esm_file.cpp -lz -o tools/door_pairing_survey
// Run:   tools/door_pairing_survey ../fresh_nv_copy/Data/FalloutNV.esm   (or an absolute path)
#include "esm/esm_file.h"
#include "common/byte_reader.h"
#include "common/units.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

using namespace esm;

static float read_f32(util::ByteReader &r) {
	uint32_t bits = r.read_u32();
	float f;
	std::memcpy(&f, &bits, 4);
	return f;
}

// Reads a REFR's raw XTEL bytes directly (bypassing resolve_refr_xtel(),
// which already resolves the destination REFR down to its owning CELL and
// throws away the destination REFR's own FormID + the "No Alarm" flag —
// we want both raw fields here to check them against wbDefinitionsFNV.pas).
struct RawXtel {
	bool present = false;
	uint32_t dest_refr_form_id = 0;
	float dest_pos[3] = { 0, 0, 0 }; // raw Gamebryo units, unconverted
	float dest_rot[3] = { 0, 0, 0 };
	uint32_t no_alarm_flag = 0xFFFFFFFF; // sentinel: "not present in payload"
	uint32_t raw_size = 0;
};

static RawXtel read_raw_xtel(const EsmFile &esm, uint32_t refr_form_id) {
	RawXtel out;
	auto refr = esm.find_record_by_form_id(refr_form_id);
	if (!refr || refr->type != "REFR") return out;
	std::vector<uint8_t> data = esm.read_record_data(*refr);
	for (const auto &s : EsmFile::parse_subrecords(data)) {
		if (s.type != "XTEL") continue;
		out.present = true;
		out.raw_size = s.size;
		const uint8_t *p = s.data;
		size_t n = s.size;
		size_t off = 0;
		auto read_u32 = [&](uint32_t &v) {
			if (off + 4 > n) return;
			std::memcpy(&v, p + off, 4);
			off += 4;
		};
		auto read_f32 = [&](float &v) {
			if (off + 4 > n) return;
			std::memcpy(&v, p + off, 4);
			off += 4;
		};
		read_u32(out.dest_refr_form_id);
		for (int i = 0; i < 3; ++i) read_f32(out.dest_pos[i]);
		for (int i = 0; i < 3; ++i) read_f32(out.dest_rot[i]);
		read_u32(out.no_alarm_flag);
		break;
	}
	return out;
}

static std::string cell_label(const EsmFile &esm, uint32_t cell_form_id) {
	if (cell_form_id == 0) return "(none)";
	std::string edid = esm.get_cell_editor_id(cell_form_id);
	auto wrld = esm.get_cell_worldspace(cell_form_id);
	char buf[256];
	if (wrld && *wrld != 0) {
		snprintf(buf, sizeof(buf), "0x%X edid='%s' (exterior, WRLD 0x%X)", cell_form_id, edid.c_str(), *wrld);
	} else {
		snprintf(buf, sizeof(buf), "0x%X edid='%s' (interior)", cell_form_id, edid.c_str());
	}
	return buf;
}

int main(int argc, char **argv) {
	std::string path = argc > 1 ? argv[1] : "fresh_nv_copy/Data/FalloutNV.esm";
	EsmFile esm;
	try {
		esm.open(path);
	} catch (const std::exception &e) {
		fprintf(stderr, "open failed: %s\n", e.what());
		return 1;
	}

	// Find an interior CELL with >=2 DOOR REFR placements.
	struct Found {
		uint32_t cell_form_id;
		std::string edid;
		std::vector<ReferencePlacement> doors;
	};
	Found found{};
	bool have_found = false;

	esm.for_each_record([&](const RecordInfo &rec) {
		if (have_found || rec.type != "CELL") return;
		// Skip exterior cells: interior CELLs have no XCLC.
		if (esm.get_exterior_cell_grid(rec.form_id).has_value()) return;

		std::vector<ReferencePlacement> doors;
		for (const auto &p : esm.get_cell_references(rec)) {
			if (p.base_type == "DOOR") doors.push_back(p);
		}
		if (doors.size() >= 2) {
			found.cell_form_id = rec.form_id;
			found.edid = esm.get_cell_editor_id(rec.form_id);
			found.doors = doors;
			have_found = true;
		}
	});

	if (!have_found) {
		printf("No interior CELL with >=2 DOOR placements found.\n");
		return 1;
	}

	printf("=== Interior CELL with >=2 DOOR placements ===\n");
	printf("CELL 0x%X edid='%s'\n\n", found.cell_form_id, found.edid.c_str());

	for (const auto &d : found.doors) {
		printf("DOOR REFR 0x%X  base=0x%X (%s)\n", d.refr_form_id, d.base_form_id, d.base_editor_id.c_str());
		printf("  DATA position (meters, via get_cell_references): (%.3f, %.3f, %.3f)\n",
				d.position[0], d.position[1], d.position[2]);

		RawXtel x = read_raw_xtel(esm, d.refr_form_id);
		if (!x.present) {
			printf("  XTEL: (none — non-teleporting door, e.g. a plain swinging door)\n\n");
			continue;
		}
		printf("  XTEL raw size = %u bytes\n", x.raw_size);
		printf("  XTEL.Door (dest REFR FormID) = 0x%X\n", x.dest_refr_form_id);
		printf("  XTEL landing pos (raw Gamebryo units) = (%.3f, %.3f, %.3f)\n", x.dest_pos[0], x.dest_pos[1], x.dest_pos[2]);
		printf("  XTEL landing rot (radians)            = (%.3f, %.3f, %.3f)\n", x.dest_rot[0], x.dest_rot[1], x.dest_rot[2]);
		if (x.no_alarm_flag != 0xFFFFFFFF) {
			printf("  XTEL No Alarm flag = %u\n", x.no_alarm_flag);
		} else {
			printf("  XTEL No Alarm flag = <subrecord too short to contain it>\n");
		}

		// Resolve the linked door REFR purely from the XTEL FormID (no
		// NAVI/NVCI lookup at all) -- this is the crux of the question.
		auto dest_refr = esm.find_record_by_form_id(x.dest_refr_form_id);
		if (dest_refr && dest_refr->type == "REFR") {
			std::vector<uint8_t> ddata = esm.read_record_data(*dest_refr);
			auto subs = EsmFile::parse_subrecords(ddata);
			uint32_t dest_base_form_id = 0;
			float dest_own_pos[3] = { 0, 0, 0 };
			bool have_own_pos = false;
			for (const auto &s : subs) {
				if (s.type == "NAME" && s.size >= 4) std::memcpy(&dest_base_form_id, s.data, 4);
				if (s.type == "DATA" && s.size >= 24) {
					util::ByteReader sr(s.data, s.size);
					dest_own_pos[0] = read_f32(sr) * units::kGamebryoUnitsToMeters;
					dest_own_pos[1] = read_f32(sr) * units::kGamebryoUnitsToMeters;
					dest_own_pos[2] = read_f32(sr) * units::kGamebryoUnitsToMeters;
					have_own_pos = true;
				}
			}
			auto owner_cell = esm.find_cell_containing_ref(x.dest_refr_form_id);
			printf("  -> resolved via XTEL FormID alone: dest REFR 0x%X exists, base=0x%X\n",
					x.dest_refr_form_id, dest_base_form_id);
			if (have_own_pos) {
				printf("     dest REFR's own DATA position (meters) = (%.3f, %.3f, %.3f)\n",
						dest_own_pos[0], dest_own_pos[1], dest_own_pos[2]);
			}
			if (owner_cell) {
				printf("     dest REFR's owning CELL: %s\n", cell_label(esm, owner_cell->form_id).c_str());
			} else {
				printf("     dest REFR's owning CELL: <not found structurally>\n");
			}
		} else {
			printf("  -> XTEL dest FormID 0x%X did NOT resolve to a REFR record!\n", x.dest_refr_form_id);
		}
		printf("\n");
	}

	if (found.doors.size() >= 2) {
		const auto &a = found.doors[0];
		const auto &b = found.doors[1];
		float dx = a.position[0] - b.position[0];
		float dy = a.position[1] - b.position[1];
		float dz = a.position[2] - b.position[2];
		float dist = std::sqrt(dx * dx + dy * dy + dz * dz);
		printf("=== Same-CELL distance sanity check ===\n");
		printf("Door 0x%X pos = (%.3f, %.3f, %.3f) meters\n", a.refr_form_id, a.position[0], a.position[1], a.position[2]);
		printf("Door 0x%X pos = (%.3f, %.3f, %.3f) meters\n", b.refr_form_id, b.position[0], b.position[1], b.position[2]);
		printf("Straight-line distance = %.3f meters\n", dist);
	}

	return 0;
}
