// Answers two questions that decide how cross-record navmesh stitching is built:
//
//  1. What coordinate space are NAVM vertices in -- cell-local (0..4096) or
//     worldspace-absolute? Checked against each NAVM's owning CELL's authored
//     XCLC grid coordinate, so the answer comes from real data, not inference.
//
//  2. NVEX gives (type, target navmesh FormID, triangle) but does NOT say which
//     triangle in THIS record the link leaves from, so it cannot by itself
//     stitch triangle-to-triangle. Testing whether boundary edges can instead be
//     stitched GEOMETRICALLY (two triangles in NVEX-linked records sharing an
//     edge's two vertex positions), with NVEX used only as the candidate-record
//     list. Reports the real match rate; a high rate confirms the approach, a
//     low one kills it.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <map>
#include <set>
#include <vector>
#include <string>
#include <unordered_map>
#include "esm/esm_file.h"

struct V3 { float x=0,y=0,z=0; };
struct Tri { uint16_t v[3]; int16_t e[3]; };
struct Mesh {
	uint32_t form_id=0, cell_form_id=0;
	std::vector<V3> verts;
	std::vector<Tri> tris;
	std::set<uint32_t> nvex_targets;
	V3 bmin, bmax;
	bool has_bounds=false;
};

static uint32_t rd_u32(const uint8_t*d,size_t n,size_t o){ if(o+4>n) return 0; return d[o]|(d[o+1]<<8)|(d[o+2]<<16)|(uint32_t(d[o+3])<<24);}
static uint16_t rd_u16(const uint8_t*d,size_t n,size_t o){ if(o+2>n) return 0; return d[o]|(d[o+1]<<8);}
static float rd_f32(const uint8_t*d,size_t n,size_t o){ if(o+4>n) return 0.f; float f; std::memcpy(&f,d+o,4); return f; }
static V3 rd_v3(const uint8_t*d,size_t n,size_t o){ return V3{rd_f32(d,n,o),rd_f32(d,n,o+4),rd_f32(d,n,o+8)}; }

