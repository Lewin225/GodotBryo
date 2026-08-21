#include "../src/esm/esm_file.h"
#include <cmath>
#include <cstdio>
#include <vector>

using namespace esm;

struct Vec3 {
	double x, y, z;
	Vec3 operator-(const Vec3 &o) const { return { x - o.x, y - o.y, z - o.z }; }
	Vec3 cross(const Vec3 &o) const {
		return { y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x };
	}
	double length() const { return std::sqrt(x * x + y * y + z * z); }
	Vec3 normalized() const {
		double l = length();
		if (l < 1e-9) return { 0, 1, 0 };
		return { x / l, y / l, z / l };
	}
};

constexpr int GRID = 33;
constexpr double VERTEX_SPACING_M = 128.0 / 70.0;

int main(int argc, char **argv) {
	if (argc < 2) {
		std::printf("usage: vnml_check <esm> [max_cells]\n");
		return 1;
	}
	int max_cells = argc > 2 ? std::atoi(argv[2]) : 20;

	EsmFile f;
	try {
		f.open(argv[1]);
	} catch (const std::exception &e) {
		std::printf("failed to open: %s\n", e.what());
		return 1;
	}

	int cells_checked = 0;
	int sample_count = 0;
	double raw_len_sum = 0.0, raw_len_min = 1e9, raw_len_max = -1e9;

	// Brute-force search over axis assignment + sign for the 3 decoded VNML
	// components against the recomputed normal, instead of assuming a byte
	// order/formula -- this project's own "verify numerically, don't
	// assume" discipline. 6 axis permutations x 8 sign combos = 48 total
	// candidates, each accumulated across every real sample.
	const int perms[6][3] = { { 0, 1, 2 }, { 0, 2, 1 }, { 1, 0, 2 }, { 1, 2, 0 }, { 2, 0, 1 }, { 2, 1, 0 } };
	double sum_angle[6][8] = {};
	double max_angle[6][8] = {};
	double computed_y_sum = 0.0;

	f.for_each_record([&](const RecordInfo &rec) {
		if (rec.type != "LAND") return;
		if (cells_checked >= max_cells) return;
		try {
			std::vector<uint8_t> data = f.read_record_data(rec);
			std::vector<Subrecord> subs = EsmFile::parse_subrecords(data);

			std::vector<int8_t> vnml_raw; // 3 bytes/vertex, signed for now, decide encoding after inspecting
			bool have_vnml = false;
			for (const auto &s : subs) {
				if (s.type == "VNML" && s.size >= static_cast<size_t>(GRID) * GRID * 3) {
					vnml_raw.resize(static_cast<size_t>(GRID) * GRID * 3);
					for (size_t i = 0; i < vnml_raw.size(); ++i) vnml_raw[i] = static_cast<int8_t>(s.data[i]);
					have_vnml = true;
				}
			}
			if (!have_vnml) return;

			auto land_opt = f.get_land_data(rec);
			if (!land_opt) return;
			const LandData &land = *land_opt;
			if (land.heights.size() != static_cast<size_t>(GRID) * GRID) return;

			cells_checked++;

			// Decode VNML using the standard Bethesda unsigned-byte encoding
			// (0..255 -> -1.0..1.0 via byte/127.5 - 1.0) as a first hypothesis
			// -- validated below by checking the raw decoded vector's length
			// against 1.0 (a real numeric sanity check, not assumed correct).
			int formula = argc > 3 ? std::atoi(argv[3]) : 0;
			auto decode_component = [formula](uint8_t b) -> double {
				if (formula == 1) {
					// signed-byte hypothesis
					return static_cast<double>(static_cast<int8_t>(b)) / 127.0;
				}
				return static_cast<double>(b) / 127.5 - 1.0;
			};

			for (int row = 1; row < GRID - 1; row += 4) {
				for (int col = 1; col < GRID - 1; col += 4) {
					size_t idx = static_cast<size_t>(row) * GRID + col;
					double c[3] = {
						decode_component(static_cast<uint8_t>(vnml_raw[idx * 3 + 0])),
						decode_component(static_cast<uint8_t>(vnml_raw[idx * 3 + 1])),
						decode_component(static_cast<uint8_t>(vnml_raw[idx * 3 + 2]))
					};
					double raw_len = std::sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2]);
					raw_len_sum += raw_len;
					raw_len_min = std::min(raw_len_min, raw_len);
					raw_len_max = std::max(raw_len_max, raw_len);

					// Recompute a normal from real height data via central
					// difference (same real heights.get_land_data() already
					// decodes and this project already trusts elsewhere).
					// Increasing Bethesda row maps to DECREASING world Z
					// (this project's own established convention).
					double h_l = land.heights[idx - 1];
					double h_r = land.heights[idx + 1];
					double h_d = land.heights[idx - GRID];
					double h_u = land.heights[idx + GRID];
					Vec3 dx = { 2.0 * VERTEX_SPACING_M, h_r - h_l, 0.0 };
					Vec3 dz = { 0.0, h_u - h_d, -2.0 * VERTEX_SPACING_M };
					Vec3 computed_n = dx.cross(dz).normalized();
					computed_y_sum += computed_n.y;

					for (int p = 0; p < 6; ++p) {
						double ax = c[perms[p][0]], ay = c[perms[p][1]], az = c[perms[p][2]];
						for (int s = 0; s < 8; ++s) {
							double sx = (s & 1) ? -1.0 : 1.0;
							double sy = (s & 2) ? -1.0 : 1.0;
							double sz = (s & 4) ? -1.0 : 1.0;
							Vec3 authored = { ax * sx, ay * sy, az * sz };
							Vec3 authored_n = authored.normalized();
							double dot = authored_n.x * computed_n.x + authored_n.y * computed_n.y + authored_n.z * computed_n.z;
							dot = std::max(-1.0, std::min(1.0, dot));
							double angle_deg = std::acos(dot) * 180.0 / M_PI;
							sum_angle[p][s] += angle_deg;
							max_angle[p][s] = std::max(max_angle[p][s], angle_deg);
						}
					}
					sample_count++;
				}
			}
		} catch (const std::exception &e) {
			std::printf("skip: %s\n", e.what());
		}
	});

	std::printf("cells checked: %d, samples: %d\n", cells_checked, sample_count);
	if (sample_count > 0) {
		std::printf("raw decoded VNML vector length: avg=%.4f min=%.4f max=%.4f (1.0 = clean unit vectors, confirms decode formula)\n",
				raw_len_sum / sample_count, raw_len_min, raw_len_max);
		std::printf("recomputed-from-heights normal.y avg: %.4f (should be close to 1.0 on mostly-flat wasteland terrain if the recompute itself is sane)\n",
				computed_y_sum / sample_count);
		std::printf("\nAll 48 axis-permutation x sign candidates, avg angle vs recomputed-from-heights normal:\n");
		const char *axis_names[3] = { "X", "Y", "Z" };
		int best_p = 0, best_s = 0;
		double best_avg = 1e9;
		for (int p = 0; p < 6; ++p) {
			for (int s = 0; s < 8; ++s) {
				double avg = sum_angle[p][s] / sample_count;
				if (avg < best_avg) {
					best_avg = avg;
					best_p = p;
					best_s = s;
				}
			}
		}
		for (int p = 0; p < 6; ++p) {
			for (int s = 0; s < 8; ++s) {
				double avg = sum_angle[p][s] / sample_count;
				bool is_best = (p == best_p && s == best_s);
				std::printf("%s world=(%s%s,%s%s,%s%s)  avg=%.2f deg  max=%.2f deg%s\n",
						is_best ? "**" : "  ",
						(s & 1) ? "-" : "+", axis_names[perms[p][0]],
						(s & 2) ? "-" : "+", axis_names[perms[p][1]],
						(s & 4) ? "-" : "+", axis_names[perms[p][2]],
						avg, max_angle[p][s], is_best ? "  <-- BEST" : "");
			}
		}
	}
	return 0;
}
