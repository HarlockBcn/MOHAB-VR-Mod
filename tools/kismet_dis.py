"""Minimal Kismet bytecode disassembler for UE4.25 cooked (unversioned) blueprint exports.

Usage: python kismet_dis.py <asset.uasset> [function-name-substring ...]
"""
import struct, sys, os
from uasset_info import parse


class Dis:
    def __init__(self, uasset):
        self.names, self.imports, self.exports = parse(uasset)
        hdr = open(uasset, 'rb').read()
        uexp = open(uasset[:-7] + '.uexp', 'rb').read()
        self.blob = hdr + uexp  # export serial offsets are relative to start of .uasset

    def oref(self, i):
        if i < 0:
            imp = self.imports[-i - 1]
            outer = imp[2]
            on = ''
            if outer < 0:
                on = self.imports[-outer - 1][3].split('/')[-1] + '.'
            return on + imp[3]
        if i > 0:
            return self.exports[i - 1][3]
        return 'null'

    def fname(self, b, o):
        i, n = struct.unpack_from('<ii', b, o)
        s = self.names[i] if 0 <= i < len(self.names) else f'?{i}'
        return (s + (f'_{n-1}' if n else '')), o + 8

    def find_script_candidates(self, data):
        for tail in (11, 12, 13, 14, 10, 15):
            end = len(data) - tail
            if end <= 8 or data[end - 1] != 0x53:
                continue
            for o in range(8, end):
                ssz = struct.unpack_from('<i', data, o - 4)[0]
                if ssz == end - o and ssz > 0:
                    msz = struct.unpack_from('<i', data, o - 8)[0]
                    if msz > 0:
                        yield o, end

    def try_dis(self, b, so, end):
        o = so
        self.mem = 0
        lines = []
        while o < end:
            m = self.mem
            s, o = self.expr(b, o)
            if s in ('trace', 'instr', 'nop'):
                continue
            lines.append(f'  {m:5x}: {s}')
        if o != end or not lines or lines[-1].strip().split(': ', 1)[1] != 'end_of_script':
            raise ValueError('bad end')
        return lines

    # --- expression reader -------------------------------------------------
    def prop(self, b, o):
        n = struct.unpack_from('<i', b, o)[0]; o += 4
        path = []
        for _ in range(n):
            s, o = self.fname(b, o); path.append(s)
        owner = struct.unpack_from('<i', b, o)[0]; o += 4
        self.mem += 8
        return '.'.join(path) if path else 'nullprop', o

    def obj(self, b, o):
        i = struct.unpack_from('<i', b, o)[0]; self.mem += 8
        return self.oref(i), o + 4

    def name(self, b, o):
        s, o = self.fname(b, o); self.mem += 12
        return s, o

    def u32(self, b, o):
        self.mem += 4; return struct.unpack_from('<I', b, o)[0], o + 4

    def expr(self, b, o):
        start_mem = self.mem
        t = b[o]; o += 1; self.mem += 1
        E = self.expr
        def params(o, endtok=0x16):
            ps = []
            while b[o] != endtok:
                p, o = E(b, o); ps.append(p)
            o += 1; self.mem += 1
            return ps, o
        if t in (0x00, 0x01, 0x02, 0x48, 0x6C):
            p, o = self.prop(b, o); return {0: 'L', 1: 'self.', 2: 'def.', 0x48: 'out ', 0x6C: 'sparse.'}[t] + p, o
        if t == 0x04:
            e, o = E(b, o); return f'return {e}', o
        if t == 0x06:
            v, o = self.u32(b, o); return f'jump {v:#x}', o
        if t == 0x07:
            v, o = self.u32(b, o); e, o = E(b, o); return f'if not ({e}) jump {v:#x}', o
        if t == 0x09:
            o += 3; self.mem += 3; e, o = E(b, o); return f'assert({e})', o
        if t == 0x0B: return 'nop', o
        if t == 0x0F:
            p, o = self.prop(b, o); a, o = E(b, o); v, o = E(b, o); return f'{a} = {v}', o
        if t in (0x12, 0x19, 0x1A):
            c, o = E(b, o); _, o = self.u32(b, o); p, o = self.prop(b, o); e, o = E(b, o)
            return f'{c}->{e}', o
        if t in (0x13, 0x2E, 0x52, 0x54, 0x55):
            c, o = self.obj(b, o); e, o = E(b, o); return f'cast<{c}>({e})', o
        if t in (0x14, 0x43, 0x44, 0x5F, 0x60):
            a, o = E(b, o); v, o = E(b, o); return f'{a} = {v}', o
        if t == 0x15: return 'endparm', o
        if t == 0x17: return 'self', o
        if t == 0x18:
            _, o = self.u32(b, o); e, o = E(b, o); return e, o
        if t in (0x1B, 0x45):
            n, o = self.name(b, o); ps, o = params(o); return f'{n}({", ".join(ps)})', o
        if t in (0x1C, 0x46, 0x63, 0x68):
            f, o = self.obj(b, o); ps, o = params(o); return f'{f}({", ".join(ps)})', o
        if t == 0x1D:
            self.mem += 4; return str(struct.unpack_from('<i', b, o)[0]), o + 4
        if t == 0x1E:
            self.mem += 4; return f'{struct.unpack_from("<f", b, o)[0]:g}', o + 4
        if t == 0x1F:
            e = b.index(b'\0', o); s = b[o:e].decode('latin-1'); self.mem += e - o + 1; return repr(s), e + 1
        if t == 0x34:
            e = o
            while b[e:e + 2] != b'\0\0': e += 2
            s = b[o:e].decode('utf-16le'); self.mem += e - o + 2; return repr(s), e + 2
        if t == 0x20:
            c, o = self.obj(b, o); return f'obj({c})', o
        if t == 0x21:
            n, o = self.name(b, o); return f'name({n})', o
        if t in (0x22, 0x23):
            v = struct.unpack_from('<fff', b, o); self.mem += 12; return f'vec{tuple(round(x, 3) for x in v)}', o + 12
        if t == 0x24:
            self.mem += 1; return f'byte({b[o]})', o + 1
        if t == 0x2C:
            self.mem += 1; return f'{b[o]}', o + 1
        if t == 0x25: return '0', o
        if t == 0x26: return '1', o
        if t == 0x27: return 'true', o
        if t == 0x28: return 'false', o
        if t == 0x29:
            k = b[o]; o += 1; self.mem += 1
            if k == 0: return 'text("")', o
            if k == 1:
                a, o = E(b, o); _, o = E(b, o); _, o = E(b, o); return f'text({a})', o
            if k in (2, 3):
                a, o = E(b, o); return f'text({a})', o
            if k == 4:
                _, o = self.obj(b, o); a, o = E(b, o); c, o = E(b, o); return f'strtable({a},{c})', o
        if t == 0x2A: return 'None', o
        if t == 0x2D: return 'NoInterface', o
        if t == 0x2B:
            self.mem += 40; return 'transform(...)', o + 40
        if t == 0x2F:
            s, o = self.obj(b, o); _, o = self.u32(b, o); ps, o = params(o, 0x30); return f'{s}{{{", ".join(ps)}}}', o
        if t == 0x31:
            a, o = E(b, o); ps, o = params(o, 0x32); return f'{a} = [{", ".join(ps)}]', o
        if t == 0x33:
            p, o = self.prop(b, o); return f'prop({p})', o
        if t in (0x35, 0x36):
            self.mem += 8; return str(struct.unpack_from('<q', b, o)[0]), o + 8
        if t == 0x38:
            k = b[o]; o += 1; self.mem += 1; e, o = E(b, o); return f'pcast{k}({e})', o
        if t in (0x39, 0x3B):
            a, o = E(b, o); _, o = self.u32(b, o); ps, o = params(o, t + 1); return f'{a} = {{{", ".join(ps)}}}', o
        if t == 0x3D:
            _, o = self.prop(b, o); _, o = self.u32(b, o); ps, o = params(o, 0x3E); return f'set{{{", ".join(ps)}}}', o
        if t == 0x3F:
            _, o = self.prop(b, o); _, o = self.prop(b, o); _, o = self.u32(b, o); ps, o = params(o, 0x40); return f'map{{{", ".join(ps)}}}', o
        if t == 0x42:
            p, o = self.prop(b, o); e, o = E(b, o); return f'{e}.{p}', o
        if t == 0x4B:
            n, o = self.name(b, o); return f'delegate({n})', o
        if t == 0x4C:
            v, o = self.u32(b, o); return f'push_flow {v:#x}', o
        if t == 0x4D: return 'pop_flow', o
        if t == 0x4E:
            e, o = E(b, o); return f'computed_jump {e}', o
        if t == 0x4F:
            e, o = E(b, o); return f'pop_flow_if_not({e})', o
        if t == 0x50: return 'breakpoint', o
        if t == 0x51:
            e, o = E(b, o); return f'iface({e})', o
        if t == 0x53: return 'end_of_script', o
        if t in (0x5A, 0x5E): return 'trace', o
        if t == 0x5B:
            v, o = self.u32(b, o); return f'skipoff({v:#x})', o
        if t in (0x5C, 0x62):
            a, o = E(b, o); v, o = E(b, o); return f'{a} {"+=" if t == 0x5C else "-="} {v}', o
        if t == 0x5D:
            a, o = E(b, o); return f'{a}.clear()', o
        if t == 0x61:
            n, o = self.name(b, o); a, o = E(b, o); c, o = E(b, o); return f'{a} = bind({c}, {n})', o
        if t == 0x64:
            p, o = self.prop(b, o); v, o = E(b, o); return f'persistent.{p} = {v}', o
        if t == 0x65:
            _, o = self.prop(b, o); _, o = self.u32(b, o); ps, o = params(o, 0x66); return f'[{", ".join(ps)}]', o
        if t == 0x67:
            e, o = E(b, o); return f'soft({e})', o
        if t == 0x69:
            n = struct.unpack_from('<H', b, o)[0]; o += 2; self.mem += 2
            _, o = self.u32(b, o); idx, o = E(b, o)
            cases = []
            for _ in range(n):
                cv, o = E(b, o); _, o = self.u32(b, o); r, o = E(b, o); cases.append(f'{cv}:{r}')
            d, o = E(b, o)
            return f'switch({idx}){{{", ".join(cases)}, default:{d}}}', o
        if t == 0x6A:
            k = b[o]; o += 1; self.mem += 1
            if k == 4:
                n, o = self.name(b, o)
            return 'instr', o
        if t == 0x6B:
            a, o = E(b, o); i, o = E(b, o); return f'{a}[{i}]', o
        if t == 0x6D:
            e, o = E(b, o); return f'fieldpath({e})', o
        raise ValueError(f'unknown token {t:#x} at {o-1}')

    def disassemble(self, export_idx):
        ci, si, oi, name, size, off = self.exports[export_idx]
        data = self.blob[off:off + size]
        err = None
        for so, end in self.find_script_candidates(data):
            try:
                return self.try_dis(data[:end], so, end)
            except Exception as ex:
                err = ex
        return [f'  <no script decoded: {err}>']


if __name__ == '__main__':
    d = Dis(sys.argv[1])
    flt = sys.argv[2:]
    for k, (ci, si, oi, name, size, off) in enumerate(d.exports):
        if d.oref(ci).endswith('Function') and (not flt or any(f.lower() in name.lower() for f in flt)):
            print(f'=== {name}')
            print('\n'.join(d.disassemble(k)))