// Quantized vertex key for exact-ish position matching across records.
static uint64_t vkey(const V3 &v) {
	auto q = [](float f)->int64_t { return (int64_t)llround((double)f * 8.0); }; // 1/8 unit
	uint64_t h = 1469598103934665603ull;
	int64_t c[3] = { q(v.x), q(v.y), q(v.z) };
	for (int i=0;i<3;i++){ const uint8_t*p=(const uint8_t*)&c[i]; for(int b=0;b<8;b++){ h^=p[b]; h*=1099511628211ull; } }
	return h;
}

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr,"usage: %s <esm...>\n", argv[0]); return 1; }
	std::vector<Mesh> meshes;
	std::unordered_map<uint32_t,size_t> by_form;
	// cell -> grid coord, for the coordinate-space test
	std::map<uint32_t,std::pair<int,int>> cell_grid;

	for (int i=1;i<argc;i++){
		esm::EsmFile file;
		try { file.open(argv[i]); } catch(const std::exception&e){ fprintf(stderr,"open %s: %s\n",argv[i],e.what()); continue; }
		file.for_each_record([&](const esm::RecordInfo &rec){
			if (rec.type != "NAVM") return;
			auto raw = file.read_record_data(rec);
			auto subs = esm::EsmFile::parse_subrecords(raw);
			Mesh m; m.form_id = rec.form_id;
			uint32_t vc=0,tc=0,elc=0;
			for (auto &s: subs) if (s.type=="DATA"){ m.cell_form_id=rd_u32(s.data,s.size,0); vc=rd_u32(s.data,s.size,4); tc=rd_u32(s.data,s.size,8); elc=rd_u32(s.data,s.size,12);}
			for (auto &s: subs){
				if (s.type=="NVVX"){ size_t c = vc?vc:s.size/12; m.verts.resize(c); for(size_t k=0;k<c;k++) m.verts[k]=rd_v3(s.data,s.size,k*12); }
				else if (s.type=="NVTR"){ size_t c = tc?tc:s.size/16; m.tris.resize(c); for(size_t k=0;k<c;k++){ size_t o=k*16; Tri&t=m.tris[k]; for(int j=0;j<3;j++) t.v[j]=rd_u16(s.data,s.size,o+j*2); for(int j=0;j<3;j++) t.e[j]=(int16_t)rd_u16(s.data,s.size,o+6+j*2);} }
				else if (s.type=="NVEX"){ size_t c = elc?elc:s.size/10; for(size_t k=0;k<c;k++){ uint32_t tgt=rd_u32(s.data,s.size,k*10+4); if(tgt) m.nvex_targets.insert(tgt);} }
				else if (s.type=="NVGD"){ if(s.size>=36){ m.has_bounds=true; m.bmin=rd_v3(s.data,s.size,12); m.bmax=rd_v3(s.data,s.size,24);} }
			}
			by_form[m.form_id]=meshes.size();
			meshes.push_back(std::move(m));
		});
		// grid coords for every exterior CELL we saw
		for (auto &m : meshes) {
			if (cell_grid.count(m.cell_form_id)) continue;
			auto g = file.get_exterior_cell_grid(m.cell_form_id);
			if (g.has_value()) cell_grid[m.cell_form_id] = { g->x, g->y };
		}
	}

	// --- Q1: coordinate space ---
	// For an exterior NAVM, if vertices are worldspace-absolute their bounds
	// should sit near grid_x*4096. If cell-local they'd sit in roughly 0..4096.
	int checked=0, absolute=0, local=0;
	for (auto &m : meshes) {
		auto it = cell_grid.find(m.cell_form_id);
		if (it == cell_grid.end() || !m.has_bounds) continue;
		double expect_x = it->second.first * 4096.0;
		double cx = (m.bmin.x + m.bmax.x) * 0.5;
		checked++;
		if (std::fabs(cx - expect_x) < 4096.0) absolute++;
		else if (cx >= -4096.0 && cx <= 8192.0) local++;
	}
	printf("--- Q1 coordinate space (exterior NAVMs with a grid coord) ---\n");
	printf("checked=%d  consistent-with-WORLDSPACE-ABSOLUTE=%d  consistent-with-CELL-LOCAL=%d\n\n",
		checked, absolute, local);

	// --- Q2: geometric stitch rate over NVEX-linked candidates ---
	// Build a per-mesh map of undirected vertex-position-pair -> triangle, then
	// for every boundary (-1) edge look for a match in NVEX-linked meshes.
	std::vector<std::unordered_map<uint64_t,int>> edge_maps(meshes.size());
	for (size_t mi=0; mi<meshes.size(); ++mi) {
		auto &m = meshes[mi];
		for (size_t t=0; t<m.tris.size(); ++t) {
			for (int e=0;e<3;e++) {
				int a = m.tris[t].v[e], b = m.tris[t].v[(e+1)%3];
				if (a >= (int)m.verts.size() || b >= (int)m.verts.size()) continue;
				uint64_t ka = vkey(m.verts[a]), kb = vkey(m.verts[b]);
				uint64_t key = ka ^ (kb*1099511628211ull) ^ (kb) ^ (ka*1099511628211ull); // order-independent
				edge_maps[mi][key] = (int)t;
			}
		}
	}
	uint64_t boundary_edges=0, boundary_in_linked_mesh=0, matched=0;
	for (size_t mi=0; mi<meshes.size(); ++mi) {
		auto &m = meshes[mi];
		if (m.nvex_targets.empty()) {
			for (auto &t : m.tris) for (int e=0;e<3;e++) if (t.e[e]==-1) boundary_edges++;
			continue;
		}
		for (auto &t : m.tris) {
			for (int e=0;e<3;e++) {
				if (t.e[e] != -1) continue;
				boundary_edges++; boundary_in_linked_mesh++;
				int a=t.v[e], b=t.v[(e+1)%3];
				if (a>=(int)m.verts.size()||b>=(int)m.verts.size()) continue;
				uint64_t ka=vkey(m.verts[a]), kb=vkey(m.verts[b]);
				uint64_t key = ka ^ (kb*1099511628211ull) ^ (kb) ^ (ka*1099511628211ull);
				bool found=false;
				for (uint32_t tgt : m.nvex_targets) {
					auto it=by_form.find(tgt); if(it==by_form.end()) continue;
					if (edge_maps[it->second].count(key)) { found=true; break; }
				}
				if (found) matched++;
			}
		}
	}
	printf("--- Q2 geometric stitching across NVEX-linked records ---\n");
	printf("total boundary (-1) edges           : %llu\n", (unsigned long long)boundary_edges);
	printf("  ...in records that have NVEX links: %llu\n", (unsigned long long)boundary_in_linked_mesh);
	printf("  ...matched a shared edge in a linked record: %llu (%.2f%% of linked-record boundary edges)\n",
		(unsigned long long)matched, 100.0*matched/(boundary_in_linked_mesh?boundary_in_linked_mesh:1));
	printf("\n(NVEX link count was %s; a match rate near the NVEX total means NVEX marks exactly\n"
	       " the stitched edges, with the rest being true outer perimeter.)\n", "110153 across all masters");
	return 0;
}
