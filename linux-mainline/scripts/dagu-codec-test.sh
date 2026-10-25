#!/bin/sh
# Venus codec test on the tablet: hardware decode and encode, checked
# against ffmpeg software decode, plus throughput.
#
#   sudo dagu-codec-test.sh [workdir]        (default /var/tmp/dagu-codec)
#
# Clips are generated with ffmpeg (testsrc2, so frames have detail and
# motion). Decode passes when every frame comes out and PSNR against the
# software decode is >= 40 dB (bit-exact decoders give "inf"). Encode
# passes when every frame comes out and PSNR against the source is
# >= 33 dB. Speed is reported, not gated, except 4K60 must reach 60 fps.
set -u
W=${1:-/var/tmp/dagu-codec}
mkdir -p "$W"
cd "$W" || exit 1
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
ms_now() { echo $(( $(date +%s%N) / 1000000 )); }

gen() { # name args...
	f=$1; shift
	[ -s "$f" ] || ffmpeg -nostdin -y -v error "$@" "$f" || { bad "generate $f"; return 1; }
}
S4K="-f lavfi -i testsrc2=size=3840x2160:rate=60 -t 2"
S1K="-f lavfi -i testsrc2=size=1920x1080:rate=30 -t 4"
gen h264-4k60.mp4 $S4K -c:v libx264 -preset superfast -profile:v high -level 5.2 -pix_fmt yuv420p -b:v 50M -g 60
gen h264-1080p.mp4 $S1K -c:v libx264 -preset superfast -profile:v high -pix_fmt yuv420p -b:v 10M -g 60
gen hevc-4k60.mp4 $S4K -c:v libx265 -preset ultrafast -pix_fmt yuv420p -b:v 40M -g 60 -tag:v hvc1 -x265-params log-level=error
gen hevc10-4k60.mp4 $S4K -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -b:v 40M -g 60 -tag:v hvc1 -x265-params log-level=error
gen vp9-4k60.webm $S4K -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 -tile-columns 2 -b:v 40M -g 60
gen vp8-1080p.webm $S1K -c:v libvpx -deadline realtime -cpu-used 8 -b:v 10M -g 60
gen mpeg2-1080p.ts $S1K -c:v mpeg2video -b:v 20M -g 30
chmod 644 ./*.mp4 ./*.webm ./*.ts 2>/dev/null

frames() {
	ffprobe -v error -count_packets -select_streams v:0 \
		-show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$1" | head -1
}
# Decode rate from the first frame on (fpsdisplaysink average), so the
# ~0.5 s pipeline start does not count against a 2 s clip.
dec_fps() { # file element
	gst-launch-1.0 -v filesrc location="$1" ! parsebin ! "$2" ! \
		fpsdisplaysink video-sink=fakevideosink text-overlay=false sync=false \
		fps-update-interval=50 2>/dev/null |
		sed -n 's/.*average: \([0-9.]*\).*/\1/p' | tail -1 | cut -d. -f1
}
dims() {
	ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
		-of default=nw=1:nk=1 "$1" | head -2 | paste -sd x
}
# Raw I420 against raw I420. Feeding the container as the reference made
# the psnr filter pair frames by timestamp against a 25 fps raw input, so
# a bit-exact decode read as 24-28 dB.
psnr() { # raw-a raw-b WxH
	if cmp -s "$1" "$2"; then
		echo inf
		return
	fi
	ffmpeg -nostdin -v info -f rawvideo -pix_fmt yuv420p -s "$3" -i "$1" \
		-f rawvideo -pix_fmt yuv420p -s "$3" -i "$2" -lavfi psnr -f null - 2>&1 |
		sed -n 's/.*PSNR.* average:\([0-9.inf]*\).*/\1/p' | tail -1
}
swdec() { # file -> sw-<file>.i420 (8-bit 4:2:0, the same as the gst path)
	[ -s "sw-$1.i420" ] ||
		ffmpeg -nostdin -v error -i "$1" -f rawvideo -pix_fmt yuv420p "sw-$1.i420"
}
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a == "inf" || a + 0 >= b) }'; }

