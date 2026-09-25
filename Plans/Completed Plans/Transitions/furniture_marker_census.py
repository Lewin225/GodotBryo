"""Which base record types use NIFs containing BSFurnitureMarker blocks.
Run from fresh_nv_copy/Data. Backs R2 in actor_transitions.md."""
import struct, zlib, os
from collections import Counter, defaultdict
# --- meshes BSA: which NIFs contain furniture-marker blocks
def bsa_files(path):
    d = open(path, 'rb').read()
    magic, ver, off, aflags, nfold, nfile, fnl, fil, _ = struct.unpack_from('<4sIIIIIIIH', d, 0)
    compressed_default = bool(aflags & 4); embed = bool(aflags & 0x100)
    folders = [struct.unpack_from('<QII', d, 36 + i*16) for i in range(nfold)]
    p = 36 + nfold*16; recs = []
    for h, cnt, _ in folders:
        ln = d[p]; name = d[p+1:p+ln].rstrip(b'\0').decode('latin1'); p += 1 + ln
        for j in range(cnt):
            fh, sz, fo = struct.unpack_from('<QII', d, p); p += 16; recs.append((name, sz, fo))
    names = d[p:p+fil].split(b'\0')
    for (folder, sz, fo), n in zip(recs, names):
        comp = compressed_default ^ bool(sz & 0x40000000); sz &= 0x3FFFFFFF
        blob = d[fo:fo+sz]
        if embed:
            l = blob[0]; blob = blob[1+l:]
        if comp:
            try: blob = zlib.decompress(blob[4:])
            except zlib.error: blob = zlib.decompressobj(-15).decompress(blob[6:])
        yield (folder + '\\' + n.decode('latin1')).lower(), blob
marker_nifs = {}
for bsa in ['Fallout - Meshes.bsa'] + [f for f in os.listdir('.') if f.endswith('- Main.bsa')]:
    for path, blob in bsa_files(bsa):
        if path.endswith('.nif') and b'BSFurnitureMarker' in blob:
            marker_nifs[path] = True
print("NIFs with BSFurnitureMarker:", len(marker_nifs))
# --- ESM: base records with MODL, grouped by type
data = open('FalloutNV.esm', 'rb').read()
def subs(buf):
    i, ext = 0, None
    while i + 6 <= len(buf):
        t = buf[i:i+4].decode('latin1'); sz = struct.unpack_from('<H', buf, i+4)[0]; i += 6
        if t == 'XXXX': ext = struct.unpack_from('<I', buf, i)[0]; i += sz; continue
        if ext is not None: sz, ext = ext, None
        yield t, buf[i:i+sz]; i += sz
by_type = defaultdict(Counter); examples = defaultdict(list)
def walk(off, end):
    while off < end:
        if data[off:off+4] == b'GRUP':
            gs = struct.unpack_from('<I', data, off+4)[0]; walk(off+24, off+gs); off += gs; continue
        rt = data[off:off+4].decode('latin1'); ds, fl, fid = struct.unpack_from('<III', data, off+4)
        body = data[off+24:off+24+ds]; off += 24+ds
        if rt in ('REFR','ACHR','ACRE','NAVM','LAND','INFO','DIAL','CELL','WRLD','PGRE'): continue
        if fl & 0x40000: body = zlib.decompressobj(-15).decompress(body[6:])
        for t, d in subs(body):
            if t == 'MODL':
                m = d.rstrip(b'\0').decode('latin1').lower()
                m = m if m.startswith('meshes\\') else 'meshes\\' + m
                has = m in marker_nifs
                by_type[rt]['with markers' if has else 'without'] += 1
                if has and rt != 'FURN' and len(examples[rt]) < 4: examples[rt].append((hex(fid), m))
                break
walk(0, len(data))
for rt, c in sorted(by_type.items(), key=lambda kv: -kv[1]['with markers']):
    if c['with markers']: print(f"  {rt}: {c['with markers']} with markers / {sum(c.values())}  {examples[rt]}")
