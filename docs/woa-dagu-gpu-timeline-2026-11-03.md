# dagu Windows GPU：进度时间线（2026-11-03）

这份文档只回答两件事：现在停在启动链的哪一步，以及哪一步还没被这次冷启动测量到。细节仍以各阶段文档为准。阶段 21 的问题码 43 已经过去，不是当前的卡点。

截至本文，平板在 Linux（B 槽）。A 槽这一轮没有再启动。下面的分区读数来自最近一次从 fastboot 切回 B 槽之后，本文写作时没有再读盘。

---

## 1. 现在停在哪

**当前位置：垫片已经能在 qcdx 映射完成时打上六处补丁。这份垫片在 Windows 分区上，还没有跑过一次。**

**卡点：上一次冷启动的加载通知把 qcdx 跳过了，六处补丁一处都没写。`StartDevice` 因此停在孔径检查，页表和切帧都没开始。**

上一次冷启动已经走过第 1 到第 5 步。第 6 步的修正已经落在盘上，测量它的那次启动还没做。第 7 步是上一次实际返回的地方，不是还要去找的新故障。

| | 状态 |
|---|---|
| 系统能进用户态 | 已通过。内核是硬链接的 26100.1。黑屏时没有新的蓝屏转储 |
| 面板 | 有背光，没有帧。固件把屏点亮了，Windows 没有把画面送出去 |
| qcdx | Start=3，按需启动。上一次冷启动已加载。映像是诊断版，2908336 字节，`8e77bf1e…`。仓库里的另一份不要换上去 |
| 原版 qcsmmu | Start=4，不加载。它会碰 APPS SMMU `0x15000000`，UFS 启动盘会掉 |
| 垫片 dagusmmu | Start=3。`map` 保持 0，不走实页表，不写 `0x03DA0000` |
| qcif | 上一次已加载。它发布 SCM / TrEE 接口，ioctl 返回 `0xC0000010`。映像加载不等于这些接口已经被 qcdx 打开 |
| 上一次补丁结果 | `qpatch` 仍是 0。当时的通知读错了 `SystemModeImage` 位域 |
| 已装上、还没启动的垫片 | DriverStore `552c40a9`，26288 字节。按文件名 `qcdxkm8250.sys` 匹配；名字为空时再比对映像大小 `0x35b000` |
| A 槽重试 | 上次 `set-active a` 把重试补到 7，随后一次启动变成 6。Windows 不会把 A 槽标成成功 |

---

## 2. 一次冷启动里的步骤

```mermaid
flowchart TD
  s1["1 ABL 把 UEFI 当成内核加载"] --> s2["2 GOP 沿用已点亮的面板"]
  s2 --> s3["3 内核进入用户态"]
  s3 --> s4["4 枚举 QCOM253A，qcdx 加载"]
  s4 --> s5["5 垫片登记加载通知"]
  s5 --> s6["6 加载时打上六处补丁"]
  s6 --> s7["7 孔径检查"]
  s7 --> s8["8 经垫片虚表建页表"]
  s8 --> s9["9 SCM / TrEE 等待"]
  s9 --> s10["10 切帧送到面板"]
  s7 -.->|"上一次没打补丁"| back["返回 0xC0000001<br/>有背光，没有帧"]

  classDef done fill:#d9ead3,stroke:#38761d,color:#000
  classDef stuck fill:#f4cccc,stroke:#990000,color:#000
  classDef returned fill:#fff2cc,stroke:#bf9000,color:#000
  classDef later fill:#f3f3f3,stroke:#666666,color:#000
  class s1,s2,s3,s4,s5 done
  class s6 stuck
  class s7,back returned
  class s8,s9,s10 later
```

绿色是上一次冷启动已经通过的。红色是当前卡点，修正已经在盘上，还没跑。黄色是上一次实际返回的位置。灰色还没被这次冷启动碰到。

