#!/usr/bin/env bash
# STREAMON Titan 480 PIX: CSID IPP → CAMIF → CLC → DISP linear NV12.
# Rear HyperOS path is CSID1 + IFE1 (IFE0 idle). Do not dual STREAMON
# with DebayerCpu / loopback.
# D-PHY 0x0114=0x0300 and CSID SOT mask must stay. Timeout STREAMON.
# media-ctl entity names MUST be quoted; PIX sink is CSID pad 4, not pad 1.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.1.158}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=8 "root@$HOST")
SCP=(scp -i "$KEY" -o StrictHostKeyChecking=no)

remote() { "${SSH[@]}" "$@"; }

# Kill SoftISP loopback — it holds VFE0 RDI and makes PIX vfe_get EBUSY.
remote 'systemctl stop dagu-camera-loopback-watch.service dagu-camera-loopback.service || true
pkill -9 -x dagu-camera-loopback || true
pkill -9 -x dagu-camera-preview || true'
remote python3 - <<'PY'
import os, re, subprocess, sys, time

def run(args, check=False):
    print('+', ' '.join(args))
    r = subprocess.run(args, capture_output=True, text=True)
    if r.stdout:
        sys.stdout.write(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    if check and r.returncode:
        raise SystemExit(f'cmd failed rc={r.returncode}: {args}')
    return r

print('===uname===')
run(['uname', '-r'])
print('===kill-loopback===')
run(['pkill', '-9', '-f', 'dagu-camera-loopback'], check=False)
run(['pkill', '-9', '-f', 'dagu-camera-preview'], check=False)
time.sleep(0.4)

MC = '/dev/media0'
print('===pix-entities===')
p = run(['media-ctl', '-d', MC, '-p'])
sensor = None
for line in p.stdout.splitlines():
    if any(s in line for s in ('msm_vfe1_pix', 'msm_vfe1_video3', 'msm_csid1',
                               'msm_vfe0_pix', 's5kjn1')):
        print(line)
    m = re.search(r's5kjn1 \d+-0010', line)
    if m:
        sensor = m.group(0)
if not sensor:
    raise SystemExit('s5kjn1 entity missing')
print(f'===sensor {sensor}===')

# HyperOS rear preview is CSID1 IPP + IFE1 DISP WM4/5 (IFE0 idle).
# CSID pad 1 is RDI0. PIX is pad 4. Drop IFE0 leftovers so this VC feeds IPP.
run(['media-ctl', '-d', MC, '-l', '"msm_csid0":4 -> "msm_vfe0_pix":0[0]'])
run(['media-ctl', '-d', MC, '-l', '"msm_csiphy1":1 -> "msm_csid0":0[0]'])
run(['media-ctl', '-d', MC, '-l', '"msm_csid0":1 -> "msm_vfe0_rdi0":0[0]'])
run(['media-ctl', '-d', MC, '-l', '"msm_csid1":1 -> "msm_vfe1_rdi0":0[0]'])
run(['media-ctl', '-d', MC, '-l', '"msm_csiphy1":1 -> "msm_csid1":0[1]'], check=True)
run(['media-ctl', '-d', MC, '-l', '"msm_csid1":4 -> "msm_vfe1_pix":0[1]'], check=True)

fmt = 'fmt:SGBRG10_1X10/4080x3060 field:none'
for spec in (
    f'"{sensor}":0[' + fmt + ']',
    '"msm_csiphy1":0[' + fmt + ']',
    '"msm_csiphy1":1[' + fmt + ']',
    '"msm_csid1":0[' + fmt + ']',
    '"msm_csid1":4[' + fmt + ']',
    '"msm_vfe1_pix":0[' + fmt + ' compose:(0,0)/1920x1080]',
    '"msm_vfe1_pix":1[fmt:YUYV8_1_5X8/1920x1080 field:none]',
):
    run(['media-ctl', '-d', MC, '-V', spec], check=True)

print('===pix-pads===')
run(['media-ctl', '-d', MC, '--get-v4l2', '"msm_vfe1_pix":0'])
run(['media-ctl', '-d', MC, '--get-v4l2', '"msm_vfe1_pix":1'])
run(['media-ctl', '-d', MC, '--get-v4l2', '"msm_csid1":4'])

pix = None
for n in os.listdir('/sys/class/video4linux'):
    try:
        name = open(f'/sys/class/video4linux/{n}/name').read().strip()
    except OSError:
        continue
    if name == 'msm_vfe1_video3':
        pix = f'/dev/{n}'
        break
if not pix:
    raise SystemExit('msm_vfe1_video3 missing')
print(f'===pix-node {pix}===')
run(['v4l2-ctl', '-d', pix, '--all'])

print('===streamon-nv12===')
try:
    os.remove('/tmp/pix.nv12')
except FileNotFoundError:
    pass
r = run([
    'timeout', '12', 'v4l2-ctl', '-d', pix,
    '--set-fmt-video=width=1920,height=1080,pixelformat=NV12',
    '--stream-mmap', '--stream-count=3', '--stream-to=/tmp/pix.nv12',
])
print(f'streamon_rc={r.returncode}')
run(['ls', '-l', '/tmp/pix.nv12'], check=False)
PY

echo '===dmesg-pix==='
remote 'dmesg | grep -iE "dagu ife|dagu csid ipp|dagu csid phy|dagu vfe|dagu camnoc|raise |Failed to power|CAMNOC|r0114|s5kjn1|clock enable failed" | tail -80 || true'
echo '===ipp-cfg0-hbin==='
remote python3 - <<'PY'
import re, subprocess
log = subprocess.check_output(['dmesg'], text=True, errors='replace')
cfg = re.findall(r'dagu csid ipp vc=\d+ decode=\d+ \d+x\d+ cfg0=(0x[0-9a-f]+)', log)
ov = re.findall(r'PIXEL PIPE OVERFLOW.*?viol_id=(\d+).*?pix=(\d+) line=(\d+)', log)
ov_old = re.findall(r'PIXEL PIPE OVERFLOW.*?camif=(0x[0-9a-f]+)/', log)
if cfg:
    v = int(cfg[-1], 16)
    print(f'ipp_cfg0={cfg[-1]} bit2_hbin={bool(v & 4)} expect_hbin=0')
if ov:
    print(f'viol_id={ov[-1][0]} pix={ov[-1][1]} line={ov[-1][2]} id19=MNDS_C_DISP')
elif ov_old:
    d0 = int(ov_old[-1], 16)
    print(f'camif_debug0={ov_old[-1]} pix={d0 & 0xffff} line={(d0>>16)&0xffff}')
go = re.findall(r'dagu ife\d+ camif go camif=(0x[0-9a-f]+) addr4/5=(0x[0-9a-f]+)/(0x[0-9a-f]+) cfg4/5=(0x[0-9a-f]+)/(0x[0-9a-f]+)', log)
if go:
    print(f'camif_go camif={go[-1][0]} addr={go[-1][1]}/{go[-1][2]} cfg={go[-1][3]}/{go[-1][4]}')
asx = re.findall(r'dagu ife\d+ overflow as0=(0x[0-9a-f]+)/(0x[0-9a-f]+) as1=(0x[0-9a-f]+)/(0x[0-9a-f]+) as2=(0x[0-9a-f]+)/(0x[0-9a-f]+) as3=(0x[0-9a-f]+)/(0x[0-9a-f]+)', log)
if asx:
    a = asx[-1]
    print('as0=%s/%s as1=%s/%s as2=%s/%s as3=%s/%s consumed=%s latched=%s' % (
        a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7],
        a[0] != '0x0', a[6] != '0x0'))
