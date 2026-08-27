# TestLab USB v2 Boot Log

> **USB Mass Storage / LSMS 路径已放弃。** `TestLabBridgeDxe` 默认关闭，不再 `StartImage` LinuxSimpleMassStorage。日常日志请用屏幕 + UART；安装改走 WinPE。

## 协议 (v2)

| 文件 | 说明 |
|------|------|
| `TESTLAB/BOOT.LOG` | 全量文本日志（ConOut 镜像） |
| `TESTLAB/BOOT.SEQ` | 递增序号，PC 用来 poll 新内容 |
| `TESTLAB/STATUS.JSON` | `{"seq":N,"usb":"waiting|ready|failed","bridge":"v2"}` |
| `TESTLAB/COMMAND.IN` | 可选：PC 写 Shell 命令 |
| `TESTLAB/COMMAND.ACK` | 命令执行结果 |

## 固件

- `TestLabBridgeDxe` 默认关闭（`TESTLAB_ENABLE_BRIDGE=0`），FDF 不打包
- 不再启动 LinuxSimpleMassStorage；`usb-on` 会返回 `ERR msc-removed`

## PC 用法

USB MSC 日志通路已关闭。当前用屏幕帧缓冲日志，或硬件 UART：

```powershell
.\tools\test-lab\lab.ps1 test-uefi -AttachSerial -SerialPort COM5
```

`test-lab.json`：

```json
{
  "usb_log_timeout_sec": 120,
  "usb_log_poll_sec": 1.0
}
```

## 限制

- TestLab USB 卷不再导出；PrePI/早期 DXE log 仍只有 UART 或屏幕能看

## 测试

```powershell
.\tools\run-testlab-tests.ps1
```

## 编译

```bash
./tools/build-dagu-uefi.sh   # 自动生成 TestLabFatDisk.bin
```