| 步 | 发生什么 | 上一次冷启动 | 盘上还没跑的修正 |
|---|---|---|---|
| 1 | ABL 把签过名的 UEFI 当成 Linux 内核加载 | 已通过 | 不改 ABL，不刷 boot |
| 2 | XBL 已经点亮面板。UEFI 的 SimpleFb 把这块帧缓冲交给 GOP | 已通过。ExitBootServices 大约 3.8 秒。源码里的 30 秒 PCIe 停顿不在已经刷进 A 槽的固件里 | 不回退这份 UEFI，也不把当前 SimpleFb 源码刷进去 |
| 3 | 内核进入用户态 | 已通过。0xA、0x6B、0xC0000428 都是版本错位，硬链接成一套 26100.1 之后不再出现 | 不换内核、不换 ntdll |
| 4 | 覆盖表追加 GPU0。PnP 枚举 `ACPI\QCOM253A\0`，qcdx 加载 | 已通过。表里有 `QCOM253A`，没有 `QCOM2509`。`_STA` 返回 `0x0F` | 不重建覆盖表。源码里的 `SupportsSecureInAperture Zero` 不是现用表，现用值是 1 |
| 5 | 垫片 DriverEntry 把 `bootgen` 加 1，清掉上一轮的 `fail` / `ncall` / `qpatch`，再登记加载通知 | 已通过。通知登记成功，所以 `step` 不是 `0x11`。`bootgen=2` 只出现在 `SYSTEM.LOG1` | 同一套登记逻辑还在 |
| 6 | qcdx 映像一映射就写六处，此时 `StartDevice` 还没运行 | **卡在这里。** 位域检查把 qcdx 跳过，`qpatch` 保持 0 | `552c40a9` 不再读位域 |
| 7 | `FUN_14029ba78` 看孔径标志 | 两个条件都成立，返回 `0xC0000001`，后面的调用都没发生 | `0x29baf0` 改成无条件跳过。还没被测量 |
| 8 | `FUN_14029b168` 建显示页表和最多 8 份引擎页表，经 `FUN_1402aa7e0` 调垫片虚表 | 未到。页表函数的唯一调用者就是第 7 步那个函数 | `map` 仍是 0 |
| 9 | `FUN_14029ac00` 等 SCM，`FUN_14029ae70` 等 TrEE，然后做版本查询 | 未到。这两次等待排在孔径检查和页表循环之后 | 超时改成 0，版本状态改成 `0xC0000001` |
| 10 | `ActivatePageTableDisplay` / `ForceSeamlessBootTransition` 把帧送进已经点亮的面板 | 未到 | 只有 `qpatch=0x3F` 而屏幕仍黑，才轮到这里 |

### 2.1 第 6 步和第 7 步怎么连在一起

加载顺序是垫片、qcif、qcdx。垫片先登记通知。qcdx 被映射时通知先跑，qcdx 自己的 `DriverEntry` 和更后面的 `StartDevice` 都还没开始。所以上一次不是「补丁打晚了」，而是「补丁函数没被叫到」。

```mermaid
flowchart TD
  entry["5 垫片 DriverEntry<br/>step 0x10"] --> gen["bootgen 加 1，清掉旧的 qpatch"]
  gen --> arm["PsSetLoadImageNotifyRoutine"]
  arm --> map["qcdx 映像映射，StartDevice 尚未开始"]
  map --> old{"上一次的通知"}
  old -->|"SystemModeImage 读出来始终像 0"| skip["直接返回<br/>qpatch 保持 0"]
  skip --> chk["7 FUN_14029ba78"]
  chk --> flag{"SupportsSecureInAperture 为 1<br/>且任一上下文 +0x40 为 1"}
  flag -->|"上一次两个都成立"| ret["返回 0xC0000001<br/>有背光，没有帧"]

  map --> now{"552c40a9，还没启动"}
  now -->|"名字以 qcdxkm8250.sys 结尾"| hit["进入 PatchQcdx"]
  now -->|"名字为空且映像大小是 0x35b000"| hit
  now -->|"其他映像"| ignore["忽略"]
  hit --> mask{"六处期望字节都对上"}
  mask -->|"mask = 0x3F，step 0x65"| pass["无条件跳过孔径检查"]
  mask -->|"有对不上的，step 0x64"| bad["qpatch 不是 0x3F"]
  pass --> pt["8 建页表"]
  pt --> scm["9 SCM / TrEE"]
  scm --> frame["10 切帧"]

  classDef done fill:#d9ead3,stroke:#38761d,color:#000
  classDef stuck fill:#f4cccc,stroke:#990000,color:#000
  classDef returned fill:#fff2cc,stroke:#bf9000,color:#000
  classDef later fill:#f3f3f3,stroke:#666666,color:#000
  class entry,gen,arm,map done
  class old,skip,now,hit stuck
  class chk,flag,ret returned
  class mask,pass,pt,scm,frame,bad later
```

`FUN_14029ba78` 内部的顺序是固定的。孔径检查在页表之前，SCM / TrEE 又在页表之后：

