#!/usr/bin/env python3
# qdis.py - ARM64 PE (.sys) disassembler with string resolution, RVA addressing.
# 用法: qdis.py <lo_rva> <hi_rva>           # 反汇编 [lo,hi) 区间（按 RVA）
#       QDIS_PE=/path/to/driver.sys qdis.py <lo> <hi>   # 换目标 PE
# 默认目标 = qcdxkm8250.sys（imagebase 0x140000000，地址按 RVA 给）。
# 自动解析 adrp+add/ldr 指向的字符串、mov 立即数里的 4 字节 ASCII tag。
import struct, sys, re, os
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
F = os.environ.get("QDIS_PE", os.path.join(
    _REPO, "winarm/drivers/QC8250/Drivers/Graphics/DXKM/qcdxkm8250.sys"))
d=open(F,'rb').read()
pe=struct.unpack_from('<I',d,0x3c)[0]; nsec=struct.unpack_from('<H',d,pe+6)[0]; optsz=struct.unpack_from('<H',d,pe+20)[0]
secs=[]
for i in range(nsec):
    o=pe+24+optsz+i*40; nm=d[o:o+8].rstrip(b'\0').decode(); vs,va,rs,ra=struct.unpack_from('<IIII',d,o+8); secs.append((nm,va,vs,ra,rs))
def off(r):
    for nm,va,vs,ra,rs in secs:
        if va<=r<va+max(vs,rs): return ra+(r-va)
def rds(r):
    o=off(r)
    if o is None: return None
    e=d.find(b'\0',o); s=d[o:e]
    if len(s)>=3 and all(32<=c<127 for c in s): return s.decode()
    # utf16
    e=o
    while e+1<len(d) and d[e:e+2]!=b'\0\0': e+=2
    try:
        u=d[o:e].decode('utf-16le')
        if len(u)>=3 and all(32<=ord(c)<127 for c in u): return 'L"'+u+'"'
    except: pass
    return None
md=Cs(CS_ARCH_ARM64,CS_MODE_LITTLE_ENDIAN); md.skipdata=True
def dis(lo,hi):
    adrp={}
    for insn in md.disasm(d[off(lo):off(lo)+(hi-lo)], lo):
        note=''
        if insn.mnemonic=='adrp':
            m=re.match(r'(\w+), #(0x[0-9a-f]+)',insn.op_str)
            if m: adrp[m.group(1)]=int(m.group(2),16)
        elif insn.mnemonic in('add','ldr'):
            m=re.match(r'(\w+), \[?(\w+), #(0x[0-9a-f]+)',insn.op_str)
            if m and m.group(2) in adrp:
                t=adrp[m.group(2)]+int(m.group(3),16); s=rds(t)
                note=f'   ; {t:#x}' + (f' "{s}"' if s else '')
        elif insn.mnemonic=='mov':
            m=re.search(r'#(0x[0-9a-f]{6,8})$',insn.op_str)
            if m:
                v=int(m.group(1),16); b=v.to_bytes(4,'little')
                if all(65<=c<=90 or 48<=c<=57 or c==95 for c in b): note=f'   ; "{b.decode()}"'
        print(f"  {insn.address:#08x}: {insn.mnemonic:7s} {insn.op_str}{note}")
lo=int(sys.argv[1],16); hi=int(sys.argv[2],16); dis(lo,hi)