ds = re.findall(r'dagu ife\d+ overflow ds as0=(0x[0-9a-f]+)/(0x[0-9a-f]+) as2=(0x[0-9a-f]+)/(0x[0-9a-f]+) as3=(0x[0-9a-f]+)/(0x[0-9a-f]+)', log)
if ds:
    d = ds[-1]
    print('ds as0=%s/%s as2=%s/%s as3=%s/%s ds_consumed=%s' % (
        d[0], d[1], d[2], d[3], d[4], d[5], d[0] != '0x0'))
meta = re.findall(r'overflow as0=.*? meta4/5=(0x[0-9a-f]+)/(0x[0-9a-f]+) pwr_iso=(0x[0-9a-f]+)', log)
if meta:
    print(f'meta={meta[-1][0]}/{meta[-1][1]} pwr_iso={meta[-1][2]}')
axi = re.findall(
    r'overflow as0=.*? bwlim4/5=(0x[0-9a-f]+)/(0x[0-9a-f]+) fh4=(0x[0-9a-f]+) dbg1=(0x[0-9a-f]+)/(0x[0-9a-f]+) cc=(0x[0-9a-f]+)/(0x[0-9a-f]+)',
    log)
if axi:
    print('bwlim=%s/%s fh4=%s dbg1=%s/%s cc=%s/%s' % axi[-1])
clc = re.findall(
    r'dagu ife\d+ pix clc in .* cc=(0x[0-9a-f]+)/(0x[0-9a-f]+)/(0x[0-9a-f]+)/(0x[0-9a-f]+)',
    log)
if clc:
    print('cc cfg/spare/m00/m11=%s/%s/%s/%s' % clc[-1])
