# 无线固件热更新测试

系统保持开着。把新固件写进 `Windows\System32\drivers`，再用 PnP（Plug and Play，即插即用）重新打开这块网卡。驱动在 `MiniportWdiOpenAdapter` 里把固件下到芯片。

注册表里的固件名仍是 `wlanfw.mbn`。QCA6390 硬件 2.0 会去掉扩展名再接上 `20.mbn`，实际打开 `wlanfw20.mbn`。角色 `fw` 把同一份字节写成这两个名字。板级数据文件名不动，不改 `BDFileName`。

在管理员权限的 PowerShell 里：

```text
powershell -ExecutionPolicy Bypass -File reload.ps1 -Role fw -Path D:\lab\wlanfw20.mbn
powershell -ExecutionPolicy Bypass -File reload.ps1 -Role m3 -Path D:\lab\m3.bin
powershell -ExecutionPolicy Bypass -File reload.ps1 -RestartOnly
powershell -ExecutionPolicy Bypass -File reload.ps1 -Restore
```

`reload.cmd` 只是转给上面的脚本，同样要管理员权限。

会拒绝这些文件：

- 路径里有 Linux 的 `ath11k` 目录
- 文件名是 `amss.bin`、`amss20.bin`、`board.bin`、`board-2.bin`、`bdwlan.elf`、`bdwlan.e11`、`bdwlan.eff`、`bd_l81a.elf`
- 摘要前缀是 2026-11-09 量过的 Linux `amss.bin`（`8ab2a06422e39890`）或 Linux `m3.bin`（`1921d25edb52f90a`）
- 文件头不是 ELF（Executable and Linkable Format，可执行与可链接格式）
- 无线固件不在 1000000 到 8000000 字节，协处理器固件不在 64000 到 1000000 字节

覆盖前把旧文件拷到 `Windows\System32\drivers\dagu-fw-backup\<时间>\`。`-Restore` 用最近一次备份盖回去并再次打开网卡。

报告写两份：脚本旁边的 `reload-report.txt`，以及 `C:\Windows\Temp\dagu-wifi-fw-reload.txt`。里面有摘要、备份目录、重新打开的退出码，以及打开前后的设备枚举。

网卡接口还没出现时，固件侧的实时诊断通道仍然开不了。这份报告只说明这次有没有重新打开设备。
