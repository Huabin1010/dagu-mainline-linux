#!/system/bin/sh
# Runs on the Android device as root from /data/local/tmp/dagu-vulkan-truth
set -e
DIR=/data/local/tmp/dagu-vulkan-truth
cd "$DIR"
export LD_LIBRARY_PATH=/system/lib64:/vendor/lib64:/vendor/lib64/hw:${LD_LIBRARY_PATH}

echo "=== caps ==="
./dagu-vk-probe --caps-only --out-dir "$DIR" | tee caps.log

install_qgl() {
  src=$1
  mkdir -p /data/vendor/gpu /data/misc/gpu
  cp "$src" /data/vendor/gpu/qgl_config.txt
  cp "$src" /data/misc/gpu/qgl_config.txt
  chmod 644 /data/vendor/gpu/qgl_config.txt /data/misc/gpu/qgl_config.txt
}

echo "=== linear (wrap + qgl pm4 dump) ==="
install_qgl "$DIR/qgl_config.txt"
export WRAP_RD="$DIR/linear_store.rd"
export WRAP_LOG="$DIR/linear_wrap.log"
LD_PRELOAD="$DIR/libkgsl_wrap.so" ./dagu-vk-probe --tiling linear --out-dir "$DIR" \
  | tee linear_run.log
ls -l "$DIR/linear_store.rd" "$DIR/linear.report.txt" 2>/dev/null || true

echo "=== optimal (wrap) ==="
export WRAP_RD="$DIR/optimal_store.rd"
export WRAP_LOG="$DIR/optimal_wrap.log"
LD_PRELOAD="$DIR/libkgsl_wrap.so" ./dagu-vk-probe --tiling optimal --out-dir "$DIR" \
  | tee optimal_run.log
ls -l "$DIR/optimal_store.rd" "$DIR/optimal.report.txt" 2>/dev/null || true

echo "=== qgl leftovers ==="
ls -l /data/vendor/gpu /data/misc/gpu 2>/dev/null | head -80
echo DEVICE_RUN_DONE
