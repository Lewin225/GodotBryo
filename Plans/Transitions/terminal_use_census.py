"""Evidence for NPC terminal use: PACK targets, script Activate on terminal refs,
terminal idles, and FURN/IDLM placed at terminals. Run from fresh_nv_copy/Data."""
import struct, zlib, re, math
from collections import Counter, defaultdict
data = open('FalloutNV.esm', 'rb').read()
def subs(buf):
    i, ext = 0, None
    while i + 6 <= len(buf):
        t = buf[i:i+4].decode('latin1'); sz = struct.unpack_from('<H', buf, i+4)[0]; i += 6
        if t == 'XXXX': ext = struct.unpack_from('<I', buf, i)[0]; i += sz; continue
        if ext is not None: sz, ext = ext, None
        yield t, buf[i:i+sz]; i += sz
rtype = {}; recs = {}; refs = {}
def walk(off, end, stack):
    while off < end:
        if data[off:off+4] == b'GRUP':
            gs, lab, gt = struct.unpack_from('<IIi', data, off+4); walk(off+24, off+gs, stack+[(gt, lab)]); off += gs; continue
        rt = data[off:off+4].decode('latin1'); ds, fl, fid = struct.unpack_from('<III', data, off+4)
        body = data[off+24:off+24+ds]; off += 24+ds
        rtype[fid] = rt
        if rt in ('PACK', 'SCPT', 'IDLE', 'TERM', 'FURN', 'IDLM', 'REFR', 'ACHR', 'INFO', 'QUST'):
            if fl & 0x40000: body = zlib.decompressobj(-15).decompress(body[6:])
            s = list(subs(body))
            if rt in ('REFR', 'ACHR'):
                d = dict(s)
                if 'NAME' in d and 'DATA' in d:
                    cell = next((l for g, l in reversed(stack) if g in (8, 9, 10)), 0)
                    refs[fid] = (struct.unpack_from('<I', d['NAME'])[0], struct.unpack_from('<3f', d['DATA']), cell,
                                 d.get('EDID', b'').rstrip(b'\0').decode('latin1'))
            else:
                recs[fid] = (rt, s)
walk(0, len(data), [])
g = lambda s, k: next((d for t, d in s if t == k), None)
gall = lambda s, k: [d for t, d in s if t == k]
edid = lambda s: (g(s, 'EDID') or b'').rstrip(b'\0').decode('latin1')
term_bases = {f for f, (rt, _) in recs.items() if rt == 'TERM'}
term_refs = {f for f, r in refs.items() if r[0] in term_bases}
print(f"TERM bases {len(term_bases)}, placed TERM refs {len(term_refs)}")

# 1. PACK targets
PTYPES = ['Find','Follow','Escort','Eat','Sleep','Wander','Travel','Accompany','UseItemAt','Ambush','FleeNotCombat','?11','Sandbox','Patrol','Guard','Dialogue','UseWeapon']
pk_types = Counter(); pk_term = []
for f, (rt, s) in recs.items():
    if rt != 'PACK': continue
    pk = g(s, 'PKDT'); ptype = pk[4] if pk and len(pk) > 4 else -1
    pk_types[PTYPES[ptype] if 0 <= ptype < len(PTYPES) else ptype] += 1
    for key in ('PTDT', 'PTD2'):
        for t in gall(s, key):
            if len(t) >= 8:
                ttype, tid = struct.unpack_from('<iI', t)
                if ttype in (0, 1) and (tid in term_refs or tid in term_bases):
                    pk_term.append((hex(f), edid(s), PTYPES[ptype] if 0 <= ptype < len(PTYPES) else ptype, key, 'ref' if ttype == 0 else 'base'))
    # location targets too
    for t in gall(s, 'PLDT') + gall(s, 'PLD2'):
        if len(t) >= 8:
            ltype, lid = struct.unpack_from('<iI', t)
            if lid in term_refs: pk_term.append((hex(f), edid(s), 'location', 'PLDT', 'ref'))
print("\n1. PACK types:", dict(pk_types))
print("   packages targeting a TERM ref/base:", len(pk_term), pk_term[:10])

# 2. Script Activate on terminal refs
term_edids = {refs[f][3].lower(): f for f in term_refs if refs[f][3]}
hits = []
for f, (rt, s) in recs.items():
    for sc in gall(s, 'SCTX'):
        txt = sc.decode('latin1')
        for m in re.finditer(r'(?im)^[^;\n]*?\b(\w+)\s*\.\s*activate\b([^\n;]*)', txt):
            if m.group(1).lower() in term_edids:
                hits.append((rt, hex(f), m.group(0).strip()[:90]))
print("\n2. script lines '<TerminalREF>.Activate ...':", len(hits))
for h in hits[:12]: print("  ", h)

# 3. IDLE anims mentioning terminal/computer/type
idl = []
for f, (rt, s) in recs.items():
    if rt != 'IDLE': continue
    txt = (edid(s) + ' ' + (g(s, 'MODL') or b'').decode('latin1')).lower()
    if re.search(r'terminal|computer|typing|keyboard|console', txt): idl.append((hex(f), edid(s), (g(s, 'MODL') or b'').rstrip(b'\0').decode('latin1')))
print("\n3. IDLE records mentioning terminal/computer/typing/keyboard:", len(idl))
for i in idl[:12]: print("  ", i)
idlm_edids = [(hex(f), edid(s)) for f, (rt, s) in recs.items() if rt == 'IDLM' and re.search(r'terminal|computer|typing|keyboard', edid(s), re.I)]
furn_edids = [(hex(f), edid(s)) for f, (rt, s) in recs.items() if rt == 'FURN' and re.search(r'terminal|computer|typing|keyboard', edid(s), re.I)]
print("   IDLM bases named terminal/computer/typing:", len(idlm_edids), idlm_edids[:10])
print("   FURN bases named terminal/computer/typing:", len(furn_edids), furn_edids[:10])

# 4. What sits within 150 raw units of each placed terminal (same cell)
by_cell = defaultdict(list)
for f, r in refs.items(): by_cell[r[2]].append(f)
near = Counter(); near_any = Counter()
for t in term_refs:
    _, tp, cell, _ = refs[t]; kinds = set()
    for o in by_cell[cell]:
        if o == t: continue
        bt = rtype.get(refs[o][0], '?')
        if bt in ('IDLM', 'FURN') and math.dist(tp, refs[o][1]) < 150: kinds.add(bt)
    near_any['IDLM' in kinds and 'FURN' in kinds and 'both' or next(iter(kinds), 'neither')] += 1
print("\n4. placed terminals with an IDLM/FURN within 150 units:", dict(near_any))