```mermaid
flowchart TD
  a["空指针检查"] --> b["FUN_1402aa240"]
  b --> c{"孔径检查 0x29baf0"}
  c -->|"上一次：标志已是 1"| dead["返回 0xC0000001"]
  c -->|"补丁之后：总是跳过"| d["CreatePageTableDisplay"]
  d --> e["CreatePageTableEngine，最多 8 次"]
  e --> f["可选的区间描述"]
  f --> g["FUN_14029ac00 等 SCM"]
  g --> h["FUN_14029ae70 等 TrEE"]
  h --> i["ActivatePageTableDisplay"]

  classDef returned fill:#fff2cc,stroke:#bf9000,color:#000
  classDef later fill:#f3f3f3,stroke:#666666,color:#000
  class c,dead returned
  class d,e,f,g,h,i later
```

孔径检查读的是适配器 `+0x422c`，以及 `+0xc50`、`+0x4070` 两个上下文对象各自的 `+0x40`。`+0x422c` 来自现用 `_DSD` 的 `SupportsSecureInAperture`，值是 1。两个 `+0x40` 在冷启动时已经是 1，那是固件 GOP 留下的孔径。页表函数 `FUN_14029b168` 的唯一调用者就是这个函数，所以槽回调不可能发生在这次返回之前。等第一次槽回调再打补丁，时间已经晚了。

### 2.2 六处补丁各自改什么

诊断映像的这六个字在盘上仍是期望值，补丁只写被映射进内存的那份，不改文件。

| 位 | RVA | 期望 | 改成 | 作用 |
|---|---|---|---|---|
| 0 | `0x29baf0` | `CBZ w8`，`0x34000248` | 无条件分支 `0x14000012`，目标仍是 `0x14029bb38` | 跳过孔径失败返回 |
| 1 | `0x29aca0` | `mov w2, #30000` | `mov w2, #0` | SCM 等待的超时 |
| 2 | `0x29af10` | `mov w2, #30000` | `mov w2, #0` | 另一处 30 秒等待 |
| 3 | `0x29afc4` | `mov w2, #30000` | `mov w2, #0` | 另一处 30 秒等待 |
| 4 | `0x29b070` | `mov w2, #1000` | `mov w2, #0` | 1 秒等待 |
| 5 | `0x27a420` | 立即数 `0xC0000010` | `0xC0000001` | 两次版本 ioctl 共用的比较值 |

六位全写上时 `qpatch` 是 `0x3F`，`step` 写成 `0x65`。少一位就是 `0x64`，并把「已经补过」的标志清掉。

超时改成 0 的依据是 `FUN_140284e38`：超时参数为 0 时它不调用 `KeWaitForSingleObject`，直接返回成功。接口到达回调只把打开设备的工作项排队，不会在注册通知的当时把设备对象填上。紧接着的 `FUN_140009358` 看见 `+0x28` 仍是空，返回 `0xC0000001`。`FUN_14027a130` 把这个状态装进 `w25` 比较两次；对上之后走驱动自己的「版本未实现，继续」，`StartDevice` 不拿 SCM 函数表也能往下走。

页表创建走 `FUN_1402aa7e0`，它调用的是垫片虚表，不是自己映射 SMMU 寄存器。`map` 保持 0，所以没有实页表遍历，也不写 APPS SMMU。

### 2.3 上一次冷启动实际留下的数

启动日志头是 `11  3 2026 05:56:27.639`。这是停住的 Windows 时钟，不是墙上时间。加载顺序是 `dagu-smmushim.sys`、`dagu-qcif.sys`、`qcdxkm8250.sys`，然后是 BasicDisplay。`qcsmmu8250.sys` 没有加载。屏幕是有背光的黑屏。A 槽重试从 7 减到 6，没有崩溃循环。

| 读数 | 主配置单元 | `SYSTEM.LOG1` | 怎么用 |
|---|---|---|---|
| 序号 | 7394 / 7393，单元被 fastboot 截断 | 日志头仍是 7393 / 7393 | 主单元和日志不要混成同一次写入 |
| `bootgen` | 1，和启动前修好的那份一样 | 有两处写成 2 | 2 说明新垫片的 DriverEntry 跑过 |
| `qpatch` | 0 | 这个值名不在日志里 | 这次启动没有写下补丁掩码 |
| `step` | `0x30` | 里面还有更早的 `0x64` / `0x40` | 主单元的 `0x30` 是截断前的旧值，表示接口已启用 |
| DSDT | 六段都在，39269 字节，校验和 0 |  | `QCOM253A` 在，`QCOM2509` 不在 |
| QCDX | Start=3，Type=1，ErrorControl=0 |  | 诊断映像路径还在 |

