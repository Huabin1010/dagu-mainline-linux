#!/usr/bin/env bash
# callback_source_funcs.check 是 NULL：poll 返回后 GLib 当 check=FALSE，
# 主线程 qcb 已入队仍要再睡 ~100ms 才 dispatch → nview 晚。
# cave@1d2b80 写 gboolean check(GSource*){ return !!callbacks; }，
# 填 funcs+8。只 live poke ubuntu gnome-shell。不写磁盘。
# usage: status|apply|restore
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

case "$cmd" in
  status|apply|restore)
    "${SSH[@]}" python3 - "$cmd" <<'PY'
import struct, sys
from pathlib import Path

cmd = sys.argv[1]
CAVE = 0x1D2B80
FUNCS = 0x2B2DA8
LOCK = 0x65F60
UNLOCK = 0x66800
N_WORDS = 22


def enc_adrp(rd: int, pc: int, dest: int) -> int:
    imm = ((dest & ~0xFFF) - (pc & ~0xFFF)) >> 12
    imm &= 0x1FFFFF
    return 0x90000000 | ((imm & 3) << 29) | ((imm >> 2) << 5) | rd


def enc_bl(pc: int, dest: int) -> int:
    return 0x94000000 | (((dest - pc) // 4) & 0x3FFFFFF)


def enc_cave() -> list[int]:
    # gboolean check(GSource *src): lock callbacks_mutex; return !!src->callbacks
    # 对齐 prepare@1d37b0，去掉 *timeout=-1（check 的 x1 不是 timeout）
    w = [
        0xD503233F,  # paciasp
        0xA9BD7BFD,  # stp x29,x30,[sp,#-48]!
        0x910003FD,  # mov x29,sp
        0xF9000BF3,  # str x19,[sp,#16]
        0xAA0003F3,  # mov x19,x0
    ]
    pc = CAVE + 4 * len(w)
    w.append(enc_adrp(0, pc, 0x2B5000))  # adrp x0, 2b5000
    w += [
        0xB988E802,  # ldrsw x2,[x0,#2280]
        0xF9403E60,  # ldr x0,[x19,#120] thread
        0x8B020000,  # add x0,x0,x2
        0x9100C000,  # add x0,x0,#0x30 callbacks_mutex
        0xF90017E0,  # str x0,[sp,#40]
    ]
    pc = CAVE + 4 * len(w)
    w.append(enc_bl(pc, LOCK))
    w += [
        0xF9404661,  # ldr x1,[x19,#136] callbacks
        0xF94017E0,  # ldr x0,[sp,#40]
        0xF100003F,  # cmp x1,#0
        0x1A9F07F3,  # cset w19,ne
    ]
    pc = CAVE + 4 * len(w)
    w.append(enc_bl(pc, UNLOCK))
    w += [
        0x2A1303E0,  # mov w0,w19
        0xF9400BF3,  # ldr x19,[sp,#16]
        0xA8C37BFD,  # ldp x29,x30,[sp],#48
        0xD50323BF,  # autiasp
        0xD65F03C0,  # ret
    ]
    assert len(w) == N_WORDS
    return w


def find_ubuntu():
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            c = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if not c.startswith(b"/usr/bin/gnome-shell") or b"--mode=ubuntu" not in c:
            continue
        maps = (p / "maps").read_text()
        base = None
        for line in maps.splitlines():
            if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
                base = int(line.split("-", 1)[0], 16)
                break
        if base is None:
            continue
        return int(p.name), base
    raise SystemExit("no ubuntu gnome-shell")


def u32(mem, addr):
    mem.seek(addr)
    return struct.unpack("<I", mem.read(4))[0]


def u64(mem, addr):
    mem.seek(addr)
    return struct.unpack("<Q", mem.read(8))[0]


def w32(mem, addr, val):
    mem.seek(addr)
    mem.write(struct.pack("<I", val))


def w64(mem, addr, val):
    mem.seek(addr)
    mem.write(struct.pack("<Q", val))


pid, base = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
cave0 = [u32(mem, base + CAVE + 4 * i) for i in range(N_WORDS)]
check = u64(mem, base + FUNCS + 8)
prepare = u64(mem, base + FUNCS)
words = enc_cave()
want_check = base + CAVE
print("pid", pid, "base", hex(base), "prepare", hex(prepare), "check", hex(check), "cave0", hex(cave0[0]))

if cmd == "status":
    poked = check == want_check and cave0[0] == 0xD503233F
    print("live", "poked" if poked else "stock-or-mixed")
elif cmd == "apply":
    if check == want_check and cave0[0] == 0xD503233F:
        print("already poked")
    else:
        if check != 0:
            raise SystemExit(f"funcs.check not NULL: {check:#x}")
        if any(x not in (0, 0xD503201F) for x in cave0):
            raise SystemExit(f"cave not empty: {[hex(x) for x in cave0]}")
        for i, w in enumerate(words):
            w32(mem, base + CAVE + 4 * i, w)
        w64(mem, base + FUNCS + 8, want_check)
        print("poked", "check", hex(want_check), "words", [hex(x) for x in words])
elif cmd == "restore":
    w64(mem, base + FUNCS + 8, 0)
    for i in range(N_WORDS):
        off = CAVE + 4 * i
        w32(mem, base + off, 0xD503201F if off >= 0x1D2BC8 else 0)
    print("restored")
mem.close()
print("tracing_on", Path("/sys/kernel/debug/tracing/tracing_on").read_text().strip())
PY
    ;;
  *)
    echo "usage: $0 {status|apply|restore}" >&2
    exit 2
    ;;
esac
