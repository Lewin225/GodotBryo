#!/usr/bin/env python3
"""Exhaustive XTEL census over one TES4-family ESM (FNV).

Usage: python3 xtel_census.py fresh_nv_copy/Data/FalloutNV.esm
Backs the numbers in actor_transitions.md. Pure Python, no native build.
Raw inflate is deliberate: one FalloutNV.esm record fails the zlib checksum."""
import struct, sys, zlib, math
from collections import Counter

path = sys.argv[1]
data = open(path, 'rb').read()

refs = {}      # formid -> dict(type, base, pos, rot, cell, world, xtel, size)
cells = {}     # formid -> dict(world, interior, grid, persistent_bucket)
bases = {}     # formid -> record type

def subrecords(buf):
    i, ext = 0, None
    while i + 6 <= len(buf):
        t = buf[i:i+4].decode('latin1'); sz = struct.unpack_from('<H', buf, i+4)[0]; i += 6
        if t == 'XXXX':
            ext = struct.unpack_from('<I', buf, i)[0]; i += sz; continue
        if ext is not None:
            sz, ext = ext, None
        yield t, buf[i:i+sz]; i += sz

def walk(off, end, stack):
    while off < end:
        t = data[off:off+4]
        if t == b'GRUP':
            gsize, label, gtype = struct.unpack_from('<IIi', data, off+4)
            walk(off+24, off+gsize, stack + [(gtype, label)])
            off += gsize; continue
        rtype = t.decode('latin1')
        dsize, flags, fid = struct.unpack_from('<III', data, off+4)
        body = data[off+24:off+24+dsize]
        off += 24 + dsize
        if flags & 0x00040000:
            body = zlib.decompressobj(-15).decompress(body[6:])
        world = next((l for g, l in reversed(stack) if g == 1), 0)
        if rtype == 'CELL':
            c = {'world': world, 'interior': False, 'grid': None,
                 'persistent_bucket': bool(stack) and stack[-1][0] == 1}
            for st, sd in subrecords(body):
                if st == 'DATA' and len(sd) >= 1: c['interior'] = bool(sd[0] & 1)
                elif st == 'XCLC' and len(sd) >= 8: c['grid'] = struct.unpack_from('<ii', sd)
            cells[fid] = c
        elif rtype in ('REFR', 'ACHR', 'ACRE'):
            cell = next((l for g, l in reversed(stack) if g in (8, 9, 10)), 0)
            r = {'type': rtype, 'cell': cell, 'world': world, 'xtel': None, 'xtel_size': 0,
                 'pos': None, 'base': 0}
            for st, sd in subrecords(body):
                if st == 'NAME': r['base'] = struct.unpack_from('<I', sd)[0]
                elif st == 'DATA' and len(sd) >= 24: r['pos'] = struct.unpack_from('<3f', sd); r['rot'] = struct.unpack_from('<3f', sd, 12)
                elif st == 'XTEL':
                    r['xtel_size'] = len(sd)
                    dest = struct.unpack_from('<I', sd)[0]
                    pos = struct.unpack_from('<3f', sd, 4); rot = struct.unpack_from('<3f', sd, 16)
                    fl = struct.unpack_from('<I', sd, 28)[0] if len(sd) >= 32 else None
                    r['xtel'] = (dest, pos, rot, fl)
            refs[fid] = r
        else:
            bases[fid] = rtype

walk(0, len(data), [])

x = {f: r for f, r in refs.items() if r['xtel']}
print(f"{path}: {len(refs)} placed refs, {len(x)} with XTEL")
print("XTEL sizes:", Counter(r['xtel_size'] for r in x.values()))
print("holder base types:", Counter(bases.get(r['base'], '?') for r in x.values()))
print("flags values:", Counter(r['xtel'][3] for r in x.values()))

dest_missing = dest_nonref = 0; dest_types = Counter(); dest_has_xtel = recip = 0
dist = []; persistent_dest = 0; dest_ext = 0; same_space = 0
nonrecip = []
for f, r in x.items():
    d, pos, rot, fl = r['xtel']
    if d not in refs:
        dest_missing += 1; continue
    dr = refs[d]
    dest_types[bases.get(dr['base'], '?')] += 1
    if dr['xtel']:
        dest_has_xtel += 1
        if dr['xtel'][0] == f: recip += 1
        else: nonrecip.append((f, d, dr['xtel'][0]))
    if dr['pos']:
        dist.append(math.dist(pos, dr['pos']))
    c = cells.get(dr['cell'], {})
    if not c.get('interior', False) and dr['world']:
        dest_ext += 1
        if c.get('persistent_bucket'): persistent_dest += 1
    src_space = r['world'] or r['cell']; dst_space = dr['world'] or dr['cell']
    if src_space == dst_space: same_space += 1

print(f"dest REFR not in this file: {dest_missing}")
print("dest base types:", dest_types)
print(f"dest has its own XTEL: {dest_has_xtel}, of which points straight back: {recip}")
print(f"non-reciprocal examples: {[(hex(a), hex(b), hex(c)) for a, b, c in nonrecip[:8]]}")
dist.sort()
if dist:
    q = lambda p: dist[min(len(dist)-1, int(p*len(dist)))]
    print(f"landing->dest door distance (raw units): min {dist[0]:.1f} p10 {q(.1):.1f} p50 {q(.5):.1f} p90 {q(.9):.1f} p99 {q(.99):.1f} max {dist[-1]:.1f}")
    print(f"  exactly 0: {sum(1 for v in dist if v < 0.01)}")
print(f"exterior destinations: {dest_ext}, dest door filed in worldspace persistent cell: {persistent_dest}")
print(f"source and destination in the same space: {same_space}")

from collections import defaultdict
incoming = defaultdict(list)
for f, r in x.items():
    incoming[r['xtel'][0]].append(f)
multi = {d: s for d, s in incoming.items() if len(s) > 1}
print(f"destinations: {len(incoming)}, with >1 incoming link: {len(multi)}")
for d, srcs in multi.items():
    for s in srcs:
        _, p, rot, _ = refs[s]['xtel']
        print(f"  dest {d:#x} from {s:#x} landing ({p[0]:.1f},{p[1]:.1f},{p[2]:.1f}) rotz {rot[2]:.3f}")

grid_cells = {(c['world'], tuple(c['grid'])) for c in cells.values() if c['grid'] is not None and not c['interior'] and not c['persistent_bucket']}
no_cell = []
for f, r in x.items():
    d, pos, rot, fl = r['xtel']
    dr = refs.get(d)
    if dr is None or not dr['world'] or cells.get(dr['cell'], {}).get('interior', False):
        continue
    g = (math.floor(pos[0] / 4096), math.floor(pos[1] / 4096))
    if (dr['world'], g) not in grid_cells:
        no_cell.append((f, dr['world'], g))
print(f"exterior landings on a grid coordinate with no CELL: {len(no_cell)} {[(hex(a), hex(w), g) for a, w, g in no_cell[:8]]}")
