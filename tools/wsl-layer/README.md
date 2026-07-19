# WSL 流式交互层

在 Windows 上维护一个**持久化的 WSL bash 会话**，通过本地 TCP 协议接收命令并**流式返回** stdout/stderr。

## 特性

- **持久 shell**：`cd`、环境变量、工作目录在多次命令之间保留
- **流式输出**：长命令（编译、日志）实时输出，不必等进程结束
- **自动拉起**：`run` 时若 daemon 未运行会自动 `start`
- **状态文件**：`.wsl-layer/state.json` 记录 host/port/pid/cwd

## 前置条件

1. 已安装 WSL 与 Linux 发行版（如 Ubuntu）
2. Windows 上可用 `python`（3.10+）
3. `wsl` 命令在 PATH 中

## 配置

仓库根目录 `wsl-layer.json`（可选）：

```json
{
  "host": "127.0.0.1",
  "port": 19627,
  "wsl_distro": "Ubuntu-22.04",
  "wsl_workspace": "~/projects/xiaomi-pad870-win11-arm",
  "initial_cwd": "~/projects/xiaomi-pad870-win11-arm"
}
```

- `wsl_workspace` / `initial_cwd`：WSL 原生目录（**不要用 `/mnt`**）

首次使用前初始化 WSL 构建环境见 [windows-wsl-split.md](../docs/windows-wsl-split.md)：

```powershell
.\tools\bootstrap-wsl-workspace.ps1 -RepoUrl <git-url>
```

## 用法

### PowerShell

```powershell
.\tools\wsl-layer\layer.ps1 start
.\tools\wsl-layer\layer.ps1 status
.\tools\wsl-layer\layer.ps1 run "uname -a"
.\tools\wsl-layer\layer.ps1 run "./tools/build-dagu-uefi.sh"
.\tools\wsl-layer\layer.ps1 cd ~/projects/xiaomi-pad870-win11-arm
.\tools\wsl-layer\layer.ps1 stop
```

### Python CLI

```powershell
python tools/wsl-layer/client.py start
python tools/wsl-layer/client.py run "echo hello && sleep 1 && echo world"
python tools/wsl-layer/client.py run "long command" --json
python tools/wsl-layer/client.py stop
```

## 协议（NDJSON）

客户端向 daemon 发送一行 JSON 请求，daemon 以多行 JSON 事件响应：

**请求**

```json
{"op":"run","command":"uname -a","timeout":null}
{"op":"cd","path":"/mnt/e/Projects/xiaomi-pad870-win11-arm"}
{"op":"ping"}
{"op":"status"}
{"op":"shutdown"}
```

**事件**

```json
{"type":"output","stream":"stdout","data":"Linux ...\n"}
{"type":"done","exit_code":0,"cwd":"/mnt/e/Projects/xiaomi-pad870-win11-arm"}
{"type":"error","message":"..."}
```

## 架构

```
PowerShell / Python client
        │ TCP (127.0.0.1:18765)
        ▼
   daemon.py (Windows Python)
        │ subprocess pipes
        ▼
   wsl -e bash -l  ← 持久会话
```

## 流式输出说明

- 命令默认通过 `script -qfec` 在伪终端中执行，**apt / cmake / ninja** 等工具的进度会实时输出
- 输出按字节块推送，不再等待整行 `\n`（支持 `\r` 进度条）
- 客户端使用 `python -u` + `os.write()`，避免 Cursor/管道场景下的 Python 缓冲
- 每次 `run` 会同步写入 **`.wsl-layer/live.log`**，可在编辑器或另一个终端实时查看：

```powershell
Get-Content -Wait .wsl-layer\live.log
# 或
.\tools\wsl-layer\layer.ps1 logs -f
```

- 含 `sudo` 的命令会先检测 `sudo -n`；若需要密码会**立刻报错**，不会无声卡住
- 管道末端的 `| tail -N` **仍会缓冲**上游输出，这是 `tail` 自身行为；要看实时日志请去掉 `tail`

> **Cursor Agent 限制：** Agent 执行长命令时，聊天窗口可能仍要等命令结束才显示输出。请用上面的 `live.log` 或本地终端 `layer.ps1 run` 查看实时进度。

## 故障排查

- **WSL ping failed**：先 `wsl --install` 或 `wsl -l -v` 确认发行版
- **Timed out waiting for daemon**：查看 `.wsl-layer/daemon.log`
- **sudo 需要密码**：在 WSL 终端执行 `sudo -v` 完成一次认证后再 run
- **端口占用**：修改 `wsl-layer.json` 中的 `port`
