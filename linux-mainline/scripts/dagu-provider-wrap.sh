#!/system/bin/sh
# Wrap HyperOS camera provider so libdagu-cdm-dump.so can read live IFE CDM.
export LD_PRELOAD=/data/local/tmp/libdagu-cdm-dump.so
exec /vendor/bin/hw/android.hardware.camera.provider@2.4-service_64 "$@"
