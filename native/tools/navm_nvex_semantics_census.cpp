// Answers: in an NVEX Edge Link { Type u32, Navmesh FormID u32, Triangle u16 },
// is "Triangle" an index into THIS record's triangles (the local edge the link
// leaves from) or into the TARGET record's triangles?
//
// xEdit's FNV schema names the field but its meaning is not documented in the
// files vendored under enginedocs/xEdit/. Geometric seam matching was already
// ruled out empirically (navm_stitch_census: only 2.1% of boundary edges in
// NVEX-linked records share vertex positions with a linked record), so NVEX is
// the only available stitching source and this semantic has to be settled
// before any traversal is built on it.
//
// Four exhaustive tests over the whole shipped population:
//   T1 in-range-local  : is Triangle always < this record's triangle count?
//   T2 in-range-target : is Triangle always < the target record's triangle count?
//   T3 local-has-boundary : does this record's triangle[Triangle] actually have
//                           a -1 (boundary) edge, as a real external seam must?
//   T4 target-has-boundary: same test, applied to the target record's triangle.
//   T5 reciprocity     : does count(A->B) == count(B->A) for every linked pair?
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <map>
#include <vector>
#include <string>
#include <unordered_map>
#include "esm/esm_file.h"

struct Tri { uint16_t v[3]; int16_t e[3]; };
struct Mesh {
	uint32_t form_id = 0;
	std::vector<Tri> tris;
	std::vector<std::pair<uint32_t,uint16_t>> links; // (target form id, triangle)
};

static uint32_t rd_u32(const uint8_t*d,size_t n,size_t o){ if(o+4>n) return 0; return d[o]|(d[o+1]<<8)|(d[o+2]<<16)|(uint32_t(d[o+3])<<24);}
static uint16_t rd_u16(const uint8_t*d,size_t n,size_t o){ if(o+2>n) return 0; return d[o]|(d[o+1]<<8);}

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr,"usage: %s <esm...>\n", argv[0]); return 1; }
	std::vector<Mesh> meshes;
	std::unordered_map<uint32_t,size_t> by_form;

	for (int i=1;i<argc;i++){
		esm::EsmFile file;
		try { file.open(argv[i]); } catch(const std::exception&e){ fprintf(stderr,"open %s: %s\n",argv[i],e.what()); continue; }
		file.for_each_record([&](const esm::RecordInfo &rec){
			if (rec.type != "NAVM") return;
			auto raw = file.read_record_data(rec);
			auto subs = esm::EsmFile::parse_subrecords(raw);
			Mesh m; m.form_id = rec.form_id;
			uint32_t tc=0, elc=0;
			for (auto &s: subs) if (s.type=="DATA"){ tc=rd_u32(s.data,s.size,8); elc=rd_u32(s.data,s.size,12); }
			for (auto &s: subs){
				if (s.type=="NVTR"){ size_t c = tc?tc:s.size/16; m.tris.resize(c);
					for(size_t k=0;k<c;k++){ size_t o=k*16; if(o+16>s.size) break; Tri&t=m.tris[k];
						for(int j=0;j<3;j++) t.v[j]=rd_u16(s.data,s.size,o+j*2);
						for(int j=0;j<3;j++) t.e[j]=(int16_t)rd_u16(s.data,s.size,o+6+j*2); } }
				else if (s.type=="NVEX"){ size_t c = elc?elc:s.size/10;
					for(size_t k=0;k<c;k++){ size_t o=k*10; if(o+10>s.size) break;
						uint32_t tgt=rd_u32(s.data,s.size,o+4); uint16_t tri=rd_u16(s.data,s.size,o+8);
						if(tgt) m.links.push_back({tgt,tri}); } }
			}
			by_form[m.form_id]=meshes.size();
			meshes.push_back(std::move(m));
		});
	}

	uint64_t total=0, in_local=0, in_target=0, local_boundary=0, target_boundary=0, target_missing=0;
	for (auto &m : meshes) {
		for (auto &lk : m.links) {
			total++;
			if (lk.second < m.tris.size()) {
				in_local++;
				bool b=false; for(int e=0;e<3;e++) if(m.tris[lk.second].e[e]==-1) b=true;
				if (b) local_boundary++;
			}
			auto it = by_form.find(lk.first);
			if (it == by_form.end()) { target_missing++; continue; }
			const Mesh &tm = meshes[it->second];
			if (lk.second < tm.tris.size()) {
				in_target++;
				bool b=false; for(int e=0;e<3;e++) if(tm.tris[lk.second].e[e]==-1) b=true;
				if (b) target_boundary++;
			}
		}
	}

	printf("Total NVEX links: %llu   (targets not found: %llu)\n", (unsigned long long)total, (unsigned long long)target_missing);
	printf("T1 Triangle < LOCAL  triangle count : %llu (%.3f%%)\n", (unsigned long long)in_local, 100.0*in_local/(total?total:1));
	printf("T2 Triangle < TARGET triangle count : %llu (%.3f%%)\n", (unsigned long long)in_target, 100.0*in_target/(total?total:1));
	printf("T3 LOCAL  triangle[Triangle] has a -1 boundary edge : %llu (%.3f%% of in-range-local)\n",
		(unsigned long long)local_boundary, 100.0*local_boundary/(in_local?in_local:1));
	printf("T4 TARGET triangle[Triangle] has a -1 boundary edge : %llu (%.3f%% of in-range-target)\n",
		(unsigned long long)target_boundary, 100.0*target_boundary/(in_target?in_target:1));

	// T5: reciprocity of link counts per ordered pair.
	std::map<std::pair<uint32_t,uint32_t>, int> directed;
	for (auto &m : meshes) for (auto &lk : m.links) directed[{m.form_id, lk.first}]++;
	int pairs=0, reciprocal_equal=0, reciprocal_missing=0;
	for (auto &kv : directed) {
		pairs++;
		auto back = directed.find({kv.first.second, kv.first.first});
		if (back == directed.end()) reciprocal_missing++;
		else if (back->second == kv.second) reciprocal_equal++;
	}
	printf("T5 directed pairs: %d | with equal reverse count: %d (%.2f%%) | with NO reverse link at all: %d\n",
		pairs, reciprocal_equal, 100.0*reciprocal_equal/(pairs?pairs:1), reciprocal_missing);
	return 0;
}
