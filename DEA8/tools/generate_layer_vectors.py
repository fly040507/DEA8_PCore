"""Independent full-layer fixtures for the real eight-core/GCore server test.

No checkpoint intermediate is injected: only RESID and prefix KV are initial
objects. All other files are passive scoreboards or external HBM parameters.
"""
from pathlib import Path
import json
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tb/data/layer_native"
F = np.float32


def words(x):
    return np.asarray(x, dtype=np.float32).view(np.uint32)


def ftz(x):
    x = np.asarray(x, dtype=np.float32)
    bits = words(x)
    return np.where((bits & 0x7f800000) == 0, (bits & 0x80000000).view(np.float32), x).astype(np.float32)


def add(a, b):
    return native_binary(a,b,False)


def mul(a, b):
    return native_binary(a,b,True)


def native_binary(a,b,multiply):
    # PG060 also flushes a pre-round denormal that would round to min_normal.
    left,right=ftz(a).astype(np.float64),ftz(b).astype(np.float64)
    exact=left*right if multiply else left+right
    rounded=ftz(exact)
    small=(np.abs(exact)>0)&(np.abs(exact)<np.finfo(np.float32).tiny)
    return np.where(small,np.copysign(np.float32(0),rounded),rounded).astype(np.float32)


def bf16(x):
    bits = words(x).astype(np.uint64)
    return ((bits + 0x7fff + ((bits >> 16) & 1)) >> 16).astype(np.uint16)


def expand(b):
    return (np.asarray(b, dtype=np.uint32) << 16).view(np.float32)


def quant(x, cover=False):
    x = np.asarray(x, dtype=np.float32)
    maximum = np.max(np.abs(x), axis=-1)
    raw = words(maximum)
    e = (raw >> 23).astype(np.int32)
    if cover:
        e += ((raw & 0x7fffff) > 0x7e0000) & (e < 254)
    step = np.exp2(e.astype(np.float64)-133)
    q = np.clip(np.rint(x.astype(np.float64)/step[..., None]), -128 if cover else -127, 127).astype(np.int16)
    return q, e


def tree(x):
    x = np.asarray(x, dtype=np.float32)
    while x.shape[-1] > 1:
        x = add(x[..., ::2], x[..., 1::2])
    return x[..., 0]


def weight(core, op, nt, kt, col, up=False):
    # Match tb_dea8_layers_native: distinct signed, feature/core/K-dependent data.
    value = 1 + (core*5 + nt*16 + col + kt%3) % 7
    if op == 5 and not up and ((nt*16+col+core) % 4 == 0):
        value = -value
    if op == 5 and up:
        value = 1 + value % 3
    return value


def project(a, core, op, ntiles, up=False):
    aq, ae = a
    result = np.zeros((51, ntiles, 16), np.float32)
    for nt in range(ntiles):
        for kt in range(aq.shape[1]):
            w = np.array([weight(core,op,nt,kt,j,up) for j in range(16)], np.int64)
            dot = np.sum(aq[:,kt,:].astype(np.int64), axis=-1)[:,None]*w[None,:]
            partial = np.ldexp(dot.astype(np.float32), ae[:,kt,None] + 128 - 266)
            result[:,nt,:] = add(result[:,nt,:], partial)
    return result


def normalize(residual, gamma):
    x = expand(residual).reshape(51,64,16)
    sums8 = tree(mul(x,x).reshape(51,64,2,8))
    sq = np.zeros(51,np.float32)
    for group in range(16):
        sq = add(sq, tree(sums8[:,4*group:4*group+4,:].reshape(51,8)))
    u = add(np.ldexp(sq,-10),F(1e-6))
    inverse = F(1)/np.sqrt(u)
    y = mul(mul(x,inverse[:,None,None]),gamma.reshape(1,64,16))
    return quant(y,cover=True), y, u, inverse


def packed_q(q, e, ram_order=False):
    data = sum((int(v)&255) << (8*j) for j,v in enumerate(q))
    return f"{int(e):02x}{data:032x}" if ram_order else f"{data:032x}{int(e):02x}"


def write_vectors(path, array, width=32):
    arr = np.asarray(array)
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text("".join("".join(f"{int(v):0{width//4}x}" for v in row[::-1])+"\n"
        for row in arr.reshape(-1,arr.shape[-1])),encoding="ascii")


def write_q(path, a, ram_order=False):
    q,e=a
    # Coordinates in files are N-tile major, then row, like physical RAMs.
    path.write_text("".join(packed_q(q[r,t],e[r,t],ram_order)+"\n"
        for t in range(q.shape[1]) for r in range(q.shape[0])),encoding="ascii")


