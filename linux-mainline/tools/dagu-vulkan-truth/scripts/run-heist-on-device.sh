#!/system/bin/sh
# Device-side heist: fake ICD + LD_PRELOAD, then ptrace spy if sphal still wins.
set -e
DIR=/data/local/tmp/dagu-vulkan-truth
cd "$DIR"

export LD_LIBRARY_PATH="$DIR:/system/lib64:/vendor/lib64:/vendor/lib64/hw:${LD_LIBRARY_PATH}"
export DAGU_VULKAN_SO="$DIR/vulkan.adreno.so"
export VK_ICD_FILENAMES="$DIR/adreno_icd.json"
export VK_DRIVER_FILES="$DIR/adreno_icd.json"

echo "=== heist sandbox ==="
if [ ! -f "$DIR/vulkan.adreno.so" ]; then
  cp /vendor/lib64/hw/vulkan.adreno.so "$DIR/vulkan.adreno.so"
fi
# Pull the blob's DT_NEEDED vendor libs next to it so default-ns dlopen can resolve.
for lib in libgsl.so libadreno_utils.so libllvm-glnext.so libadreno_app_profiles.so; do
  if [ -f "/vendor/lib64/$lib" ] && [ ! -f "$DIR/$lib" ]; then
    cp "/vendor/lib64/$lib" "$DIR/$lib" || true
  fi
done
ls -l "$DIR/vulkan.adreno.so" "$DIR/libkgsl_wrap.so" "$DIR/kgsl_spy" "$DIR/adreno_icd.json" 2>/dev/null || true
echo "ICD=$(cat $DIR/adreno_icd.json)"

install_qgl() {
  src=$1
  mkdir -p /data/vendor/gpu /data/misc/gpu
  rm -f /data/vendor/gpu/cmdbuf_* /data/vendor/gpu/ib_cmdbuf_* /data/vendor/gpu/qgl_bin_log_* \
        /data/misc/gpu/cmdbuf_* /data/misc/gpu/ib_cmdbuf_* /data/misc/gpu/qgl_bin_log_*
  cp "$src" /data/vendor/gpu/qgl_config.txt
  cp "$src" /data/misc/gpu/qgl_config.txt
  chmod 644 /data/vendor/gpu/qgl_config.txt /data/misc/gpu/qgl_config.txt
}

install_qgl "$DIR/qgl_config_force_gmem.txt"
echo "=== qgl_config ==="
cat /data/vendor/gpu/qgl_config.txt

PASSES=${HEIST_PASSES:-ABCD}
echo "HEIST_PASSES=$PASSES"

if echo "$PASSES" | grep -q A; then
echo "=== heist pass A: ICD + LD_PRELOAD wrap, LINEAR 128 draws ==="
export WRAP_RD="$DIR/heist_icd_linear.rd"
export WRAP_LOG="$DIR/heist_icd_linear.wrap.log"
set +e
LD_PRELOAD="$DIR/libkgsl_wrap.so" ./dagu-vk-probe --tiling linear --draws 128 --out-dir "$DIR" \
  > "$DIR/heist_icd_linear.run.log" 2>&1
rc_a=$?
set -e
echo "passA_exit=$rc_a"
tail -n 40 "$DIR/heist_icd_linear.run.log" || true
echo "---- wrap log ----"
cat "$DIR/heist_icd_linear.wrap.log" 2>/dev/null | tail -n 80 || true
ls -l "$DIR/heist_icd_linear.rd" "$DIR/linear.report.txt" 2>/dev/null || true

saw_kgsl=0
if grep -q "kgsl fd=" "$DIR/heist_icd_linear.wrap.log" 2>/dev/null; then
  saw_kgsl=1
fi
if grep -q "GPU_COMMAND" "$DIR/heist_icd_linear.wrap.log" 2>/dev/null; then
  saw_kgsl=1
fi
echo "passA_saw_kgsl=$saw_kgsl"
fi

if echo "$PASSES" | grep -q B; then
echo "=== heist pass B: ptrace kgsl_spy (namespace-proof) ==="
export WRAP_RD="$DIR/heist_spy_linear.rd"
export WRAP_LOG="$DIR/heist_spy_linear.wrap.log"
set +e
./kgsl_spy -- ./dagu-vk-probe --tiling linear --draws 128 --out-dir "$DIR" \
  > "$DIR/heist_spy_linear.run.log" 2>&1
rc_b=$?
set -e
echo "passB_exit=$rc_b"
tail -n 40 "$DIR/heist_spy_linear.run.log" || true
echo "---- spy log head/tail ----"
sed -n '1,60p' "$DIR/heist_spy_linear.wrap.log" 2>/dev/null || true
echo "..."
tail -n 80 "$DIR/heist_spy_linear.wrap.log" 2>/dev/null || true
ls -l "$DIR/heist_spy_linear.rd" 2>/dev/null || true
fi

if echo "$PASSES" | grep -q C; then
echo "=== heist pass C: spy LINEAR CLEAR+STORE then loadOp=LOAD ==="
export WRAP_RD="$DIR/heist_spy_load.rd"
export WRAP_LOG="$DIR/heist_spy_load.wrap.log"
set +e
./kgsl_spy -- ./dagu-vk-probe --tiling linear --draws 128 --load-second --out-dir "$DIR" \
  > "$DIR/heist_spy_load.run.log" 2>&1
rc_c=$?
set -e
echo "passC_exit=$rc_c"
tail -n 40 "$DIR/heist_spy_load.run.log" || true
ls -l "$DIR/heist_spy_load.rd" 2>/dev/null || true
fi

if echo "$PASSES" | grep -q D; then
echo "=== heist pass D: spy LINEAR two-subpass input attachment ==="
export WRAP_RD="$DIR/heist_spy_input.rd"
export WRAP_LOG="$DIR/heist_spy_input.wrap.log"
set +e
./kgsl_spy -- ./dagu-vk-probe --tiling linear --draws 128 --input-second --out-dir "$DIR" \
  > "$DIR/heist_spy_input.run.log" 2>&1
rc_d=$?
set -e
echo "passD_exit=$rc_d"
tail -n 60 "$DIR/heist_spy_input.run.log" || true
ls -l "$DIR/heist_spy_input.rd" "$DIR/linear_input.report.txt" 2>/dev/null || true
fi

echo "=== maps of last probe (if still around) ==="
pid=$(pidof dagu-vk-probe 2>/dev/null | awk '{print $1}')
if [ -n "$pid" ]; then
  grep -E 'vulkan.adreno|kgsl-3d|libkgsl_wrap' "/proc/$pid/maps" || true
fi

echo "=== qgl leftovers ==="
ls -l /data/vendor/gpu /data/misc/gpu 2>/dev/null | head -80
echo HEIST_DEVICE_DONE