`0x30` 只表示三个设备接口注册并启用了。它不表示 qcdx 已经查询过接口，也不表示补丁写过。槽回调会把 `step` 刷到 `0x60`。上一次主单元里看不到这次启动新写的 `0x60` 或 `0x65`。

---

## 3. 历史时间线

```mermaid
flowchart LR
  a["10-29 至 10-30<br/>认到 QCOM253A"] --> b["10-31 上午<br/>补 ENGS / PMCL"]
  b --> c["10-31<br/>QCOM2509 拆掉启动盘"]
  c --> d["10-31 下午<br/>活页表会复位"]
  d --> e["11-02<br/>垫片回答接口"]
  e --> f["11-02 夜<br/>用户态和可见桌面"]
  f --> g["11-03<br/>冷启动有背光无帧"]
  g --> h["现在<br/>补丁已装，未启动"]

  classDef past fill:#d9ead3,stroke:#38761d,color:#000
  classDef now fill:#f4cccc,stroke:#990000,color:#000
  class a,b,c,d,e,f,g past
  class h now
```

### 10 月 29–30 日：让驱动认到这块 GPU

| 日期 | 阶段 | 结果 |
|---|---|---|
| 10-29 | 0 | 注册表覆盖表能枚举测试设备。qcdx 的依赖表列出来了 |
| 10-29 | 1–2 | 第一版 PEP 直接蓝屏。`SOSI` 被编成 4 字节会变成 `0x1A`。全仓只有 `QCOM253A` 有显示驱动，据此做了 GPU0 |
| 10-30 | 3–4 | PEP 用的 HID 没有 INF。装上 `QCOM253A` 后设备显示成 Adreno 640，启动卡在 qcdx 加载之后，没有转储 |
| 10-30 | 5–7 | PEP 实验 A/B/C 没把这次卡死解释掉。处理器空闲门控在当前开关下不注册 |

### 10 月 30–31 日：补 ACPI，并确认原版 SMMU 不能加载

| 日期 | 阶段 | 结果 |
|---|---|---|
| 10-30 | 8 | 补上 `ENGS` / `RESI` / `TMDT`。没有 `GmuInternal` 和 `GpuInternal`，初始化会直接返回 |
| 10-31 | 9 | 补上 `PMCL` / `_HRV`。当时还没上板 |
| 10-31 | 10、12 | 覆盖表里一旦出现 `QCOM2509`，原版 qcsmmu 会在启动早期拆掉 UFS。覆盖表从此只留 GPU0 |
| 10-31 | 11、15 | 运行时拉起能进 qcdx。缺 `REGR` 时是空指针；补上之后开始等 SMMU 设备接口 |
| 10-31 | 13 | UEFI 给 GPU CX 上电，大核调频修好 |
| 10-31 | 14–19 | Adreno SMMU 多数寄存器可以从 HLOS 写。原版 qcsmmu 的活页表遍历会经 QHEE 整机复位。`map` 因此保持 0 |

### 11 月 2 日：垫片代替 qcsmmu，用户态恢复

| 时间 | 阶段 | 结果 |
|---|---|---|
| 白天 | 20 | 垫片注册 GPU、显示、视频三个设备接口，查询缓冲 `0x1A0`，版本 2。不映射 `0x15000000`。运行时拉起收到槽回调，随后在高 IRQL 上空指针。当时 `QCDX` 被留在 Start=3 |
| 晚间 | 21 | 第 25 槽改成交回子区间对象，不再把内核地址当成区间长度。运行时重启后问题码 43 消失：`subok=1`，`suboff=0x9C000000`，`subsz=0xFA0000`（1600×2560×4），`ncall=160`，`step=0x60`。那次没有做冷启动验证 |
| 夜里 | 启动链 | 旧 ESP 引导文件、内核 26100.9457、ntdll 和内核不是同一套，先后挡住用户态。硬链接成一套 26100.1 之后能进桌面。那次桌面可见时，垫片收到过槽回调 |

阶段 21 的运行时成功和后来的冷启动黑屏不矛盾。运行时拉起时孔径路径已经走过，或者当时的标志没有在 `StartDevice` 入口把函数打回去。冷启动时 GOP 把 `+0x40` 留成 1，未打补丁的 `FUN_14029ba78` 在任何槽回调之前返回。

### 11 月 3 日：冷启动变成有背光的黑屏

