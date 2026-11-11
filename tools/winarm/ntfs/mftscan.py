# Find base records whose ATTRIBUTE_LIST lists a $DATA extent in the same
# record that has highest VCN < lowest VCN (empty run list): winload's
# NtfspLookupAttributeVcnEx follows the list back to the same extent forever.
import struct,sys
exec(open(__import__('os').path.join(__import__('os').path.dirname(__file__),'mftrec.py')).read().split('def dump(n):')[0])
nrec=None
for vcn,lcn,l in mruns: pass
total=(mruns[-1][0]+mruns[-1][2])*clus//rec
bad=[]
for n in range(total):
    raw=readrec(n)
    if raw[:4]!=b'FILE': continue
    try: r=fixup(raw)
    except AssertionError: continue
    flags=struct.unpack_from('<H',r,0x16)[0]; base=struct.unpack_from('<Q',r,0x20)[0]
    if not flags&1 or base: continue
    a=struct.unpack_from('<H',r,0x14)[0]; used=struct.unpack_from('<I',r,0x18)[0]
    has_al=False; empty=[]
    while a<used:
        t,ln=struct.unpack_from('<II',r,a)
        if t==0xffffffff or ln==0: break
        if t==0x20: has_al=True
        if r[a+8]:
            sv,ev=struct.unpack_from('<qq',r,a+0x10)
            if ev<sv: empty.append(hex(t))
        a+=ln
    if has_al and empty: bad.append((n,empty))
print('records',total,'suspicious',bad)
