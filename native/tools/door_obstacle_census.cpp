// door_obstacle_census: the objects the original engine cuts out of the navmesh
// at runtime ("Doors, like objects with the 'obstacle' tag, automatically cut
// the navmesh in game", GECK navmesh tutorial), across FalloutNV.esm.
//
// - DOOR bases, and ACTI/CONT/SCOL/MSTT/LIGH/STAT bases with record-header bit
//   25 (0x02000000, xEdit "Obstacle"): how many, how many carry OBND.
// - Their placed REFRs: XTEL or internal, locked (XLOC), rotated other than
//   about the vertical, scaled.
// - Per interior space, the most locked internal doors.
// - For each internal door, the NAVM triangles of its space under the door's
//   footprint (OBND x/y, rotated about Z, scaled, at the REFR; z within the
//   OBND z range plus a margin), and how much of each such triangle's area lies
//   inside the footprint. Area fractions near 1 mean whole triangles match the
//   footprint; low fractions mean a cut must split triangles.
//
//   tools/door_obstacle_census
#include "common/units.h"
#include "esm/esm_file.h"
#include "nav/navmesh_database.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

using namespace esm;

namespace {

// -1 per EsmReferencePhysicaliser; the census reruns with +1 to check it.
float g_rotation_sign = -1.0f;

constexpr uint32_t kObstacleFlag = 0x02000000;
constexpr uint8_t kCellInteriorFlag = 0x01;
// Footprint triangles are those within this height of the door's OBND z range.
constexpr float kHeightMarginMeters = 1.0f;
// A rotation beyond this about X or Y counts as non-vertical.
constexpr float kTiltRadians = 0.01f;

struct Base {
	std::string type;
	std::string editor_id;
	uint32_t flags = 0;
	bool has_obnd = false;
	int16_t obnd[6] = { 0, 0, 0, 0, 0, 0 };
};

struct Placement {
	uint32_t form_id = 0;
	uint32_t base = 0;
	uint32_t space = 0;
	bool interior = false;
	float position[3] = { 0, 0, 0 };
	float rotation[3] = { 0, 0, 0 };
	float scale = 1.0f;
	bool has_xtel = false;
	bool has_xloc = false;
};

struct Point2 {
	float x, y;
};

float cross(const Point2 &o, const Point2 &a, const Point2 &b) {
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

float polygon_area(const std::vector<Point2> &polygon) {
	float twice = 0.0f;
	for (size_t i = 0; i < polygon.size(); ++i) {
		const Point2 &a = polygon[i];
		const Point2 &b = polygon[(i + 1) % polygon.size()];
		twice += a.x * b.y - b.x * a.y;
	}
	return std::fabs(twice) * 0.5f;
}

// Sutherland-Hodgman: `subject` clipped to the convex, counter-clockwise `clip`.
std::vector<Point2> clip_polygon(std::vector<Point2> subject, const std::vector<Point2> &clip) {
	for (size_t e = 0; e < clip.size() && !subject.empty(); ++e) {
		const Point2 &a = clip[e];
		const Point2 &b = clip[(e + 1) % clip.size()];
		std::vector<Point2> input = subject;
		subject.clear();
		for (size_t i = 0; i < input.size(); ++i) {
			const Point2 &p = input[i];
			const Point2 &q = input[(i + 1) % input.size()];
			float side_p = cross(a, b, p);
			float side_q = cross(a, b, q);
			if (side_p >= 0.0f) {
				subject.push_back(p);
			}
			if ((side_p >= 0.0f) != (side_q >= 0.0f)) {
				float t = side_p / (side_p - side_q);
				subject.push_back({ p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t });
			}
		}
	}
	return subject;
}

std::vector<Point2> counter_clockwise(std::vector<Point2> polygon) {
	if (polygon.size() >= 3 && cross(polygon[0], polygon[1], polygon[2]) < 0.0f) {
		std::reverse(polygon.begin(), polygon.end());
	}
	return polygon;
}

// The door's footprint in metres: OBND's x/y rectangle, scaled, rotated about
// Z by the REFR's rotation, at its position. Counter-clockwise.
std::vector<Point2> footprint(const Base &base, const Placement &placement) {
	float s = placement.scale * units::kGamebryoUnitsToMeters;
	float corners[4][2] = {
		{ base.obnd[0] * s, base.obnd[1] * s },
		{ base.obnd[3] * s, base.obnd[1] * s },
		{ base.obnd[3] * s, base.obnd[4] * s },
		{ base.obnd[0] * s, base.obnd[4] * s },
	};
	// Gamebryo REFR rotation: the placement basis negates the authored angle
	// (EsmReferencePhysicaliser.authored_rotation_basis), so a point turns by
	// -rotation.z about Z.
	float angle = g_rotation_sign * placement.rotation[2];
	float c = std::cos(angle), sn = std::sin(angle);
	std::vector<Point2> out;
	for (auto &corner : corners) {
		float x = corner[0] * c - corner[1] * sn;
		float y = corner[0] * sn + corner[1] * c;
		out.push_back({ placement.position[0] * units::kGamebryoUnitsToMeters + x,
				placement.position[1] * units::kGamebryoUnitsToMeters + y });
	}
	return counter_clockwise(out);
}

template <typename T>
T read(const Subrecord &s, size_t offset) {
	T value{};
	if (offset + sizeof(T) <= s.size) std::memcpy(&value, s.data + offset, sizeof(T));
	return value;
}

void print_histogram(const char *label, const std::map<int, int> &histogram) {
	std::printf("%s:", label);
	for (auto &[key, count] : histogram) std::printf(" %d:%d", key, count);
	std::printf("\n");
}

} // namespace

int main(int argc, char **argv) {
	uint32_t inspect_form_id = 0;
	for (int i = 1; i < argc; ++i) {
		std::string arg = argv[i];
		if (arg == "--flip-rotation") g_rotation_sign = 1.0f;
		if (arg.rfind("--inspect=", 0) == 0) inspect_form_id = (uint32_t)std::stoul(arg.substr(10), nullptr, 16);
	}
	EsmFile file;
	try {
		file.open("../fresh_nv_copy/Data/FalloutNV.esm");
	} catch (const std::exception &e) {
		std::fprintf(stderr, "%s\n", e.what());
		return 1;
	}
	nav::NavmeshDatabase navmesh;
	navmesh.load({ "../fresh_nv_copy/Data/FalloutNV.esm" });

	const std::set<std::string> obstacle_types = { "ACTI", "CONT", "SCOL", "MSTT", "LIGH", "STAT" };
	std::map<uint32_t, Base> bases;
	std::vector<Placement> placements;
	uint32_t current_wrld = 0;
	uint32_t current_cell = 0;
	bool current_interior = false;
	file.for_each_record([&](const RecordInfo &r) {
		bool is_base = r.type == "DOOR" || obstacle_types.count(r.type);
		if (r.type != "WRLD" && r.type != "CELL" && r.type != "REFR" && !is_base) return;
		std::vector<uint8_t> data;
		try {
			data = file.read_record_data(r);
		} catch (...) {
			return;
		}
		auto subrecords = EsmFile::parse_subrecords(data);
		if (r.type == "WRLD") {
			current_wrld = r.form_id;
			return;
		}
		if (r.type == "CELL") {
			current_cell = r.form_id;
			current_interior = false;
			for (auto &s : subrecords) {
				if (s.type == "DATA" && s.size >= 1) current_interior = (s.data[0] & kCellInteriorFlag) != 0;
			}
			return;
		}
		if (is_base) {
			Base base;
			base.type = r.type;
			base.flags = r.flags;
			for (auto &s : subrecords) {
				if (s.type == "EDID") base.editor_id = (const char *)s.data;
				if (s.type == "OBND" && s.size >= 12) {
					for (int i = 0; i < 6; ++i) base.obnd[i] = read<int16_t>(s, i * 2);
					// An all-zero OBND gives no footprint.
					base.has_obnd = base.obnd[3] != base.obnd[0] && base.obnd[4] != base.obnd[1];
				}
			}
			bases[r.form_id] = base;
			return;
		}
		Placement placement;
		placement.form_id = r.form_id;
		placement.interior = current_interior;
		placement.space = current_interior ? current_cell : current_wrld;
		for (auto &s : subrecords) {
			if (s.type == "NAME") placement.base = read<uint32_t>(s, 0);
			if (s.type == "XTEL") placement.has_xtel = true;
			if (s.type == "XLOC") placement.has_xloc = true;
			if (s.type == "XSCL") placement.scale = read<float>(s, 0);
			if (s.type == "DATA" && s.size >= 24) {
				for (int i = 0; i < 3; ++i) placement.position[i] = read<float>(s, i * 4);
				for (int i = 0; i < 3; ++i) placement.rotation[i] = read<float>(s, 12 + i * 4);
			}
		}
		placements.push_back(placement);
	});

	// Bases.
	std::map<std::string, int> door_bases, door_bases_with_obnd, obstacle_bases, obstacle_bases_with_obnd;
	for (auto &[id, base] : bases) {
		bool obstacle = (base.flags & kObstacleFlag) != 0;
		if (base.type == "DOOR") {
			door_bases["DOOR"]++;
			if (base.has_obnd) door_bases_with_obnd["DOOR"]++;
			if (obstacle) door_bases["DOOR with the obstacle bit"]++;
		} else if (obstacle) {
			obstacle_bases[base.type]++;
			if (base.has_obnd) obstacle_bases_with_obnd[base.type]++;
		}
	}
	std::printf("DOOR bases: %d (non-zero OBND on %d, obstacle bit on %d)\n", door_bases["DOOR"], door_bases_with_obnd["DOOR"], door_bases["DOOR with the obstacle bit"]);
	std::printf("obstacle-flagged bases by type:\n");
	for (auto &[type, count] : obstacle_bases) std::printf("  %s: %d (OBND on %d)\n", type.c_str(), count, obstacle_bases_with_obnd[type]);

	// Placements.
	int doors = 0, xtel_doors = 0, internal_doors = 0, internal_locked = 0, internal_interior = 0, door_tilted = 0;
	std::map<std::string, int> obstacle_placements, obstacle_tilted, obstacle_scaled;
	std::map<uint32_t, int> locked_internal_by_space;
	std::vector<const Placement *> internal_door_placements;
	for (auto &placement : placements) {
		auto found = bases.find(placement.base);
		if (found == bases.end()) continue;
		const Base &base = found->second;
		bool tilted = std::fabs(placement.rotation[0]) > kTiltRadians || std::fabs(placement.rotation[1]) > kTiltRadians;
		if (base.type == "DOOR") {
			doors++;
			if (tilted) door_tilted++;
			if (placement.has_xtel) {
				xtel_doors++;
				continue;
			}
			internal_doors++;
			if (placement.interior) internal_interior++;
			if (placement.has_xloc) {
				internal_locked++;
				locked_internal_by_space[placement.space]++;
			}
			internal_door_placements.push_back(&placement);
		} else if (base.flags & kObstacleFlag) {
			obstacle_placements[base.type]++;
			if (tilted) obstacle_tilted[base.type]++;
			if (std::fabs(placement.scale - 1.0f) > 0.001f) obstacle_scaled[base.type]++;
		}
	}
	std::printf("placed doors: %d (XTEL %d, internal %d: %d in interiors, %d locked; rotated off vertical: %d)\n",
			doors, xtel_doors, internal_doors, internal_interior, internal_locked, door_tilted);
	std::printf("placed obstacle-flagged references by type:\n");
	for (auto &[type, count] : obstacle_placements) std::printf("  %s: %d (rotated off vertical %d, scaled %d)\n", type.c_str(), count, obstacle_tilted[type], obstacle_scaled[type]);
	int most_locked = 0;
	uint32_t most_locked_space = 0;
	for (auto &[space, count] : locked_internal_by_space) {
		if (count > most_locked) {
			most_locked = count;
			most_locked_space = space;
		}
	}
	std::printf("most locked internal doors in one space: %d (space %08X); spaces with any: %zu\n", most_locked, most_locked_space, locked_internal_by_space.size());

	// Triangles under internal door footprints.
	std::map<int, int> triangles_per_door, inside_percent_hist, inside_percent_small_hist;
	struct DoorDetail {
		int triangles;
		const Placement *placement;
	};
	std::vector<DoorDetail> details;
	std::map<int, int> under_flag_bits, all_flag_bits;
	int under_triangle_total = 0, all_triangle_total = 0;
	for (uint32_t record_index = 0; navmesh.record_at(record_index) != nullptr; ++record_index) {
		for (const nav::Triangle &t : navmesh.record_at(record_index)->triangles) {
			all_triangle_total++;
			for (int bit = 0; bit < 16; ++bit) {
				if (t.flags & (1 << bit)) all_flag_bits[bit]++;
			}
		}
	}
	int doors_without_obnd = 0, doors_without_navmesh = 0;
	float largest_area = 0.0f;
	for (const Placement *placement : internal_door_placements) {
		const Base &base = bases[placement->base];
		if (!base.has_obnd) {
			doors_without_obnd++;
			continue;
		}
		std::vector<Point2> quad = footprint(base, *placement);
		float scale_m = placement->scale * units::kGamebryoUnitsToMeters;
		float z_min = placement->position[2] * units::kGamebryoUnitsToMeters + std::min(base.obnd[2], base.obnd[5]) * scale_m - kHeightMarginMeters;
		float z_max = placement->position[2] * units::kGamebryoUnitsToMeters + std::max(base.obnd[2], base.obnd[5]) * scale_m + kHeightMarginMeters;
		float quad_min_x = 1e30f, quad_max_x = -1e30f, quad_min_y = 1e30f, quad_max_y = -1e30f;
		for (auto &p : quad) {
			quad_min_x = std::min(quad_min_x, p.x);
			quad_max_x = std::max(quad_max_x, p.x);
			quad_min_y = std::min(quad_min_y, p.y);
			quad_max_y = std::max(quad_max_y, p.y);
		}
		int under = 0;
		bool has_records = false;
		std::vector<float> inside_fractions;
		bool inspect = placement->form_id == inspect_form_id;
		if (inspect) {
			std::printf("inspect REFR %08X %s: position (%.2f %.2f %.2f) m, rot z %.2f, OBND (%d %d %d)-(%d %d %d), z window %.2f..%.2f\n",
					placement->form_id, base.editor_id.c_str(), placement->position[0] / 70.0f, placement->position[1] / 70.0f, placement->position[2] / 70.0f,
					placement->rotation[2], base.obnd[0], base.obnd[1], base.obnd[2], base.obnd[3], base.obnd[4], base.obnd[5], z_min, z_max);
			for (auto &p : quad) std::printf("  footprint corner (%.2f %.2f)\n", p.x, p.y);
		}
		for (uint32_t record_index : navmesh.records_in_space(placement->space)) {
			has_records = true;
			const nav::NavMeshRecord *record = navmesh.record_at(record_index);
			if (record->bounds.max.x < quad_min_x || record->bounds.min.x > quad_max_x) continue;
			if (record->bounds.max.y < quad_min_y || record->bounds.min.y > quad_max_y) continue;
			for (uint32_t t = 0; t < record->triangles.size(); ++t) {
				nav::Vec3 a, b, c;
				if (!navmesh.triangle_corners(record_index, t, &a, &b, &c)) continue;
				if (inspect) {
					float cx = (a.x + b.x + c.x) / 3.0f, cy = (a.y + b.y + c.y) / 3.0f;
					float px = placement->position[0] / 70.0f, py = placement->position[1] / 70.0f;
					if (std::hypot(cx - px, cy - py) < 2.0f) {
						std::printf("  near triangle %u: (%.2f %.2f %.2f) (%.2f %.2f %.2f) (%.2f %.2f %.2f)\n", t, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z);
					}
				}
				float tz_max = std::max({ a.z, b.z, c.z });
				float tz_min = std::min({ a.z, b.z, c.z });
				if (tz_max < z_min || tz_min > z_max) continue;
				std::vector<Point2> triangle = counter_clockwise({ { a.x, a.y }, { b.x, b.y }, { c.x, c.y } });
				std::vector<Point2> inside = clip_polygon(triangle, quad);
				if (inside.size() < 3) continue;
				float inside_area = polygon_area(inside);
				if (inside_area < 1e-4f) continue;
				float area = polygon_area(triangle);
				under++;
				under_triangle_total++;
				for (int bit = 0; bit < 16; ++bit) {
					if (record->triangles[t].flags & (1 << bit)) under_flag_bits[bit]++;
				}
				largest_area = std::max(largest_area, area);
				inside_fractions.push_back(inside_area / area);
			}
		}
		for (float fraction : inside_fractions) {
			int bucket = (int)std::lround(fraction * 10.0f) * 10;
			inside_percent_hist[bucket]++;
			if (under <= 4) inside_percent_small_hist[bucket]++;
		}
		if (has_records) details.push_back({ under, placement });
		if (inspect) std::printf("  triangles under the footprint: %d\n", under);
		if (!has_records) doors_without_navmesh++;
		triangles_per_door[std::min(under, 20)]++;
	}
	std::printf("internal doors without a non-zero OBND: %d; in a space with no NAVM: %d\n", doors_without_obnd, doors_without_navmesh);
	print_histogram("NAVM triangles under each internal door footprint (20 = 20 or more)", triangles_per_door);
	print_histogram("share of each such triangle's area inside the footprint, percent (rounded to 10)", inside_percent_hist);
	print_histogram("  the same for doors with 1-4 triangles", inside_percent_small_hist);
	std::printf("NVTR Flags bits, triangles under internal doors (%d) vs all triangles (%d):\n", under_triangle_total, all_triangle_total);
	for (int bit = 0; bit < 16; ++bit) {
		if (!under_flag_bits[bit] && !all_flag_bits[bit]) continue;
		std::printf("  0x%04X: %.1f%% under doors, %.2f%% of all\n", 1 << bit,
				100.0 * under_flag_bits[bit] / std::max(under_triangle_total, 1), 100.0 * all_flag_bits[bit] / std::max(all_triangle_total, 1));
	}
	std::printf("largest such triangle: %.2f m^2\n", largest_area);
	std::sort(details.begin(), details.end(), [](const DoorDetail &a, const DoorDetail &b) { return a.triangles > b.triangles; });
	auto describe = [&](const DoorDetail &d) {
		const Base &base = bases[d.placement->base];
		std::printf("  REFR %08X %s: %d triangles; OBND %dx%dx%d units, scale %.2f, rot (%.2f %.2f %.2f), space %08X%s\n",
				d.placement->form_id, base.editor_id.c_str(), d.triangles,
				base.obnd[3] - base.obnd[0], base.obnd[4] - base.obnd[1], base.obnd[5] - base.obnd[2],
				d.placement->scale, d.placement->rotation[0], d.placement->rotation[1], d.placement->rotation[2],
				d.placement->space, d.placement->interior ? "" : " (exterior)");
	};
	std::printf("most triangles:\n");
	for (size_t i = 0; i < details.size() && i < 8; ++i) describe(details[i]);
	std::printf("no triangles (sample):\n");
	int shown = 0;
	for (auto &d : details) {
		if (d.triangles == 0 && shown < 8) {
			describe(d);
			shown++;
		}
	}
	std::map<std::string, int> zero_by_base;
	for (auto &d : details) {
		if (d.triangles == 0) zero_by_base[bases[d.placement->base].editor_id]++;
	}
	std::vector<std::pair<int, std::string>> zero_sorted;
	for (auto &[name, count] : zero_by_base) zero_sorted.push_back({ count, name });
	std::sort(zero_sorted.rbegin(), zero_sorted.rend());
	std::printf("no triangles, by base:");
	for (size_t i = 0; i < zero_sorted.size() && i < 12; ++i) std::printf(" %s:%d", zero_sorted[i].second.c_str(), zero_sorted[i].first);
	std::printf("\n");
	return 0;
}
