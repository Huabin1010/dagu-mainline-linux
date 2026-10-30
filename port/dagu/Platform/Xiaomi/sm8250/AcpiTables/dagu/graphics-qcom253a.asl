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
// PMCL（参考板约一万行的电源时钟表，引用 \_SB.SIDT/SIDV/SOID）本阶段不移植，
// 先验证能否越过上述门控。
//
// 相对参考节点做的裁剪：
//   - 去掉 9923 行面板配置 blob（_ROM/_DOD/_LID/_HRV/AVS0），那是面板点亮逻辑，
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
}