| 顺序 | 做了什么 | 读到什么 |
|---|---|---|
| 1 | 去掉 UEFI 里 30 秒 PCIe 停顿 | ExitBootServices 大约 3.8 秒。画面问题还在。A 槽上的 UEFI 是 `f1d11953…`，这次不刷 |
| 2 | 垫片每次启动写 `bootgen`，并清掉上一轮的 `fail` / `ncall` / `qpatch` | 用来把旧的 `fail=0xC0000001`、`ncall=58` 和这一代分开。那份只做记号的垫片是 25264 字节，`14e32bb8…` |
| 3 | 一次 A 槽冷启动 | qcdx 没出现在 `05:56:17` 那段启动日志里。覆盖表被截成第一段，配置单元序号也不一致 |
| 4 | 从 `SYSTEM.bak-qcdx4` 把六段 DSDT 和 QCDX Start=3 接回去 | 表长 39269，校验和 0。下一次启动重新加载 qcdx |
| 5 | 加载通知里打六处补丁，再冷启动一次。跑的是 `bf010d25…` | 日志头 `05:56:27`。qcdx 已加载。屏幕有背光、没有帧。`bootgen` 只在日志里变成 2。`qpatch` 仍是 0 |
| 6 | 反编译孔径检查、等待函数、版本查询和页表调用 | 六处期望字节保持不动。上一轮没打上，是因为 `IMAGE_INFO` 的位域布局和通知实际读取的不一致 |
| 7 | `552c40a9` 写入 DriverStore | **还没有启动。** 之后只改了源码注释，二进制没有为注释重编 |

---

## 4. 已经有结论、先不要再动

- 黑屏时机器停在用户态，不是蓝屏，也不是 26100.1 这套文件的版本错位。
- 背光已经亮着。Linux 下把亮度从 400 调到 1500 只解释 Linux 自己的暗屏。
- A 槽里的 UEFI 已经没有 30 秒 PCIe 停顿。当前仓库里的 SimpleFb 源码和刷进去的那份不是同一份，现在不刷。
- 原版 qcsmmu、PEP、`map=1`、活页表遍历会拆启动盘或经 QHEE 复位。这一步用垫片代替它们。
- Zap、GX、面板 `_ROM` / `PCFG` 仍延后。第 6 步还没测过。
- `QCDX` 保持 Start=3。运行中把它改成 4，PnP 会停掉已经起来的设备。qcdx 还在跑时不要停垫片。

---

## 5. 下一次启动要看的数

只在决定测量第 6 步时再切 A 槽。A 槽重试现在是 6，Windows 不会把这一槽标成成功。要看的是这一代垫片自己写下的值。主配置单元如果再次出现序号不一致，以含有新 `bootgen` 的那一侧为准。

```mermaid
flowchart TD
  boot["下一次冷启动<br/>期望 bootgen = 3"] --> gen{"bootgen"}
  gen -->|"仍是 2，或主单元里找不到新值"| old["552c40a9 的 DriverEntry 没跑到"]
  gen -->|"3"| step{"step"}
  step -->|"0x11"| noreg["加载通知登记失败"]
  step -->|"0x30，且没有 qpatch"| nopatch["通知跑了，但没进入 PatchQcdx"]
  step -->|"0x64"| bytes["六处里有期望字节对不上<br/>看 qpatch 哪一位是 0"]
  step -->|"0x65"| patch{"qpatch"}
  patch -->|"0x3F"| screen{"屏幕"}
  patch -->|"其他"| bits["step 和掩码不一致，先重读单元"]
  screen -->|"有帧"| ok["第 10 步通过"]
  screen -->|"仍是有背光的黑屏"| frame["补丁已经生效<br/>卡点移到切帧"]

  classDef now fill:#f4cccc,stroke:#990000,color:#000
  classDef next fill:#fff2cc,stroke:#bf9000,color:#000
  classDef ok fill:#d9ead3,stroke:#38761d,color:#000
  class boot now
  class gen,step,patch,screen next
  class ok ok
```

| 项 | 第 6 步打上了 | 还停在上一次 |
|---|---|---|
| `bootgen` | 3 | 2，或主单元仍是 1 而日志里没有 3 |
| `qpatch` | `0x3F`，六位全 1 | 0。加载通知仍没匹配到这份 qcdx |
| `step` | `0x65` | `0x64` 是期望字节不对；`0x30` 是只启用了接口；`0x11` 是通知没登记上 |
| `ncall` | 这一代从 0 重新计。非 0 说明孔径检查之后真的进了槽回调 | 0，同时 `qpatch` 也是 0：回调和补丁都没发生 |
| 屏幕 | 有帧则第 10 步通过 | `qpatch=0x3F` 仍是有背光的黑屏，才去看 `ActivatePageTableDisplay` |

`qpatch` 到了 `0x3F` 之前，不改 GOP，不刷 UEFI，不把 `map` 设成 1。
