"""Keep legacy oracles; independently model PG060 DAZ/pre-round FTZ.

PG060 UNDERFLOW: a number denormalized before rounding is set to zero.
In particular, min_normal * (1 - 2**-24) must not round up to min_normal.
https://docs.amd.com/api/khub/documents/4O72wuOIKLc8gzcZogZgeg/content
"""
from pathlib import Path
import numpy as np

ROOT=Path(__file__).resolve().parent/"data"


def daz(bits):
    bits=np.uint32(bits)
    if bits&0x7f800000==0:bits&=np.uint32(0x80000000)
    return bits.view(np.float32)


def main():
    changed={}
    with np.errstate(all="ignore"):
        for name,operation in [("add",lambda a,b:a+b),("multiply",lambda a,b:a*b)]:
            lines=[];differences=0
            for line in (ROOT/f"{name}.mem").read_text().splitlines():
                if not line.strip():continue
                raw=int(line,16);a=(raw>>64)&0xffffffff;b=(raw>>32)&0xffffffff
                # A binary64 product represents two binary32 significands
                # exactly; it also preserves the small cancellation boundary.
                exact=operation(np.float64(daz(a)),np.float64(daz(b)))
                result=np.float32(exact).view(np.uint32)
                if 0<abs(exact)<np.float64(np.finfo(np.float32).tiny):
                    result&=np.uint32(0x80000000)
                if result&0x7f800000==0:result&=np.uint32(0x80000000)
                if result&0x7f800000==0x7f800000 and result&0x7fffff:result=np.uint32(0x7fc00000)
                differences+=int(result!=raw&0xffffffff)
                lines.append(f"{a:08x}{b:08x}{int(result):08x}\n")
            (ROOT/f"{name}_native.mem").write_text("".join(lines),encoding="ascii")
            changed[name]=differences
    print("NATIVE_FP_ORACLES_READY",changed,"legacy_vectors_preserved=1")


if __name__=="__main__":main()
