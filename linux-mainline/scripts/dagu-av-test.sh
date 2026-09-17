#!/usr/bin/env bash
# Speaker / mic / cameras on a running dagu. Use Wi-Fi SSH, not ttyGS0.
# Stock Android speaker: TERT_TDM_RX_0, 2ch S24_LE 48 kHz, all CS35L41 slot 0/1.
# Stock speaker-mic: TX DEC0=SWR_MIC, SMIC MUX0=ADC3, ADC4 MIXER, ADC4 MUX=INP5.
# Capture PCM is MultiMedia2 (hw:0,1) so it does not steal speaker MM1.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=8 "root@$HOST")

remote() { "${SSH[@]}" "$@"; }

echo "==> $HOST audio + camera"
remote 'set -e
echo ===uname===
uname -r
echo ===sound-cards===
cat /proc/asound/cards 2>/dev/null || true
echo ===speaker-route===
amixer -c 0 cset name="TERT_TDM_RX_0 Audio Mixer MultiMedia1" 1 || true
for p in TL TR BL BR; do
  amixer -c 0 cset name="$p PCM Source" ASP || true
  amixer -c 0 cset name="$p Analog PCM" 18 || amixer -c 0 cset name="$p Analog PCM Volume" 18 || true
  amixer -c 0 cset name="$p Digital PCM" 817 || amixer -c 0 cset name="$p Digital PCM Volume" 817 || true
  amixer -c 0 cset name="$p PCM Source" DSP || true
  amixer -c 0 cset name="$p Speaker" on || true
done
echo ===aplay-list===
aplay -l 2>/dev/null || true
arecord -l 2>/dev/null || true
echo ===speaker===
# Stock path is S24_LE 48 kHz stereo, CAF TDM_MAX_SLOTS=4 (6.144 MHz BCLK).
speaker-test -D hw:0,0 -c 2 -r 48000 -F S24_LE -t sine -f 440 -l 3 >/tmp/spk.log 2>&1 &
SPK=$!
sleep 1
echo ===dapm-amp===
for w in "TL Main AMP" "TR Main AMP" "BL Main AMP" "BR Main AMP" "TL SPK" "TR SPK" "TL AMP Playback"; do
  f=$(find /sys/kernel/debug/asoc -name "$w" 2>/dev/null | head -1)
  echo -n "$w: "; cat "$f" 2>/dev/null | head -1 || true
done
wait $SPK || true
cat /tmp/spk.log || true
echo ===cs35l41===
dmesg | grep -iE "cs35l41|PUP|AFE enable|fail to start AFE|tdm_cfg|dagu TDM|0x100ef|cmd 0x" | tail -40 || true
echo ===mic-route===
if [ -x /usr/local/sbin/dagu-mic-route.sh ]; then
  /usr/local/sbin/dagu-mic-route.sh || true
else
  amixer -c 0 cset name="MultiMedia2 Mixer TX_CODEC_DMA_TX_3" 1 || true
  amixer -c 0 cset name="TX DEC0 MUX" "SWR_MIC" || true
  amixer -c 0 cset name="TX SMIC MUX0" "ADC3" || true
  amixer -c 0 cset name="TX_AIF1_CAP Mixer DEC0" 1 || true
  amixer -c 0 cset name="ADC4_MIXER Switch" 1 || true
  amixer -c 0 cset name="ADC4 MUX" "INP5" || true
  amixer -c 0 cset name="ADC4 Switch" 1 || true
  amixer -c 0 cset name="TX3 MODE" "ADC_NORMAL" || true
  amixer -c 0 cset name="ADC4 Volume" 12 || true
fi
echo ===arecord===
arecord -D hw:0,1 -c 1 -r 48000 -f S16_LE -d 2 /tmp/mic.wav || \
  arecord -D plughw:0,1 -c 1 -r 48000 -f S16_LE -d 2 /tmp/mic.wav || true
