# Minimal MSF/PDB reader: pull public symbols (S_PUB32) + section map, map RVA->name.
import struct,sys
d=open(sys.argv[1],'rb').read()
assert d.startswith(b'Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0')
bs,fpm,nblk,dirsz,_=struct.unpack_from('<IIIII',d,32)
dirmap=struct.unpack_from('<I',d,52)[0]
nb=(dirsz+bs-1)//bs
dirblocks=struct.unpack_from('<%dI'%nb,d,dirmap*bs)
dirdata=b''.join(d[b*bs:(b+1)*bs] for b in dirblocks)[:dirsz]
ns=struct.unpack_from('<I',dirdata,0)[0]
sizes=struct.unpack_from('<%dI'%ns,dirdata,4)
o=4+4*ns; streams=[]
for s in sizes:
    if s==0xffffffff: streams.append(b''); continue
    n=(s+bs-1)//bs; bl=struct.unpack_from('<%dI'%n,dirdata,o); o+=4*n
    streams.append(b''.join(d[b*bs:(b+1)*bs] for b in bl)[:s])
dbi=streams[3]
symrec=struct.unpack_from('<H',dbi,20)[0]
modsz,secc,secm,srcinfo,tsm,mfc,dbghdr,ecs=struct.unpack_from('<8i',dbi,24)
dbgo=64+modsz+secc+secm+srcinfo+tsm+ecs
dh=struct.unpack_from('<11H',dbi,dbgo)
sechdr_stream=dh[5]
sh=streams[sechdr_stream]
secs=[]
for i in range(0,len(sh),40):
    name=sh[i:i+8].rstrip(b'\0'); vsz,va=struct.unpack_from('<II',sh,i+8); secs.append((name,va))
syms=streams[symrec]; out=[]
i=0
while i+4<=len(syms):
    ln,typ=struct.unpack_from('<HH',syms,i)
    if typ==0x110e:
        fl,off,seg=struct.unpack_from('<IIH',syms,i+4)
        name=syms[i+14:syms.index(b'\0',i+14)].decode(errors='replace')
        if 1<=seg<=len(secs): out.append((secs[seg-1][1]+off,name))
    i+=ln+2
out.sort()
import bisect
keys=[a for a,_ in out]
for a in sys.argv[2:]:
    a=int(a,16); k=bisect.bisect_right(keys,a)-1
    print('%#x %s+%#x'%(a,out[k][1],a-out[k][0]) if k>=0 else hex(a))
