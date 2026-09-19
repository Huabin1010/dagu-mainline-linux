# dagu FDT（Flattened Device Tree，扁平设备树）

`dagu.dtb` 来自 HyperOS 活树 `dumps/dagu-20260826-210700-root/dt/fdt.dtb`，**不是** Linux 7.0 [`sm8250-xiaomi-dagu.dts`](../../../../../../linux-mainline/dts/sm8250-xiaomi-dagu.dts) 的 `dtc` 产物。

刷新：

```bash
./tools/install-dagu-fdt.sh
```

`dagu.dtb.sha256` 是拷贝后的哈希。校验脚本 [`tools/dagu-linux-to-uefi-map.py`](../../../../../../tools/dagu-linux-to-uefi-map.py) 要求 blob 里同时有 `dagu` 和 `l81a`。