def rope(x, frequencies):
    angle = np.arange(816,867,dtype=np.float32)[:,None]/np.power(F(10000),np.asarray(frequencies,np.float32)[None,:]/F(128),dtype=np.float32)
    c,s=np.cos(angle),np.sin(angle)
    return add(mul(x[:,0],c),-mul(x[:,1],s)),add(mul(x[:,1],c),mul(x[:,0],s))


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    initial = bf16(F(.25)+np.arange(51,dtype=np.float32)[:,None]%3/F(8)+
        (np.arange(1024,dtype=np.float32)[None,:]%7)/F(16))
    gamma0=np.array([1+(j%5)/64 for j in range(1024)],np.float32)
    gamma1=np.array([1+(j%3)/32 for j in range(1024)],np.float32)
    write_vectors(OUT/"initial.mem",initial.reshape(51,64,16).transpose(1,0,2),16)
    write_vectors(OUT/"gamma0.mem",words(gamma0).reshape(-1,1))
    write_vectors(OUT/"gamma1.mem",words(gamma1).reshape(-1,1))
    x0,_,u0,inv0=normalize(initial,gamma0)
    write_q(OUT/"xhat0.mem",x0,True)
    write_vectors(OUT/"u0.mem",words(u0).reshape(-1,1))
    prefix_kq=np.empty((816,16,16),np.int16)
    prefix_ke=np.full((816,16),124,np.int32)
    prefix_vq=np.empty((51,256,16),np.int16)
    prefix_ve=np.full((51,256),126,np.int32)
    for token in range(816):
        for t in range(16):prefix_kq[token,t,:]=1+(token//16+t+np.arange(16))%5
    for block in range(51):
        for col in range(256):prefix_vq[block,col,:]=1+(block+col+np.arange(16))%7
    # Physical prefix bank image: K row parity, V feature parity.
    for kind in range(2):
        for feature in range(16):
            for parity in range(2):
                lines=[]
                for address in range(408):
                    if kind==0:
                        token=2*address+parity;q=prefix_kq[token,feature];e=prefix_ke[token,feature]
                    else:
                        block=address//8;col=16*feature+2*(address%8)+parity
                        q=prefix_vq[block,col];e=prefix_ve[block,col]
                    lines.append(packed_q(q,e,True)+"\n")
                (OUT/f"prefix_{kind}_{feature}_{parity}.mem").write_text("".join(lines),encoding="ascii")
    kq=np.zeros((880,16,16),np.int16);ke=np.zeros((880,16),np.int32)
    kq[:816]=prefix_kq;ke[:816]=prefix_ke
    vq=np.zeros((55,256,16),np.int16);ve=np.zeros((55,256),np.int32)
    vq[:51]=prefix_vq;ve[:51]=prefix_ve
    qheads=[]
    for core in range(8):
        d=OUT/f"core{core}";d.mkdir(exist_ok=True)
        raw_k=project(x0,core,1,2)
        a,b=rope(raw_k,np.arange(core*16,core*16+16))
        local_k=quant(np.stack([a,b],axis=1))
        write_q(d/"k.mem",local_k)
        for half in range(2):kq[816:867,core+8*half]=local_k[0][:,half];ke[816:867,core+8*half]=local_k[1][:,half]
        raw_v=project(x0,core,2,2).reshape(51,32)
        padded=np.zeros((64,32),np.float32);padded[:51]=raw_v
        vdata,ves=quant(padded.reshape(4,16,32).transpose(0,2,1))
        lines=[]
        for nt in range(2):
            for group in range(4):
                for col in range(16):lines.append(packed_q(vdata[group,nt*16+col],ves[group,nt*16+col])+"\n")
        (d/"v.mem").write_text("".join(lines),encoding="ascii")
        vq[51:,32*core:32*core+32]=vdata;ve[51:,32*core:32*core+32]=ves
        raw_q=project(x0,core,0,16)
        canonical=np.zeros_like(raw_q)
        for group in range(8):
            a,b=rope(raw_q[:,2*group:2*group+2],np.arange(16*group,16*group+16))
            canonical[:,group]=a;canonical[:,group+8]=b
        qhead=quant(canonical);qheads.append(qhead);write_q(d/"q.mem",qhead)
    oheads=[];all_p=[]
    for core in range(8):
        d=OUT/f"core{core}"
        q,qe=qheads[core]
        m=np.full(51,-np.inf,np.float32);l=np.zeros(51,np.float32);o=np.zeros((51,16,16),np.float32)
        plist=[];scores=[];stats=[]
        for block in range(55):
            score=np.zeros((51,16),np.float32)
            for kt in range(16):
                dots=q[:,kt,:].astype(np.int64)@kq[16*block:16*block+16,kt,:].astype(np.int64).T
                part=np.ldexp(dots.astype(np.float32),qe[:,kt,None]+ke[None,16*block:16*block+16,kt]-270)
                score=add(score,part)
            valid=np.ones((51,16),bool)
            if block>=51:
                keys=16*block+np.arange(16)
                valid=keys[None,:]<=np.where(np.arange(51)==0,816,866)[:,None]
            score=np.where(valid,score,F(-np.inf))
            new=np.maximum(m,np.max(score,axis=1));aa=F(m-new);alpha=np.exp(aa)
            p=np.where(valid,np.exp(F(score-new[:,None])),F(0))
            pq,pe=quant(p)
            l=add(mul(alpha,l),tree(p))
            for nt in range(16):
                dots=pq.astype(np.int64)@vq[block,16*nt:16*nt+16,:].astype(np.int64).T
                part=np.ldexp(dots.astype(np.float32),pe[:,None]+ve[block,None,16*nt:16*nt+16]-266)
                o[:,nt]=add(mul(alpha[:,None],o[:,nt]),part)
            m=new
            plist.extend((pq[r],pe[r]) for r in range(51))
            scores.append(score.copy());stats.append(np.stack([m,aa,alpha,l],axis=-1))
        afinal=mul(o,(F(1)/l)[:,None,None]);oa=quant(afinal);oheads.append(oa)
        write_q(d/"o.mem",oa)
        (d/"p.mem").write_text("".join(packed_q(q,e)+"\n" for q,e in plist),encoding="ascii")
        write_vectors(d/"score.mem",words(np.asarray(scores)).reshape(-1,1))
        write_vectors(d/"stats.mem",words(np.asarray(stats)).reshape(-1,4)[:,::-1])
    opartials=[project(oheads[c],c,4,64) for c in range(8)]
    reduced_o=tree(np.stack(opartials,axis=-1))
    mid=bf16(add(expand(initial).reshape(51,64,16),reduced_o)).reshape(51,1024)
    write_vectors(OUT/"mid.mem",mid.reshape(51,64,16).transpose(1,0,2),16)
    x1,_,u1,inv1=normalize(mid,gamma1);write_q(OUT/"xhat1.mem",x1,True)
    write_vectors(OUT/"u1.mem",words(u1).reshape(-1,1))
    zheads=[]
    with np.errstate(over="ignore",invalid="raise"):
        for c in range(8):
            gate=project(x1,c,5,32);up=project(x1,c,5,32,True)
            u=mul(mul(mul(F(.044715),gate),gate),gate)
            z=mul(add(gate,u),F(-2*np.sqrt(2/np.pi)))
            gelu=mul(gate,F(1)/add(F(1),np.exp(z)))
            zhead=quant(mul(gelu,up));zheads.append(zhead);write_q(OUT/f"core{c}/z.mem",zhead)
    dpartials=[project(zheads[c],c,6,64) for c in range(8)]
    reduced_d=tree(np.stack(dpartials,axis=-1))
    final_resid=bf16(add(expand(mid).reshape(51,64,16),reduced_d)).reshape(51,1024)
    write_vectors(OUT/"next.mem",final_resid.reshape(51,64,16).transpose(1,0,2),16)
    x2,y2,u2,inv2=normalize(final_resid,gamma0)
    write_q(OUT/"xhat2.mem",x2,True)
    write_vectors(OUT/"u2.mem",words(u2).reshape(-1,1))
    write_vectors(OUT/"final.mem",words(y2).transpose(1,0,2))
    for c in range(8):
        write_vectors(OUT/f"core{c}/reduce_o.mem",words(opartials[c]).transpose(1,0,2))
        write_vectors(OUT/f"core{c}/reduce_down.mem",words(dpartials[c]).transpose(1,0,2))
    (OUT/"manifest.json").write_text(json.dumps({
        "layer_cases":[1,9,18],"skipped_layers_executed":False,
        "oracle":"NumPy per-B16 integer dot then ordered native FP32; FP32 tree/BF16 residual; real gamma",
        "pcore_quant":"floor exponent/RNE/signed saturation [-127,127]",
        "gcore_quant":"COVER127_RNE; separate frozen contract",
        "initial_exceptions":["RESID", "prefix KV", "Mask/RoPE parameter ROM"],
        "outputs_are_scoreboards_only":True,"internal_tb_models":False
    },indent=2),encoding="utf-8")
    print("LAYER_GOLD_READY cores=8 jobs=7 QK=440 PV=440 independent=1")


if __name__=="__main__":main()
