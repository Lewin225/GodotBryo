#include "tri_loader.h"
#include "../common/units.h"

#include <cstring>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace tri {
namespace {
class Reader {
	const std::vector<uint8_t> &b; size_t p = 0;
	void need(size_t n) const { if (n > b.size() - p) throw std::runtime_error("TRI truncated"); }
public:
	Reader(const std::vector<uint8_t> &bytes) : b(bytes) {}
	size_t remaining() const { return b.size() - p; }
	uint32_t u32() { need(4); uint32_t v = uint32_t(b[p]) | (uint32_t(b[p+1])<<8) | (uint32_t(b[p+2])<<16) | (uint32_t(b[p+3])<<24); p += 4; return v; }
	int32_t i32() { return static_cast<int32_t>(u32()); }
	int16_t i16() { need(2); uint16_t v = uint16_t(b[p]) | (uint16_t(b[p+1])<<8); p += 2; return static_cast<int16_t>(v); }
	float f32() { uint32_t x = u32(); float v; std::memcpy(&v, &x, sizeof(v)); return v; }
	void skip(size_t n) { need(n); p += n; }
	std::string string() { uint32_t n = u32(); if (n > b.size() - p) throw std::runtime_error("TRI string truncated"); std::string s(reinterpret_cast<const char *>(b.data()+p), n); p += n; if (!s.empty() && s.back() == '\0') s.pop_back(); return s; }
};
void check_count(uint32_t n, size_t item_size, size_t remaining, const char *what) {
	if (n > remaining / item_size) throw std::runtime_error(std::string("TRI invalid ") + what + " count");
}
void check_index(uint32_t i, uint32_t n, const char *what) { if (i >= n) throw std::runtime_error(std::string("TRI ") + what + " index out of bounds"); }
}

Mesh load(const std::vector<uint8_t> &bytes, const std::string &source_path) {
	if (bytes.size() < 64) throw std::runtime_error("TRI header truncated");
	if (std::memcmp(bytes.data(), "FRTRI003", 8) != 0) throw std::runtime_error("invalid TRI magic");
	Reader r(bytes); r.skip(8);
	uint32_t v=r.u32(), t=r.u32(), q=r.u32(), lv=r.u32(), ls=r.u32(), x=r.u32(), ext=r.u32(), md=r.u32(), ms=r.u32(), k=r.u32();
	(void)ext;
	r.skip(16);
	if (!v || v > std::numeric_limits<uint32_t>::max()-k) throw std::runtime_error("invalid TRI vertex count");
	Mesh out; out.source_path=source_path; out.vertex_count=v; out.triangle_count=t; out.quad_count=q; out.statistical_vertex_count=k;
	if (size_t(v + k) > (bytes.size() - 64) / (3 * sizeof(float))) throw std::runtime_error("TRI vertices truncated");
	out.vertices.resize(size_t(v+k)*3);
	for (size_t i=0;i<out.vertices.size();++i) out.vertices[i]=r.f32()*units::kGamebryoUnitsToMeters;
	check_count(t, 3*sizeof(uint32_t), bytes.size()-64, "triangle"); out.triangles.resize(size_t(t)*3);
	for (auto &i:out.triangles) { i=r.u32(); check_index(i,v+k,"triangle"); }
	check_count(q, 4*sizeof(uint32_t), bytes.size()-64, "quad"); out.quads.resize(size_t(q)*4);
	for (auto &i:out.quads) { i=r.u32(); check_index(i,v+k,"quad"); }
	for (uint32_t i=0;i<lv;++i) { r.i32(); r.string(); }
	for (uint32_t i=0;i<ls;++i) { r.i32(); r.f32(); r.f32(); r.f32(); r.string(); }
	if (ext & 1) { // per-facet X or per-vertex V texture coordinates
		uint32_t n = x ? x : v; r.skip(size_t(n)*2*sizeof(float));
		if (x) { r.skip(size_t(t)*3*sizeof(uint32_t)); r.skip(size_t(q)*4*sizeof(uint32_t)); }
	}
	if (md > r.remaining() / 8) throw std::runtime_error("TRI delta morph count out of bounds");
	out.delta_morphs.reserve(md);
	for (uint32_t m=0;m<md;++m) { DeltaMorph d; d.name=r.string(); float scale=r.f32(); if (!std::isfinite(scale)) throw std::runtime_error("TRI delta scale is not finite"); d.deltas.resize(size_t(v)*3); for (auto &f:d.deltas) f=float(r.i16())*scale*units::kGamebryoUnitsToMeters; out.delta_morphs.push_back(std::move(d)); }
	if (ms > r.remaining() / 8) throw std::runtime_error("TRI statistical morph count out of bounds");
	out.statistical_morphs.reserve(ms);
	for (uint32_t m=0;m<ms;++m) { StatisticalMorph s; s.name=r.string(); uint32_t n=r.u32(); if (n > v) throw std::runtime_error("TRI statistical morph vertex count out of bounds"); s.vertex_indices.resize(n); for (auto &i:s.vertex_indices) { i=r.u32(); check_index(i,v,"statistical morph"); } out.statistical_morphs.push_back(std::move(s)); }
	if (r.remaining() != 0) throw std::runtime_error("TRI has trailing data");
	return out;
}
}
