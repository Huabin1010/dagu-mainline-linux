# 常用命令（dagu）

在安卓系统里进 **bootloader fastboot**（兔子界面，USB `18d1:d00d`）：

```bash
adb reboot bootloader
```

本机已 root（Magisk）时，平板上也可以：

```bash
su -c reboot bootloader
```

或 Magisk App → **重启** → **引导程序 / Bootloader**。

不要用 `adb reboot fastboot`：那是 userspace **fastbootd**，不是刷 `boot_b` / `dtbo_b` 用的 ABL fastboot。

adb 连不上时：关机 → **按住音量下 + 电源**，直到兔子。USB 调试要开；线插上后选「传输文件」。确认：

```bash
adb devices
python3 linux-mainline/scripts/fb-usb.py devices
```
