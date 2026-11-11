import struct,subprocess,sys
dev='/dev/sda36'
f=open(dev,'rb'); bs=f.read(512)
bps=struct.unpack_from('<H',bs,11)[0]; spc=bs[13]; clus=bps*spc
mftlcn=struct.unpack_from('<Q',bs,0x30)[0]
c=struct.unpack_from('<b',bs,0x40)[0]; rec=(clus*c) if c>0 else (1<<(-c))
print('bps',bps,'cluster',clus,'mft lcn',mftlcn,'record',rec)
# read $MFT record 0 to get MFT runlist
def fixup(b):
    b=bytearray(b); uo,uc=struct.unpack_from('<HH',b,4); usn=b[uo:uo+2]
    for i in range(1,uc):
        p=i*512-2; assert b[p:p+2]==usn, 'fixup mismatch'; b[p:p+2]=b[uo+2*i:uo+2*i+2]
    return bytes(b)
def runs(b,o):
    out=[];lcn=0;vcn=0
    while b[o]:
        h=b[o]; ln=h&0xf; lo=h>>4; o+=1
        l=int.from_bytes(b[o:o+ln],'little'); o+=ln
        d=int.from_bytes(b[o:o+lo],'little',signed=True) if lo else 0; o+=lo
        lcn+=d; out.append((vcn,lcn if lo else None,l)); vcn+=l
    return out
f.seek(mftlcn*clus); r0=fixup(f.read(rec))
a=struct.unpack_from('<H',r0,0x14)[0]
mruns=None
while True:
    t,ln=struct.unpack_from('<II',r0,a)
    if t==0xffffffff: break
    if t==0x80: mruns=runs(r0,a+struct.unpack_from('<H',r0,a+0x20)[0])
    a+=ln
def readrec(n):
    off=n*rec
    for vcn,lcn,l in mruns:
        if vcn*clus<=off<(vcn+l)*clus:
            f.seek(lcn*clus+off-vcn*clus); return f.read(rec)
def dump(n):
    raw=readrec(n)
    print('== record',n,'sig',raw[:4])
    try: r=fixup(raw)
    except AssertionError as e: print('  FIXUP FAILED (torn record)'); r=raw
    seq=struct.unpack_from('<H',r,0x10)[0]; flags=struct.unpack_from('<H',r,0x16)[0]
    used,alloc=struct.unpack_from('<II',r,0x18); base=struct.unpack_from('<Q',r,0x20)[0]
    print('  seq',seq,'flags',hex(flags),'used',used,'base',hex(base))
    a=struct.unpack_from('<H',r,0x14)[0]
    while a<used:
        t,ln=struct.unpack_from('<II',r,a)
        if t==0xffffffff or ln==0: break
        nr=r[a+8]
        nl,no=r[a+9],struct.unpack_from('<H',r,a+10)[0]
        name=r[a+no:a+no+2*nl].decode('utf-16le') if nl else ''
        s='  attr %#x len %d nonres %d name %r'%(t,ln,nr,name)
        if nr:
            sv,ev=struct.unpack_from('<QQ',r,a+0x10); ro=struct.unpack_from('<H',r,a+0x20)[0]
            alloc,size,init=struct.unpack_from('<QQQ',r,a+0x28)
            rl=runs(r,a+ro)
            s+=' vcn %d..%d size %#x init %#x runs %d %s'%(sv,ev,size,init,len(rl),rl[:6])
        print(s); a+=ln
for n in map(int,sys.argv[1:]): dump(n)

def attrlist(n):
    r=fixup(readrec(n)); a=struct.unpack_from('<H',r,0x14)[0]
    while True:
        t,ln=struct.unpack_from('<II',r,a)
        if t==0xffffffff: break
        if t==0x20:
            nr=r[a+8]
            if nr: print('  attrlist non-resident'); return
            vl,vo=struct.unpack_from('<IH',r,a+0x10); v=r[a+vo:a+vo+vl]; o=0
            while o<len(v):
                at,rl=struct.unpack_from('<IH',v,o); nl,no=v[o+6],v[o+7]
                svcn,mref=struct.unpack_from('<QQ',v,o+8); inst=struct.unpack_from('<H',v,o+0x18)[0]
                nm=v[o+no:o+no+2*nl].decode('utf-16le') if nl else ''
                print('  list type %#x startvcn %d -> record %d seq %d inst %d %r'%(at,svcn,mref&0xffffffffffff,mref>>48,inst,nm))
                if rl==0: break
                o+=rl
        a+=ln
import os
if os.environ.get('AL'): attrlist(int(os.environ['AL']))

def insts(n):
    r=fixup(readrec(n)); a=struct.unpack_from('<H',r,0x14)[0]
    print('  next_instance',struct.unpack_from('<H',r,0x28)[0])
    while True:
        t,ln=struct.unpack_from('<II',r,a)
        if t==0xffffffff: break
        print('  type %#x instance %d nonres %d'%(t,struct.unpack_from('<H',r,a+0xe)[0],r[a+8]))
        a+=ln
if os.environ.get('IN'):
    for n in os.environ['IN'].split(','): print('==',n); insts(int(n))

if os.environ.get('SCAN'):
    # every in-use base record in the config directory index with an ATTRIBUTE_LIST
    import subprocess
    out=subprocess.run(['ntfsls','-F','-l','-i','/dev/sda36','-p','/Windows/System32/config'] if False else ['true'],capture_output=True)
