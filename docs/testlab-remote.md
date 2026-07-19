# TestLab USB v2 Boot Log

Type-C 连接即可读取 UEFI 启动日志（无需 USB-TTL）。固件在 UEFI 显示稳定后延迟启动 USB Mass Storage，PC 轮询 `TESTLAB` 卷中的文件。

## 协议 (v2)

| 文件 | 说明 |
|------|------|
| `TESTLAB/BOOT.LOG` | 全量文本日志（ConOut 镜像） |
| `TESTLAB/BOOT.SEQ` | 递增序号，PC 用来 poll 新内容 |
| `TESTLAB/STATUS.JSON` | `{"seq":N,"usb":"waiting|ready|failed","bridge":"v2"}` |
| `TESTLAB/COMMAND.IN` | 可选：PC 写 Shell 命令 |
| `TESTLAB/COMMAND.ACK` | 命令执行结果 |

## 固件

- `TestLabBridgeDxe` v3：RAM FAT，**ReadyToBoot 后**再启动（不干扰 SimpleInit 显示）
- **默认不**替换 `gST->ConOut`、**不**自动 USB MSC；Type-C 导出需 `COMMAND.IN` 写 `usb-on` 或 SimpleInit 菜单

## PC 用法

```powershell
# 检查 TESTLAB 盘符是否已挂载
.\tools\test-lab\lab.ps1 usb-log preflight

# 实时查看 + 落盘
.\tools\test-lab\lab.ps1 usb-log watch --log logs\test-lab\boot.log

# 链式引导 + 自动抓 USB log（推荐）
.\tools\test-lab\lab.ps1 test-uefi -AttachUsb

# USB + UART 双通道
.\tools\test-lab\lab.ps1 test-uefi -AttachUsb -AttachSerial -SerialPort COM5
```

`test-lab.json`：

```json
{
  "usb_log_timeout_sec": 120,
  "usb_log_poll_sec": 1.0
}
```

## 限制

- USB MSC 在 UEFI 启动约 **30 秒** 后才挂载；`test-uefi -AttachUsb` 默认等待 60s
- TestLabBridge 加载 **之前** 的 PrePI/早期 DXE log 仍只有 UART 能抓

## 测试

```powershell
.\tools\run-testlab-tests.ps1
```

## 编译

```bash
./tools/build-dagu-uefi.sh   # 自动生成 TestLabFatDisk.bin
```
