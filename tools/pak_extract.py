"""Extract specific files from UE4 v9 paks (unencrypted, zlib)."""
import struct, sys, os, glob, zlib
from pak_list import rd_fstring

def index(path):
    sz = os.path.getsize(path)
    with open(path, 'rb') as f:
        f.seek(sz - 221); ft = f.read(221)
        i = ft.find(b'\xe1\x12\x6f\x5a')
        ver, ioff, isz = struct.unpack_from('<IQQ', ft, i + 4)
        f.seek(ioff); b = f.read(isz)
    mount, o = rd_fstring(b, 0)
    n = struct.unpack_from('<i', b, o)[0]; o += 4
    ents = {}
    for _ in range(n):
        name, o = rd_fstring(b, o)
        off, size, usize, cm = struct.unpack_from('<QQQI', b, o); o += 28 + 20
        blocks = []
        if cm:
            nb = struct.unpack_from('<i', b, o)[0]; o += 4
            for k in range(nb):
                blocks.append(struct.unpack_from('<QQ', b, o)); o += 16
        flags = b[o]; o += 1
        bs = struct.unpack_from('<I', b, o)[0]; o += 4
        ents[mount + name] = (off, size, usize, cm, blocks, flags)
    return ents

def extract(path, e):
    off, size, usize, cm, blocks, flags = e
    assert not (flags & 1), 'encrypted'
    with open(path, 'rb') as f:
        if not cm:
            # entry header precedes data: 8+8+8+4+20+1+4 = 53 bytes
            f.seek(off + 53); return f.read(usize)
        out = b''
        for s, en in blocks:
            f.seek(off + s); out += zlib.decompress(f.read(en - s))
        return out

if __name__ == '__main__':
    pakdir, outdir, pats = sys.argv[1], sys.argv[2], sys.argv[3:]
    for p in sorted(glob.glob(os.path.join(pakdir, '*.pak'))):
        ents = index(p)
        for name, e in ents.items():
            if any(pt in name for pt in pats):
                rel = name.replace('../../../', '')
                dst = os.path.join(outdir, rel); os.makedirs(os.path.dirname(dst), exist_ok=True)
                open(dst, 'wb').write(extract(p, e)); print('extracted', rel, e[2])
