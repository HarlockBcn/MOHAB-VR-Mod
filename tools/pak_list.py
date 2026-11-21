"""List files inside UE4 v9 (4.25) .pak files (unencrypted index)."""
import struct, sys, os, glob

def rd_fstring(b, o):
    n = struct.unpack_from('<i', b, o)[0]; o += 4
    if n == 0: return '', o
    if n < 0:
        n = -n; s = b[o:o+2*n].decode('utf-16le').rstrip('\0'); return s, o + 2*n
    s = b[o:o+n].decode('latin-1').rstrip('\0'); return s, o + n

def list_pak(path):
    sz = os.path.getsize(path)
    with open(path, 'rb') as f:
        f.seek(sz - 221); ft = f.read(221)
        i = ft.find(b'\xe1\x12\x6f\x5a')
        ver, ioff, isz = struct.unpack_from('<IQQ', ft, i + 4)
        f.seek(ioff); b = f.read(isz)
    mount, o = rd_fstring(b, 0)
    n = struct.unpack_from('<i', b, o)[0]; o += 4
    out = []
    for _ in range(n):
        name, o = rd_fstring(b, o)
        off, size, usize, cm = struct.unpack_from('<QQQI', b, o); o += 28
        o += 20
        if cm:
            nb = struct.unpack_from('<i', b, o)[0]; o += 4 + nb * 16
        o += 1 + 4
        out.append((mount + name, usize))
    return out

if __name__ == '__main__':
    d = sys.argv[1]
    for p in sorted(glob.glob(os.path.join(d, '*.pak'))):
        for name, usize in list_pak(p):
            print(f'{os.path.basename(p)}\t{usize}\t{name}')
