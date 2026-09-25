// Exercises NavmeshDatabase against the real shipped masters: load timing
// against the < 5s boot budget, structural totals, a snap query, a real route,
// and a coarse-index-on vs coarse-index-off comparison (same answer, different
// cost). Also snaps every placed actor in the game to the navmesh, which is the
// question that started this: where would physicalizing an actor actually put
// them, and how far is that from their authored position?
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <chrono>
#include <string>
#include <vector>
#include <map>
#include "nav/navmesh_database.h"
#include "esm/esm_file.h"

using Clock = std::chrono::steady_clock;
static double ms_since(Clock::time_point t) {
	return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: %s <esm...>\n", argv[0]); return 1; }
	std::vector<std::string> paths;
	for (int i = 1; i < argc; ++i) paths.push_back(argv[i]);

	nav::NavmeshDatabase db;
	db.load(paths);
	const nav::LoadStats &s = db.stats();

	printf("=== load ===\n");
	printf("records=%llu vertices=%llu triangles=%llu\n",
		(unsigned long long)s.records, (unsigned long long)s.vertices, (unsigned long long)s.triangles);
	printf("authored NVEX links=%llu | derived cross-record links=%llu | unresolved targets=%llu\n",
		(unsigned long long)s.authored_edge_links, (unsigned long long)s.derived_cross_links,
		(unsigned long long)s.unresolved_edge_link_targets);
	printf("clamped out-of-range NVTR edges=%llu\n", (unsigned long long)s.clamped_out_of_range_edges);
	printf("resident=%.2f MB\n", s.resident_bytes / (1024.0 * 1024.0));
	printf("timing: open=%.1f walk=%.1f read=%.1f parse=%.1f index=%.1f stitch=%.1f TOTAL=%.1f ms (%.2f s)\n",
		s.open_ms, s.walk_ms, s.read_ms, s.parse_ms, s.index_ms, s.stitch_ms, s.total_ms, s.total_ms / 1000.0);
	printf("BOOT BUDGET (5000 ms): %s\n\n", s.total_ms < 5000.0 ? "PASS" : "FAIL");

	printf("=== spaces ===\n");
	auto spaces = db.spaces();
	printf("distinct spaces with navmesh: %zu\n", spaces.size());
	// Biggest space by record count -- the exterior wasteland, in practice.
	uint32_t biggest = 0; size_t biggest_n = 0;
	for (uint32_t sp : spaces) {
		size_t n = db.records_in_space(sp).size();
		if (n > biggest_n) { biggest_n = n; biggest = sp; }
	}
	printf("largest space 0x%08X with %zu records\n\n", biggest, biggest_n);

	// --- snap + route in the largest space, using two real record centers ---
	const auto &recs = db.records_in_space(biggest);
	if (recs.size() >= 2) {
		const nav::NavMeshRecord *a = db.record_at(recs[0]);
		const nav::NavMeshRecord *b = db.record_at(recs[biggest_n / 2]);
		printf("=== snap (coarse index on vs off must agree) ===\n");
		auto t1 = Clock::now();
		nav::SnapResult on = db.snap(biggest, a->center, 60.0f, true);
		double on_ms = ms_since(t1);
		auto t2 = Clock::now();
		nav::SnapResult off = db.snap(biggest, a->center, 60.0f, false);
		double off_ms = ms_since(t2);
		printf("coarse ON : found=%d tri=%u dist=%.2f  (%.3f ms)\n", on.found, on.global_triangle, on.distance, on_ms);
		printf("coarse OFF: found=%d tri=%u dist=%.2f  (%.3f ms)\n", off.found, off.global_triangle, off.distance, off_ms);
		printf("AGREE: %s | speedup %.1fx\n\n",
			(on.found == off.found && on.global_triangle == off.global_triangle) ? "yes" : "NO",
			off_ms > 0 ? off_ms / (on_ms > 0 ? on_ms : 1e-6) : 0.0);

		printf("=== route across the space ===\n");
		auto t3 = Clock::now();
		nav::RouteResult r = db.route(biggest, a->center, b->center, 60.0f, true);
		double route_ms = ms_since(t3);
		printf("found=%d waypoints=%zu triangles=%zu visited=%u length=%.1f  (%.1f ms)\n\n",
			r.found, r.waypoints.size(), r.triangles.size(), r.visited_nodes, r.length, route_ms);
	}

	// --- snap every placed actor: the original "would this drop them in a river" question ---
	printf("=== placed-actor snap census ===\n");
	std::vector<std::pair<uint32_t, nav::Vec3>> actors; // space, position
	{
		esm::EsmFile file;
		try {
			file.open(paths[0]);
			std::vector<esm::RecordInfo> cells;
			file.for_each_record([&](const esm::RecordInfo &rec) {
				if (rec.type == "CELL") cells.push_back(rec);
			});
			for (const esm::RecordInfo &cell : cells) {
				auto ws = file.get_cell_worldspace(cell.form_id);
				uint32_t space = (ws.has_value() && *ws != 0) ? *ws : cell.form_id;
				for (const auto &p : file.get_cell_actors(cell)) {
					actors.push_back({ space, nav::Vec3{ p.position[0], p.position[1], p.position[2] } });
				}
			}
		} catch (const std::exception &e) {
			printf("(actor census skipped: %s)\n", e.what());
		}
	}
	if (!actors.empty()) {
		auto t4 = Clock::now();
		int on_mesh = 0, near_mesh = 0, far_mesh = 0, miss_in_navmeshed_space = 0;
		int in_space_without_navmesh = 0;
		double worst = 0;
		for (auto &a : actors) {
			bool space_has_navmesh = !db.records_in_space(a.first).empty();
			if (!space_has_navmesh) { in_space_without_navmesh++; continue; }
			nav::SnapResult sr = db.snap(a.first, a.second, 8.0f, true);
			if (!sr.found) { miss_in_navmeshed_space++; continue; }
			if (sr.distance <= 0.25f) on_mesh++;
			else if (sr.distance <= 2.0f) near_mesh++;
			else far_mesh++;
			if (sr.distance > worst) worst = sr.distance;
		}
		double all_ms = ms_since(t4);
		printf("actors=%zu\n", actors.size());
		printf("  in a space with NO navmesh at all : %d  (expected: not every cell is navmeshed)\n", in_space_without_navmesh);
		printf("  space HAS navmesh but snap missed : %d  (this is the number that matters)\n", miss_in_navmeshed_space);
		printf("  on-mesh(<=0.25m)=%d  near(<=2m)=%d  far(>2m)=%d\n", on_mesh, near_mesh, far_mesh);
		printf("worst snap distance=%.2f m | whole census took %.1f ms (%.3f ms/actor)\n",
			worst, all_ms, all_ms / actors.size());

		// If misses in navmeshed spaces are common, the fault is ours, not the
		// data -- dump a few so the cause is visible rather than guessed at.
		int dumped = 0;
		for (auto &a : actors) {
			if (dumped >= 5) break;
			if (db.records_in_space(a.first).empty()) continue;
			nav::SnapResult sr = db.snap(a.first, a.second, 8.0f, true);
			if (sr.found) continue;
			const auto &recs2 = db.records_in_space(a.first);
			const nav::NavMeshRecord *r0 = db.record_at(recs2[0]);
			printf("  MISS space=0x%08X actor=(%.0f, %.0f, %.0f) | space has %zu records, first bounds=(%.0f..%.0f, %.0f..%.0f, %.0f..%.0f)\n",
				a.first, a.second.x, a.second.y, a.second.z, recs2.size(),
				r0->bounds.min.x, r0->bounds.max.x, r0->bounds.min.y, r0->bounds.max.y, r0->bounds.min.z, r0->bounds.max.z);
			dumped++;
		}
	}
	return 0;
}