ls -l /tmp/mic.wav 2>/dev/null || true
python3 - <<'PY' || true
import struct, math, wave
try:
    w = wave.open("/tmp/mic.wav", "rb")
    n = w.getnframes()
    data = w.readframes(n)
    s = struct.unpack("<%dh" % (len(data)//2), data)
    buf = s[len(s)//2:] if s else []
    rms = math.sqrt(sum(x*x for x in buf)/len(buf)) if buf else 0
    peak = max(abs(x) for x in buf) if buf else 0
    print("mic rms=%.1f peak=%d frames=%d" % (rms, peak, n))
except Exception as e:
    print("mic analyze:", e)
PY
echo ===pipeline-links===
MC=/dev/media0
media-ctl -d $MC -p 2>/dev/null | head -5 || true
S5K=$(media-ctl -d $MC -p | sed -n "s/^- entity [0-9]*: \\(s5kjn1 [^ ]*\\) (.*/\\1/p" | head -1)
IMX=$(media-ctl -d $MC -p | sed -n "s/^- entity [0-9]*: \\(imx596[^ ]* [^ ]*\\) (.*/\\1/p" | head -1)
echo "entities: S5K=$S5K IMX=$IMX"
# Rear s5kjn1 -> csiphy1 -> csid0 -> vfe0_rdi0
media-ctl -d $MC -l "\"msm_csiphy1\":1 -> \"msm_csid0\":0[1]" || true
media-ctl -d $MC -l "\"msm_csid0\":1 -> \"msm_vfe0_rdi0\":0[1]" || true
if [ -n "$S5K" ]; then
  media-ctl -d $MC -V "\"$S5K\":0[fmt:SGBRG10_1X10/4080x3060 field:none]" || true
fi
media-ctl -d $MC -V "\"msm_csiphy1\":0[fmt:SGBRG10_1X10/4080x3060 field:none]" || true
media-ctl -d $MC -V "\"msm_csiphy1\":1[fmt:SGBRG10_1X10/4080x3060 field:none]" || true
media-ctl -d $MC -V "\"msm_csid0\":0[fmt:SGBRG10_1X10/4080x3060 field:none]" || true
media-ctl -d $MC -V "\"msm_csid0\":1[fmt:SGBRG10_1X10/4080x3060 field:none]" || true
media-ctl -d $MC -V "\"msm_vfe0_rdi0\":0[fmt:SGBRG10_1X10/4080x3060 field:none]" || true
# Front imx596 -> csiphy4 -> csid1 -> vfe1_rdi0
media-ctl -d $MC -l "\"msm_csiphy4\":1 -> \"msm_csid1\":0[1]" || true
media-ctl -d $MC -l "\"msm_csid1\":1 -> \"msm_vfe1_rdi0\":0[1]" || true
if [ -n "$IMX" ]; then
  media-ctl -d $MC -V "\"$IMX\":0[fmt:SBGGR10_1X10/2592x1952 field:none]" || true
fi
media-ctl -d $MC -V "\"msm_csiphy4\":0[fmt:SBGGR10_1X10/2592x1952 field:none]" || true
media-ctl -d $MC -V "\"msm_csiphy4\":1[fmt:SBGGR10_1X10/2592x1952 field:none]" || true
media-ctl -d $MC -V "\"msm_csid1\":0[fmt:SBGGR10_1X10/2592x1952 field:none]" || true
media-ctl -d $MC -V "\"msm_csid1\":1[fmt:SBGGR10_1X10/2592x1952 field:none]" || true
media-ctl -d $MC -V "\"msm_vfe1_rdi0\":0[fmt:SBGGR10_1X10/2592x1952 field:none]" || true
echo ===v4l===
ls /dev/video* /dev/media* 2>/dev/null || true
echo ===subdevs===
for s in /dev/v4l-subdev*; do
  info=$(v4l2-ctl -d "$s" --info 2>/dev/null | grep -i "Card type" || true)
  echo "$s $info"
done
echo ===rear-stream===
# msm_vfe0_video0 = rear RDI. 10-bit GBRG packed fourcc is pGAA.
v4l_by_name() { local n; for n in /sys/class/video4linux/video*; do
  [ "$(cat "$n/name" 2>/dev/null)" = "$1" ] && echo "/dev/$(basename "$n")" && return; done; return 1; }
rear=$(v4l_by_name msm_vfe0_video0 || echo /dev/video0)
echo using $rear pgAA 4080x3060
rm -f /tmp/rear.raw
timeout 20 v4l2-ctl -d "$rear" --set-fmt-video=width=4080,height=3060,pixelformat=pgAA \
  --stream-mmap --stream-count=1 --stream-to=/tmp/rear.raw &
RSP=$!
sleep 1
echo camnoc_src=$(cat /sys/kernel/debug/clk/cam_cc_camnoc_axi_clk_src/clk_rate 2>/dev/null) \
  camnoc=$(cat /sys/kernel/debug/clk/cam_cc_camnoc_axi_clk/clk_rate 2>/dev/null) \
  ife0_axi=$(cat /sys/kernel/debug/clk/cam_cc_ife_0_axi_clk/clk_rate 2>/dev/null)
wait $RSP || true
ls -l /tmp/rear.raw 2>/dev/null || true
echo ===front-stream===
media-ctl -d $MC -l "\"msm_csiphy4\":1 -> \"msm_csid1\":0[1]" || true
media-ctl -d $MC -l "\"msm_csid1\":1 -> \"msm_vfe1_rdi0\":0[1]" || true
# msm_vfe1_video0 = front RDI. 10-bit BGGR packed fourcc is pBAA.
front=$(v4l_by_name msm_vfe1_video0 || echo /dev/video3)
echo using $front pBAA 2592x1952
rm -f /tmp/front.raw
timeout 12 v4l2-ctl -d "$front" --set-fmt-video=width=2592,height=1952,pixelformat=pBAA \
  --stream-mmap --stream-count=1 --stream-to=/tmp/front.raw || true
ls -l /tmp/front.raw 2>/dev/null || true
echo ===imx596===
dmesg | grep -iE "imx596|s5kjn1|camss|Failed to start media|streaming" | tail -40 || true
'
echo "==> done"
echo "Speaker: listen for 440 Hz. Mic: /tmp/mic.wav >44 bytes. Cameras: /tmp/rear.raw and /tmp/front.raw >0."