cst = re.findall(
    r'dagu ife\d+ pix cst=(0x[0-9a-f]+) offu=(0x[0-9a-f]+) offv=(0x[0-9a-f]+) postc70=(0x[0-9a-f]+)/(0x[0-9a-f]+) midc70=(0x[0-9a-f]+)/(0x[0-9a-f]+)',
    log)
if cst:
    print('cst=%s offu/offv=%s/%s postc70=%s/%s midc70=%s/%s' % cst[-1])
cn = re.findall(
    r'dagu ife\d+ camnoc (\S+) lin=(0x[0-9a-f]+)/urg=(0x[0-9a-f]+)(?:/maxwr=(0x[0-9a-f]+))? rdi=(0x[0-9a-f]+)/urg=(0x[0-9a-f]+)(?:/maxwr=(0x[0-9a-f]+))? ubwc=(0x[0-9a-f]+)/urg=(0x[0-9a-f]+) err=(0x[0-9a-f]+) pri=(0x[0-9a-f]+)/(0x[0-9a-f]+)',
    log)
for tag in ('rst', 'qos', 'ovf'):
    hits = [c for c in cn if c[0] == tag]
    if hits:
        c = hits[-1]
        print('camnoc %s lin=%s/urg=%s/maxwr=%s rdi=%s/urg=%s/maxwr=%s ubwc=%s/urg=%s err=%s pri=%s/%s' % (
            c[0], c[1], c[2], c[3] or '?', c[4], c[5], c[6] or '?', c[7], c[8], c[9], c[10], c[11]))
bus = re.findall(
    r'dagu ife\d+ bus (\S+) comp=(0x[0-9a-f]+)/(0x[0-9a-f]+) fh0=(0x[0-9a-f]+) top=(0x[0-9a-f]+)/(0x[0-9a-f]+) drop4=(0x[0-9a-f]+)/(0x[0-9a-f]+)',
    log)
for tag in ('rst', 'clr', 'go', 'ovf'):
    hits = [b for b in bus if b[0] == tag]
    if hits:
        b = hits[-1]
        print('bus %s comp=%s/%s fh0=%s top=%s/%s drop4=%s/%s' % b)
if not cfg:
    print('no ipp cfg0 log')
PY
echo '===irq==='
remote 'grep -iE "csid|ife|vfe" /proc/interrupts || true'
echo '===0114==='
remote 'dmesg | grep -i "r0114" | tail -5 || true'
echo '===sot-mask==='
remote 'grep -n "CSID SOT" /proc/kallsyms >/dev/null; dmesg | grep -i "SOT/EOT stay masked" | tail -3 || true'

mkdir -p "$ROOT/out/camera"
if remote 'test -s /tmp/pix.nv12'; then
  "${SCP[@]}" "root@$HOST:/tmp/pix.nv12" "$ROOT/out/camera/pix.nv12"
  python3 - <<PY
from pathlib import Path
p = Path("$ROOT/out/camera/pix.nv12")
raw = p.read_bytes()
w, h = 1920, 1080
need = w * h * 3 // 2
n = len(raw) // need
print(f"nv12 bytes={len(raw)} frames={n} expect={need}")
if n:
    frame = raw[:need]
    y = frame[:w*h]
    # crude luma PNG via PIL if present, else skip
    try:
        from PIL import Image
        img = Image.frombytes('L', (w, h), y)
        out = Path("$ROOT/out/camera/pix-y.png")
        img.save(out)
        print(f"wrote {out} mean={sum(y)/len(y):.1f}")
    except Exception as e:
        print(f"no luma png: {e}")
PY
fi

echo '===restore-rdi0==='
remote python3 - <<'PY'
import subprocess
subprocess.run(['media-ctl', '-d', '/dev/media0', '-l',
                '"msm_csid1":4 -> "msm_vfe1_pix":0[0]'])
subprocess.run(['media-ctl', '-d', '/dev/media0', '-l',
                '"msm_csiphy1":1 -> "msm_csid1":0[0]'])
subprocess.run(['media-ctl', '-d', '/dev/media0', '-l',
                '"msm_csiphy1":1 -> "msm_csid0":0[1]'])
subprocess.run(['media-ctl', '-d', '/dev/media0', '-l',
                '"msm_csid0":1 -> "msm_vfe0_rdi0":0[1]'])
print('ife1 pix dropped, rdi0 re-enabled')
PY
remote 'systemctl start dagu-camera-loopback-watch.service || true'

echo "==> host g_serial"
lsusb | grep -E "0525:a4a7|18d1:d00d|18d1:4ee7" || true
echo "==> done (NV12 /tmp/pix.nv12 on device; streamon_rc=0 and size>0 means frames)"
