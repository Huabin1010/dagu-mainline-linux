# 可恢复测试实验室

本目录存放 **Golden Backup**（刷机前分区镜像）。  
由 `tools/test-lab/lab.ps1 backup` 自动生成，**勿手动删除**。

若 `fastboot fetch` 失败（HyperOS 常见），请：

1. 保留小米官方线刷包路径，写入 `test-lab.json` → `mi_flash_rom_path`
2. 或使用 Magisk root 后 `dd` 备份 boot 分区
3. 实验期坚持 **`fastboot boot` 链式引导**，不写 boot 分区 → 多数失败可 `lab.ps1 recover` 直接 reboot 回 Android