# ---- hardware decode: correctness and speed ----
dec_test() { # label file element
	label=$1 f=$2 el=$3
	n=$(frames "$f") sz=$(dims "$f")
	rm -f dec.i420
	gst-launch-1.0 -q filesrc location="$f" ! parsebin ! "$el" ! videoconvert ! \
		video/x-raw,format=I420 ! filesink location=dec.i420 >gst.log 2>&1
	rc=$?
	w=${sz%x*} h=${sz#*x}
	got=$(( $(stat -c %s dec.i420 2>/dev/null || echo 0) / (w * h * 3 / 2) ))
	swdec "$f"
	p=$(psnr dec.i420 "sw-$f.i420" "$sz")
	fps=$(dec_fps "$f" "$el")
	fps=${fps:-0}
	msg="decode $label: $got/$n frames, PSNR ${p:-none} dB, $fps fps"
	if [ $rc = 0 ] && [ "$got" = "$n" ] && [ -n "$p" ] && ge "$p" 40; then
		case $label in *4K60*) [ $fps -ge 60 ] || { bad "$msg (below 60 fps)"; return; } ;; esac
		ok "$msg"
	else
		bad "$msg rc=$rc $(tail -1 gst.log | cut -c1-120)"
	fi
}
dec_test "H.264 High L5.2 4K60" h264-4k60.mp4 v4l2h264dec
dec_test "H.264 High 1080p30" h264-1080p.mp4 v4l2h264dec
dec_test "HEVC Main 4K60" hevc-4k60.mp4 v4l2h265dec
dec_test "HEVC Main10 4K60" hevc10-4k60.mp4 v4l2h265dec
dec_test "VP9 4K60" vp9-4k60.webm v4l2vp9dec
dec_test "VP8 1080p30" vp8-1080p.webm v4l2vp8dec
# MPEG-2: Venus on SM8250 does not offer it (kernel hides the broken
# firmware path); playback must pick the software decoder and be exact.
if gst-inspect-1.0 v4l2mpeg2dec >/dev/null 2>&1; then
	bad "MPEG-2: v4l2mpeg2dec is still registered (corrupt hardware path)"
else
	dec_test "MPEG-2 1080p30 (software)" mpeg2-1080p.ts avdec_mpeg2video
fi

# ---- hardware encode: source is a software decode of the clip ----
enc_test() { # label src element parser caps extension
	label=$1 src=$2 el=$3 parse=$4 caps=$5 ext=$6
	sz=$(dims "$src") w=${sz%x*} h=${sz#*x}
	n=$(frames "$src")
	fr=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$src")
	swdec "$src"
	cp -f "sw-$src.i420" "src-$sz.i420"
	# Feed NV12 straight to the encoder. A videoconvert in front of it
	# applied a BT.601->BT.709 matrix (rawvideoparse and the encoder
	# fixate different colorimetry), and every encoder read as 24 dB.
	[ -s "src-$sz.nv12" ] || ffmpeg -nostdin -v error -f rawvideo -pix_fmt yuv420p \
		-s "$sz" -i "src-$sz.i420" -f rawvideo -pix_fmt nv12 "src-$sz.nv12"
	out="enc.$ext"
	rm -f "$out"
	t0=$(ms_now)
	gst-launch-1.0 -q filesrc location="src-$sz.nv12" ! \
		rawvideoparse format=nv12 width="$w" height="$h" framerate="$fr" ! \
		$el ! $caps ! $parse ! filesink location="$out" >gst.log 2>&1
	rc=$?
	t=$(( $(ms_now) - t0 ))
	got=$(frames "$out" 2>/dev/null)
	rm -f encdec.i420
	ffmpeg -nostdin -v error -i "$out" -f rawvideo -pix_fmt yuv420p encdec.i420
	p=$(psnr encdec.i420 "src-$sz.i420" "$sz")
	fps=$(( n * 1000 / (t ? t : 1) ))
	msg="encode $label: ${got:-0}/$n frames, PSNR ${p:-none} dB, $fps fps incl. raw read"
	if [ $rc = 0 ] && [ "${got:-0}" = "$n" ] && [ -n "$p" ] && ge "$p" 33; then
		ok "$msg"
	else
		bad "$msg rc=$rc $(tail -1 gst.log | cut -c1-120)"
	fi
}
enc_test "H.264 4K60 L5.2" h264-4k60.mp4 \
	"v4l2h264enc extra-controls=controls,video_bitrate=50000000" h264parse \
	"video/x-h264,level=(string)5.2" h264
enc_test "H.264 1080p30" h264-1080p.mp4 \
	"v4l2h264enc extra-controls=controls,video_bitrate=10000000" h264parse video/x-h264 h264
enc_test "HEVC 4K60" hevc-4k60.mp4 \
	"v4l2h265enc extra-controls=controls,video_bitrate=40000000" h265parse video/x-h265 h265
enc_test "HEVC 1080p30" h264-1080p.mp4 \
	"v4l2h265enc extra-controls=controls,video_bitrate=8000000" h265parse video/x-h265 h265
enc_test "VP8 1080p30" vp8-1080p.webm \
	"v4l2vp8enc extra-controls=controls,video_bitrate=10000000" "matroskamux" video/x-vp8 webm

echo "codec test: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
