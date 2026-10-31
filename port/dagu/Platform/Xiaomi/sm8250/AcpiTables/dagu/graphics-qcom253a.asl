// =============================================================================
// dagu GPU 节点 —— 高通 MTP 单体模型 (QCOM253A)
// =============================================================================
//
// 背景（阶段 2 结论，见 docs/woa-dagu-gpu-stage2-2026-10-30.md）：
//
// 仓库里实际存在的 GPU 驱动是 winarm/drivers/QC8250/Drivers/Graphics/DXKM/
// qcdx8250.inf，它只绑定一个硬件 ID：ACPI\VEN_QCOM&DEV_253A（及若干 REV_ 变体）。
// 这是高通 MTP 的“单体式”GPU 模型：一个 QCOM253A 节点的 _CRS 里同时声明
// 显示(MDSS)、视频(Venus)、GPU 时钟(GPU_CC)、GMU、GPU SMMU 的全部 MMIO。
//
// dagu 现有的 graphics.asl / display.asl / venus.asl 走的是另一套“社区分离式”
// HID（QCOM24B4 GPU、QCOM24B9 GMU、QCOM24B5 MDSS、QCOM24B8 Venus ……）。
// 经全仓库 INF 扫描确认：这些分离式 HID 没有任何驱动 INF 绑定，所以用它们时
// 设备会枚举出来但永远停在“无驱动”。要让仓库自带的 qcdx8250 驱动能加载，
// GPU 节点的 _HID 必须是 QCOM253A。
//
// 地址来源：参考板 qcom-mtp8250 的 QCOM253A 节点 _CRS（BBUF 分支）。dagu 与
// MTP8250 同为 SM8250，下列 11 段 MMIO 与 dagu 的 PlatformMemoryMapLib 逐一吻合
// （MDSS 0x0AE00000、Venus 0x0AA00000、GPU_CC 0x02C90000 等）。参考 _CRS 用
// \_SB.SIDV 在 ABUF/BBUF 间二选一；dagu live 的 SIDV=0x00020000，SIDV<0x20000
// 为假，本就返回 BBUF，故此处直接固定为 BBUF，省去无用分支。
//
// -----------------------------------------------------------------------------
// 阶段 8（见 docs/woa-dagu-gpu-stage8-2026-10-30.md）：补上 RESI / ENGS / TMDT
// -----------------------------------------------------------------------------
// 阶段 4 的现象是驱动能绑定、但加载时 Windows 启动挂死（无 dump）。阶段 8 逆向
// qcdxkm8250.sys 找到一个在当时必然失败的启动门控：FUN_1402b4be0 会遍历一张命名
// 内存区表，必须同时找到 "GmuInternal" 和 "GpuInternal"，缺任何一个就打日志
// （0xe5f / 0xe71）并失败返回。这两个名字由 FUN_14029b168 从 ACPI 的
// GraphicsGlobalPT / GraphicsGmuPT 条目翻译而来，而这些条目来自本节点的
// ENGS 方法（FUN_14025f0b0 解析其中的 "ENGINES" 包）。
//
// 注意这是“必要条件缺失”，不等于已经解释了阶段 4 的挂死：门控本身是打日志后
// 失败返回，而阶段 4 看到的是无蓝屏无 dump 的硬卡死，两者未必是同一现象。补齐
// ENGS 之后仍可能卡在别处（例如寄存器块未上电）。
//
// 本文件此前只有 _HID/_UID/_CLS/MON0/_STA/_CRS，没有 ENGS，驱动拿到零个引擎、
// 零张页表，必然过不了上述门控。阶段 8 从参考板移植三个方法：
//
//   RESI  给 _CRS 的 15 段资源按顺序命名（GFX_REGS / GPU_CC / MDP_REGS ...）。
//         参考板有 AINF/BINF 两份按 SIDV 二选一，实测两份内容逐字节相同，
//         dagu 固定走 BINF，所以这里只留一份并命名 RBUF。
//   ENGS  引擎表。含 5 个 ENGINE（GRAPHICS/MDPBLT/ROTATOR/VIDEO/CRYPTO）、
//         DISPLAYS、RESOURCES 和 13 项 PAGETABLES。门控需要的名字出自这里。
//   TMDT  热域表，把 GRAPHICS/MDPBLT/ROTATOR 归到 GPU 域。
//
// 三个方法从 qcom-mtp8250 DSDT.dsl 原样移植，编译后反编译与参考板逐字节相同，
// 没有任何外部对象引用（ENGS/TMDT 本就没有，RESI 的 \_SB.SIDV 分支已去掉）。
//
// 阶段 9（见 docs/woa-dagu-gpu-stage9-2026-10-31.md）：PMCL + _HRV + _IDT 也已移植。
//   PMCL 是参考板约一万行的电源/时钟部件模型，驱动过了阶段 8 的门控后读它，给 GPU/
//   显示各部件建立 F-state / P-state 电源模型。整段只引用 \_SB.SIDT/SIDV/SOID（dagu
//   的 dsdt_common.asl 已定义这三个占位符），原样照搬不改名。
//   _HRV 由 SIDT/SIDV/SOID/SDFE 算出 Adreno 650 的 REV id；_IDT 是 SIDT 的别名。
//   三者连同既有节点一起离线 iasl 编译：0 error 0 warning（42 条 _HRV 的 remark 无害）。
// 仍未移植：_ROM/PCFG 面板表（dagu 面板是 L81A 1600x2560，与参考板 Sharp 面板不同，
//   属扫描输出/点屏，不影响驱动绑定与初始化）、_DEP（参考里还依赖 dagu 没有的 IMM0/
//   PILC/RPEN/TREE/SCM0 等节点）。
//
// 相对参考节点做的裁剪：
//   - 去掉 9923 行面板配置 blob（_ROM/_DOD/_LID/AVS0（_HRV 已在阶段 9 移植）），那是面板点亮逻辑，
//     与“驱动能否绑定”无关，且引用大量 dagu 不存在的对象。
//   - 去掉 _DEP（参考里依赖 MMU0/MMU1/IMM0/PEP0/SCM0/TREE 等节点）。SMMU 侧
//     已在 smmu.asl 对齐参考板 HID 并启用，但 _DEP 暂不恢复，避免悬空引用。
//
// 另注：GPU 驱动运行时会打开 \Device\QCOM_PEPDriver。阶段 8 确认这条不是致命
// 依赖：FUN_1402b9f20 打开失败时只置标志位 0x1800000000 后返回 void，调用方
// 不检查返回值。所以 PEP 的 0x101 不阻塞 GPU 驱动初始化。
//
// 状态：离线 iasl 编译通过，0 error 0 warning。板上未验证。
// 两套模型互斥：启用本文件时必须停用 graphics.asl 里的 GPU0/GMU0。
// =============================================================================
Device (GPU0)
{
    Name (_HID, "QCOM253A")  // 高通 MTP 单体 GPU/显示/视频驱动绑定点（qcdx8250.inf）
    Name (_UID, Zero)
    Alias (\_SB.SIDT, _IDT)  // 阶段9：芯片 ID 表别名（SIDT 由固件启动时按 ChipInfo 填入）
    Name (_CLS, Package (0x03) { 0x03, 0x00, 0x00 })  // PCI 类码：显示控制器

    Device (MON0)
    {
        Method (_ADR, 0, NotSerialized)
        {
            Return (Zero)
        }
    }

    Method (_STA, 0, NotSerialized)
    {
        Return (0x0F)
    }

    Method (_CRS, 0, NotSerialized)
    {
        Name (BBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0AE00000, 0x00140000)  // MDSS 显示控制器
            Memory32Fixed (ReadWrite, 0x088E0000, 0x000F4000)  // MDP throttle
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, ,, ) { 0x00000073 }
            Memory32Fixed (ReadWrite, 0x02C00000, 0x0003F010)  // GMU
            Memory32Fixed (ReadWrite, 0x02C60000, 0x0003F000)  // GMU PDC
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, ,, ) { 0x0000014C }
            Memory32Fixed (ReadWrite, 0x0B290000, 0x0000FFFF)  // GPU SMMU
            Memory32Fixed (ReadWrite, 0x0B490000, 0x00010000)
            Memory32Fixed (ReadWrite, 0x02C90000, 0x00009000)  // GPU_CC
            Memory32Fixed (ReadWrite, 0x0C200000, 0x0000FFFF)
            Memory32Fixed (ReadWrite, 0x0AA00000, 0x00200000)  // Venus 视频编解码
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, ,, ) { 0x000000CE }
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, ,, ) { 0x000000CF }
            GpioIo (Exclusive, PullUp, 0x0000, 0x0000, IoRestrictionNone,
                "\\_SB.GIO0", 0x00, ResourceConsumer, , ) { 0x0007 }
            GpioIo (Exclusive, PullUp, 0x0000, 0x0000, IoRestrictionNone,
                "\\_SB.GIO0", 0x00, ResourceConsumer, , ) { 0x0006 }
        })
        Return (BBUF)
    }

    // -------------------------------------------------------------------------
    // RESI —— 给 _CRS 里的资源按顺序命名（阶段 8 新增）
    //
    // qcdxkm8250.sys 用 "RESOURCE" 关键字解析这张表，把 _CRS 的第 N 段资源和一个
    // 名字（GFX_REGS / GPU_CC / MDP_REGS ...）以及一个引擎（GRAPHICS / DISPLAY /
    // VIDEO）关联起来。顺序必须和 _CRS 的返回顺序逐项对应。
    //
    // 参考板 qcom-mtp8250 的 RESI 有 AINF/BINF 两份，按 \_SB.SIDV 二选一。实测两
    // 份内容除包名外逐字节相同，且 dagu live SIDV=0x00020000 固定走 BINF，所以这
    // 里只保留一份并命名 RBUF。
    // -------------------------------------------------------------------------
    Method (RESI, 0, NotSerialized)
    {
        Name (RBUF, Package (0x11)
        {
            0x03,
            Zero,
            Package (0x03)
            {
                "RESOURCE",
                "MDP_REGS",
                "DISPLAY"
            },

            Package (0x03)
            {
                "RESOURCE",
                "DP_PHY_REGS",
                "DISPLAY"
            },

            Package (0x03)
            {
                "RESOURCE",
                "VSYNC_INTERRUPT",
                "DISPLAY"
            },

            Package (0x03)
            {
                "RESOURCE",
                "GFX_REGS",
                "GRAPHICS"
            },

            Package (0x03)
            {
                "RESOURCE",
                "GFX_REG_CONT",
                "GRAPHICS"
            },

            Package (0x03)
            {
                "RESOURCE",
                "GFX_INTERRUPT",
                "GRAPHICS"
            },

            Package (0x03)
            {
                "RESOURCE",
                "GPU_PDC_SEQ_MEM",
                "GRAPHICS"
            },

            Package (0x03)
            {
                "RESOURCE",
                "GPU_PDC_REGS",
                "GRAPHICS"
            },

            Package (0x03)
            {
                "RESOURCE",
                "GPU_CC",
                "GRAPHICS"
            },

            Package (0x03)
            {
                "RESOURCE",
                "GPU_RPMH_CPRF",
                "GRAPHICS"
            },

            Package (0x03)
            {
                "RESOURCE",
                "VIDEO_REGS",
                "VIDEO"
            },

            Package (0x03)
            {
                "RESOURCE",
                "VIDC_INTERRUPT",
                "VIDEO"
            },

            Package (0x03)
            {
                "RESOURCE",
                "VIDC_WD_INTERRUPT",
                "VIDEO"
            },

            Package (0x03)
            {
                "RESOURCE",
                "DSI_PANEL_RESET",
                "DISPLAY"
            },

            Package (0x03)
            {
                "RESOURCE",
                "DSI_PANEL_MODE_SELECT",
                "DISPLAY"
            }
        })
        Return (RBUF)
    }

    // -------------------------------------------------------------------------
    // ENGS —— 引擎与页表描述（阶段 8 新增，本阶段的关键改动）
    //
    // 静态分析确认这是 qcdxkm8250.sys 启动路径上的一个必需输入，证据见
    // docs/woa-dagu-gpu-stage8-2026-10-30.md：
    //
    //   FUN_14025f0b0 查 "ENGINES" 包，逐个引擎解析
    //     -> FUN_14029b168 读 "PAGETABLEUSAGE"，把 ASL 里的页表名翻译成内部区名：
    //          GraphicsGlobalPT -> GpuInternal
    //          GraphicsGmuPT    -> GmuInternal / GmuCached
    //     -> FUN_1402b4be0 启动门控遍历这些区名，GmuInternal 或 GpuInternal 缺一个
    //        就打日志（0xe5f / 0xe71）并失败返回。
    //
    // 本文件此前没有 ENGS，驱动拿到零个引擎、零张页表，这条门控必然失败。
    // 阶段 4 真机现象是 Windows 停在启动阶段、ntbtlog 最后一条是 qcdxkm8250.sys，
    // 且没有 dump。门控是「打日志后失败返回」而不是挂死，所以这里只能说缺 ENGS
    // 一定过不了门控，不能断定阶段 4 的挂死就是门控造成的——两者的关系未验证。
    //
    // 原样照搬参考板，不做裁剪：门控比对的是字面名字，改名字就失配。五个引擎
    // （GRAPHICS / MDPBLT / ROTATOR / VIDEO / CRYPTO）、七个 DISPLAY、13 张页表
    // 全部保留。每个引擎的 MMUINFO 都声明 ArmSmmuV2，所以 smmu.asl 一起启用。
    // -------------------------------------------------------------------------
    Method (ENGS, 0, NotSerialized)
    {
        Name (EBUF, Package (0x06)
        {
            0x03,
            0x02,
            0x0048002B,
            Package (0x07)
            {
                "ENGINES",
                0x05,
                Package (0x0A)
                {
                    "ENGINE",
                    "GRAPHICS",
                    "Adreno6X",
                    One,
                    One,
                    Zero,
                    Package (0x0B)
                    {
                        "MMUINFO",
                        "Miniport",
                        "ArmSmmuV2",
                        0x02,
                        0x31,
                        "V8L",
                        "SMMUID",
                        ToUUID ("9833c712-3292-4ffb-b0f4-2bd20e1f7f66") /* Unknown UUID */,
                        "SMMUINTERFACEID",
                        Buffer (0x10)
                        {
                            /* 0000 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ........
                            /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   // ........
                        },

                        Package (0x0E)
                        {
                            "PAGETABLEUSAGE",
                            0x04,
                            "GraphicsGlobalPT",
                            Zero,
                            0x03030000,
                            "GraphicsPerProcessPT",
                            Zero,
                            0x03030000,
                            "GraphicsSecurePT",
                            One,
                            0x030A0000,
                            "GraphicsGmuPT",
                            0x03,
                            0x03030008
                        }
                    },

                    Package (0x03)
                    {
                        "PERF_CONTROLS",
                        Package (0x02)
                        {
                            0x02,
                            Package (0x02)
                            {
                                "LimitForPassiveCooling",
                                One
                            }
                        },

                        Package (0x02)
                        {
                            0x03,
                            Package (0x02)
                            {
                                "LimitForPassiveCooling",
                                One
                            }
                        }
                    },

                    Package (0x02)
                    {
                        "THERMAL_DOMAINS",
                        "GPU"
                    },

                    Package (0x05)
                    {
                        "PROPERTIES",
                        0x03,
                        Package (0x02)
                        {
                            "GmemBaseAddr",
                            Zero
                        },

                        Package (0x02)
                        {
                            "GmemSize",
                            0x00100000
                        },

                        Package (0x02)
                        {
                            "SMMUCount",
                            One
                        }
                    }
                },

                Package (0x09)
                {
                    "ENGINE",
                    "MDPBLT",
                    "MDP5.x",
                    0x02,
                    One,
                    Zero,
                    Package (0x02)
                    {
                        "SHAREDSMMU",
                        "ROTATOR"
                    },

                    Package (0x03)
                    {
                        "PERF_CONTROLS",
                        Package (0x02)
                        {
                            0x02,
                            Package (0x02)
                            {
                                "LimitForPassiveCooling",
                                One
                            }
                        },

                        Package (0x02)
                        {
                            0x03,
                            Package (0x02)
                            {
                                "LimitForPassiveCooling",
                                One
                            }
                        }
                    },

                    Package (0x02)
                    {
                        "THERMAL_DOMAINS",
                        "GPU"
                    }
                },

                Package (0x09)
                {
                    "ENGINE",
                    "ROTATOR",
                    "MDP5.x",
                    0x03,
                    One,
                    Zero,
                    Package (0x0B)
                    {
                        "MMUINFO",
                        "Miniport",
                        "ArmSmmuV2",
                        0x02,
                        0x20,
                        "V8L",
                        "SMMUID",
                        ToUUID ("36079ae4-78e8-452d-af50-0cff78b2f1ca") /* Unknown UUID */,
                        "SMMUINTERFACEID",
                        Buffer (0x10)
                        {
                            /* 0000 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ........
                            /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   // ........
                        },

                        Package (0x04)
                        {
                            "PAGETABLEUSAGE",
                            0x02,
                            "MdpNonSecurePT",
                            "MdpSecurePT"
                        }
                    },

                    Package (0x03)
                    {
                        "PERF_CONTROLS",
                        Package (0x02)
                        {
                            0x02,
                            Package (0x02)
                            {
                                "LimitForPassiveCooling",
                                One
                            }
                        },

                        Package (0x02)
                        {
                            0x03,
                            Package (0x02)
                            {
                                "LimitForPassiveCooling",
                                One
                            }
                        }
                    },

                    Package (0x02)
                    {
                        "THERMAL_DOMAINS",
                        "GPU"
                    }
                },

                Package (0x0A)
                {
                    "ENGINE",
                    "VIDEO",
                    "Venus",
                    0x04,
                    One,
                    Zero,
                    Package (0x0B)
                    {
                        "MMUINFO",
                        "Engine",
                        "ArmSmmuV2",
                        0x02,
                        0x20,
                        "V8L",
                        "SMMUID",
                        ToUUID ("665e0f8e-add3-49d1-91bc-5540c5f57fba") /* Unknown UUID */,
                        "SMMUINTERFACEID",
                        ToUUID ("1c3fc0e8-0b11-4ee0-be89-3e21420a865f") /* Unknown UUID */,
                        Package (0x07)
                        {
                            "PAGETABLEUSAGE",
                            0x05,
                            "VideoNonSecurePT",
                            "VideoSecurePT1",
                            "VideoSecurePT2",
                            "VideoSecurePT3",
                            "VideoSecurePT4"
                        }
                    },

                    Package (0x05)
                    {
                        "PERF_CONTROLS",
                        Package (0x01)
                        {
                            0x02
                        },

                        Package (0x01)
                        {
                            0x03
                        },

                        Package (0x01)
                        {
                            0x04
                        },

                        Package (0x01)
                        {
                            0x05
                        }
                    },

                    Package (0x01)
                    {
                        "THERMAL_DOMAINS"
                    },

                    Package (0x03)
                    {
                        "PROPERTIES",
                        One,
                        Package (0x02)
                        {
                            "DecMaxFps",
                            0x3C
                        }
                    }
                },

                Package (0x09)
                {
                    "ENGINE",
                    "CRYPTO",
                    "Crypto1.0",
                    0x05,
                    One,
                    Zero,
                    Package (0x0B)
                    {
                        "MMUINFO",
                        "Miniport",
                        "ArmSmmuV2",
                        0x02,
                        0x20,
                        "V8L",
                        "SMMUID",
                        ToUUID ("36079ae4-78e8-452d-af50-0cff78b2f1ca") /* Unknown UUID */,
                        "SMMUINTERFACEID",
                        Buffer (0x10)
                        {
                            /* 0000 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ........
                            /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   // ........
                        },

                        Package (0x04)
                        {
                            "PAGETABLEUSAGE",
                            0x02,
                            "CryptoNonSecurePT",
                            "CryptoSecurePT"
                        }
                    },

                    Package (0x02)
                    {
                        "PERF_CONTROLS",
                        Package (0x01)
                        {
                            0x02
                        }
                    },

                    Package (0x01)
                    {
                        "THERMAL_DOMAINS"
                    }
                }
            },

            Package (0x0C)
            {
                "DISPLAYS",
                "MDP5.x",
                0x07,
                Package (0x07)
                {
                    "DISPLAY",
                    "INTERNAL1",
                    Zero,
                    One,
                    Zero,
                    Package (0x05)
                    {
                        "PERF_CONTROLS",
                        Package (0x01)
                        {
                            0x02
                        },

                        Package (0x01)
                        {
                            0x03
                        },

                        Package (0x01)
                        {
                            0x04
                        },

                        Package (0x01)
                        {
                            0x05
                        }
                    },

                    Package (0x01)
                    {
                        "THERMAL_DOMAINS"
                    }
                },

                Package (0x07)
                {
                    "DISPLAY",
                    "EXTERNAL1",
                    0x06,
                    One,
                    Zero,
                    Package (0x05)
                    {
                        "PERF_CONTROLS",
                        Package (0x01)
                        {
                            0x02
                        },

                        Package (0x01)
                        {
                            0x03
                        },

                        Package (0x01)
                        {
                            0x04
                        },

                        Package (0x01)
                        {
                            0x05
                        }
                    },

                    Package (0x01)
                    {
                        "THERMAL_DOMAINS"
                    }
                },

                Package (0x07)
                {
                    "DISPLAY",
                    "EXTERNAL2",
                    0x07,
                    One,
                    Zero,
                    Package (0x05)
                    {
                        "PERF_CONTROLS",
                        Package (0x01)
                        {
                            0x02
                        },

                        Package (0x01)
                        {
                            0x03
                        },

                        Package (0x01)
                        {
                            0x04
                        },

                        Package (0x01)
                        {
                            0x05
                        }
                    },

                    Package (0x01)
                    {
                        "THERMAL_DOMAINS"
                    }
                },

                Package (0x07)
                {
                    "DISPLAY",
                    "EXTERNAL3",
                    0x08,
                    One,
                    Zero,
                    Package (0x05)
                    {
                        "PERF_CONTROLS",
                        Package (0x01)
                        {
                            0x02
                        },

                        Package (0x01)
                        {
                            0x03
                        },

                        Package (0x01)
                        {
                            0x04
                        },

                        Package (0x01)
                        {
                            0x05
                        }
                    },

                    Package (0x01)
                    {
                        "THERMAL_DOMAINS"
                    }
                },

                Package (0x07)
                {
                    "DISPLAY",
                    "EXTERNAL4",
                    0x09,
                    One,
                    Zero,
                    Package (0x05)
                    {
                        "PERF_CONTROLS",
                        Package (0x01)
                        {
                            0x02
                        },

                        Package (0x01)
                        {
                            0x03
                        },

                        Package (0x01)
                        {
                            0x04
                        },

                        Package (0x01)
                        {
                            0x05
                        }
                    },

                    Package (0x01)
                    {
                        "THERMAL_DOMAINS"
                    }
                },

                Package (0x07)
                {
                    "DISPLAY",
                    "EXTERNAL5",
                    0x0A,
                    One,
                    Zero,
                    Package (0x05)
                    {
                        "PERF_CONTROLS",
                        Package (0x01)
                        {
                            0x02
                        },

                        Package (0x01)
                        {
                            0x03
                        },

                        Package (0x01)
                        {
                            0x04
                        },

                        Package (0x01)
                        {
                            0x05
                        }
                    },

                    Package (0x01)
                    {
                        "THERMAL_DOMAINS"
                    }
                },

                Package (0x07)
                {
                    "DISPLAY",
                    "EXTERNAL6",
                    0x0B,
                    One,
                    Zero,
                    Package (0x05)
                    {
                        "PERF_CONTROLS",
                        Package (0x01)
                        {
                            0x02
                        },

                        Package (0x01)
                        {
                            0x03
                        },

                        Package (0x01)
                        {
                            0x04
                        },

                        Package (0x01)
                        {
                            0x05
                        }
                    },

                    Package (0x01)
                    {
                        "THERMAL_DOMAINS"
                    }
                },

                Package (0x02)
                {
                    "RESOURCES",
                    Package (0x0B)
                    {
                        "MMUINFO",
                        "Miniport",
                        "ArmSmmuV2",
                        0x02,
                        0x20,
                        "V8L",
                        "SMMUID",
                        ToUUID ("36079ae4-78e8-452d-af50-0cff78b2f1ca") /* Unknown UUID */,
                        "SMMUINTERFACEID",
                        Buffer (0x10)
                        {
                            /* 0000 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ........
                            /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   // ........
                        },

                        Package (0x04)
                        {
                            "PAGETABLEUSAGE",
                            0x02,
                            "MdpNonSecurePT",
                            "MdpSecurePT"
                        }
                    }
                },

                Package (0x22)
                {
                    "PRIMARY_SOURCE_MODES",
                    0x20,
                    Package (0x02)
                    {
                        0x0280,
                        0x01E0
                    },

                    Package (0x02)
                    {
                        0x0280,
                        0x0168
                    },

                    Package (0x02)
                    {
                        0x0320,
                        0x0258
                    },

                    Package (0x02)
                    {
                        0x03C0,
                        0x021C
                    },

                    Package (0x02)
                    {
                        0x0500,
                        0x02D0
                    },

                    Package (0x02)
                    {
                        0x0500,
                        0x0438
                    },

                    Package (0x02)
                    {
                        0x0400,
                        0x0300
                    },

                    Package (0x02)
                    {
                        0x0480,
                        0x0300
                    },

                    Package (0x02)
                    {
                        0x0500,
                        0x0300
                    },

                    Package (0x02)
                    {
                        0x0550,
                        0x0300
                    },

                    Package (0x02)
                    {
                        0x0556,
                        0x0300
                    },

                    Package (0x02)
                    {
                        0x0640,
                        0x0384
                    },

                    Package (0x02)
                    {
                        0x0500,
                        0x0400
                    },

                    Package (0x02)
                    {
                        0x0780,
                        0x0438
                    },

                    Package (0x02)
                    {
                        0x0780,
                        0x04B0
                    },

                    Package (0x02)
                    {
                        0x0780,
                        0x0500
                    },

                    Package (0x02)
                    {
                        0x0800,
                        0x0438
                    },

                    Package (0x02)
                    {
                        0x0800,
                        0x0480
                    },

                    Package (0x02)
                    {
                        0x0800,
                        0x0600
                    },

                    Package (0x02)
                    {
                        0x0A00,
                        0x0438
                    },

                    Package (0x02)
                    {
                        0x0A00,
                        0x0640
                    },

                    Package (0x02)
                    {
                        0x0A00,
                        0x05A0
                    },

                    Package (0x02)
                    {
                        0x0A00,
                        0x0800
                    },

                    Package (0x02)
                    {
                        0x0C80,
                        0x0708
                    },

                    Package (0x02)
                    {
                        0x0C80,
                        0x0960
                    },

                    Package (0x02)
                    {
                        0x0C80,
                        0x0800
                    },

                    Package (0x02)
                    {
                        0x0D70,
                        0x05A0
                    },

                    Package (0x02)
                    {
                        0x0F00,
                        0x0438
                    },

                    Package (0x02)
                    {
                        0x0F00,
                        0x0640
                    },

                    Package (0x02)
                    {
                        0x0F00,
                        0x0960
                    },

                    Package (0x02)
                    {
                        0x0F00,
                        0x0870
                    },

                    Package (0x02)
                    {
                        0x1000,
                        0x0870
                    }
                }
            },

            Package (0x0F)
            {
                "PAGETABLES",
                0x0D,
                Package (0x07)
                {
                    "GraphicsGlobalPT",
                    One,
                    Zero,
                    One,
                    One,
                    0x0000008000000000,
                    0x0000000800000000
                },

                Package (0x07)
                {
                    "GraphicsPerProcessPT",
                    Zero,
                    Zero,
                    Zero,
                    Zero,
                    0x00400000,
                    0x0000007FFFC00000
                },

                Package (0x07)
                {
                    "GraphicsSecurePT",
                    Zero,
                    One,
                    One,
                    One,
                    0x0000008000000000,
                    0x0000000A00000000
                },

                Package (0x07)
                {
                    "GraphicsGmuPT",
                    Zero,
                    Zero,
                    Zero,
                    Zero,
                    Zero,
                    0x80000000
                },

                Package (0x07)
                {
                    "MdpNonSecurePT",
                    Zero,
                    Zero,
                    Zero,
                    Zero,
                    0x00100000,
                    0xFFF00000
                },

                Package (0x07)
                {
                    "MdpSecurePT",
                    Zero,
                    One,
                    Zero,
                    One,
                    0x00100000,
                    0xFFF00000
                },

                Package (0x09)
                {
                    "VideoNonSecurePT",
                    Zero,
                    Zero,
                    Zero,
                    One,
                    0x00100000,
                    0xBFF00000,
                    0x1B,
                    Zero
                },

                Package (0x09)
                {
                    "VideoSecurePT1",
                    Zero,
                    One,
                    Zero,
                    One,
                    0xC0000000,
                    0x10000000,
                    0x09,
                    One
                },

                Package (0x09)
                {
                    "VideoSecurePT2",
                    Zero,
                    One,
                    Zero,
                    One,
                    0xD0000000,
                    0x10000000,
                    0x07,
                    0x02
                },

                Package (0x09)
                {
                    "VideoSecurePT3",
                    Zero,
                    One,
                    Zero,
                    One,
                    0xE0000000,
                    0x10000000,
                    0x02,
                    0x03
                },

                Package (0x09)
                {
                    "VideoSecurePT4",
                    Zero,
                    One,
                    Zero,
                    One,
                    0xF0000000,
                    0x10000000,
                    0x2A,
                    0x04
                },

                Package (0x07)
                {
                    "CryptoNonSecurePT",
                    Zero,
                    Zero,
                    Zero,
                    Zero,
                    0x00100000,
                    0x7FF00000
                },

                Package (0x07)
                {
                    "CryptoSecurePT",
                    Zero,
                    One,
                    Zero,
                    One,
                    0x80000000,
                    0x80000000
                }
            }
        })
        Return (EBUF) /* \_SB_.GPU0.ENGS.EBUF */
    }

    // -------------------------------------------------------------------------
    // TMDT —— 热域声明（阶段 8 新增）
    //
    // ENGS 里每个引擎的 "THERMAL_DOMAINS" 都指向 "GPU"，这里给出它的定义。
    // -------------------------------------------------------------------------
    Method (TMDT, 0, NotSerialized)
    {
        Name (RBUF, Package (0x03)
        {
            One,
            Zero,
            Package (0x03)
            {
                "THERMAL_DOMAINS",
                One,
                Package (0x03)
                {
                    "GPU",
                    "GPU0",
                    Package (0x03)
                    {
                        "GRAPHICS",
                        "MDPBLT",
                        "ROTATOR"
                    }
                }
            }
        })
        Return (RBUF) /* \_SB_.GPU0.TMDT.RBUF */
    }

    // =========================================================================
    // 阶段 9：PMCL —— 电源/时钟部件模型（从 MTP 参考板 DSDT 逐字移植）
    //
    // 见 docs/woa-dagu-gpu-stage9-2026-10-31.md。qcdxkm8250.sys 过了阶段 8 的
    // GmuInternal/GpuInternal 门控之后，会读这张表建立 GPU/显示各部件的电源状态
    // 模型（F-state / P-state）。整段仅引用 \_SB.SIDT / \_SB.SIDV / \_SB.SOID，
    // 这三个占位符 dsdt_common.asl 已定义，由固件启动时按芯片 SKU/版本填入。
    // 原样照搬，不改名：表内字符串是驱动按字面匹配的关键字。
    // =========================================================================
    Method (PMCL, 0, NotSerialized)
    {
        Name (RBUF, Package (0x0F)
        {
            0x03, 
            0x02, 
            0x0C, 
            Package (0x10)
            {
                "COMPONENT", 
                Zero, 
                ToUUID ("2c135991-4391-4633-90b1-fa96f2e2cc04") /* Unknown UUID */, 
                "PRIMDISPLAY_POWER_STATES", 
                "HW_BLOCK_MDP", 
                Package (0x02)
                {
                    "DISPLAY", 
                    "INTERNAL1"
                }, 

                0x02, 
                0x06, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "PWR_OFF", 
                    One, 
                    One, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "INTERNAL1_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "INTERNAL1_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0D)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "INTERNAL1_SCAN_CONTROL", 
                    "*", 
                    "DISPLAY_SOURCE_SCAN_CTRL", 
                    0x05, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x04, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x03, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x02, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x12)
                {
                    "PSTATE_SET", 
                    0x03, 
                    "INTERNAL1_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    0x0A, 
                    One, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x1B6B0B00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x14904840, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x11E1A300, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x0BEBC200, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x0A37CADB, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x08F0D180, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x05F5E100, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x051BD4B0, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x0124F800, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        Zero, 
                        0x03
                    }
                }, 

                Package (0x3A)
                {
                    "PSTATE_SET", 
                    0x04, 
                    "INTERNAL1_EBI_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x32, 
                    0x23, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x00000003AECEF2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000396F76EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000037F1FEAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000003674866A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x000000034F70E2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x0000000337995EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x000000031FC1DAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x0000000307EA56A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000002F012D2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000002D83B4EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000002C063CAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x00000002A88C46A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000290B4C2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000278DD3EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000026105BAA0, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x000000025B8E7F80, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x10, 
                        0x000000023C346000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x11, 
                        0x00000002245CDC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x12, 
                        0x000000020C855800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x13, 
                        0x00000001F4ADD400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x14, 
                        0x00000001DCD65000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x15, 
                        0x00000001C4FECC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000001AD274800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x17, 
                        0x00000001954FC400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x18, 
                        0x000000017D784000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x19, 
                        0x0000000165A0BC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x000000014DC93800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x0000000135F1B400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x000000011E1A3000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1D, 
                        0x000000010642AC00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1E, 
                        0xEE6B2800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1F, 
                        0xD693A400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x20, 
                        0xBEBC2000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x21, 
                        0xA6E49C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x22, 
                        0x8F0D1800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x23, 
                        0x77359400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x24, 
                        0x5F5E1000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x25, 
                        0x59682F00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x26, 
                        0x53724E00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x27, 
                        0x4D7C6D00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x28, 
                        0x47868C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x29, 
                        0x4190AB00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x3B9ACA00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x35A4E900, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x29B92700, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x23C34600, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x1DCD6500, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x30, 
                        0x17D78400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x31, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    0x05, 
                    "INTERNAL1_EBI_INSTANT_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }
            }, 

            Package (0x0E)
            {
                "COMPONENT", 
                One, 
                ToUUID ("30bdf1b5-28f7-4c0c-ac47-273dd1401e11") /* Unknown UUID */, 
                "GRAPHICS_POWER_STATES", 
                "HW_BLOCK_GRAPHICS", 
                Package (0x02)
                {
                    "ENGINE", 
                    "GRAPHICS"
                }, 

                0x02, 
                0x04, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "PWR_OFF", 
                    0x2711, 
                    0x0A, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "GRAPHICS_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "GRAPHICS_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    One, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x02)
                {
                    "ENGINE_PSTATE_SET", 
                    0x02
                }, 

                Package (0x02)
                {
                    "ENGINE_PSTATE_SET", 
                    0x03
                }
            }, 

            Package (0x0F)
            {
                "COMPONENT", 
                0x02, 
                ToUUID ("07ca2add-df87-49e1-8583-08687dc81c8e") /* Unknown UUID */, 
                "MDPBLT_POWER_STATES", 
                "HW_BLOCK_MDP", 
                Package (0x02)
                {
                    "ENGINE", 
                    "MDPBLT"
                }, 

                0x03, 
                0x04, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x03
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "CLK_OFF", 
                    0x2710, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    0x02, 
                    "PWR_OFF", 
                    0x000186A0, 
                    Zero, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "MDPBLT_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "MDPBLT_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x12)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "MDPBLT_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    0x0A, 
                    0x02, 
                    Zero, 
                    Package (0x05)
                    {
                        "PSTATE", 
                        Zero, 
                        0x1B6B0B00, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        One, 
                        0x14904840, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x42
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x02, 
                        0x11E1A300, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x42
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x03, 
                        0x0BEBC200, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x42
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x04, 
                        0x0A37CADB, 
                        0x03, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x21
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x05, 
                        0x08F0D180, 
                        0x03, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x21
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x06, 
                        0x05F5E100, 
                        0x03, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x21
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x07, 
                        0x051BD4B0, 
                        0x03, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x08, 
                        0x0124F800, 
                        0x03, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x09, 
                        Zero, 
                        0x03, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }
                }, 

                Package (0x40)
                {
                    "PSTATE_SET", 
                    0x03, 
                    "MDPBLT_AXI_BANDWIDTH_CONTROL", 
                    "*", 
                    "BANDWIDTH", 
                    0x38, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x05)
                    {
                        "PSTATE", 
                        Zero, 
                        0x00000003AECEF2A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000396F76EA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000037F1FEAA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000003674866A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x04, 
                        0x000000034F70E2A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x05, 
                        0x0000000337995EA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x06, 
                        0x000000031FC1DAA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x07, 
                        0x0000000307EA56A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000002F012D2A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000002D83B4EA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000002C063CAA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x00000002A88C46A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000290B4C2A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000278DD3EA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000026105BAA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x00000002492E36A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x10, 
                        0x000000023156B2A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x11, 
                        0x00000002197F2EA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x12, 
                        0x0000000201A7AAA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x13, 
                        0x00000001E9D026A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x14, 
                        0x00000001D1F8A2A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x15, 
                        0x00000001BA211EA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000001A2499AA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x17, 
                        0x000000018A7216A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x18, 
                        0x00000001729A92A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x19, 
                        0x000000015AC30EA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x0000000142EB8AA0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x000000012B1406A0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x00000001133C82A0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1D, 
                        0xFB64FEA0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1E, 
                        0xE38D7AA0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1F, 
                        0xCBB5F6A0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x20, 
                        0xB3DE72A0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x21, 
                        0x9C06EEA0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x22, 
                        0x8F0D1800, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x23, 
                        0x89173700, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x24, 
                        0x83215600, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x25, 
                        0x7D2B7500, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x26, 
                        0x77359400, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x27, 
                        0x713FB300, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x28, 
                        0x6B49D200, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x29, 
                        0x6553F100, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x5F5E1000, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x59682F00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x53724E00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x4D7C6D00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x47868C00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x4190AB00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x30, 
                        0x3B9ACA00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x31, 
                        0x35A4E900, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x32, 
                        0x2FAF0800, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x33, 
                        0x29B92700, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x34, 
                        0x23C34600, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x35, 
                        0x1DCD6500, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x36, 
                        0x17D78400, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x37, 
                        Zero, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }
                }
            }, 

            Package (0x0F)
            {
                "COMPONENT", 
                0x03, 
                ToUUID ("4d5ffbf5-d791-41cd-89cb-0154129ba607") /* Unknown UUID */, 
                "ROTATOR_POWER_STATES", 
                "HW_BLOCK_ROTATOR", 
                Package (0x02)
                {
                    "ENGINE", 
                    "ROTATOR"
                }, 

                0x03, 
                0x04, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x03
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "CLK_OFF", 
                    0x2710, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    0x02, 
                    "PWR_OFF", 
                    0x000186A0, 
                    Zero, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "ROTATOR_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "ROTATOR_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0E)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "ROTATOR_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    0x06, 
                    0x02, 
                    Zero, 
                    Package (0x05)
                    {
                        "PSTATE", 
                        Zero, 
                        0x1B6B0B00, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        One, 
                        0x14904840, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x42
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x02, 
                        0x11E1A300, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x42
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x03, 
                        0x0A37CADB, 
                        0x03, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x21
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x04, 
                        0x0124F800, 
                        0x03, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x05, 
                        Zero, 
                        0x03, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }
                }, 

                Package (0x40)
                {
                    "PSTATE_SET", 
                    0x03, 
                    "ROTATOR_AXI_BANDWIDTH_CONTROL", 
                    "*", 
                    "BANDWIDTH", 
                    0x38, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x05)
                    {
                        "PSTATE", 
                        Zero, 
                        0x00000003AECEF2A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000396F76EA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000037F1FEAA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000003674866A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x04, 
                        0x000000034F70E2A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x05, 
                        0x0000000337995EA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x06, 
                        0x000000031FC1DAA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x07, 
                        0x0000000307EA56A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000002F012D2A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000002D83B4EA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000002C063CAA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x00000002A88C46A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000290B4C2A0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000278DD3EA0, 
                        Zero, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000026105BAA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x64
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x00000002492E36A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x10, 
                        0x000000023156B2A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x11, 
                        0x00000002197F2EA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x12, 
                        0x0000000201A7AAA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x13, 
                        0x00000001E9D026A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x14, 
                        0x00000001D1F8A2A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x15, 
                        0x00000001BA211EA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000001A2499AA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x4B
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x17, 
                        0x000000018A7216A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x18, 
                        0x00000001729A92A0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x19, 
                        0x000000015AC30EA0, 
                        One, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x0000000142EB8AA0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x000000012B1406A0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x00000001133C82A0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1D, 
                        0xFB64FEA0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x32
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1E, 
                        0xE38D7AA0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x1F, 
                        0xCBB5F6A0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x20, 
                        0xB3DE72A0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x21, 
                        0x9C06EEA0, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x22, 
                        0x8F0D1800, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x23, 
                        0x89173700, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x24, 
                        0x83215600, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x25, 
                        0x7D2B7500, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x26, 
                        0x77359400, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x27, 
                        0x713FB300, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x28, 
                        0x6B49D200, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x29, 
                        0x6553F100, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x5F5E1000, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x59682F00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x53724E00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x4D7C6D00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x47868C00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x4190AB00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x30, 
                        0x3B9ACA00, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            0x19
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x31, 
                        0x35A4E900, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x32, 
                        0x2FAF0800, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x33, 
                        0x29B92700, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x34, 
                        0x23C34600, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x35, 
                        0x1DCD6500, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x36, 
                        0x17D78400, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }, 

                    Package (0x05)
                    {
                        "PSTATE", 
                        0x37, 
                        Zero, 
                        0x02, 
                        Package (0x02)
                        {
                            "GPU", 
                            Zero
                        }
                    }
                }
            }, 

            Package (0x11)
            {
                "COMPONENT", 
                0x04, 
                ToUUID ("d0e1bb1a-703d-4be8-b450-64a4fbfca6a8") /* Unknown UUID */, 
                "VIDEO_POWER_STATES", 
                "HW_BLOCK_VIDEO", 
                Package (0x02)
                {
                    "ENGINE", 
                    "VIDEO"
                }, 

                0x03, 
                0x06, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x03
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "CLK_OFF", 
                    0x2710, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    0x02, 
                    "PWR_OFF", 
                    0x000186A0, 
                    Zero, 
                    One
                }, 

                Package (0x0B)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "VIDEO_RESET", 
                    "*", 
                    "RESET", 
                    0x03, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x02, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0B)
                {
                    "PSTATE_SET", 
                    One, 
                    "VIDEO_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x03, 
                    One, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x02, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0F)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "VIDEO_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    0x07, 
                    0x05, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x1FC4EF40, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x1A76E700, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x15C17540, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x14257880, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x0E4E1C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x0BEBC200, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        Zero, 
                        0x03
                    }
                }, 

                Package (0x77)
                {
                    "PSTATE_SET", 
                    0x03, 
                    "VIDEO_AXI_PORT_BW", 
                    "*", 
                    "BANDWIDTH", 
                    0x6F, 
                    0x6C, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x000000051F4D5C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000513619A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000050775D800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000004FB8A1600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x00000004EF9E5400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x00000004E3B29200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x00000004D7C6D000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x00000004CBDB0E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000004BFEF4C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000004B4038A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000004A817C800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x000000049C2C0600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000490404400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000484548200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000047868C000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x000000046C7CFE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x10, 
                        0x0000000460913C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x11, 
                        0x0000000454A57A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x12, 
                        0x0000000448B9B800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x13, 
                        0x000000043CCDF600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x14, 
                        0x0000000430E23400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x15, 
                        0x0000000424F67200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000004190AB000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x17, 
                        0x000000040D1EEE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x18, 
                        0x0000000401332C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x19, 
                        0x00000003F5476A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x00000003E95BA800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x00000003DD6FE600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x00000003D1842400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1D, 
                        0x00000003C5986200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1E, 
                        0x00000003B9ACA000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1F, 
                        0x00000003ADC0DE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x20, 
                        0x00000003A1D51C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x21, 
                        0x0000000395E95A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x22, 
                        0x0000000389FD9800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x23, 
                        0x000000037E11D600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x24, 
                        0x0000000372261400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x25, 
                        0x00000003663A5200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x26, 
                        0x000000035A4E9000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x27, 
                        0x000000034E62CE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x28, 
                        0x0000000342770C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x29, 
                        0x00000003368B4A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x000000032A9F8800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x000000031EB3C600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x0000000312C80400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x0000000306DC4200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x00000002FAF08000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x00000002EF04BE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x30, 
                        0x00000002E318FC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x31, 
                        0x00000002D72D3A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x32, 
                        0x00000002CB417800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x33, 
                        0x00000002BF55B600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x34, 
                        0x00000002B369F400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x35, 
                        0x00000002A77E3200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x36, 
                        0x000000029B927000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x37, 
                        0x000000028FA6AE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x38, 
                        0x0000000283BAEC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x39, 
                        0x0000000277CF2A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3A, 
                        0x000000026BE36800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3B, 
                        0x000000025FF7A600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3C, 
                        0x00000002540BE400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3D, 
                        0x0000000248202200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3E, 
                        0x000000023C346000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3F, 
                        0x0000000230489E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x40, 
                        0x00000002245CDC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x41, 
                        0x0000000218711A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x42, 
                        0x000000020C855800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x43, 
                        0x0000000200999600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x44, 
                        0x00000001F4ADD400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x45, 
                        0x00000001E8C21200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x46, 
                        0x00000001DCD65000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x47, 
                        0x00000001D0EA8E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x48, 
                        0x00000001C4FECC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x49, 
                        0x00000001B9130A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4A, 
                        0x00000001AD274800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4B, 
                        0x00000001A13B8600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4C, 
                        0x00000001954FC400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4D, 
                        0x0000000189640200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4E, 
                        0x000000017D784000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4F, 
                        0x00000001718C7E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x50, 
                        0x0000000165A0BC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x51, 
                        0x0000000159B4FA00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x52, 
                        0x000000014DC93800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x53, 
                        0x0000000141DD7600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x54, 
                        0x0000000135F1B400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x55, 
                        0x000000012A05F200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x56, 
                        0x000000011E1A3000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x57, 
                        0x00000001122E6E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x58, 
                        0x000000010642AC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x59, 
                        0xFA56EA00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5A, 
                        0xEE6B2800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5B, 
                        0xE27F6600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5C, 
                        0xD693A400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5D, 
                        0xCAA7E200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5E, 
                        0xBEBC2000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5F, 
                        0xB2D05E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x60, 
                        0xA6E49C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x61, 
                        0x9AF8DA00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x62, 
                        0x8F0D1800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x63, 
                        0x83215600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x64, 
                        0x77359400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x65, 
                        0x6B49D200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x66, 
                        0x5F5E1000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x67, 
                        0x53724E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x68, 
                        0x47868C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x69, 
                        0x3B9ACA00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x6A, 
                        0x2FAF0800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x6B, 
                        0x23C34600, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x6C, 
                        0x17D78400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x6D, 
                        0x0BEBC200, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x6E, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x77)
                {
                    "PSTATE_SET", 
                    0x04, 
                    "VIDEO_LLC_AXI_PORT_BW", 
                    "*", 
                    "BANDWIDTH", 
                    0x6F, 
                    0x6E, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x000000051F4D5C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000513619A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000050775D800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000004FB8A1600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x00000004EF9E5400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x00000004E3B29200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x00000004D7C6D000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x00000004CBDB0E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000004BFEF4C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000004B4038A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000004A817C800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x000000049C2C0600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000490404400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000484548200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000047868C000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x000000046C7CFE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x10, 
                        0x0000000460913C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x11, 
                        0x0000000454A57A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x12, 
                        0x0000000448B9B800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x13, 
                        0x000000043CCDF600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x14, 
                        0x0000000430E23400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x15, 
                        0x0000000424F67200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000004190AB000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x17, 
                        0x000000040D1EEE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x18, 
                        0x0000000401332C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x19, 
                        0x00000003F5476A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x00000003E95BA800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x00000003DD6FE600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x00000003D1842400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1D, 
                        0x00000003C5986200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1E, 
                        0x00000003B9ACA000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1F, 
                        0x00000003ADC0DE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x20, 
                        0x00000003A1D51C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x21, 
                        0x0000000395E95A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x22, 
                        0x0000000389FD9800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x23, 
                        0x000000037E11D600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x24, 
                        0x0000000372261400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x25, 
                        0x00000003663A5200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x26, 
                        0x000000035A4E9000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x27, 
                        0x000000034E62CE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x28, 
                        0x0000000342770C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x29, 
                        0x00000003368B4A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x000000032A9F8800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x000000031EB3C600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x0000000312C80400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x0000000306DC4200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x00000002FAF08000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x00000002EF04BE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x30, 
                        0x00000002E318FC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x31, 
                        0x00000002D72D3A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x32, 
                        0x00000002CB417800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x33, 
                        0x00000002BF55B600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x34, 
                        0x00000002B369F400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x35, 
                        0x00000002A77E3200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x36, 
                        0x000000029B927000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x37, 
                        0x000000028FA6AE00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x38, 
                        0x0000000283BAEC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x39, 
                        0x0000000277CF2A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3A, 
                        0x000000026BE36800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3B, 
                        0x000000025FF7A600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3C, 
                        0x00000002540BE400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3D, 
                        0x0000000248202200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3E, 
                        0x000000023C346000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x3F, 
                        0x0000000230489E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x40, 
                        0x00000002245CDC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x41, 
                        0x0000000218711A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x42, 
                        0x000000020C855800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x43, 
                        0x0000000200999600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x44, 
                        0x00000001F4ADD400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x45, 
                        0x00000001E8C21200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x46, 
                        0x00000001DCD65000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x47, 
                        0x00000001D0EA8E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x48, 
                        0x00000001C4FECC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x49, 
                        0x00000001B9130A00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4A, 
                        0x00000001AD274800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4B, 
                        0x00000001A13B8600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4C, 
                        0x00000001954FC400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4D, 
                        0x0000000189640200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4E, 
                        0x000000017D784000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x4F, 
                        0x00000001718C7E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x50, 
                        0x0000000165A0BC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x51, 
                        0x0000000159B4FA00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x52, 
                        0x000000014DC93800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x53, 
                        0x0000000141DD7600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x54, 
                        0x0000000135F1B400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x55, 
                        0x000000012A05F200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x56, 
                        0x000000011E1A3000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x57, 
                        0x00000001122E6E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x58, 
                        0x000000010642AC00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x59, 
                        0xFA56EA00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5A, 
                        0xEE6B2800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5B, 
                        0xE27F6600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5C, 
                        0xD693A400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5D, 
                        0xCAA7E200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5E, 
                        0xBEBC2000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x5F, 
                        0xB2D05E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x60, 
                        0xA6E49C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x61, 
                        0x9AF8DA00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x62, 
                        0x8F0D1800, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x63, 
                        0x83215600, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x64, 
                        0x77359400, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x65, 
                        0x6B49D200, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x66, 
                        0x5F5E1000, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x67, 
                        0x53724E00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x68, 
                        0x47868C00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x69, 
                        0x3B9ACA00, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x6A, 
                        0x2FAF0800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x6B, 
                        0x23C34600, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x6C, 
                        0x17D78400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x6D, 
                        0x0BEBC200, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x6E, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0C)
                {
                    "PSTATE_SET", 
                    0x05, 
                    "VIDEO_CLOCK_DISABLE_ENABLE", 
                    "*", 
                    "INTERNAL", 
                    0x04, 
                    0x03, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x03, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x02, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        Zero, 
                        0x02
                    }
                }
            }, 

            Package (0x0D)
            {
                "COMPONENT", 
                0x05, 
                ToUUID ("cc4d73fa-c3c2-4c7e-a217-d468f4611bbd") /* Unknown UUID */, 
                "CRYPTO_POWER_STATES", 
                "HW_BLOCK_NONE", 
                Package (0x02)
                {
                    "ENGINE", 
                    "CRYPTO"
                }, 

                0x02, 
                0x03, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x03
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "PWR_OFF", 
                    0x000186A0, 
                    Zero, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "CRYPTO_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "CRYPTO_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    One, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x09)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "CRYPTO_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    One, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        Zero, 
                        Zero
                    }
                }
            }, 

            Package (0x10)
            {
                "COMPONENT", 
                0x06, 
                ToUUID ("6069b502-0611-4c94-8778-0a4e1610f5e5") /* Unknown UUID */, 
                "DP_POWER_STATES", 
                "HW_BLOCK_MDP", 
                Package (0x02)
                {
                    "DISPLAY", 
                    "EXTERNAL1"
                }, 

                0x02, 
                0x06, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "PWR_OFF", 
                    One, 
                    One, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "EXTERNAL1_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "EXTERNAL1_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x12)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "EXTERNAL1_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    0x0A, 
                    One, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x1B6B0B00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x14904840, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x11E1A300, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x0BEBC200, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x0A37CADB, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x08F0D180, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x05F5E100, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x051BD4B0, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x0124F800, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        Zero, 
                        0x03
                    }
                }, 

                Package (0x3A)
                {
                    "PSTATE_SET", 
                    0x03, 
                    "EXTERNAL1_EBI_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x32, 
                    0x23, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x00000003AECEF2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000396F76EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000037F1FEAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000003674866A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x000000034F70E2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x0000000337995EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x000000031FC1DAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x0000000307EA56A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000002F012D2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000002D83B4EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000002C063CAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x00000002A88C46A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000290B4C2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000278DD3EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000026105BAA0, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x000000025B8E7F80, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x10, 
                        0x000000023C346000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x11, 
                        0x00000002245CDC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x12, 
                        0x000000020C855800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x13, 
                        0x00000001F4ADD400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x14, 
                        0x00000001DCD65000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x15, 
                        0x00000001C4FECC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000001AD274800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x17, 
                        0x00000001954FC400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x18, 
                        0x000000017D784000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x19, 
                        0x0000000165A0BC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x000000014DC93800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x0000000135F1B400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x000000011E1A3000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1D, 
                        0x000000010642AC00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1E, 
                        0xEE6B2800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1F, 
                        0xD693A400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x20, 
                        0xBEBC2000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x21, 
                        0xA6E49C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x22, 
                        0x8F0D1800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x23, 
                        0x77359400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x24, 
                        0x5F5E1000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x25, 
                        0x59682F00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x26, 
                        0x53724E00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x27, 
                        0x4D7C6D00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x28, 
                        0x47868C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x29, 
                        0x4190AB00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x3B9ACA00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x35A4E900, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x29B92700, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x23C34600, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x1DCD6500, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x30, 
                        0x17D78400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x31, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    0x04, 
                    "EXTERNAL1_EBI_INSTANT_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0C)
                {
                    "PSTATE_SET", 
                    0x05, 
                    "EXTERNAL1_SCAN_CONTROL", 
                    "*", 
                    "DISPLAY_SOURCE_SCAN_CTRL", 
                    0x04, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x03, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x02, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        Zero, 
                        0x02
                    }
                }
            }, 

            Package (0x10)
            {
                "COMPONENT", 
                0x07, 
                ToUUID ("436e1ed8-45ba-4ff2-addc-59ca0df71668") /* Unknown UUID */, 
                "EX2_POWER_STATES", 
                "HW_BLOCK_MDP", 
                Package (0x02)
                {
                    "DISPLAY", 
                    "EXTERNAL2"
                }, 

                0x02, 
                0x06, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "PWR_OFF", 
                    One, 
                    One, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "EXTERNAL2_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "EXTERNAL2_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x12)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "EXTERNAL2_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    0x0A, 
                    One, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x1B6B0B00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x14904840, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x11E1A300, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x0BEBC200, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x0A37CADB, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x08F0D180, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x05F5E100, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x051BD4B0, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x0124F800, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        Zero, 
                        0x03
                    }
                }, 

                Package (0x3A)
                {
                    "PSTATE_SET", 
                    0x03, 
                    "EXTERNAL2_EBI_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x32, 
                    0x23, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x00000003AECEF2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000396F76EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000037F1FEAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000003674866A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x000000034F70E2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x0000000337995EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x000000031FC1DAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x0000000307EA56A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000002F012D2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000002D83B4EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000002C063CAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x00000002A88C46A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000290B4C2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000278DD3EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000026105BAA0, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x000000025B8E7F80, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x10, 
                        0x000000023C346000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x11, 
                        0x00000002245CDC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x12, 
                        0x000000020C855800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x13, 
                        0x00000001F4ADD400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x14, 
                        0x00000001DCD65000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x15, 
                        0x00000001C4FECC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000001AD274800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x17, 
                        0x00000001954FC400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x18, 
                        0x000000017D784000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x19, 
                        0x0000000165A0BC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x000000014DC93800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x0000000135F1B400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x000000011E1A3000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1D, 
                        0x000000010642AC00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1E, 
                        0xEE6B2800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1F, 
                        0xD693A400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x20, 
                        0xBEBC2000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x21, 
                        0xA6E49C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x22, 
                        0x8F0D1800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x23, 
                        0x77359400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x24, 
                        0x5F5E1000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x25, 
                        0x59682F00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x26, 
                        0x53724E00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x27, 
                        0x4D7C6D00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x28, 
                        0x47868C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x29, 
                        0x4190AB00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x3B9ACA00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x35A4E900, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x29B92700, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x23C34600, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x1DCD6500, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x30, 
                        0x17D78400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x31, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    0x04, 
                    "EXTERNAL2_EBI_INSTANT_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0C)
                {
                    "PSTATE_SET", 
                    0x05, 
                    "EXTERNAL2_SCAN_CONTROL", 
                    "*", 
                    "DISPLAY_SOURCE_SCAN_CTRL", 
                    0x04, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x03, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x02, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        Zero, 
                        0x02
                    }
                }
            }, 

            Package (0x10)
            {
                "COMPONENT", 
                0x08, 
                ToUUID ("d8136865-c7c0-45c3-b777-3d58919fa3d0") /* Unknown UUID */, 
                "EX3_POWER_STATES", 
                "HW_BLOCK_MDP", 
                Package (0x02)
                {
                    "DISPLAY", 
                    "EXTERNAL3"
                }, 

                0x02, 
                0x06, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "PWR_OFF", 
                    One, 
                    One, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "EXTERNAL3_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "EXTERNAL3_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x12)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "EXTERNAL3_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    0x0A, 
                    One, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x1B6B0B00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x14904840, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x11E1A300, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x0BEBC200, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x0A37CADB, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x08F0D180, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x05F5E100, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x051BD4B0, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x0124F800, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        Zero, 
                        0x03
                    }
                }, 

                Package (0x3A)
                {
                    "PSTATE_SET", 
                    0x03, 
                    "EXTERNAL3_EBI_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x32, 
                    0x23, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x00000003AECEF2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000396F76EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000037F1FEAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000003674866A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x000000034F70E2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x0000000337995EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x000000031FC1DAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x0000000307EA56A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000002F012D2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000002D83B4EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000002C063CAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x00000002A88C46A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000290B4C2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000278DD3EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000026105BAA0, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x000000025B8E7F80, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x10, 
                        0x000000023C346000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x11, 
                        0x00000002245CDC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x12, 
                        0x000000020C855800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x13, 
                        0x00000001F4ADD400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x14, 
                        0x00000001DCD65000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x15, 
                        0x00000001C4FECC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000001AD274800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x17, 
                        0x00000001954FC400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x18, 
                        0x000000017D784000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x19, 
                        0x0000000165A0BC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x000000014DC93800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x0000000135F1B400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x000000011E1A3000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1D, 
                        0x000000010642AC00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1E, 
                        0xEE6B2800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1F, 
                        0xD693A400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x20, 
                        0xBEBC2000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x21, 
                        0xA6E49C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x22, 
                        0x8F0D1800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x23, 
                        0x77359400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x24, 
                        0x5F5E1000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x25, 
                        0x59682F00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x26, 
                        0x53724E00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x27, 
                        0x4D7C6D00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x28, 
                        0x47868C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x29, 
                        0x4190AB00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x3B9ACA00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x35A4E900, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x29B92700, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x23C34600, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x1DCD6500, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x30, 
                        0x17D78400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x31, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    0x04, 
                    "EXTERNAL3_EBI_INSTANT_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0C)
                {
                    "PSTATE_SET", 
                    0x05, 
                    "EXTERNAL3_SCAN_CONTROL", 
                    "*", 
                    "DISPLAY_SOURCE_SCAN_CTRL", 
                    0x04, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x03, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x02, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        Zero, 
                        0x02
                    }
                }
            }, 

            Package (0x10)
            {
                "COMPONENT", 
                0x09, 
                ToUUID ("d60914f9-98a9-41d9-be08-d87f4e98fe14") /* Unknown UUID */, 
                "EX4_POWER_STATES", 
                "HW_BLOCK_MDP", 
                Package (0x02)
                {
                    "DISPLAY", 
                    "EXTERNAL4"
                }, 

                0x02, 
                0x06, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "PWR_OFF", 
                    One, 
                    One, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "EXTERNAL4_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "EXTERNAL4_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x12)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "EXTERNAL4_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    0x0A, 
                    One, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x1B6B0B00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x14904840, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x11E1A300, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x0BEBC200, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x0A37CADB, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x08F0D180, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x05F5E100, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x051BD4B0, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x0124F800, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        Zero, 
                        0x03
                    }
                }, 

                Package (0x3A)
                {
                    "PSTATE_SET", 
                    0x03, 
                    "EXTERNAL4_EBI_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x32, 
                    0x23, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x00000003AECEF2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000396F76EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000037F1FEAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000003674866A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x000000034F70E2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x0000000337995EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x000000031FC1DAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x0000000307EA56A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000002F012D2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000002D83B4EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000002C063CAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x00000002A88C46A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000290B4C2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000278DD3EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000026105BAA0, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x000000025B8E7F80, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x10, 
                        0x000000023C346000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x11, 
                        0x00000002245CDC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x12, 
                        0x000000020C855800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x13, 
                        0x00000001F4ADD400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x14, 
                        0x00000001DCD65000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x15, 
                        0x00000001C4FECC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000001AD274800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x17, 
                        0x00000001954FC400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x18, 
                        0x000000017D784000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x19, 
                        0x0000000165A0BC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x000000014DC93800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x0000000135F1B400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x000000011E1A3000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1D, 
                        0x000000010642AC00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1E, 
                        0xEE6B2800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1F, 
                        0xD693A400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x20, 
                        0xBEBC2000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x21, 
                        0xA6E49C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x22, 
                        0x8F0D1800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x23, 
                        0x77359400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x24, 
                        0x5F5E1000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x25, 
                        0x59682F00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x26, 
                        0x53724E00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x27, 
                        0x4D7C6D00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x28, 
                        0x47868C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x29, 
                        0x4190AB00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x3B9ACA00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x35A4E900, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x29B92700, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x23C34600, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x1DCD6500, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x30, 
                        0x17D78400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x31, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    0x04, 
                    "EXTERNAL4_EBI_INSTANT_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0C)
                {
                    "PSTATE_SET", 
                    0x05, 
                    "EXTERNAL4_SCAN_CONTROL", 
                    "*", 
                    "DISPLAY_SOURCE_SCAN_CTRL", 
                    0x04, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x03, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x02, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        Zero, 
                        0x02
                    }
                }
            }, 

            Package (0x10)
            {
                "COMPONENT", 
                0x0A, 
                ToUUID ("cd75f5c1-4e7d-4685-8033-ad2cf0aeacba") /* Unknown UUID */, 
                "EX5_POWER_STATES", 
                "HW_BLOCK_MDP", 
                Package (0x02)
                {
                    "DISPLAY", 
                    "EXTERNAL5"
                }, 

                0x02, 
                0x06, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "PWR_OFF", 
                    One, 
                    One, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "EXTERNAL5_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "EXTERNAL5_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x12)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "EXTERNAL5_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    0x0A, 
                    One, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x1B6B0B00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x14904840, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x11E1A300, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x0BEBC200, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x0A37CADB, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x08F0D180, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x05F5E100, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x051BD4B0, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x0124F800, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        Zero, 
                        0x03
                    }
                }, 

                Package (0x3A)
                {
                    "PSTATE_SET", 
                    0x03, 
                    "EXTERNAL5_EBI_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x32, 
                    0x23, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x00000003AECEF2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000396F76EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000037F1FEAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000003674866A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x000000034F70E2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x0000000337995EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x000000031FC1DAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x0000000307EA56A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000002F012D2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000002D83B4EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000002C063CAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x00000002A88C46A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000290B4C2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000278DD3EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000026105BAA0, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x000000025B8E7F80, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x10, 
                        0x000000023C346000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x11, 
                        0x00000002245CDC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x12, 
                        0x000000020C855800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x13, 
                        0x00000001F4ADD400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x14, 
                        0x00000001DCD65000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x15, 
                        0x00000001C4FECC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000001AD274800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x17, 
                        0x00000001954FC400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x18, 
                        0x000000017D784000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x19, 
                        0x0000000165A0BC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x000000014DC93800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x0000000135F1B400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x000000011E1A3000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1D, 
                        0x000000010642AC00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1E, 
                        0xEE6B2800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1F, 
                        0xD693A400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x20, 
                        0xBEBC2000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x21, 
                        0xA6E49C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x22, 
                        0x8F0D1800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x23, 
                        0x77359400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x24, 
                        0x5F5E1000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x25, 
                        0x59682F00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x26, 
                        0x53724E00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x27, 
                        0x4D7C6D00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x28, 
                        0x47868C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x29, 
                        0x4190AB00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x3B9ACA00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x35A4E900, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x29B92700, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x23C34600, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x1DCD6500, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x30, 
                        0x17D78400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x31, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    0x04, 
                    "EXTERNAL5_EBI_INSTANT_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0C)
                {
                    "PSTATE_SET", 
                    0x05, 
                    "EXTERNAL5_SCAN_CONTROL", 
                    "*", 
                    "DISPLAY_SOURCE_SCAN_CTRL", 
                    0x04, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x03, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x02, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        Zero, 
                        0x02
                    }
                }
            }, 

            Package (0x10)
            {
                "COMPONENT", 
                0x0B, 
                ToUUID ("9e0196b4-44c5-4cb8-9bbd-7f5267cadd63") /* Unknown UUID */, 
                "EX6_POWER_STATES", 
                "HW_BLOCK_MDP", 
                Package (0x02)
                {
                    "DISPLAY", 
                    "EXTERNAL6"
                }, 

                0x02, 
                0x06, 
                Package (0x06)
                {
                    "FSTATE", 
                    Zero, 
                    "ALL_ON", 
                    Zero, 
                    Zero, 
                    0x02
                }, 

                Package (0x06)
                {
                    "FSTATE", 
                    One, 
                    "PWR_OFF", 
                    One, 
                    One, 
                    One
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    Zero, 
                    "EXTERNAL6_RESET", 
                    "*", 
                    "RESET", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    One, 
                    "EXTERNAL6_FOOTSWITCH_OVERRIDE", 
                    "*", 
                    "FOOTSWITCH_OVERRIDE", 
                    0x02, 
                    0xFFFFFFFF, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x12)
                {
                    "PSTATE_SET", 
                    0x02, 
                    "EXTERNAL6_CORE_CLOCK_CONTROL", 
                    "*", 
                    "CORE_CLOCK", 
                    0x0A, 
                    One, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x1B6B0B00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x14904840, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x11E1A300, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x0BEBC200, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x0A37CADB, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x08F0D180, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x05F5E100, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x051BD4B0, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x0124F800, 
                        0x03
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        Zero, 
                        0x03
                    }
                }, 

                Package (0x3A)
                {
                    "PSTATE_SET", 
                    0x03, 
                    "EXTERNAL6_EBI_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x32, 
                    0x23, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x00000003AECEF2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x0000000396F76EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        0x000000037F1FEAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        0x00000003674866A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x04, 
                        0x000000034F70E2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x05, 
                        0x0000000337995EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x06, 
                        0x000000031FC1DAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x07, 
                        0x0000000307EA56A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x08, 
                        0x00000002F012D2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x09, 
                        0x00000002D83B4EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0A, 
                        0x00000002C063CAA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0B, 
                        0x00000002A88C46A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0C, 
                        0x0000000290B4C2A0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0D, 
                        0x0000000278DD3EA0, 
                        Zero
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0E, 
                        0x000000026105BAA0, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x0F, 
                        0x000000025B8E7F80, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x10, 
                        0x000000023C346000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x11, 
                        0x00000002245CDC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x12, 
                        0x000000020C855800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x13, 
                        0x00000001F4ADD400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x14, 
                        0x00000001DCD65000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x15, 
                        0x00000001C4FECC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x16, 
                        0x00000001AD274800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x17, 
                        0x00000001954FC400, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x18, 
                        0x000000017D784000, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x19, 
                        0x0000000165A0BC00, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1A, 
                        0x000000014DC93800, 
                        One
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1B, 
                        0x0000000135F1B400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1C, 
                        0x000000011E1A3000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1D, 
                        0x000000010642AC00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1E, 
                        0xEE6B2800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x1F, 
                        0xD693A400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x20, 
                        0xBEBC2000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x21, 
                        0xA6E49C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x22, 
                        0x8F0D1800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x23, 
                        0x77359400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x24, 
                        0x5F5E1000, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x25, 
                        0x59682F00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x26, 
                        0x53724E00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x27, 
                        0x4D7C6D00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x28, 
                        0x47868C00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x29, 
                        0x4190AB00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2A, 
                        0x3B9ACA00, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2B, 
                        0x35A4E900, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2C, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2D, 
                        0x29B92700, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2E, 
                        0x23C34600, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x2F, 
                        0x1DCD6500, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x30, 
                        0x17D78400, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x31, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0A)
                {
                    "PSTATE_SET", 
                    0x04, 
                    "EXTERNAL6_EBI_INSTANT_BANDWIDTH", 
                    "*", 
                    "BANDWIDTH", 
                    0x02, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x2FAF0800, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        Zero, 
                        0x02
                    }
                }, 

                Package (0x0C)
                {
                    "PSTATE_SET", 
                    0x05, 
                    "EXTERNAL6_SCAN_CONTROL", 
                    "*", 
                    "DISPLAY_SOURCE_SCAN_CTRL", 
                    0x04, 
                    Zero, 
                    Zero, 
                    Package (0x04)
                    {
                        "PSTATE", 
                        Zero, 
                        0x03, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        One, 
                        0x02, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x02, 
                        One, 
                        0x02
                    }, 

                    Package (0x04)
                    {
                        "PSTATE", 
                        0x03, 
                        Zero, 
                        0x02
                    }
                }
            }
        })
        Name (P001, Package (0x0E)
        {
            "ENGINE_PSTATE_SET", 
            0x02, 
            "GRAPHICS_FREQ_CONTROL", 
            "CORE_CLOCK", 
            0x05, 
            0x03, 
            "TRUE", 
            One, 
            One, 
            Package (0x06)
            {
                "PSTATE", 
                Zero, 
                0x175D7200, 
                0x04, 
                Package (0x02)
                {
                    "GPU", 
                    0x64
                }, 

                Package (0x03)
                {
                    0xC0, 
                    0x802D5FFD, 
                    0x7D11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                One, 
                0x12C684C0, 
                0x05, 
                Package (0x02)
                {
                    "GPU", 
                    0x50
                }, 

                Package (0x03)
                {
                    0x80, 
                    0x802D5FFD, 
                    0x8C11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x02, 
                0x0E01D0C0, 
                0x06, 
                Package (0x02)
                {
                    "GPU", 
                    0x3C
                }, 

                Package (0x03)
                {
                    0x40, 
                    0xA02D5FFD, 
                    0xA511
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x03, 
                0x094C5F00, 
                0x07, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }, 

                Package (0x03)
                {
                    0x30, 
                    0xA02D5FFD, 
                    0xD911
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x04, 
                Zero, 
                0x08, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }, 

                Package (0x03)
                {
                    Zero, 
                    Zero, 
                    Zero
                }
            }
        })
        Name (P002, Package (0x0F)
        {
            "ENGINE_PSTATE_SET", 
            0x02, 
            "GRAPHICS_FREQ_CONTROL", 
            "CORE_CLOCK", 
            0x06, 
            0x03, 
            "TRUE", 
            0x02, 
            0x02, 
            Package (0x06)
            {
                "PSTATE", 
                Zero, 
                0x1F972880, 
                0x03, 
                Package (0x02)
                {
                    "GPU", 
                    0x64
                }, 

                Package (0x03)
                {
                    0x0100, 
                    0xA02C5FFD, 
                    0x6711
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                One, 
                0x175D7200, 
                0x04, 
                Package (0x02)
                {
                    "GPU", 
                    0x4A
                }, 

                Package (0x03)
                {
                    0xC0, 
                    0x802D5FFD, 
                    0x7D11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x02, 
                0x12C684C0, 
                0x05, 
                Package (0x02)
                {
                    "GPU", 
                    0x3B
                }, 

                Package (0x03)
                {
                    0x80, 
                    0x802D5FFD, 
                    0x8C11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x03, 
                0x0E01D0C0, 
                0x06, 
                Package (0x02)
                {
                    "GPU", 
                    0x2C
                }, 

                Package (0x03)
                {
                    0x40, 
                    0xA02D5FFD, 
                    0xA511
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x04, 
                0x094C5F00, 
                0x07, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }, 

                Package (0x03)
                {
                    0x30, 
                    0xA02D5FFD, 
                    0xD911
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x05, 
                Zero, 
                0x08, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }, 

                Package (0x03)
                {
                    Zero, 
                    Zero, 
                    Zero
                }
            }
        })
        Name (P003, Package (0x13)
        {
            "ENGINE_PSTATE_SET", 
            0x02, 
            "GRAPHICS_FREQ_CONTROL", 
            "CORE_CLOCK", 
            0x0A, 
            0x03, 
            "TRUE", 
            0x06, 
            0x06, 
            Package (0x06)
            {
                "PSTATE", 
                Zero, 
                0x2ACBCF80, 
                Zero, 
                Package (0x02)
                {
                    "GPU", 
                    0x64
                }, 

                Package (0x03)
                {
                    0x01B0, 
                    0x802C5FFD, 
                    0x6611
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                One, 
                0x27EF6380, 
                One, 
                Package (0x02)
                {
                    "GPU", 
                    0x5D
                }, 

                Package (0x03)
                {
                    0x01A0, 
                    0x802C5FFD, 
                    0x5A11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x02, 
                0x2540BE40, 
                0x02, 
                Package (0x02)
                {
                    "GPU", 
                    0x57
                }, 

                Package (0x03)
                {
                    0x0180, 
                    0x802C5FFD, 
                    0x5B11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x03, 
                0x2376FAC0, 
                0x03, 
                Package (0x02)
                {
                    "GPU", 
                    0x53
                }, 

                Package (0x03)
                {
                    0x0140, 
                    0xA02C5FFD, 
                    0x5F11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x04, 
                0x1F972880, 
                0x04, 
                Package (0x02)
                {
                    "GPU", 
                    0x4A
                }, 

                Package (0x03)
                {
                    0x0100, 
                    0xA02C5FFD, 
                    0x6711
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x05, 
                0x175D7200, 
                0x05, 
                Package (0x02)
                {
                    "GPU", 
                    0x37
                }, 

                Package (0x03)
                {
                    0xC0, 
                    0x802D5FFD, 
                    0x7D11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x06, 
                0x12C684C0, 
                0x06, 
                Package (0x02)
                {
                    "GPU", 
                    0x2C
                }, 

                Package (0x03)
                {
                    0x80, 
                    0x802D5FFD, 
                    0x8C11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x07, 
                0x0E01D0C0, 
                0x07, 
                Package (0x02)
                {
                    "GPU", 
                    0x21
                }, 

                Package (0x03)
                {
                    0x40, 
                    0xA02D5FFD, 
                    0xA511
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x08, 
                0x094C5F00, 
                0x08, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }, 

                Package (0x03)
                {
                    0x30, 
                    0xA02D5FFD, 
                    0xD911
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x09, 
                Zero, 
                0x09, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }, 

                Package (0x03)
                {
                    Zero, 
                    Zero, 
                    Zero
                }
            }
        })
        Name (P004, Package (0x12)
        {
            "ENGINE_PSTATE_SET", 
            0x02, 
            "GRAPHICS_FREQ_CONTROL", 
            "CORE_CLOCK", 
            0x09, 
            0x03, 
            "TRUE", 
            0x05, 
            0x05, 
            Package (0x06)
            {
                "PSTATE", 
                Zero, 
                0x27EF6380, 
                Zero, 
                Package (0x02)
                {
                    "GPU", 
                    0x64
                }, 

                Package (0x03)
                {
                    0x01A0, 
                    0x802C5FFD, 
                    0x5A11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                One, 
                0x2540BE40, 
                One, 
                Package (0x02)
                {
                    "GPU", 
                    0x5D
                }, 

                Package (0x03)
                {
                    0x0180, 
                    0x802C5FFD, 
                    0x5B11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x02, 
                0x2376FAC0, 
                0x02, 
                Package (0x02)
                {
                    "GPU", 
                    0x59
                }, 

                Package (0x03)
                {
                    0x0140, 
                    0xA02C5FFD, 
                    0x5F11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x03, 
                0x1F972880, 
                0x03, 
                Package (0x02)
                {
                    "GPU", 
                    0x4F
                }, 

                Package (0x03)
                {
                    0x0100, 
                    0xA02C5FFD, 
                    0x6711
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x04, 
                0x175D7200, 
                0x04, 
                Package (0x02)
                {
                    "GPU", 
                    0x3B
                }, 

                Package (0x03)
                {
                    0xC0, 
                    0x802D5FFD, 
                    0x7D11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x05, 
                0x12C684C0, 
                0x05, 
                Package (0x02)
                {
                    "GPU", 
                    0x2F
                }, 

                Package (0x03)
                {
                    0x80, 
                    0x802D5FFD, 
                    0x8C11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x06, 
                0x0E01D0C0, 
                0x06, 
                Package (0x02)
                {
                    "GPU", 
                    0x23
                }, 

                Package (0x03)
                {
                    0x40, 
                    0xA02D5FFD, 
                    0xA511
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x07, 
                0x094C5F00, 
                0x07, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }, 

                Package (0x03)
                {
                    0x30, 
                    0xA02D5FFD, 
                    0xD911
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x08, 
                Zero, 
                0x08, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }, 

                Package (0x03)
                {
                    Zero, 
                    Zero, 
                    Zero
                }
            }
        })
        Name (P005, Package (0x12)
        {
            "ENGINE_PSTATE_SET", 
            0x02, 
            "GRAPHICS_FREQ_CONTROL", 
            "CORE_CLOCK", 
            0x09, 
            0x03, 
            "TRUE", 
            0x05, 
            0x05, 
            Package (0x06)
            {
                "PSTATE", 
                Zero, 
                0x1EA30480, 
                Zero, 
                Package (0x02)
                {
                    "GPU", 
                    0x64
                }, 

                Package (0x03)
                {
                    0x01A0, 
                    0x802C5FFD, 
                    0x5A11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                One, 
                0x1DCD6500, 
                One, 
                Package (0x02)
                {
                    "GPU", 
                    0x61
                }, 

                Package (0x03)
                {
                    0x0180, 
                    0x802C5FFD, 
                    0x5B11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x02, 
                0x1B7A4D40, 
                0x02, 
                Package (0x02)
                {
                    "GPU", 
                    0x5A
                }, 

                Package (0x03)
                {
                    0x0140, 
                    0xA02C5FFD, 
                    0x5F11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x03, 
                0x1823CF40, 
                0x03, 
                Package (0x02)
                {
                    "GPU", 
                    0x4F
                }, 

                Package (0x03)
                {
                    0x0100, 
                    0xA02C5FFD, 
                    0x6711
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x04, 
                0x12C684C0, 
                0x04, 
                Package (0x02)
                {
                    "GPU", 
                    0x3D
                }, 

                Package (0x03)
                {
                    0xC0, 
                    0x802D5FFD, 
                    0x7D11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x05, 
                0x0F424000, 
                0x05, 
                Package (0x02)
                {
                    "GPU", 
                    0x32
                }, 

                Package (0x03)
                {
                    0x80, 
                    0x802D5FFD, 
                    0x8C11
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x06, 
                0x0A8CCE40, 
                0x06, 
                Package (0x02)
                {
                    "GPU", 
                    0x22
                }, 

                Package (0x03)
                {
                    0x40, 
                    0xA02D5FFD, 
                    0xA511
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x07, 
                0x06EA0500, 
                0x07, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }, 

                Package (0x03)
                {
                    0x30, 
                    0xA02D5FFD, 
                    0xD911
                }
            }, 

            Package (0x06)
            {
                "PSTATE", 
                0x08, 
                Zero, 
                0x08, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }, 

                Package (0x03)
                {
                    Zero, 
                    Zero, 
                    Zero
                }
            }
        })
        Name (P006, Package (0x13)
        {
            "ENGINE_PSTATE_SET", 
            0x03, 
            "GRAPHICS_BW_CONTROL", 
            "BANDWIDTH", 
            0x0A, 
            Zero, 
            "TRUE", 
            0x06, 
            0x06, 
            Package (0x05)
            {
                "PSTATE", 
                Zero, 
                0x00000001AE2AAE40, 
                0x0180, 
                Package (0x02)
                {
                    "GPU", 
                    0x64
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                One, 
                0x00000001729F2680, 
                0x0100, 
                Package (0x02)
                {
                    "GPU", 
                    0x56
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x02, 
                0x0000000142949100, 
                0x0100, 
                Package (0x02)
                {
                    "GPU", 
                    0x4A
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x03, 
                0xF278C100, 
                0xC0, 
                Package (0x02)
                {
                    "GPU", 
                    0x38
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x04, 
                0xB6FC7B80, 
                0x80, 
                Package (0x02)
                {
                    "GPU", 
                    0x2A
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x05, 
                0xA25CF100, 
                0x80, 
                Package (0x02)
                {
                    "GPU", 
                    0x26
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x06, 
                0x824BB680, 
                0x80, 
                Package (0x02)
                {
                    "GPU", 
                    0x1E
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x07, 
                0x6B685680, 
                0x40, 
                Package (0x02)
                {
                    "GPU", 
                    0x19
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x08, 
                0x47680780, 
                0x30, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x09, 
                Zero, 
                Zero, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }
            }
        })
        Name (P007, Package (0x14)
        {
            "ENGINE_PSTATE_SET", 
            0x03, 
            "GRAPHICS_BW_CONTROL", 
            "BANDWIDTH", 
            0x0B, 
            Zero, 
            "TRUE", 
            0x07, 
            0x07, 
            Package (0x05)
            {
                "PSTATE", 
                Zero, 
                0x00000001F2D4CE40, 
                0x01A0, 
                Package (0x02)
                {
                    "GPU", 
                    0x64
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                One, 
                0x00000001AE2AAE40, 
                0x0180, 
                Package (0x02)
                {
                    "GPU", 
                    0x56
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x02, 
                0x00000001729F2680, 
                0x0100, 
                Package (0x02)
                {
                    "GPU", 
                    0x4A
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x03, 
                0x0000000142949100, 
                0x0100, 
                Package (0x02)
                {
                    "GPU", 
                    0x41
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x04, 
                0xF278C100, 
                0xC0, 
                Package (0x02)
                {
                    "GPU", 
                    0x31
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x05, 
                0xB6FC7B80, 
                0x80, 
                Package (0x02)
                {
                    "GPU", 
                    0x25
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x06, 
                0xA25CF100, 
                0x80, 
                Package (0x02)
                {
                    "GPU", 
                    0x21
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x07, 
                0x824BB680, 
                0x80, 
                Package (0x02)
                {
                    "GPU", 
                    0x1A
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x08, 
                0x6B685680, 
                0x40, 
                Package (0x02)
                {
                    "GPU", 
                    0x16
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x09, 
                0x47680780, 
                0x30, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }
            }, 

            Package (0x05)
            {
                "PSTATE", 
                0x0A, 
                Zero, 
                Zero, 
                Package (0x02)
                {
                    "GPU", 
                    Zero
                }
            }
        })
        If (((((\_SB.SOID == 0x0164) && (\_SB.SIDV >= 0x00020001)) && (
            \_SB.SIDT == 0x03)) || (((\_SB.SOID == 0x01E1) && (\_SB.SIDV >= 0x00020001)) && (\_SB.SIDT == 
            0x02))))
        {
            DerefOf (RBUF [0x04]) [0x0C] = P001 /* \_SB_.GPU0.PMCL.P001 */
        }
        ElseIf ((((((\_SB.SOID == 0x0164) && (\_SB.SIDV == 0x00020000)) && 
            (\_SB.SIDT == 0x05)) || (((\_SB.SOID == 0x0164) && (\_SB.SIDV >= 0x00020001)) && (
            \_SB.SIDT == 0x02))) || (((\_SB.SOID == 0x01E1) && (\_SB.SIDV >= 0x00020000)) && (\_SB.SIDT == 
            One))))
        {
            DerefOf (RBUF [0x04]) [0x0C] = P002 /* \_SB_.GPU0.PMCL.P002 */
        }
        ElseIf (((((\_SB.SOID == 0x0164) && (\_SB.SIDV >= 0x00020001)) && 
            (\_SB.SIDT == 0x05)) || (((\_SB.SOID == 0x01E1) && (\_SB.SIDV >= 0x00020001)) && (
            \_SB.SIDT == 0x03))))
        {
            DerefOf (RBUF [0x04]) [0x0C] = P003 /* \_SB_.GPU0.PMCL.P003 */
        }
        ElseIf ((\_SB.SIDV >= 0x00020000))
        {
            DerefOf (RBUF [0x04]) [0x0C] = P004 /* \_SB_.GPU0.PMCL.P004 */
        }
        Else
        {
            DerefOf (RBUF [0x04]) [0x0C] = P005 /* \_SB_.GPU0.PMCL.P005 */
        }

        If ((((((\_SB.SOID == 0x0164) && (\_SB.SIDV == 0x00020000)) && (
            \_SB.SIDT == 0x05)) || (((\_SB.SOID == 0x0164) && (\_SB.SIDV >= 0x00020001)) && (\_SB.SIDT == 
            0x02))) || (((\_SB.SOID == 0x01E1) && (\_SB.SIDV >= 0x00020000)) && (\_SB.SIDT == One))))
        {
            DerefOf (RBUF [0x04]) [0x0D] = P006 /* \_SB_.GPU0.PMCL.P006 */
        }
        Else
        {
            DerefOf (RBUF [0x04]) [0x0D] = P007 /* \_SB_.GPU0.PMCL.P007 */
        }

        Return (RBUF) /* \_SB_.GPU0.PMCL.RBUF */
    }

    // =========================================================================
    // 阶段 9：_HRV —— 硬件版本（由 SIDT/SIDV/SOID/SDFE 算出 Adreno 650 的 REV id）
    // 让 qcdx8250.inf 能匹配到具体的 REV_0913/0D15（PAF，"Adreno 650"）安装段；
    // 算不到已知 REV 时回落到通用 DEV_253A，绑定不受影响。
    // =========================================================================
    Method (_HRV, 0, NotSerialized)  // _HRV: Hardware Revision
    {
        Name (RESU, Zero)
        Name (TIER, Zero)
        Name (MINO, Zero)
        Name (MAJO, Zero)
        Name (TYPE, Zero)
        Name (FAMI, Zero)
        TIER = (\_SB.SIDT & 0x0F)
        MINO = (\_SB.SIDV & 0x07)
        MINO <<= 0x04
        MAJO = ((\_SB.SIDV >> 0x10) & 0x07)
        MAJO <<= 0x07
        If ((\_SB.SOID == 0x0164))
        {
            TYPE = (One << 0x0A)
        }

        If ((\_SB.SDFE == 0x5D))
        {
            FAMI = (One << 0x0B)
        }
        ElseIf ((\_SB.SDFE == 0x66))
        {
            FAMI = (0x02 << 0x0B)
        }

        RESU |= TIER /* \_SB_.GPU0._HRV.RESU */
        RESU |= MINO /* \_SB_.GPU0._HRV.RESU */
        RESU |= MAJO /* \_SB_.GPU0._HRV.RESU */
        RESU |= TYPE /* \_SB_.GPU0._HRV.RESU */
        RESU |= FAMI /* \_SB_.GPU0._HRV.RESU */
        Return (RESU) /* \_SB_.GPU0._HRV.RESU */
    }

}
