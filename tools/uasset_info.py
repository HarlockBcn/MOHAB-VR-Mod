"""Dump name map, imports and exports of a UE4.25 cooked .uasset."""
import struct, sys
from pak_list import rd_fstring

def parse(path):
    b = open(path, 'rb').read()
    o = 0
    tag, legacy = struct.unpack_from('<Ii', b, o); o += 8
    if legacy != -4: o += 4
    ue4, lic = struct.unpack_from('<ii', b, o); o += 8
    ncv = struct.unpack_from('<i', b, o)[0]; o += 4 + ncv * 20
    total = struct.unpack_from('<i', b, o)[0]; o += 4
    folder, o = rd_fstring(b, o)
    pflags, ncount, noff = struct.unpack_from('<Iii', b, o); o += 12
    if not (pflags & 0x80000000):
        _, o = rd_fstring(b, o)
    o += 8  # gatherable
    ecount, eoff, icount, ioff = struct.unpack_from('<iiii', b, o)
    names = []
    p = noff
    for _ in range(ncount):
        s, p = rd_fstring(b, p); p += 4; names.append(s)
    def fn(p):
        i, n = struct.unpack_from('<ii', b, p)
        return names[i] + (f'_{n-1}' if n else '')
    imports = []
    p = ioff
    for _ in range(icount):
        imports.append((fn(p), fn(p + 8), struct.unpack_from('<i', b, p + 16)[0], fn(p + 20))); p += 28
    exports = []
    p = eoff
    for _ in range(ecount):
        ci, si, ti, oi = struct.unpack_from('<iiii', b, p)
        name = fn(p + 16)
        size, off = struct.unpack_from('<qq', b, p + 28)
        exports.append((ci, si, oi, name, size, off)); p += 104
    return names, imports, exports

def ref(imports, exports, i):
    if i < 0: return 'I:' + imports[-i - 1][3]
    if i > 0: return 'E:' + exports[i - 1][3]
    return '-'

if __name__ == '__main__':
    names, imports, exports = parse(sys.argv[1])
    what = sys.argv[2] if len(sys.argv) > 2 else 'all'
    if what in ('all', 'names'):
        print('== NAMES'); print('\n'.join(names))
    if what in ('all', 'imports'):
        print('== IMPORTS')
        for k, (cp, cn, oi, on) in enumerate(imports): print(-k - 1, cn, on, 'outer=', ref(imports, exports, oi))
    if what in ('all', 'exports'):
        print('== EXPORTS')
        for k, (ci, si, oi, name, size, off) in enumerate(exports):
            print(k + 1, ref(imports, exports, ci), name, 'super=', ref(imports, exports, si), 'outer=', ref(imports, exports, oi), size)
