// SPDX-License-Identifier: GPL-2.0
/*
 * camss-vfe-480.c
 *
 * Qualcomm MSM Camera Subsystem - VFE (Video Front End) Module v480 (SM8250)
 *
 * Copyright (C) 2020-2021 Linaro Ltd.
 * Copyright (C) 2021 Jonathan Marek
 */

#include <linux/dma-mapping.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/math64.h>
#include <media/v4l2-mediabus.h>

#include "camss.h"
#include "camss-vfe.h"

#define VFE_GLOBAL_RESET_CMD		(vfe_is_lite(vfe) ? 0x0c : 0x1c)
#define	    GLOBAL_RESET_HW_AND_REG	(vfe_is_lite(vfe) ? BIT(1) : BIT(0))

#define VFE_CORE_CFG_0			0x2c
/* CAF cam_vfe480.h top_common_reg. Linux never programmed it. Dump only. */
#define VFE_CORE_CFG_1			0x30
#define     CORE_CFG_0_INPUTMUX_PP	5
/* CAF cam_vfe480.h operating_mode_shift=11. Online CSID = 1, FE = 2. */
#define     CORE_CFG_0_OPERATING_MODE	11
/*
 * CAF cam_vfe480.h pixel_pattern_shift=24 overlaps dsp_mode_shift=24
 * and CAM_SHIFT_TOP_CORE_CFG_DSP_STREAMING=25. cam_vfe_camif_ver3.c
 * never writes pattern into core_cfg_0. CamX titan480 CAMIF Fill
 * @0x526508 ORs MODULE 0x101 then BFI pattern into bits 24-26
 * (0x526538). GBRG=3 << 24 on CORE_CFG is 0x63000800 and turns
 * DSP streaming on. Bayer for the pixel pipe is CAMIF MODULE
 * plus Demux 0x3070/0x3074. Keep the CORE shift named so persist
 * can reject stuffing pattern there.
 */
#define     CORE_CFG_0_PIXEL_PATTERN	24
#define     CORE_CFG_0_DSP_STREAMING	25
/* CAF cam_vfe_top_ver3.h: (~r2pd & 1) << shift. Default r2pd=0 → set bit. */
#define     CORE_CFG_0_DISP_DS4_R2PD	27
#define     CORE_CFG_0_DISP_DS16_R2PD	28
#define     CORE_CFG_0_VID_DS4_R2PD	29
#define     CORE_CFG_0_VID_DS16_R2PD	30
#define VFE_TOP_DEBUG_CFG		0xdc
#define VFE_TOP_DEBUG_0			0x80
/* CAF cam_vfe_camif_ver3.c: violation_status[5:0] is a module id, not a mask. */
#define     VIOL_ID_MASK		0x3f
#define     VIOL_ID_MNDS_C_DISP		19
#define VFE_CORE_CGC_OVD_1		0x94
#define VFE_VIOLATION_STATUS		0x74
#define CAMIF_DEBUG_1			0x27f0
#define CAMIF_DEBUG_0			0x27f4
#define VFE_CORE_CGC_OVD_0		0x20
#define VFE_AHB_CGC_OVD			0x24
#define VFE_NOC_CGC_OVD			0x28

#define VFE_REG_UPDATE_CMD		(vfe_is_lite(vfe) ? 0x20 : 0x34)
static inline int reg_update_rdi(struct vfe_device *vfe, int n)
{
	return vfe_is_lite(vfe) ? BIT(n) : BIT(1 + (n));
}

#define	    REG_UPDATE_RDI		reg_update_rdi
/* CAF cam_vfe480.h camif_reg_data.reg_update_cmd_data */
#define     REG_UPDATE_PIX		0x41
#define VFE_IRQ_CMD			(vfe_is_lite(vfe) ? 0x24 : 0x38)
#define     IRQ_CMD_GLOBAL_CLEAR	BIT(0)

#define VFE_IRQ_MASK(n)			((vfe_is_lite(vfe) ? 0x28 : 0x3c) + (n) * 4)
#define	    IRQ_MASK_0_RESET_ACK	(vfe_is_lite(vfe) ? BIT(17) : BIT(0))
#define	    IRQ_MASK_0_BUS_TOP_IRQ	(vfe_is_lite(vfe) ? BIT(4) : BIT(7))
/* CAF cam_vfe480.h error_irq_mask0 0x82000200: bit31 PIXEL PIPE OVERFLOW */
#define	    IRQ_MASK_0_PIX_OVERFLOW	BIT(31)
/* CAF subscribe_irq_mask1 0x7: CAMIF SOF / EOF / EPOCH */
#define	    IRQ_MASK_1_CAMIF		0x7
#define VFE_IRQ_CLEAR(n)		((vfe_is_lite(vfe) ? 0x34 : 0x48) + (n) * 4)
#define VFE_IRQ_STATUS(n)		((vfe_is_lite(vfe) ? 0x40 : 0x54) + (n) * 4)
#define VFE_DIAGNOSTIC_HW		0x64

#define BUS_REG_BASE			(vfe_is_lite(vfe) ? 0x1a00 : 0xaa00)

#define VFE_BUS_WM_CGC_OVERRIDE		(BUS_REG_BASE + 0x08)
#define		WM_CGC_OVERRIDE_ALL	(0x3FFFFFF)
/*
 * CAF cam_vfe480.h common_reg.comp_cfg_0/1 = 0xAA0C/0xAA10.
 * cam_vfe_bus_ver3_start_comp_grp writes them ONLY if is_dual:
 *   master: cfg0 bit(grp+14), cfg1 bit(grp)
 *   slave:  cfg0 bit(grp)|bit(grp+14), cfg1 bit(grp)
 * That is Dual-IFE address sync, not a WM4–7 membership mask.
 * HyperOS rear preview is single IFE1; #336 rst→ovf readback 0/0
 * matches CAF leaving them alone. Do not stuff 0xF0 / 0x30
 * (software composite_mask of clients 4–7) into these regs.
 * Client→COMP_GRP is the cam_vfe480.h table (DISP Y/C/DS4/DS16
 * = COMP_GRP_1). SRC_GRP frame headers are independent.
 */
#define VFE_BUS_COMP_CFG_0		(BUS_REG_BASE + 0x0c)
#define VFE_BUS_COMP_CFG_1		(BUS_REG_BASE + 0x10)
#define VFE_BUS_IF_FRAMEHEADER_CFG(n)	(BUS_REG_BASE + 0x34 + (n) * 4)
#define		BUS_FRAMEHEADER_GRPS	6
#define VFE_BUS_OVERFLOW_STATUS_CLEAR	(BUS_REG_BASE + 0x60)
#define VFE_BUS_DEBUG_STATUS_TOP_CFG	(BUS_REG_BASE + 0xd4)
#define VFE_BUS_DEBUG_STATUS_TOP	(BUS_REG_BASE + 0xd8)

#define VFE_BUS_WM_TEST_BUS_CTRL	(BUS_REG_BASE + 0xdc)

#define VFE_BUS_IRQ_MASK(n)		(BUS_REG_BASE + 0x18 + (n) * 4)
static inline int bus_irq_mask_0_rdi_rup(struct vfe_device *vfe, int n)
{
	return vfe_is_lite(vfe) ? BIT(n) : BIT(3 + (n));
}

#define     BUS_IRQ_MASK_0_RDI_RUP	bus_irq_mask_0_rdi_rup
static inline int bus_irq_mask_0_comp_done(struct vfe_device *vfe, int n)
{
	return vfe_is_lite(vfe) ? BIT(4 + (n)) : BIT(6 + (n));
}

#define     BUS_IRQ_MASK_0_COMP_DONE	bus_irq_mask_0_comp_done
#define VFE_BUS_IRQ_CLEAR(n)		(BUS_REG_BASE + 0x20 + (n) * 4)
#define VFE_BUS_IRQ_STATUS(n)		(BUS_REG_BASE + 0x28 + (n) * 4)
#define VFE_BUS_IRQ_CLEAR_GLOBAL	(BUS_REG_BASE + 0x30)
#define VFE_BUS_CCIF_VIOLATION		(BUS_REG_BASE + 0x64)
#define VFE_BUS_OVERFLOW_STATUS		(BUS_REG_BASE + 0x68)
#define VFE_BUS_IMAGE_SIZE_VIOLATION	(BUS_REG_BASE + 0x70)
#define     BUS_IRQ_MASK_0_PIX_RUP	BIT(0)

#define VFE_BUS_WM_CFG(n)		(BUS_REG_BASE + 0x200 + (n) * 0x100)
#define		WM_CFG_EN			(0)
#define		WM_CFG_MODE			(16)
#define			MODE_QCOM_PLAIN	(0)
#define			MODE_MIPI_RAW	(1)
#define VFE_BUS_WM_IMAGE_ADDR(n)	(BUS_REG_BASE + 0x204 + (n) * 0x100)
#define VFE_BUS_WM_FRAME_INCR(n)	(BUS_REG_BASE + 0x208 + (n) * 0x100)
#define VFE_BUS_WM_IMAGE_CFG_0(n)	(BUS_REG_BASE + 0x20c + (n) * 0x100)
#define		WM_IMAGE_CFG_0_DEFAULT_WIDTH	(0xFFFF)
#define VFE_BUS_WM_IMAGE_CFG_1(n)	(BUS_REG_BASE + 0x210 + (n) * 0x100)
#define VFE_BUS_WM_IMAGE_CFG_2(n)	(BUS_REG_BASE + 0x214 + (n) * 0x100)
#define VFE_BUS_WM_PACKER_CFG(n)	(BUS_REG_BASE + 0x218 + (n) * 0x100)
/*
 * CAF get_packer_fmt(NV12)=PLAIN_8_LSB_MSB_10=3 for Y and C.
 * NV21 chroma WM 1/3/5 is the ODD_EVEN twin (=4). Packer 3 was
 * last tried while Crop/MNDS still wrote CLC +0x64 spare, so
 * POST never finished; 4 on the same broken CLC also left
 * as0=0. CLC PIXEL/LINE and 2ppc V now stick — NV12 is 3.
 * 0xB is CamX UBWC overlay; do not write it onto linear NV12.
 * #365: chroma WM PLAIN_8=1 (Y stays 3).
 */
#define		PACKER_PLAIN_8			1
#define		PACKER_PLAIN_8_LSB_MSB_10	3
#define		PACKER_PLAIN_8_LSB_MSB_10_ODD_EVEN 4
#define		PACKER_PLAIN_64			10
#define		PACKER_UBWC_NV12		0xB
#define VFE_BUS_WM_DEBUG_CFG(n)		(VFE_BUS_WM_CFG(n) + 0x78)
/* CAF start_wm: bits[7:0]=status_0 mux, bits[15:8]=status_1.
 * Mux 1 is the packer FSM (dbg 0x20a/0x2ea). Mux 11 is
 * constraint_errors on debug_status_1; cfg=1 left that mux 0
 * so dbg1=0 was telemetry-blind.
 */
#define		WM_DEBUG_STATUS_0_MUX		1
#define		WM_DEBUG_STATUS_1_CONSTRAINT	11
#define VFE_BUS_WM_DEBUG(n)		(VFE_BUS_WM_CFG(n) + 0x7c)
/* CAF print_dimensions: 0=last consumed 1=last frame 2=fifo cnt 3=current. */
#define VFE_BUS_WM_ADDR_STATUS0(n)	(VFE_BUS_WM_CFG(n) + 0x68)
#define VFE_BUS_WM_ADDR_STATUS1(n)	(VFE_BUS_WM_CFG(n) + 0x6c)
#define VFE_BUS_WM_ADDR_STATUS2(n)	(VFE_BUS_WM_CFG(n) + 0x70)
#define VFE_BUS_WM_ADDR_STATUS3(n)	(VFE_BUS_WM_CFG(n) + 0x74)
/* CAF cam_vfe480.h common_reg.ubwc_static_ctrl. COMP_GRP_1 start ORs
 * DT ubwc-static-cfg. dagu is LPDDR5 → second cell 0x1036. This is
 * BUS DDR/UBWC encoder clocking, not "compress the NV12". Live
 * HyperOS preview also sets WM4/5 mode_cfg bit0 (UBWC_NV12); V4L2
 * linear keeps mode_cfg = 0.
 */
#define VFE_BUS_UBWC_STATIC_CTRL	(BUS_REG_BASE + 0x58)
#define		UBWC_STATIC_LPDDR5	0x1036
#define VFE_BUS_PWR_ISO_CFG		(BUS_REG_BASE + 0x5c)
#define VFE_BUS_WM_UBWC_BW_LIMIT(n)	(VFE_BUS_WM_CFG(n) + 0x1c)
#define VFE_BUS_WM_UBWC_META_ADDR(n)	(VFE_BUS_WM_CFG(n) + 0x40)
/*
 * CAF kona-camera.dtsi qcom,cam-cpas@ac40000 cam_camnoc. Linux
 * deleted camss interconnects because BCM rpmh_write_batch hangs
 * this QHEE. cam_cpastop_poweron still programs the NIU AHB LUTs
 * without ICC. IFE_LINEAR is DISP NV12; IFE_UBWC_STATS is WM6/7
 * PD10 in COMP_GRP_1; IFE_RDI_WR is the working RDI port.
 */
#define CAMNOC_PHYS			0x0ac42000UL
#define CAMNOC_SIZE			0x8000
#define CAMNOC_IFE_LINEAR		0xa00
#define CAMNOC_IFE_RDI_WR		0x1400
#define CAMNOC_IFE_UBWC_STATS		0x1a00
#define CAMNOC_NIU_FILL			0x20
#define CAMNOC_NIU_MAXWR		0x08
#define CAMNOC_NIU_PRI_LO		0x30
#define CAMNOC_NIU_PRI_HI		0x34
#define CAMNOC_NIU_URGENCY		0x38
#define CAMNOC_NIU_DANGER		0x40
#define CAMNOC_NIU_SAFE			0x48
#define CAMNOC_ERRVLD			0x7010
/* CAF cpastop_v480_100.h cam_cpas_v480_100_camnoc_specific */
#define CAMNOC_PRI_LO			0x66665433
#define CAMNOC_PRI_HI			0x66666666
#define CAMNOC_URGENCY			0x1030
#define CAMNOC_DANGER			0xffffff00
#define CAMNOC_SAFE			0x000f
#define VFE_BUS_WM_UBWC_META_CFG(n)	(VFE_BUS_WM_CFG(n) + 0x44)
#define VFE_BUS_WM_UBWC_MODE_CFG(n)	(VFE_BUS_WM_CFG(n) + 0x48)
#define VFE_BUS_WM_UBWC_STATS_CTRL(n)	(VFE_BUS_WM_CFG(n) + 0x4c)
#define VFE_BUS_WM_UBWC_CTRL_2(n)	(VFE_BUS_WM_CFG(n) + 0x50)
#define VFE_BUS_WM_DEBUG_1(n)		(VFE_BUS_WM_CFG(n) + 0x80)
/* CAF cam_vfe480.h client 4 frame_header_cfg 0xB028. */
#define VFE_BUS_WM_FRAME_HEADER_CFG(n)	(VFE_BUS_WM_CFG(n) + 0x28)
#define		DISP_META_PAGE		4096

#define VFE_BUS_WM_IRQ_SUBSAMPLE_PERIOD(n)	(BUS_REG_BASE + 0x230 + (n) * 0x100)
#define VFE_BUS_WM_IRQ_SUBSAMPLE_PATTERN(n)	(BUS_REG_BASE + 0x234 + (n) * 0x100)
#define VFE_BUS_WM_FRAMEDROP_PERIOD(n)		(BUS_REG_BASE + 0x238 + (n) * 0x100)
#define VFE_BUS_WM_FRAMEDROP_PATTERN(n)		(BUS_REG_BASE + 0x23c + (n) * 0x100)

#define VFE_BUS_WM_SYSTEM_CACHE_CFG(n)	(BUS_REG_BASE + 0x260 + (n) * 0x100)
#define VFE_BUS_WM_BURST_LIMIT(n)	(BUS_REG_BASE + 0x264 + (n) * 0x100)

/* for titan 480, each bus client is hardcoded to a specific path
 * and each bus client is part of a hardcoded "comp group"
 */
#define RDI_WM(n)			((vfe_is_lite(vfe) ? 0 : 23) + (n))
#define RDI_COMP_GROUP(n)		((vfe_is_lite(vfe) ? 0 : 11) + (n))

/* CAF cam_vfe480.h BUS client 4/5 DISP Y/C, COMP_GRP_1 */
#define DISP_Y_WM			4
#define DISP_C_WM			5
#define DISP_DS4_WM			6
#define DISP_DS16_WM			7
#define DISP_COMP_GROUP			1
/*
 * Live HyperOS COMP_GRP_1 mask 0xF0 = WM4–7. WM6/7 are PD10 after
 * DISP R2PD (format 0x24, packer PLAIN_64). Sizes/strides from the
 * 2026-09-16 21:06 start window, not invented.
 */
#define DISP_DS4_W			240
#define DISP_DS4_H			135
#define DISP_DS4_STRIDE			2048
#define DISP_DS4_INCR			327680
#define DISP_DS16_W			60
#define DISP_DS16_H			34
#define DISP_DS16_STRIDE		768
#define DISP_DS16_INCR			49152

#define MAX_VFE_OUTPUT_LINES	4

/*
 * Titan 480 CLC from camera.qcom.so CreateCmdList (titan480 HWL),
 * not from MOVZ #0x5600 / stats 0x8c00. module_cfg is base+0x60
 * except Demux13, which packs 7 AHB regs at 0x3090.
 *
 *   CAMIF PP     0x2660 / crop 0x2668  camxifecamifpptitan480.cpp
 *   Demux13      0x3090 x7 compact live 2026-09-17, not identity GBRG map
 *   Demosaic36   0x3860                camxifedemosaic36titan480.cpp
 *   CST12        0x4060 / 0x4068 x12   camxifecst12titan480.cpp
 *   RoundClamp   0x4260 x1 + 0x4270 x6 camxiferoundclamp11titan480.cpp
 *   Crop11 Y/C   0x4460/0x4660 x9      camxifecrop11titan480.cpp
 *   RoundClamp MID Y/C 0x4860/0x4a60   idx 1 between Crop and MNDS
 *   MNDS Disp Y  0x4c60 x9             "Scaler Display(Full) path"
 *   MNDS Disp C  0x4e60 x9
 *   RoundClamp POST Y/C 0x5060/0x5260 + 0x5070/0x5270 x6
 *
 * 0x8c00/0x8e00 are CS/iHist stats. 0x6400 is Video Full MNDS.
 * Do not STREAMON DISP without demux+demosaic+MNDS — empty CLC
 * hangs CAMNOC. POST RoundClamp EN=0 backs up MNDS C at line 1530.
 */
#define CLC_MODULE_CFG			0x60
#define CLC_PREPROCESS			0x2200
/* CamX 0x4e7688 DMI helper: w2=sel w4=offset w5=count. #315 used
 * sel4 offset 0x280 as n. Banks: 1 n=0x100, 2 n=0x100, 3 n=0x80,
 * 4 n=0xa8. Do not pack 0x2268 x46 zeros (reset / ABF class).
 */
#define     BLS_DMI_BANKS		4
#define     BLS_DMI_N1			0x100
#define     BLS_DMI_N2			0x100
#define     BLS_DMI_N3			0x80
#define     BLS_DMI_N4			0xa8
#define CLC_CAMIF			0x2600
#define     CAMIF_EN			BIT(0)
#define     CAMIF_IFE_OUT_EN		BIT(8)
/* CamX 0x526538: BFI pattern, #24, #3 into CAMIF MODULE_CFG. */
#define     CAMIF_PIXEL_PATTERN		24
#define CAMIF_SPARE			0x2664
#define CAMIF_CROP_WIDTH		0x2668
#define CAMIF_CROP_HEIGHT		0x266c
#define CAMIF_LINE_SKIP			0x2670
#define CAMIF_PIXEL_SKIP		0x2674
#define CAMIF_PERIOD			0x2678
#define CAMIF_IRQ_SUBSAMPLE		0x267c
#define CLC_CAMIF_EPOCH			0x2680
/*
 * CamX titan480 IFE PP CreateCmdList between CAMIF and Demux.
 * Same CLC as BLS: EN=0 is a brick wall (violation bit1 on 0x2200).
 */
#define CLC_PDPC11			0x2800
#define CLC_PDPC30			0x2e00
#define     PDPC30_AHB			0x68
#define     PDPC30_AHB_N		16
#define     PDPC30_DMI_N		0x90
#define     PDPC_GAIN_UNITY		0x400
/*
 * Pedestal13 compact CreateCmdList @0x540a30: MODULE_CFG 0x2c60 x1.
 * FULL @0x540198 packs 0x2c68 x5 + DMI 0x2c08 banks 1/2 ×0x208.
 * BLS EN=0 is a brick wall on this CLC; pedestal is the same class
 * of black-level subtract. Identity is a zero LUT (subtract 0),
 * not empty EN. Compact does not pack 0x2c5c / 0x2c68.
 */
#define CLC_PEDESTAL			0x2c00
#define     PEDESTAL_LUT_N		0x208
#define     PEDESTAL_WIN		0x5c
#define     PEDESTAL_AHB		0x68
#define CLC_ABF				0x3200
/*
 * camera.qcom.so has no IFE GIC HWL. Linux called 0x3400 "GIC".
 * Compact ABF bank1 @0x5359d8 is 0x3260 x1. Compact bank2 @0x528688
 * is 0x3460 x1. FULL @0x5275b8 packs 0x3458 x3 + 0x3468 x46 + DMI
 * 0x3408. DumpRegConfig SECTION 0x3458/0x3468 is the IQ object, not
 * CreateCmdList. Do not pack 0x3458/0x3468. PackIQ @0x5279c0: 12-bit
 * last/first at object+36/+40 = 0x3270/0x3274. compact leaves 0x3268
 * at HW reset 0x8000/0x1000100. Do not Crop11 0x3268 / 0x3270.
 */
#define     ABF_REGION			0x70
#define CLC_GIC				0x3400
#define     ABF_BANK2_DMI_N1		0x100
#define     ABF_BANK2_DMI_N3		0x80
#define     ABF_BANK2_DMI_N4		0xa8
#define     ABF_BANK2_LUT_BANK		0x58
#define     ABF_BANK2_AHB		0x68
#define     ABF_BANK2_AHB_N		46
/* Live DumpRegConfig 0x3460, not BIT(0). Compact ABF is 0x3260 only. */
#define     ABF_BANK2_MODULE		0xc101
#define CLC_HDR				0x2400
/* CAF cam_vfe480.h: only CAMIF has debug_0 at 0x27F4. CLC +0x04 is
 * hw_status (CAMIF 0x2604). Crop +0x64 is the spare/status hole.
 */
#define CLC_HW_STATUS			0x04
#define CLC_CAMIF_DEBUG_1		0x1f0
#define CLC_CC				0x3a00
/*
 * camera.qcom.so CC13 CreateCmdList: 1 AHB word MODULE_CFG at 0x3a60
 * then 9 words at 0x3a68 from IQ+0x1c. Compact packs 0x3a60 x1 only.
 * +0x64 is the same spare hole as Crop/CAMIF.
 * EN=1 with a zero 3×3 is not BLS-style pass-through — it multiplies
 * RGB by 0 so POST never presents packer valid (as0=0, viol_id=0).
 * Live DumpRegConfig packs 13-bit pairs (A0=0x80, B1=0x80, C2=0x80),
 * not nine Q10 scalars. Q10 0x400 on the diagonal zeroed B0|B1.
 */
#define     CLC_CC_SPARE		0x64
#define     CLC_CC_MATRIX		0x68
#define     CC_GAIN_UNITY		0x400
/*
 * camera.qcom.so titan480 CreateCmdList between Demosaic/CC and CST.
 * GTM10 0x3658 x15, WB13 0x3c58 x3, Gamma16 0x3e58 x3. Linearization34
 * compact is 0x2a60 x6 after PDPC11. CalculateHWSetting packs DMI
 * n=36 (9 PWL segments × 4 channels) as 14-bit pairs at 0x2a08
 * banks 1/2, then 6 AHB words from MODULE_CFG. Empty EN=1 overflowed
 * line 0. EN=0 was never identity-tested (BLS-class candidate).
 */
#define CLC_LIN				0x2a00
#define     LIN_DMI_N			36
#define CLC_GTM				0x3600
/*
 * 0x3600 is LSC40 (camxifelsc40titan480.cpp @0x5378a8), not GTM10.
 * GTM10 packs 0x3c58/0x3c08. FULL LSC: 0x3658 x3, 0x3668 x11,
 * DMI 0x3608 sel1/2/3 n=0x374 (=17x13x4). Compact only 0x3660 x1.
 * Empty EN=1 overflowed line 0. Identity DMI is Q10 pair unity.
 *
 * #329 EN=1 with 0x3668=0: interpolator window empty, as0=0
 * line=1530. PackIQ @0x537e6c: config0 bits[3:0]/[7:4] = mesh-2
 * (15/11 → 17x13). Live DumpRegConfig Config 0-10 (not a 256×128
 * guess): 0xbf, 0x7f007f, 0x1000000f×2, 0x30004, 0, 0x30000,
 * 0x4000400, 0x40, 0, 0. Identity DMI is Q10 pair unity.
 */
#define     GTM_DMI_N			0x374
#define     LSC_AHB			0x68
#define     LSC_CFG_N			11
#define     LSC_MESH_HM2		15
#define     LSC_MESH_VM2		11
#define CLC_WB				0x3c00
#define CLC_GAMMA			0x3e00
#define     CLC_DMI_CFG			0x08
#define     CLC_DMI_LUT			0x0c
#define     GAMMA_LUT_N			256
#define     WB_LUT_N			512
#define CLC_DEMUX_BASE			0x3000
#define CLC_DEMUX			0x3090
#define     DEMUX_GAIN_UNITY		0x04000400
#define     DEMUX_PERIOD_KEEPALL	0x00010001
/*
 * Compact CreateCmdList @0x52dfbc: 0x3090 x7 from IQ object+0x18.
 * Live DumpRegConfig 2026-09-17 (rear IFE1), not Q10 unity / GBRG map:
 *   +0x18 moduleConfig 0x3c003c01 → 0x3090
 *   +0x1c gainCH0      0x10111011 → 0x3094
 *   +0x20 gainCH12     0x10101010 → 0x3098
 *   +0x24 rightGainCH0 0x10111011 → 0x309c
 *   +0x28 rightGainCH12 0x10101010 → 0x30a0
 *   +0x2c even         0xac       → 0x30a4
 *   +0x30 odd          0xc9       → 0x30a8
 * DEMUX_EVEN_GBRG stays as the 2-bit map name persist needs; compact
 * does not pack that encoding at 0x3090.
 */
#define     DEMUX_COMPACT_CFG		0x3c003c01
#define     DEMUX_COMPACT_GAIN0		0x10111011
#define     DEMUX_COMPACT_GAIN12	0x10101010
#define     DEMUX_COMPACT_EVEN		0xac
#define     DEMUX_COMPACT_ODD		0xc9
#define     DEMOSAIC_COMPACT_CFG	0x4001
/*
 * camera.qcom.so Demux13 CreateCmdList @0x53ef10: 0x3058 x3
 * (ends at MODULE_CFG 0x3060), skip +0x64 spare, 0x3068 x10,
 * 0x30ac x10, DMI 0x3008 banks 1×512 + 2×256. Compact HWL
 * still packs 7 words at 0x3090 from IQ+0x18 (live values above).
 *
 * Live: 0x0FEF0000 at 0x3068 → 0 (not PIXEL). 0x00010001 at
 * 0x3068 → 0x1 (bit16 drops, same class as MNDS 0x103→0x101).
 * Word0 is EN; period keep-all belongs at +0x6c like 0x3094.
 */
#define     DEMUX_WIN			0x68
#define     DEMUX_WIN_N			10
#define     DEMUX_TAIL			0xac
/*
 * CreateCmdList 0x53ef44 packs 0x30ac ×10 from object+0x4c.
 * EN+period at 0x30ac/0x30b0 dropped (spare hole, #Demux-tail).
 * MODULE of a Crop11 block sits at base+0x60, so a Crop11 whose
 * MODULE is 0x30ac has base 0x304c. Reset 0 there is an empty
 * window after Demux period — CLC after Demux never presents
 * packer valid (as0=0, viol_id=0, line=1530).
 */
#define     CLC_DEMUX_TAIL_CROP		0x304c
#define     DEMUX_DMI1_N		0x200
#define     DEMUX_DMI2_N		0x100
/* 2-bit channel map, 0=R 1=GR 2=GB 3=B. GBRG even GB,B odd R,GR. */
#define     DEMUX_EVEN_GBRG		0xeeeeeeee
#define     DEMUX_ODD_GBRG		0x44444444
#define CLC_DEMOSAIC			0x3800
#define CLC_DEMOSAIC_INTERP		0x3878
#define     DEMOSAIC_WB			0x68
#define     DEMOSAIC_WB_N		4
/*
 * CamX compact Demosaic36 is {0x3860, 1} MODULE_CFG only. FULL Fill
 * packs 13-bit pairs into 0x3878/0x387c (mid-scale 0x80 → 0x800080).
 * Writing that over HW reset is the ABF 0x3268 class. Dump interp;
 * do not program it until a CamX compact dump shows those dwords.
 *
 * camxifewb13titan480 CreateCmdList @0x546be8 packs 0x3868 x4, not
 * 0x3c58 (that is GTM10). Reset 0 at the four channel gains after
 * Demosaic EN=1 is a black RGB brick (CAMIF still counts line=1530,
 * packer as0=0). Identity is Q10 0x400 like Demux/CC. Do not touch
 * 0x3878.
 */
#define     DEMOSAIC_INTERP_MID		((0x80 << 16) | 0x80)
#define CLC_CST				0x4000
#define CLC_CST_MATRIX			0x4068
/*
 * CreateCmdList Display: CST → RoundClamp11 PRE 0x4200 → Crop11 Y
 * 0x4400 / C 0x4600 → RoundClamp11 MID 0x4800/0x4a00 → MNDS →
 * RoundClamp11 POST 0x5000/0x5200. Compact {0x4260,10} is MODULE_CFG
 * + spare + PIXEL/LINE + 6 clamp words. FULL packs 0x4260×1 +
 * 0x4270×6, then a second list writes 0x4268×2 / 0x5068×2 /
 * 0x5268×2 (same +0x68/+0x6c keep-all as Crop11). Reset 0 there
 * is an empty window: POST EN=1 still never presents packer valid.
 */
#define CLC_RNDCLAMP			0x4200
#define CLC_CROP			0x4400
#define CLC_CROP_C			0x4600
/*
 * Titan 480 CLC +0x64 is the same spare/status hole as CAMIF_SPARE
 * 0x2664. PIXEL at +0x64 bounced 0x0FEF0000 → 0x6d0000 (empty
 * horizontal window, 0 AXI). Width/height sit at +0x68/+0x6c like
 * CAMIF_CROP_WIDTH/HEIGHT.
 */
#define     CROP_SPARE			0x64
#define     CROP_PIXEL			0x68
#define     CROP_LINE			0x6c
/*
 * CamX CreateCmdList packs 9 AHB words from 0x4460. PIXEL/LINE at
 * +0x68/+0x6c stick; +0x64 is the CAMIF spare hole. The remaining
 * five words are the same stripe/pad handshake as Display MNDS
 * (H_STRIPE last in [31:16]). Reset 0 is an empty stripe: POST
 * never presents packer valid (WM4 dbg=0, as0=0, viol_id=0).
 */
#define     CROP_H_STRIPE		0x70
#define     CROP_H_PAD			0x74
#define     CROP_V_SIZE			0x78
#define     CROP_V_PHASE		0x7c
#define     CROP_V_STRIPE		0x80
#define CLC_RNDCLAMP_MID_Y		0x4800
#define CLC_RNDCLAMP_MID_C		0x4a00
#define CLC_MNDS_Y			0x4c00
#define CLC_MNDS_C			0x4e00
#define CLC_RNDCLAMP_POST_Y		0x5000
#define CLC_RNDCLAMP_POST_C		0x5200
/*
 * CamX compact after POST C {0x5260,10}: {0x5504,2} {0x5704,2}
 * {0x5a60,10}. CreateCmdList packs 0x5860×1 + 0x5870×6 and
 * 0x5868×2 / 0x5a68×2 — same RoundClamp11 IP as POST. #316
 * OUT keep-all stuck (outy=0x77f0000/0x4370000) and still
 * as0=0 packer 0x2ea — EN=0 there is not the remaining stall.
 *
 * compact CreateCmdList @0x52e8e0 reads IQ +0x6c:
 *   5 → TAP 0x5408×2 / 0x5504×2 (DS4)
 *   6 → TAP 0x5c08×2 / 0x5d04×2 (DS16 AHB, not DMI LUT)
 *   3 → TAP 0x7408×2 / 0x7504×2
 *   else Display Full: ret, packs nothing. Linear NV12 is
 *   WM4/5; type-5/6 TAP is off.
 * #317: 0x5408 bounced 0 (CLC DMI_CFG auto-clear), 0x540c stuck
 * with LINE — crop encoding stuffed into the DS4 Y LUT.
 * #318: empty Crop EN at 0x5e00 STREAMON EPIPE -32. Do not
 * write TAP crop/DMI or EN 0x5e00. Dump 0x5408/0x5504 as
 * reset. Do not EN WM6/7 without a real DSX10 program.
 *
 * IFE DSX10 @0x509548 / @0x5018d4 (DMI 0x5c08 sel 1..13 +
 * 0x5e68×9) has zero BL xrefs. ELF 0x8bba10 live vtable packs
 * BPS 0x6c58, not IFE 0x5e68. LUT bytes still missing.
 * Filling (i<<8)|i or zeros is the LIN/empty-EN class.
 */
#define CLC_DS411_Y_CROP		0x5408
#define CLC_DS411_C_CROP		0x5504
#define CLC_RNDCLAMP_OUT_Y		0x5800
#define CLC_RNDCLAMP_OUT_C		0x5a00
#define     RNDCLAMP_CH0		0x70
#define     RNDCLAMP_MODULE_CFG		0x3c01

/*
 * Display MNDS21: MODULE_CFG at +0x60, then 8 config words from
 * +0x68 (camxifemnds21titan480.cpp + CAMIF spare hole). +0x64 is
 * RO status: H_SIZE 0x077F0FEF bounced to 0x6d0600 while +0x68
 * stuck. Writing phase into the size slot is in_w=1 → packer wait.
 */
#define MNDS_SPARE			0x64
#define MNDS_H_SIZE			0x68
#define MNDS_H_PHASE			0x6c
#define MNDS_H_STRIPE			0x70
#define MNDS_H_PAD			0x74
#define MNDS_V_SIZE			0x78
#define MNDS_V_PHASE			0x7c
#define MNDS_V_STRIPE			0x80
#define MNDS_V_PAD			0x84
#define MNDS_PHASE_Q			21

static void vfe_global_reset(struct vfe_device *vfe)
{
	writel_relaxed(IRQ_MASK_0_RESET_ACK, vfe->base + VFE_IRQ_MASK(0));
	writel_relaxed(GLOBAL_RESET_HW_AND_REG, vfe->base + VFE_GLOBAL_RESET_CMD);
}

static u32 vfe_480_pixel_pattern(u32 code)
{
	switch (code) {
	case MEDIA_BUS_FMT_SRGGB8_1X8:
	case MEDIA_BUS_FMT_SRGGB10_1X10:
	case MEDIA_BUS_FMT_SRGGB12_1X12:
	case MEDIA_BUS_FMT_SRGGB14_1X14:
		return 0;
	case MEDIA_BUS_FMT_SGRBG8_1X8:
	case MEDIA_BUS_FMT_SGRBG10_1X10:
	case MEDIA_BUS_FMT_SGRBG12_1X12:
	case MEDIA_BUS_FMT_SGRBG14_1X14:
		return 1;
	case MEDIA_BUS_FMT_SBGGR8_1X8:
	case MEDIA_BUS_FMT_SBGGR10_1X10:
	case MEDIA_BUS_FMT_SBGGR12_1X12:
	case MEDIA_BUS_FMT_SBGGR14_1X14:
		return 2;
	case MEDIA_BUS_FMT_SGBRG8_1X8:
	case MEDIA_BUS_FMT_SGBRG10_1X10:
	case MEDIA_BUS_FMT_SGBRG12_1X12:
	case MEDIA_BUS_FMT_SGBRG14_1X14:
	default:
		return 3; /* GBRG: s5kjn1 */
	}
}

static void vfe_480_clc_enable(struct vfe_device *vfe, u32 base, u32 val)
{
	writel_relaxed(val, vfe->base + base + CLC_MODULE_CFG);
}

static void vfe_480_pack(struct vfe_device *vfe, u32 addr,
			 const u32 *w, unsigned int n)
{
	unsigned int i;

	for (i = 0; i < n; i++)
		writel_relaxed(w[i], vfe->base + addr + i * 4);
}

static void vfe_480_crop(struct vfe_device *vfe, u32 base, u32 last_x,
			 u32 last_y);

/*
 * Live IFE CDM 2026-09-17 (1MB dmabuf, Display Full packet 2):
 * FULL @0x53ef10 packs 0x3058 x3 + 0x3068 x10 + 0x30ac x10 AND
 * compact 0x3090 x7. Reset 0 at 0x30ac is an empty window after
 * Demux — packer as0=0, viol_id=0, line=1530. Do not Crop11-guess
 * last/first onto 0x3068; these 10-word blobs are the CDM.
 */
static void vfe_480_demux(struct vfe_device *vfe, u32 in_w, u32 in_h)
{
	static const u32 live_3090[] = {
		DEMUX_COMPACT_CFG, DEMUX_COMPACT_GAIN0, DEMUX_COMPACT_GAIN12,
		DEMUX_COMPACT_GAIN0, DEMUX_COMPACT_GAIN12,
		DEMUX_COMPACT_EVEN, DEMUX_COMPACT_ODD,
	};
	static const u32 live_3058[] = {
		0x00000001, 0x00000001, 0x00e35203,
	};
	static const u32 live_3068[] = {
		0x000003c0, 0x01001000, 0x00004020, 0x00140014,
		0x00001a5c, 0x00001d4f, 0x000009b6, 0x000008bc,
		0x00020008, 0x0bf40ff0,
	};
	static const u32 live_30ac[] = {
		0x0000443c, 0x000003ff, 0x00000000, 0x00200080,
		0x00000020, 0x000a000a, 0x00000064, 0x00000080,
		0x00000060, 0x00000014,
	};

	/*
	 * live_3068 last word 0x0bf40ff0 is rear 4080×3060. Packing
	 * that onto imx596 2592×1952 leaves Demux after CAMIF with
	 * an empty window (#367 overflow line=976 as0=0). Camera ID 1
	 * heap: last 0x07a00a20, 3058 third word 0xe24203.
	 * 0x3090 even/odd 0xac/0xc9 is GBRG compact (rear). Front
	 * BGGR heap 0x3090 is 0x08c908c9 ×4 + even 0xca odd 0x9c.
	 */
	if (in_w == 4080 && in_h == 3060) {
		vfe_480_pack(vfe, CLC_DEMUX, live_3090, ARRAY_SIZE(live_3090));
		vfe_480_pack(vfe, 0x3058, live_3058, ARRAY_SIZE(live_3058));
		vfe_480_pack(vfe, 0x3068, live_3068, ARRAY_SIZE(live_3068));
		vfe_480_pack(vfe, 0x30ac, live_30ac, ARRAY_SIZE(live_30ac));
	} else if (in_w == 2592 && in_h == 1952) {
		/*
		 * #419 Camera ID 1 live 1MB CDM 2026-09-18 15:24:
		 * 0x3090 compact gain 0x04040404 (not heap 0x08c908c9),
		 * 0x3068 middle 0x20b1/0x17e7/0x7d5/0xab6. Last still
		 * 0x07a00a20. #417/#418 640 MID/OUT dest 0-byte; Demux
		 * blob was still the heap snapshot. One module.
		 * #419 on #436: demux=0x3c003c01/0x4040404 stuck,
		 * /tmp/pix.nv12 0 bytes, viol=0 img=0 bus=0 as0=0,
		 * mid_y=0xe01/0x79f/0xa1f. Same quiet class as #413.
		 * Compact gain is not the identity stall. Keep.
		 * #420 first-list 0x3058 {0,0,0xe24003} @0x1c0 with
		 * that 0x3090/0x3068. Linux still had later-list
		 * {1,1,0xe24203} @0x114a0 (AWB 0x04df04df companion).
		 * One variable: Demux 0x3058 first-list. Do not
		 * 0x04df04df. Do not 640 dest. Do not Dual-IFE.
		 * #420 on #437: /tmp/pix.nv12 0 bytes, viol=0
		 * img=0x0 as0=0 bus=0x0, demux still 0x4040404.
		 * Same quiet class as #419. 0x3058 first-list is
		 * not the identity stall. Keep.
		 */
		static const u32 front_3090[] = {
			0x3c003c01, 0x04040404, 0x04040404, 0x04040404,
			0x04040404, 0x000000ca, 0x0000009c,
		};
		static const u32 front_3058[] = {
			0x00000000, 0x00000000, 0x00e24003,
		};
		static const u32 front_3068[] = {
			0x000003c0, 0x01001000, 0x00004020, 0x00140014,
			0x000020b1, 0x000017e7, 0x000007d5, 0x00000ab6,
			0x00000000, 0x07a00a20,
		};
		static const u32 front_30ac[] = {
			0x0000443c, 0x000003ff, 0x00000000, 0x00200080,
			0x00000020, 0x000a000a, 0x00000064, 0x00000040,
			0x00000060, 0x00000014,
		};

		vfe_480_pack(vfe, CLC_DEMUX, front_3090, ARRAY_SIZE(front_3090));
		vfe_480_pack(vfe, 0x3058, front_3058, ARRAY_SIZE(front_3058));
		vfe_480_pack(vfe, 0x3068, front_3068, ARRAY_SIZE(front_3068));
		vfe_480_pack(vfe, 0x30ac, front_30ac, ARRAY_SIZE(front_30ac));
	}
}

/*
 * CC13 FULL CreateCmdList @0x52925c: 0x3a60 x1 from +0x18, 0x3a68 x9
 * from +0x1c. Live IQ 2026-09-17 (rear IFE1), not unpacked Q10:
 *   A0=0x80 A1=0 / B0=0 B1=0x80 / C0=0 C2=0x80, offsets 0, shift 0.
 */
static void vfe_480_cc(struct vfe_device *vfe)
{
	static const u32 live_cc13[9] = {
		0x80, 0,
		0x800000, 0,
		0, 0x80,
		0, 0, 0,
	};
	u32 i;

	/* #362: restore live CC EN; PDPC30 stays MODULE=0. */
	vfe_480_clc_enable(vfe, CLC_CC, BIT(0));
	writel_relaxed(0, vfe->base + CLC_CC + CLC_CC_SPARE);
	for (i = 0; i < 9; i++)
		writel_relaxed(live_cc13[i],
			       vfe->base + CLC_CC + CLC_CC_MATRIX + i * 4);
}

/*
 * Gamma16 CDM DMI_32: DMIAddr 0x3e08, DMISel 1/2/3, 0x100 words.
 * CDM writes sel to DMI_CFG then bursts LUT to DMI_CFG+4. 16-bit
 * identity (i<<8)|i is the pass-through curve, not an empty EN.
 */
static void vfe_480_clc_dmi32(struct vfe_device *vfe, u32 base, u32 sel,
			      const u32 *lut, unsigned int n)
{
	unsigned int i;

	writel_relaxed(sel, vfe->base + base + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < n; i++)
		writel_relaxed(lut[i], vfe->base + base + CLC_DMI_LUT);
	wmb();
}

static void vfe_480_gamma(struct vfe_device *vfe)
{
	u32 lut[GAMMA_LUT_N];
	unsigned int i, bank;

	for (i = 0; i < GAMMA_LUT_N; i++)
		lut[i] = (i << 8) | i;
	for (bank = 1; bank <= 3; bank++)
		vfe_480_clc_dmi32(vfe, CLC_GAMMA, bank, lut, GAMMA_LUT_N);
	writel_relaxed(0, vfe->base + CLC_GAMMA + CLC_DMI_CFG);
	wmb();
	/*
	 * 0x3e58×3 lands on 0x3e58/0x3e5c/0x3e60. Third word is
	 * MODULE_CFG. #351 packed 0,0,1: MODULE still 1, AXI as0
	 * consumed, NV12 all zero. Identity DMI is not live
	 * 0xdfdcXXXX. #352 MODULE=0 until a real Gamma LUT exists.
	 */
	vfe_480_pack(vfe, 0x3e58, (const u32[]){ 0, 0, 0 }, 3);
}

/*
 * WB13 CDM DMI_32: DMIAddr 0x3c08, DMISel 1, 0x200 words. Gamma
 * identity DMI already proved this protocol (EN=1, line=1530, no
 * line-0 overflow). Q10 pair unity matches Demux. EN=0 between
 * CC and Gamma may still be a hardwired RGB stall.
 */
static void vfe_480_wb(struct vfe_device *vfe)
{
	unsigned int i;

	writel_relaxed(1, vfe->base + CLC_WB + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < WB_LUT_N; i++)
		writel_relaxed(DEMUX_GAIN_UNITY,
			       vfe->base + CLC_WB + CLC_DMI_LUT);
	wmb();
	writel_relaxed(0, vfe->base + CLC_WB + CLC_DMI_CFG);
	wmb();
	/*
	 * Same map as Gamma: 0x3c60 is MODULE. #351 0,0,1 kept EN
	 * and wrote zeros. True bypass is 0,0,0. Comment about
	 * EN=0 RGB stall is the #352 falsifier — keep live Crop.
	 */
	vfe_480_pack(vfe, 0x3c58, (const u32[]){ 0, 0, 0 }, 3);
}

static void vfe_480_gtm(struct vfe_device *vfe, u32 last_x, u32 last_y)
{
	static const u32 live_lsc40[LSC_CFG_N] = {
		LSC_MESH_HM2 | (LSC_MESH_VM2 << 4), /* Config 0 = 0xbf */
		0x007f007f,
		0x1000000f,
		0x1000000f,
		0x00030004,
		0,
		0x00030000,
		0x04000400,
		0x40,
		0,
		0,
	};
	unsigned int i, bank;

	/* AHB is the live 4080×1530 dump, not a 256×128 guess. */
	(void)last_x;
	(void)last_y;

	for (bank = 1; bank <= 3; bank++) {
		writel_relaxed(bank, vfe->base + CLC_GTM + CLC_DMI_CFG);
		wmb();
		for (i = 0; i < GTM_DMI_N; i++)
			writel_relaxed(DEMUX_GAIN_UNITY,
				       vfe->base + CLC_GTM + CLC_DMI_LUT);
		wmb();
	}
	writel_relaxed(0, vfe->base + CLC_GTM + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < LSC_CFG_N; i++)
		writel_relaxed(live_lsc40[i],
			       vfe->base + CLC_GTM + LSC_AHB + i * 4);
	/* #356: live 0x3668 stays; 0x3660 MODULE=0 is true bypass. */
	vfe_480_pack(vfe, 0x3658, (const u32[]){ 0, 0, 0 }, 3);
}

/*
 * Live Linearization34 DMI 36 + 16 AHB knees from A-slot preview
 * (dmabuf 212992B off 0x2c8d0, heap type=0x1a n=0x24). #345 wrote
 * MODULE EN=1 and 16 knees from 0x2a64: PIXEL PIPE OVERFLOW line=0,
 * 2a64 readback 0, 2a68 truncated 0x25102e/0x201c. Compact dump is
 * 0x2a60 x6 — 16 FULL knees are not that window. EN=0 is bypass
 * (line=1530). Do not call until CreateCmdList names the AHB dest.
 */
static void __maybe_unused vfe_480_lin(struct vfe_device *vfe)
{
	static const u32 live_dmi[LIN_DMI_N] = {
		0x00000000, 0x00000000, 0x00000000, 0x00000000,
		0x04000000, 0x04000000, 0x04000000, 0x04000000,
		0x040007f7, 0x040007f7, 0x040007f7, 0x040007f7,
		0x04000fee, 0x04000fee, 0x04000fee, 0x04000fee,
		0x040017e5, 0x040017e5, 0x040017e5, 0x040017e5,
		0x04001fdc, 0x04001fdc, 0x04001fdc, 0x04001fdc,
		0x040027d3, 0x040027d3, 0x040027d3, 0x040027d3,
		0x04002fca, 0x04002fca, 0x04002fca, 0x04002fca,
		0x042037c1, 0x0421b7c1, 0x042237c1, 0x0420b7c1,
	};
	static const u32 live_ahb[16] = {
		0x08370040, 0x1825102e, 0x2813201c, 0x3801300a,
		0x083a0043, 0x18281031, 0x2816201f, 0x3804300d,
		0x08380041, 0x1826102f, 0x2814201d, 0x3802300b,
		0x083b0044, 0x18291032, 0x28172020, 0x3805300e,
	};
	unsigned int i, bank;

	for (bank = 1; bank <= 2; bank++) {
		writel_relaxed(bank, vfe->base + CLC_LIN + CLC_DMI_CFG);
		wmb();
		for (i = 0; i < LIN_DMI_N; i++)
			writel_relaxed(live_dmi[i],
				       vfe->base + CLC_LIN + CLC_DMI_LUT);
		wmb();
	}
	writel_relaxed(0, vfe->base + CLC_LIN + CLC_DMI_CFG);
	wmb();
	writel_relaxed(BIT(0), vfe->base + CLC_LIN + CLC_MODULE_CFG);
	/* Heap: MODULE at +0x60, then 16 knees packed at +0x64. */
	for (i = 0; i < 16; i++)
		writel_relaxed(live_ahb[i],
			       vfe->base + CLC_LIN + 0x64 + i * 4);
}

static void vfe_480_pedestal(struct vfe_device *vfe, u32 last_x, u32 last_y)
{
	unsigned int i, bank;

	/* Compact @0x540a30 is 0x2c60 x1. last_x/y are FULL Crop11. */
	(void)last_x;
	(void)last_y;

	for (bank = 1; bank <= 2; bank++) {
		writel_relaxed(bank, vfe->base + CLC_PEDESTAL + CLC_DMI_CFG);
		wmb();
		for (i = 0; i < PEDESTAL_LUT_N; i++)
			writel_relaxed(0, vfe->base + CLC_PEDESTAL + CLC_DMI_LUT);
		wmb();
	}
	/*
	 * Same class as BLS #327 / ABF #337: DMI_CFG leftover eats AHB.
	 * Compact does not pack 0x2c5c or 0x2c68. #332 Crop11 HEIGHT
	 * at 0x2c68 truncated 1529→505. #338 still zeroed those 5
	 * words over HW reset. Do not pack 0x2c5c/0x2c68.
	 */
	writel_relaxed(0, vfe->base + CLC_PEDESTAL + CLC_DMI_CFG);
	wmb();
	/* #353: EN=1 + zero LUT is CST-zero class; MODULE=0 is true bypass. */
	vfe_480_clc_enable(vfe, CLC_PEDESTAL, 0);
}

/*
 * CamX bls12titan480 CreateCmdList DMI 0x2208 four banks then
 * 0x2268 x0x2e from object+0x18. No compact 0x2260 packer. #315
 * wrote sel4 n=0x280 (offset, not count). Identity DMI is
 * subtract-0. PIXEL/LINE at +0x68 bounced 0 (#314 write-only).
 * #326/#327 packed Crop11 keep-all into 0x2268 — same class as
 * ABF #337 0x3270 last=1. CreateCmdList does not pack Crop11.
 * Without live IQ bytes leave 0x2268 at HW reset. Do not zero.
 */
static void vfe_480_bls(struct vfe_device *vfe, u32 last_x, u32 last_y)
{
	static const u32 bls_dmi_n[BLS_DMI_BANKS + 1] = {
		0, BLS_DMI_N1, BLS_DMI_N2, BLS_DMI_N3, BLS_DMI_N4,
	};
	unsigned int i, bank;

	(void)last_x;
	(void)last_y;

	for (bank = 1; bank <= BLS_DMI_BANKS; bank++) {
		writel_relaxed(bank, vfe->base + CLC_PREPROCESS + CLC_DMI_CFG);
		wmb();
		for (i = 0; i < bls_dmi_n[bank]; i++)
			writel_relaxed(0, vfe->base + CLC_PREPROCESS + CLC_DMI_LUT);
		wmb();
	}
	/*
	 * CamX DMI helper returns before packing 0x2268. Close DMI
	 * so MODULE lands on APB. BLS DMI_CFG=0 before AHB. Do not
	 * Crop11 0x2268 / do not zero the 46-word IQ body. #354:
	 * EN=1 + reset 0x2268 is an unknown subtract; MODULE=0 is
	 * true bypass. #352/#353 EN=0 on GTM/Pedestal still DQBUF.
	 */
	writel_relaxed(0, vfe->base + CLC_PREPROCESS + CLC_DMI_CFG);
	wmb();
	vfe_480_clc_enable(vfe, CLC_PREPROCESS, 0);
}

/*
 * CamX BPCPDPC30 FULL @0x5369ac: 0x2e58 x3, 0x2e68 x16, DMI 0x2e08
 * sel1 n=0x90. Compact HWL @0x537048 only writes MODULE_CFG 0x2e60 x1
 * from object+0x20. Empty PDPC11 EN=1 overflowed at line 0 — this is
 * identity DMI (no defects) plus MODULE_CFG BIT(0) so BPC/PDAF stay
 * off. Live CDM packet 2 packs 0x2e58 x3 + 0x2e68 x16 (the 16
 * words #345 put on LIN 0x2a64). Compact is MODULE only.
 * PDPC11 stays EN=0.
 */
static void vfe_480_pdpc30(struct vfe_device *vfe)
{
	static const u32 live_2e58[] = {
		0x00000000, 0x00000000, 0x00000000,
	};
	static const u32 live_2e68[] = {
		0x08370040, 0x1825102e, 0x2813201c, 0x3801300a,
		0x083a0043, 0x18281031, 0x2816201f, 0x3804300d,
		0x08380041, 0x1826102f, 0x2814201d, 0x3802300b,
		0x083b0044, 0x18291032, 0x28172020, 0x3805300e,
	};
	unsigned int i;

	writel_relaxed(1, vfe->base + CLC_PDPC30 + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < PDPC30_DMI_N; i++)
		writel_relaxed(0, vfe->base + CLC_PDPC30 + CLC_DMI_LUT);
	wmb();
	writel_relaxed(0, vfe->base + CLC_PDPC30 + CLC_DMI_CFG);
	wmb();
	vfe_480_pack(vfe, 0x2e58, live_2e58, ARRAY_SIZE(live_2e58));
	vfe_480_pack(vfe, 0x2e68, live_2e68, ARRAY_SIZE(live_2e68));
}

/*
 * CamX ABF40 PackIQ 12-bit region at object+0x24/+0x28 → 0x3270/0x3274
 * (CreateCmdList FULL 0x3268 x19). Compact @0x5359d8 is 0x3260 x1 only.
 * #337 wrote Crop11 keep-all at 0x3270: readback last=1 (0x10000), a
 * 1-pixel window. Do not pack 0x3270. Leave HW reset like compact.
 * Compact bank2 @0x528688 is 0x3460 x1. FULL @0x5275b8 packs
 * 0x3458 x3 + 0x3468 x46. Live CDM packet 2 has both. #337 Crop11
 * keep-all at 0x3270 is not this 19-word IQ blob.
 */
static void vfe_480_abf_region(struct vfe_device *vfe, u32 last_x, u32 last_y)
{
	static const u32 live_3268[] = {
		0x00008020, 0x01d501a6, 0x000009b6, 0x000008bc,
		0x003c003c, 0x3f591000, 0x02050205, 0x00301408,
		0x00000420, 0x40320007, 0x800c8081, 0x00a00c88,
		0x00030000, 0x00000a10, 0x01410010, 0x01005102,
		0x40020001, 0x007000e1, 0x00700070,
	};

	(void)last_x;
	(void)last_y;
	writel_relaxed(0, vfe->base + CLC_ABF + CLC_DMI_CFG);
	wmb();
	/* #355: live 0x3268 stays; MODULE=0 is true bypass. */
	vfe_480_clc_enable(vfe, CLC_ABF, 0);
	vfe_480_pack(vfe, 0x3268, live_3268, ARRAY_SIZE(live_3268));
}

static void vfe_480_abf_bank2(struct vfe_device *vfe)
{
	unsigned int i;

	writel_relaxed(1, vfe->base + CLC_GIC + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < ABF_BANK2_DMI_N1; i++)
		writel_relaxed(0, vfe->base + CLC_GIC + CLC_DMI_LUT);
	wmb();
	writel_relaxed(3, vfe->base + CLC_GIC + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < ABF_BANK2_DMI_N3; i++)
		writel_relaxed(0, vfe->base + CLC_GIC + CLC_DMI_LUT);
	wmb();
	writel_relaxed(4, vfe->base + CLC_GIC + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < ABF_BANK2_DMI_N4; i++)
		writel_relaxed(0, vfe->base + CLC_GIC + CLC_DMI_LUT);
	wmb();
	writel_relaxed(0, vfe->base + CLC_GIC + CLC_DMI_CFG);
	wmb();
	/*
	 * Live CDM packet 2: FULL 0x3458 x3 (MODULE 0xc101 in word 2)
	 * then 0x3468 x46. #357: live 0x3468 stays; 0x3460 MODULE=0
	 * is true bypass. #355 only cleared bank1 0x3260.
	 */
	vfe_480_pack(vfe, 0x3458, (const u32[]){ 0, 0, 0 }, 3);
	{
		static const u32 live_3468[] = {
			0x03800380, 0x03800380, 0x00636363, 0x00636363,
			0x00000000, 0x01000100, 0x01000100, 0x00030403,
			0x3a063808, 0x00633864, 0x0000029a, 0x028f0000,
			0x0a3c05c2, 0x01000100, 0x01000100, 0x00000000,
			0x00000000, 0x00000000, 0x01000100, 0x01000100,
			0x00000000, 0x00000000, 0x01000000, 0x0ccc0200,
			0x004d004d, 0x004d004d, 0x00000000, 0x00000000,
			0x00000000, 0x004d004d, 0x004d004d, 0x00000000,
			0x00000000, 0x00000800, 0x00010001, 0x0020c080,
			0x01a6009b, 0x01d5008c, 0x011d00e6, 0x20040408,
			0x01000100, 0x01000100, 0x00000000, 0x00000000,
			0x000003c0, 0x0000087f,
		};

		vfe_480_pack(vfe, 0x3468, live_3468, ARRAY_SIZE(live_3468));
	}
}

/*
 * Compact CST12 @0x52d178 is 0x4060 x1. FULL @0x52cb7c adds
 * 0x4068 x12 from IQ+0x1c. #344 EN=1 and HW-reset matrix 0
 * zeros RGB (CC-class). Guessed BT.601 was that FULL mix.
 * Live provider object 6f01acfe10 (vtable ELF 0x8bb7d0 =
 * FULL CreateCmdList) type=0xf MODULE=1 + 12 AHB at +0x1c.
 * Live CDM word6/10 is 0x02000000 (512<<16). #364 [9:0]=0x200
 * stuck but Y mean≈0.1 UV=0 — low 10 bits are not origin.
 */
static void vfe_480_cst(struct vfe_device *vfe)
{
	static const u32 live_cst12[] = {
		0x00750259, 0x00000132, 0x00000000, 0x03ff0000,
		0x01fe1eae, 0x00001f54, 0x02000000, 0x03ff0000,
		0x1fad1e55, 0x000001fe, 0x02000000, 0x03ff0000,
	};
	unsigned int i;

	vfe_480_clc_enable(vfe, CLC_CST, 1);
	for (i = 0; i < ARRAY_SIZE(live_cst12); i++)
		writel_relaxed(live_cst12[i],
			       vfe->base + CLC_CST + 0x68 + 4 * i);
}

/*
 * RoundClamp11 PRE + Crop11 sit between CST and MNDS; MID (idx 1)
 * is the Display Full block between Crop and MNDS; POST drains
 * MNDS to DISP WM. EN=0 on POST is a brick wall: viol_id=0 PIXEL
 * PIPE OVERFLOW at chroma last line, 0 NV12. CamX writes MODULE_CFG
 * 0x3c01, PIXEL/LINE keep-all at +0x68/+0x6c, then 6 clamp/round
 * words at +0x70. +0x64 is the same spare hole as Crop.
 */
static void vfe_480_rndclamp(struct vfe_device *vfe, u32 base,
			     u32 last_x, u32 last_y)
{
	u32 pixel = (last_x << 16) | 0;
	u32 line = (last_y << 16) | 0;
	u32 i;

	vfe_480_clc_enable(vfe, base, RNDCLAMP_MODULE_CFG);
	writel_relaxed(0, vfe->base + base + CROP_SPARE);
	writel_relaxed(pixel, vfe->base + base + CROP_PIXEL);
	writel_relaxed(line, vfe->base + base + CROP_LINE);
	for (i = 0; i < 3; i++) {
		writel_relaxed((0x3ff << 16) | 0,
			       vfe->base + base + RNDCLAMP_CH0 + i * 8);
		writel_relaxed(0, vfe->base + base + RNDCLAMP_CH0 + 4 + i * 8);
	}
}

static void vfe_480_crop(struct vfe_device *vfe, u32 base, u32 last_x, u32 last_y)
{
	u32 pixel = (last_x << 16) | 0;
	u32 line = (last_y << 16) | 0;

	/*
	 * CamX Display Crop11 / MNDS CreateCmdList OR MODULE with 0x3
	 * (EN + bit1 output). #322 wrote BIT(0) only: windows stuck,
	 * packer dbg 0x2ea never valid. Same CLC 9-word +0x68 class.
	 */
	vfe_480_clc_enable(vfe, base, BIT(0) | BIT(1));
	writel_relaxed(0, vfe->base + base + CROP_SPARE);
	writel_relaxed(pixel, vfe->base + base + CROP_PIXEL);
	writel_relaxed(line, vfe->base + base + CROP_LINE);
	writel_relaxed(last_x << 16, vfe->base + base + CROP_H_STRIPE);
	writel_relaxed(0, vfe->base + base + CROP_H_PAD);
	writel_relaxed(line, vfe->base + base + CROP_V_SIZE);
	writel_relaxed(0, vfe->base + base + CROP_V_PHASE);
	writel_relaxed(last_y << 16, vfe->base + base + CROP_V_STRIPE);
}

static void vfe_480_mnds(struct vfe_device *vfe, u32 base,
			 u32 in_w, u32 in_h, u32 out_w, u32 out_h)
{
	u32 phase_h, phase_v, interp = 0, cfg;

	if (!in_w || !in_h || !out_w || !out_h)
		return;

	phase_h = (u32)div_u64((u64)in_w << MNDS_PHASE_Q, out_w);
	phase_v = (u32)div_u64((u64)in_h << MNDS_PHASE_Q, out_h);

	/*
	 * CamX mndsConfig*.interpReso: more taps when downscale > 2 / 4.
	 * MODULE_CFG bit0 EN, bits 8-9 interp. Display chroma is
	 * 4080×765→1920×540 so H >2× → interp=1 (0x101).
	 */
	if (phase_h > (2u << MNDS_PHASE_Q) || phase_v > (2u << MNDS_PHASE_Q))
		interp = 1;
	if (phase_h > (4u << MNDS_PHASE_Q) || phase_v > (4u << MNDS_PHASE_Q))
		interp = 2;
	/*
	 * CamX Display CreateCmdList ORs MODULE_CFG with 0x3 (EN + bit1)
	 * and inserts interpReso into phase[29:28]. Stripe last is
	 * OUT-1; 0/0 is an empty window and keeps viol_id 19.
	 */
	cfg = BIT(0) | BIT(1) | (interp << 8);

	vfe_480_clc_enable(vfe, base, cfg);
	writel_relaxed(((out_w - 1) << 16) | (in_w - 1),
		       vfe->base + base + MNDS_H_SIZE);
	writel_relaxed(phase_h | (interp << 28),
		       vfe->base + base + MNDS_H_PHASE);
	writel_relaxed((out_w - 1) << 16,
		       vfe->base + base + MNDS_H_STRIPE);
	writel_relaxed(0, vfe->base + base + MNDS_H_PAD);
	writel_relaxed(((out_h - 1) << 16) | (in_h - 1),
		       vfe->base + base + MNDS_V_SIZE);
	writel_relaxed(phase_v | (interp << 28),
		       vfe->base + base + MNDS_V_PHASE);
	writel_relaxed((out_h - 1) << 16,
		       vfe->base + base + MNDS_V_STRIPE);
	writel_relaxed(0, vfe->base + base + MNDS_V_PAD);
}

/*
 * Live IFE CDM Display Full scaler + TAP. MODULE/H_SIZE are not
 * Linux keep-all 2ppc. TAP 0x5408×2 is AHB 0x307/0x9016c7d
 * (DumpRegConfig lumaConfig/filter), not Crop11 and not DMI LUT.
 * #350 dropped RoundClamp overlay: PIXEL PIPE OVERFLOW, 0-byte
 * NV12, as0=0 as3 latched. Live 0x68 is not Linux keep-all, but
 * it is what lets DQBUF complete (#349). Restore it. Skip
 * 0x5608/0x5e08 MODULE — those EN DS4/DS16 without WM6/7.
 *
 * Rear 4080×3060 last 0xfef0bf3 is s5kjn1 pixel-domain 4079×3059.
 * Front imx596 last 0xa1f079f is Camera ID 1 heap 2591×1951
 * (2026-09-17). Do not copy 0xfef0bf3 onto 2592×1952. Display
 * Full stripe on that heap is 1919×1079, not 1440×1080.
 */
static void vfe_480_live_display_cdm(struct vfe_device *vfe,
				     u32 in_w, u32 in_h)
{
	static const u32 rear_crop_y[] = {
		0x00000001, 0x00000600, 0x0fef0bf3, 0xc0cc0000,
		0x00000000, 0xc0cc0000, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 rear_crop_c[] = {
		0x00000001, 0x00000600, 0x0fef0bf3, 0xc1980000,
		0x00000000, 0xc1980000, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 rear_mnds_y[] = {
		0x00000001, 0x00000600, 0x0fef0bf3, 0xc043dbcf,
		0x00000000, 0xc043e7db, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 rear_mnds_c[] = {
		0x00000001, 0x00000600, 0x0fef0bf3, 0xc087b79e,
		0x00000000, 0xc087cfb6, 0x00000000, 0x00000000,
		0x00000000,
	};
	/*
	 * Camera ID 1 live 2026-09-17 23:16, Device 1, provider 14720:
	 * CamX Display full path is 2304×1296, Applied [0,7,2592,1458],
	 * MNDS output 2314×1314. IPE then zooms [192,108,1920,1080]
	 * on that 2304 buffer. 1MB CDM is still the 640 list
	 * (0x0a1f079f / 0xc081999a). Heap MODULE=1 last 0x0a1f05bf =
	 * 2592×1472 with Q21 0xc023d82c = 2592/2314 (not the invented
	 * 2592/1920 Q21, not dest last 1920×1080). MODULE 0x101 last
	 * 0x077f0437 is the IPE 1920 object; #378–#380 programmed it
	 * onto IFE MNDS_C and stayed viol 19. 640 CDM packs Crop as
	 * MODULE=1 + scale phase @0x4460/0x4660 and MNDS as same last
	 * + Y unity / C 0xc0400000 @0x4c60/0x4e60. #381 uses that
	 * packing on the live 0x0a1f05bf blobs. #382 MID/POST 0x50f/0x8ff
	 * on 2304 WM wrote the first non-zero front NV12 (Y 91–147,
	 * UV 125–140, 2048 bytes short of 1 frame) then viol_id=0 at
	 * CAMIF last line. #383 Crop dest last 0x08ff050f / 0x047f0287
	 * stuck, still 4476928 bytes, but viol_id=14 and clcstat
	 * crop=1 — dest last on Crop is falsified. #384 WM/V4L2
	 * 2320×1320 pad (16-aligned around CamX MNDS 2314×1314)
	 * stuck on #398 when RC stayed 2304: IMAGE_CFG 0x5280910,
	 * img=0x30, as0=0, 0-byte. #386 RC+WM both 2320 on #400:
	 * mid_y=0x527/0x90f, wm4=0x5280910, img=0x0, as0 consumed,
	 * 4591616 (need 4593600, UV short 1984), Y 87–101 UV~128.
	 * Still viol_id=0 line=976. #384 2320 WM falsified only
	 * when RC stayed 2304 (img=0x30). Do not dest last on
	 * MNDS_C (viol 19). Do not copy 0xfef0bf3.
	 */
	/*
	 * Display Full 2320 pack (not executed; persist + falsified):
	 * 0x00000001, 0x00000600, 0x0a1f05bf, 0xc023d82c
	 * 0x00000001, 0x00000600, 0x0a1f05bf, 0xc047b058
	 * 0x00000001, 0x00000600, 0x0a1f05bf, 0xc0200000
	 * 0x00000001, 0x00000600, 0x0a1f05bf, 0xc0400000
	 * #412 Camera ID 1 live BUS is identity last 0x0a1f079f.
	 * #415 MNDS_C 2× pack @0x4e60 landed (hph=0xc0400000) and
	 * still 0-byte img=0 bus=0 — same #413 class. Crop Y/C
	 * unity was not the 1MB CDM: live 0x4460 is 0xc081999a /
	 * 0xc0822222, 0x4660 is 0xc1033334 / 0xc1044444 (2592/640
	 * and 2592/320). Rear AXI moved only after copying that
	 * Crop 9-word, not Crop unity. Do not put 0xc081999a on
	 * MNDS 0x4c60 (640 list there is unity; WM stays 2592).
	 */
	static const u32 front_crop_y[] = {
		0x00000001, 0x00000600, 0x0a1f079f, 0xc081999a,
		0x00000000, 0xc0822222, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 front_crop_c[] = {
		0x00000001, 0x00000600, 0x0a1f079f, 0xc1033334,
		0x00000000, 0xc1044444, 0x00000000, 0x00000000,
		0x00000000,
	};
	/*
	 * MNDS MODULE stays 1. #381 last 0x0a1f05bf was Display Full
	 * 1472. #412 identity last 0x0a1f079f + unity. Dest last
	 * 0x077f0437 identity (#380) and 2× (#378) both stuck viol 19
	 * with 1920 dest on 640 2×. Do not invent 2592/1920 Q21. Do
	 * not copy 0xfef0bf3. Do not stuff unpacked last into MNDS
	 * V_STRIPE.
	 * #415 CLC chroma 2ppc 2× @0x4e60: hph=0xc0400000 still
	 * 0-byte img=0 bus=0. Keep that pack. Crop was the gap vs
	 * live 1MB CDM, not MNDS_C H_PHASE. Do not H_SIZE dest.
	 * Do not H_PHASE 0xc047b058. Do not H_STRIPE dest. Do not
	 * Dual-IFE COMP_CFG.
	 */
	static const u32 front_mnds_y[] = {
		0x00000001, 0x00000600, 0x0a1f079f, 0xc0200000,
		0x00000000, 0xc0200000, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 front_mnds_c[] = {
		0x00000001, 0x00000600, 0x0a1f079f, 0xc0400000,
		0x00000000, 0xc0400000, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 live_tap_ds4[] = { 0x00000307, 0x09016c7d };
	static const u32 live_tap_ds4c[] = { 0x00b404eb, 0x00020781 };
	static const u32 live_tap_ds16[] = { 0x00000f07, 0x09016c7d };
	static const u32 live_tap_ds16c[] = { 0x0000010d, 0x000001df };
	const u32 *crop_y, *crop_c, *mnds_y, *mnds_c;

	if (in_w == 4080 && in_h == 3060) {
		crop_y = rear_crop_y;
		crop_c = rear_crop_c;
		mnds_y = rear_mnds_y;
		mnds_c = rear_mnds_c;
	} else if (in_w == 2592 && in_h == 1952) {
		crop_y = front_crop_y;
		crop_c = front_crop_c;
		mnds_y = front_mnds_y;
		mnds_c = front_mnds_c;
	} else {
		return;
	}

	vfe_480_pack(vfe, CLC_CROP + CLC_MODULE_CFG, crop_y, 9);
	vfe_480_pack(vfe, CLC_CROP_C + CLC_MODULE_CFG, crop_c, 9);
	vfe_480_pack(vfe, CLC_MNDS_Y + CLC_MODULE_CFG, mnds_y, 9);
	vfe_480_pack(vfe, CLC_MNDS_C + CLC_MODULE_CFG, mnds_c, 9);
	/*
	 * #403 front MNDS_C V_SIZE 0x0293016f after 640 pack
	 * zeros vsz. vfe_480_mnds already wrote
	 * ((660-1)<<16)|((736/2)-1) then pack stomped it. Same
	 * 2ppc chroma in as pipe_h/2, same 660 out as WM5/RC
	 * last 0x293. #418 vsz=0x293016f still 4591616 — not
	 * the chroma gap. Keep. #404 V_STRIPE 0x02930000 =
	 * (660-1)<<16 stuck on #419 vst=0x2930000 still 4591616
	 * UV 659.145 — not the chroma gap. Keep.
	 * #405 V_PHASE (368<<21)/660 = 0x0011d7a9: pack zeros
	 * vph the same way. Same 2ppc in/out as V_SIZE.
	 * #420 vph=0x1117a9 (HW drops phase[15:14]) still
	 * 4591616 UV 659.145 — not the chroma gap. Keep.
	 * #406 H_STRIPE (2320-1)<<16 = 0x090f0000 after pack
	 * zeros hst. Same OUT-1 as vfe_480_mnds.
	 * #421 hst=0x90f0000 still 4591616 UV 659.145 — not
	 * the chroma gap. Keep.
	 * #407 H_SIZE 0x090f0a1f on #422: hsz=0x90f0a1f
	 * stuck, /tmp/pix.nv12 0 bytes, viol=0x13 (19)
	 * MNDS_C, as0 Y consumed C=0, dbg=0x269/0x226,
	 * bus=0x0. Display Full dest in H_SIZE with 640
	 * chroma phase 0xc0400000 is dest last class
	 * (#380 viol 19). CamX Display Full H_SIZE dest
	 * pairs with phase 0xc023d82c (2592/2314), not
	 * 640 2×. Reverted. Pack H_SIZE stays 0x0a1f05bf.
	 * Do not retry H_SIZE as the chroma gap.
	 * #408 H_PHASE 0xc047b058 on #424: hph=0xc047b058
	 * stuck, /tmp/pix.nv12 0 bytes, img=0x20, as0 Y
	 * consumed C=0, bus=0x80000000, viol=0, dbg=0x269/0x206.
	 * Display Full chroma Q21 2592/1157 without matching
	 * dest (H_SIZE still pack 0x0a1f05bf, H_PAD still
	 * 640 2× 0xc0400000) stalls WM5. #407 was dest
	 * without this phase (viol 19). Reverted. Pack
	 * H_PHASE stays 0xc0400000.
	 * Do not retry H_PHASE 0xc047b058 as the chroma gap.
	 * #409 IMAGE_CFG_1 on Camera ID 1 live (53dcc70, no flash):
	 * CAF cam_vfe_bus_ver3_update_wm WM:5 h_init 0x0 every
	 * frame. Linux already writel IMAGE_CFG_1=0. Not the
	 * chroma gap. Do not write non-zero IMAGE_CFG_1.
	 * Live IMAGE_CFG_0 is 0x3D00A20 (2592×976) with WM4
	 * 0x7A00A20 (2592×1952), COMP_GRP_1 status_0=0x80,
	 * WM6/7 EN. That size is IFE identity, not Display
	 * Full 2320. Do not WM-only 2592 (same class as #398
	 * WM vs RC). Do not empty-enable WM6/7. Do not Dual-IFE
	 * COMP_CFG. Do not dest last.
	 * #410 V_PAD 0x0011d7a9 on #426: vpd=0x0 stuck (HW
	 * bounced), still 4591616 UV 659.145. CLC_MNDS_C + MNDS_V_PAD
	 * is not the H_PAD=H_PHASE slot. Reverted.
	 * Do not retry V_PAD as the chroma gap.
	 * #411 H_PAD 0xc047b212 on #427: hpd=0xc047b212 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 C=0
	 * bus=0x0 dbg=0x269/0x2c6. Camera ID 1 Crop C pad on
	 * 640 MNDS_C H_PHASE 0xc0400000 stalls WM write.
	 * Reverted. Pack H_PAD stays 0xc0400000.
	 * Do not retry H_PAD as the chroma gap.
	 * Do not retry front packer 3. Do not retry height 659.
	 * Do not retry FRAME_INCR 1984. Do not retry WM5 2304.
	 * Do not retry V_STRIPE as the chroma gap.
	 * Do not retry V_PHASE as the chroma gap.
	 * Do not retry H_STRIPE as the chroma gap.
	 * #412 identity: WM+RC+MNDS+CSID 2592×1952 together.
	 * Pack 640 leftover dest/phase was the chroma gap.
	 * Y H_SIZE dest=src 0x0a1f0a1f with unity H_PHASE
	 * 0xc0200000 (not #407 dest 0x090f0a1f on 640 2×).
	 * #412 on #429: hsz=0xa1f0a1f stuck, /tmp/pix.nv12 0
	 * bytes, viol=0 img=0x10 as0=0 bus=0x80000000
	 * wm4=0x7a00a20 wm5=0x3d00a20 vcrop=0x79f0000.
	 * Dest/src in H_SIZE overwrites pack last 0x0a1f079f
	 * — same class as #407. Reverted. Pack last stays
	 * 0x0a1f079f. Do not retry H_SIZE dest=src as the chroma gap.
	 * Keep V_SIZE dest 1952 src 2ppc 976.
	 * Display Full MNDS_C 0x0293016f / 0x02930000 /
	 * 0x0011d7a9 / 0x090f0000 stays in comments only.
	 * Do not Dual-IFE COMP_CFG. Do not WM-only 2592.
	 * Do not writel CLC_MNDS_C + MNDS_H_STRIPE dest.
	 * #413 on #430: pack last hsz=0xa1f079f stuck, hst=0 both Y/C,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0=0 bus=0x0.
	 * #414 stripe last OUT-1 0x0a1f0000 after pack zeros
	 * hst. Not dest/src H_SIZE. Not #406 2320 0x090f0000.
	 * #414 on #431: hst=0xa1f0000 stuck, /tmp/pix.nv12 0
	 * bytes, viol=0 img=0x10 as0=0 bus=0x80000000. Same
	 * BUS IRQ class as #412 H_SIZE dest. Reverted. Pack
	 * H_STRIPE stays 0. Do not retry H_STRIPE dest as the chroma gap.
	 * #415 on #432: MNDS_C pack 0xc0400000 stuck, hph=0xc0400000 stuck
	 * hsz=0xa1f079f, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0=0
	 * bus=0x0. Same quiet class as #413. 2× chroma phase is not
	 * the identity stall. Keep the 0x4e60 pack.
	 * Do not retry MNDS_C 2× as the chroma gap.
	 * #416 Crop Y/C 9-word from live 1MB CDM 0x4460/0x4660.
	 * Not MNDS 0x4c60 0xc081999a. Not WM-only. Not Dual-IFE.
	 * #417 Camera ID 1 live 2026-09-18 15:24 in-process dmabuf
	 * (provider 10529, last 0x0a1f079f): Crop 9-word is that
	 * same 640 phase. MID 0x4868 n=2 { 0x000001df, 0x0000027f }
	 * (480×640) / 0x4a68 { 0x000000ef, 0x0000013f } (240×320).
	 * POST 0x5068 stays 0x79f/0xa1f identity. #416 left MID
	 * at identity 2592 against Crop dest 640 — quiet 0-byte.
	 * One variable: live MID dest. Do not WM 640. Do not
	 * Dual-IFE COMP_CFG. Do not H_SIZE dest.
	 * #417 on #434: mid_y=0xe01/0x1df/0x27f mid_c=0xef/0x13f
	 * stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0=0
	 * bus=0x0, camif irq1 0x1 0xc 0x2 0x1. Same quiet class
	 * as #416. Crop dest 640 vs POST/WM 2592 still stalls.
	 * Do not retry MID 480×640 as the identity stall.
	 */
	if (in_w == 2592 && in_h == 1952) {
		writel_relaxed(0x079f03cf,
			       vfe->base + CLC_MNDS_Y + MNDS_V_SIZE);
		writel_relaxed(0x079f0000,
			       vfe->base + CLC_MNDS_Y + MNDS_V_STRIPE);
		writel_relaxed(0x00100000,
			       vfe->base + CLC_MNDS_Y + MNDS_V_PHASE);
		writel_relaxed(0x03cf01e7,
			       vfe->base + CLC_MNDS_C + MNDS_V_SIZE);
		writel_relaxed(0x03cf0000,
			       vfe->base + CLC_MNDS_C + MNDS_V_STRIPE);
		writel_relaxed(0x00100000,
			       vfe->base + CLC_MNDS_C + MNDS_V_PHASE);
	}

	/*
	 * CamX RoundClamp11 0x68 is unpacked last_y, last_x (front
	 * 1MB CDM 0x4868=0x1df/0x27f = 480×640 dest). Not Linux
	 * keep-all (last<<16)|0 (#350 overflow). Rear 0x4868 is
	 * 14-bit 0x3c01a3. Camera ID 1 live Display Full is
	 * 2304×1296, MNDS 2314×1314. #382 MID 0x50f/0x8ff on 2304
	 * WM wrote 1 truncated NV12. #384 WM 2320 with 2304 dest:
	 * img=0x30 as0=0. #386 RC+WM 2320 on #400: 4591616 short
	 * 1984, img=0x0, still line=976. Keep MID/POST/OUT
	 * 2320×1320 (0x00000527, 0x0000090f, chroma 0x00000293, 0x00000487).
	 * PRE is CSID 2ppc last 735 0x000002df, 0x00000a1f (#388 Display Full).
	 * #412 identity PRE 0x3cf/0xa1f (976 2ppc), MID/POST/OUT
	 * 0x79f/0xa1f, chroma 0x3cf/0x50f. Do not dest last on
	 * Crop. Do not copy 0xfef0bf3. Do not invent Q21.
	 */
	if (in_w == 2592 && in_h == 1952) {
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP, RNDCLAMP_MODULE_CFG);
		vfe_480_pack(vfe, CLC_RNDCLAMP + 0x68,
			     (const u32[]){ 0x000003cf, 0x00000a1f }, 2);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_MID_Y, 0x0e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_MID_Y + 0x68,
			     (const u32[]){ 0x0000079f, 0x00000a1f }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_MID_Y + 0x70,
			     (const u32[]){ 0x00ff0000, 0x16, 0x00ff0000, 0x16,
					    0, 0 },
			     6);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_MID_C, 0x3e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_MID_C + 0x68,
			     (const u32[]){ 0x000003cf, 0x0000050f }, 2);
	} else {
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_MID_Y, 0x0e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_MID_Y + 0x68,
			     (const u32[]){ 0x003c01a3, 0x0000027f }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_MID_Y + 0x70,
			     (const u32[]){ 0x00ff0000, 0x16, 0x00ff0000, 0x16,
					    0, 0 },
			     6);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_MID_C, 0x3e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_MID_C + 0x68,
			     (const u32[]){ 0x001e00d1, 0x0000013f }, 2);
	}
	/*
	 * Live CDM chroma round is odd (0x17 / 7): keep 10-bit for
	 * UBWC. Linear packer 3 takes LSB[7:0] of 10-bit 512 → UV≈0
	 * (#362 green). Y uses even (0x16 / 6) and 8-bit is correct.
	 * #363: even round on C so 512→128 like Y.
	 */
	vfe_480_pack(vfe, CLC_RNDCLAMP_MID_C + 0x70,
		     (const u32[]){ 0x00ff0000, 0x16, 0x00ff0000, 0x16, 0, 0 },
		     6);

	if (in_w == 2592 && in_h == 1952) {
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_POST_Y, 0x0e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_Y + 0x68,
			     (const u32[]){ 0x0000079f, 0x00000a1f }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_Y + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_POST_C, 0x3e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_C + 0x68,
			     (const u32[]){ 0x000003cf, 0x0000050f }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_C + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
		/*
		 * #418 Camera ID 1 live 0x5868 n=2 { 0x000001e7, 0x00000287 }
		 * (488×648) / 0x5a68 { 0x000000f3, 0x00000143 }.
		 * #417 MID 640 + identity OUT 2592 still 0-byte.
		 * POST stays live 0x5068 identity. Do not WM 640.
		 * #418 on #435: /tmp/pix.nv12 0 bytes, viol=0
		 * img=0x0 as0=0 bus=0x0, mid stuck 0x1df/0x27f,
		 * post still 0x79f/0xa1f. Same quiet class as
		 * #417. Do not retry OUT 488×648 as the identity stall.
		 */
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_OUT_Y, 0x0e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_Y + 0x68,
			     (const u32[]){ 0x0000079f, 0x00000a1f }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_Y + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_OUT_C, 0x3e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_C + 0x68,
			     (const u32[]){ 0x000003cf, 0x0000050f }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_C + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
	} else {
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_POST_Y, 0x0e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_Y + 0x68,
			     (const u32[]){ 0x00b404eb, 0x00020781 }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_Y + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_POST_C, 0x3e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_C + 0x68,
			     (const u32[]){ 0x005a0275, 0x000103c0 }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_C + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);

		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_OUT_Y, 0x0e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_Y + 0x68,
			     (const u32[]){ 0x0000010d, 0x000001df }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_Y + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_OUT_C, 0x3e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_C + 0x68,
			     (const u32[]){ 0x00000086, 0x000000ef }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_C + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
	}

	vfe_480_pack(vfe, CLC_DS411_Y_CROP, live_tap_ds4,
		     ARRAY_SIZE(live_tap_ds4));
	/*
	 * #421 Camera ID 1 live 0x5504 n=2 { 0x0000079f, 0x00000a1f }
	 * (identity). Linux packed rear 0x00b404eb/0x00020781 onto
	 * 2592×1952. Y 0x5408 already matches live 0x00000307 /
	 * 0x09016c7d. Do not copy 0x5d04 0x1e7/0x287 (OUT 488×648).
	 * Do not empty DS411. Do not WM 640. Do not Dual-IFE.
	 * #419/#420 Demux first-list still 0-byte.
	 */
	if (in_w == 2592 && in_h == 1952)
		vfe_480_pack(vfe, CLC_DS411_C_CROP,
			     (const u32[]){ 0x0000079f, 0x00000a1f }, 2);
	else
		vfe_480_pack(vfe, CLC_DS411_C_CROP, live_tap_ds4c,
			     ARRAY_SIZE(live_tap_ds4c));
	vfe_480_pack(vfe, 0x5c08, live_tap_ds16, ARRAY_SIZE(live_tap_ds16));
	vfe_480_pack(vfe, 0x5d04, live_tap_ds16c, ARRAY_SIZE(live_tap_ds16c));
}

static const char *vfe_480_viol_name(u32 id)
{
	switch (id) {
	case 18:
		return "MNDS_Y";
	case 19:
		return "MNDS_C";
	case 20:
		return "CROP_RND_Y";
	case 21:
		return "CROP_RND_C";
	default:
		return "?";
	}
}

static void __iomem *vfe_480_camnoc;

static void vfe_480_camnoc_dump(struct vfe_device *vfe, const char *when)
{
	void __iomem *cn = vfe_480_camnoc;

	if (!cn)
		return;
	if (when[0] == 'o')
		dev_info_ratelimited(vfe->camss->dev,
				     "dagu ife%d camnoc %s lin=0x%x/urg=0x%x/maxwr=0x%x rdi=0x%x/urg=0x%x/maxwr=0x%x ubwc=0x%x/urg=0x%x err=0x%x pri=0x%x/0x%x\n",
				     vfe->id, when,
				     readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_FILL),
				     readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_URGENCY),
				     readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_MAXWR),
				     readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_FILL),
				     readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_URGENCY),
				     readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_MAXWR),
				     readl_relaxed(cn + CAMNOC_IFE_UBWC_STATS + CAMNOC_NIU_FILL),
				     readl_relaxed(cn + CAMNOC_IFE_UBWC_STATS + CAMNOC_NIU_URGENCY),
				     readl_relaxed(cn + CAMNOC_ERRVLD),
				     readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_PRI_LO),
				     readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_PRI_HI));
	else
		dev_info(vfe->camss->dev,
			 "dagu ife%d camnoc %s lin=0x%x/urg=0x%x/maxwr=0x%x rdi=0x%x/urg=0x%x/maxwr=0x%x ubwc=0x%x/urg=0x%x err=0x%x pri=0x%x/0x%x\n",
			 vfe->id, when,
			 readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_FILL),
			 readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_URGENCY),
			 readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_MAXWR),
			 readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_FILL),
			 readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_URGENCY),
			 readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_MAXWR),
			 readl_relaxed(cn + CAMNOC_IFE_UBWC_STATS + CAMNOC_NIU_FILL),
			 readl_relaxed(cn + CAMNOC_IFE_UBWC_STATS + CAMNOC_NIU_URGENCY),
			 readl_relaxed(cn + CAMNOC_ERRVLD),
			 readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_PRI_LO),
			 readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_PRI_HI));
}

static void vfe_480_camnoc_niu_qos(void __iomem *niu)
{
	writel_relaxed(CAMNOC_PRI_LO, niu + CAMNOC_NIU_PRI_LO);
	writel_relaxed(CAMNOC_PRI_HI, niu + CAMNOC_NIU_PRI_HI);
	writel_relaxed(CAMNOC_URGENCY, niu + CAMNOC_NIU_URGENCY);
	writel_relaxed(CAMNOC_DANGER, niu + CAMNOC_NIU_DANGER);
	writel_relaxed(CAMNOC_SAFE, niu + CAMNOC_NIU_SAFE);
}

static void vfe_480_camnoc_ife_qos(struct vfe_device *vfe)
{
	if (!vfe_480_camnoc)
		return;
	vfe_480_camnoc_dump(vfe, "rst");
	vfe_480_camnoc_niu_qos(vfe_480_camnoc + CAMNOC_IFE_LINEAR);
	vfe_480_camnoc_niu_qos(vfe_480_camnoc + CAMNOC_IFE_RDI_WR);
	vfe_480_camnoc_niu_qos(vfe_480_camnoc + CAMNOC_IFE_UBWC_STATS);
	wmb();
	vfe_480_camnoc_dump(vfe, "qos");
}

static void vfe_480_bus_dump(struct vfe_device *vfe, const char *tag)
{
	dev_info(vfe->camss->dev,
		 "dagu ife%d bus %s comp=0x%x/0x%x fh0=0x%x top=0x%x/0x%x drop4=0x%x/0x%x irqsub4=0x%x/0x%x cfg0=0x%x stride4=0x%x\n",
		 vfe->id, tag,
		 readl_relaxed(vfe->base + VFE_BUS_COMP_CFG_0),
		 readl_relaxed(vfe->base + VFE_BUS_COMP_CFG_1),
		 readl_relaxed(vfe->base + VFE_BUS_IF_FRAMEHEADER_CFG(0)),
		 readl_relaxed(vfe->base + VFE_BUS_DEBUG_STATUS_TOP_CFG),
		 readl_relaxed(vfe->base + VFE_BUS_DEBUG_STATUS_TOP),
		 readl_relaxed(vfe->base + VFE_BUS_WM_FRAMEDROP_PERIOD(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_FRAMEDROP_PATTERN(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PERIOD(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PATTERN(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_2(DISP_Y_WM)));
}

/*
 * CAF cam_vfe480.h if_frameheader_cfg[SRC_GRP]. CamX only sets bit2 of
 * en_cfg when it also programs frame_header_addr. A reset leftover on
 * SRC_GRP_0 makes DISP wait for a header beat and never issue AXI
 * (as3 latched, as0=0, CAMNOC fill=0). Linear NV12 has no header.
 */
static void vfe_480_bus_common(struct vfe_device *vfe)
{
	unsigned int i;

	vfe_480_bus_dump(vfe, "rst");
	for (i = 0; i < BUS_FRAMEHEADER_GRPS; i++)
		writel_relaxed(0, vfe->base + VFE_BUS_IF_FRAMEHEADER_CFG(i));
	writel_relaxed(1, vfe->base + VFE_BUS_OVERFLOW_STATUS_CLEAR);
	/*
	 * CAF debug_status_top_cfg: n+1 selects BUS client n.
	 * 1 was VID WM0 (never started) — frozen 0x1f8098 before SOF.
	 * DISP Y is client 4.
	 */
	writel_relaxed(DISP_Y_WM + 1, vfe->base + VFE_BUS_DEBUG_STATUS_TOP_CFG);
	wmb();
	vfe_480_bus_dump(vfe, "clr");
}

static void vfe_480_pix_pipeline(struct vfe_device *vfe, struct vfe_line *line)
{
	struct v4l2_mbus_framefmt *sink = &line->fmt[MSM_VFE_PAD_SINK];
	struct v4l2_pix_format_mplane *pix =
		&line->video_out.active_fmt.fmt.pix_mp;
	u32 in_w = sink->width;
	u32 in_h = sink->height;
	u32 out_w = pix->width;
	u32 out_h = pix->height;
	u32 pipe_h;
	u32 epoch;
	u32 core;

	if (!in_w)
		in_w = out_w;
	if (!in_h)
		in_h = out_h;
	if (!out_w)
		out_w = in_w;
	if (!out_h)
		out_h = in_h;
	/*
	 * Titan 480 CAMIF is 2ppc: overflow/stop debug line sticks at
	 * in_h/2 (4080×3060 → line=1530, pix=4080) for the whole
	 * STREAMON. CAF epoch = pixel_h/4 is mid-frame of that
	 * counter. Crop11 LINE and MNDS V_SIZE are the same line
	 * unit as the debug counter — 3059 never arrives, so POST
	 * never hands WM4 a line (dbg=0, as0=0, viol_id=0).
	 * CAMIF_CROP_HEIGHT stays sensor pixels; CLC V uses pipe_h.
	 */
	pipe_h = in_h / 2;
	if (!pipe_h)
		pipe_h = in_h;
	/*
	 * #387 CSID IPP VCROP last 0x05bf feeds 1472 pixel / 736
	 * 2ppc lines. Overflow moved 976→736. CAMIF/PRE still used
	 * in_h/2=976 (last 975 never arrives). #388 pipe_h is the
	 * CSID window in 2ppc: pipe_h = (0x05bf + 1) / 2 = 736 on
	 * Display Full. #412 identity CSID is full 1951; pipe_h
	 * stays in_h / 2 = 976. Do not retry pipe_h 736. Do not
	 * retry #385 CAMIF 735. Do not Dual-IFE COMP_CFG.
	 * Do not retry 0x05bf as the chroma gap.
	 */

	/* Ungate CLC / NOC so demux→demosaic→MNDS actually clocks. */
	writel_relaxed(0xffffffff, vfe->base + VFE_CORE_CGC_OVD_0);
	writel_relaxed(0xffffffff, vfe->base + VFE_CORE_CGC_OVD_1);
	writel_relaxed(0xffffffff, vfe->base + VFE_AHB_CGC_OVD);
	writel_relaxed(0xffffffff, vfe->base + VFE_NOC_CGC_OVD);
	/* CAF cam_vfe480.h pwr_iso_cfg. Isolated DISP clients latch as3
	 * and never consume. RDI is a different BUS port.
	 */
	writel_relaxed(0, vfe->base + VFE_BUS_PWR_ISO_CFG);
	vfe_480_bus_common(vfe);
	/* CAF cam_cpastop_poweron IFE write-port LUTs. Not ICC. */
	vfe_480_camnoc_ife_qos(vfe);

	/*
	 * CAF (~r2pd & 1) << shift: bit set = R2PD off. Bits 24-25 are
	 * dsp_mode / DSP_STREAMING — do not put Bayer there (0x63000800
	 * vs Android 0x60000800). Display Full compact does not pack
	 * DSX10 (0x52e8e0 ret). Empty DS411 hung CAMNOC. CAF client
	 * table puts WM4–7 in COMP_GRP_1 for COMP_DONE IRQ; that is
	 * not COMP_CFG_0. R2PD-on without DSX waits for PD10 (#310).
	 * Linear NV12 is WM4/5 only — DISP R2PD off, WM6/7 stay EN=0
	 * until a real DSX10 DMI program.
	 * VID 29-30 stay off. CORE_CFG_1 is dump-only. Bayer is Demux.
	 */
	core = 1 << CORE_CFG_0_OPERATING_MODE;
	core |= BIT(CORE_CFG_0_VID_DS4_R2PD) | BIT(CORE_CFG_0_VID_DS16_R2PD);
	core |= BIT(CORE_CFG_0_DISP_DS4_R2PD) | BIT(CORE_CFG_0_DISP_DS16_R2PD);
	writel_relaxed(core, vfe->base + VFE_CORE_CFG_0);
	/* CAF top_debug_cfg_en = 1 at 0xDC. */
	writel_relaxed(1, vfe->base + VFE_TOP_DEBUG_CFG);

	/*
	 * 0x2200 is BLS12. Overflow-era EN=0 looked like a brick
	 * wall (violation bit1). #352/#353 EN=0 still DQBUF. CamX
	 * DMI 0x2208 four banks then 0x2268 x0x2e IQ. PIXEL/LINE at
	 * +0x68 bounced 0 on #314 (write-only). Crop11 keep-all
	 * there is ABF 0x3270 class — do not pack it. #354 MODULE=0
	 * because 0x2268 stays at HW reset (unknown subtract).
	 */
	vfe_480_bls(vfe, in_w - 1, pipe_h - 1);
	writel_relaxed(1, vfe->base + VFE_DIAGNOSTIC_HW);
	vfe_480_pedestal(vfe, in_w - 1, pipe_h - 1);

	/*
	 * Empty PDPC11 EN=1 overflowed at line 0 — leave 0x2800 off.
	 * PDPC30 at 0x2e00 is identity DMI. CamX ABF40 compact only
	 * writes MODULE_CFG 0x3260; it does not pack 0x3268. EN=1
	 * plus four zeros overwrote HW reset 0x8000/0x1000100 (CC-
	 * class empty kernel). EN=0 is bypass (line=1530, as0=0).
	 * Compact path: EN=1, leave 0x3268 at reset. Compact bank2
	 * @0x528688 is 0x3460 x1: identity DMI then MODULE 0xc101.
	 * Do not pack FULL 0x3458/0x3468.
	 */
	vfe_480_pdpc30(vfe);
	vfe_480_demux(vfe, in_w, in_h);
	vfe_480_abf_region(vfe, in_w - 1, pipe_h - 1);
	vfe_480_abf_bank2(vfe);
	/* Live CDM packet 2: 0x3868 x4 + 0x3860=0x4001 + 0x3878 x2.
	 * #361: restore Demosaic EN; PDPC30 stays MODULE=0.
	 * Rear 0x07540400/0x697. Front Camera ID 1 1MB CDM 0x3868
	 * is 0x05fa0400/0x82c (later AWB 0x056a0400/0x8aa). Do not
	 * pack rear WB onto 2592×1952.
	 */
	{
		static const u32 rear_3868[] = {
			0x07540400, 0x00000697, 0x00000000, 0x00000000,
		};
		static const u32 front_3868[] = {
			0x05fa0400, 0x0000082c, 0x00000000, 0x00000000,
		};
		const u32 *wb13 = (in_w == 2592 && in_h == 1952) ?
				  front_3868 : rear_3868;

		vfe_480_pack(vfe, CLC_DEMOSAIC + DEMOSAIC_WB, wb13, 4);
		vfe_480_clc_enable(vfe, CLC_DEMOSAIC, DEMOSAIC_COMPACT_CFG);
		vfe_480_pack(vfe, 0x3878, (const u32[]){ 0x80, 0x00800066 }, 2);
	}
	vfe_480_gtm(vfe, in_w - 1, pipe_h - 1);
	vfe_480_cc(vfe);
	vfe_480_wb(vfe);
	vfe_480_gamma(vfe);
	vfe_480_cst(vfe);
	vfe_480_rndclamp(vfe, CLC_RNDCLAMP, in_w - 1, pipe_h - 1);
	vfe_480_crop(vfe, CLC_CROP, in_w - 1, pipe_h - 1);
	/* CamX Display Crop11 writes Y 0x4460 and C 0x4660. */
	if (pipe_h / 2)
		vfe_480_crop(vfe, CLC_CROP_C, in_w - 1, pipe_h / 2 - 1);
	vfe_480_rndclamp(vfe, CLC_RNDCLAMP_MID_Y, in_w - 1, pipe_h - 1);
	if (pipe_h / 2)
		vfe_480_rndclamp(vfe, CLC_RNDCLAMP_MID_C, in_w - 1,
				 pipe_h / 2 - 1);

	vfe_480_mnds(vfe, CLC_MNDS_Y, in_w, pipe_h, out_w, out_h);
	/* NV12 chroma is 4:2:0 of the 2ppc luma height. */
	vfe_480_mnds(vfe, CLC_MNDS_C, in_w, pipe_h / 2, out_w, out_h / 2);
	vfe_480_rndclamp(vfe, CLC_RNDCLAMP_POST_Y, out_w - 1, out_h - 1);
	if (out_h / 2)
		vfe_480_rndclamp(vfe, CLC_RNDCLAMP_POST_C, out_w - 1,
				 out_h / 2 - 1);
	vfe_480_rndclamp(vfe, CLC_RNDCLAMP_OUT_Y, out_w - 1, out_h - 1);
	if (out_h / 2)
		vfe_480_rndclamp(vfe, CLC_RNDCLAMP_OUT_C, out_w - 1,
				 out_h / 2 - 1);

	/*
	 * Live Display Full CDM packet 1 (1MB dmabuf 2026-09-17).
	 * CreateCmdList packs these 9-word / TAP-2 blobs; Linux
	 * keep-all 2ppc 1529 is a different map. CAMIF HEIGHT stays
	 * pipe_h (in_h/2). Do not EN 0x5e00 / WM6/7.
	 */
	vfe_480_live_display_cdm(vfe, in_w, in_h);

	/* CAMIF window: last in [31:16], first in [15:0]. 0/0 is empty. */
	/*
	 * Debug counter max is pix=4080 line=1530 (Titan 480 2ppc).
	 * IPP CFG0 bit2 hbin was the 2040-wide cut; width stays 4080.
	 * HEIGHT in the same units as that counter: last=pipe_h-1.
	 * last=in_h-1 (3059) never arrives — IFE_OUT crop does not
	 * complete, CLC sees no pixels, packer dbg 0x2ea, as0=0.
	 */
	writel_relaxed(0, vfe->base + CAMIF_SPARE);
	writel_relaxed(((in_w - 1) << 16) | 0, vfe->base + CAMIF_CROP_WIDTH);
	/*
	 * #385 CAMIF last 735 with CSID keep-all 1951: overflow still
	 * line=976. #387 CSID last 0x05bf moved overflow to 736.
	 * #388 pipe_h=(0x05bf+1)/2 so last=735 matches that feed.
	 */
	writel_relaxed(((pipe_h - 1) << 16) | 0, vfe->base + CAMIF_CROP_HEIGHT);
	/* Titan 170 keep-all: 1-bits in skip pattern, period 1, IRQ every frame. */
	writel_relaxed(0xffffffff, vfe->base + CAMIF_LINE_SKIP);
	writel_relaxed(0xffffffff, vfe->base + CAMIF_PIXEL_SKIP);
	writel_relaxed(0x00010001, vfe->base + CAMIF_PERIOD);
	writel_relaxed(0xffffffff, vfe->base + CAMIF_IRQ_SUBSAMPLE);

	epoch = in_h / 4;
	/*
	 * CAF epoch = pixel_h/4 mid of the 2ppc debug counter.
	 * in_h/4=488 is 66% of CSID 736 (#387). #389 used the
	 * live Crop last window 1472: epoch=0x140170 stuck on
	 * #403, still viol_id=0 line=736 4591616. Epoch is not
	 * the EOF drain. #390 CSID IPP EARLY_EOF_EN cfg0=0xa02b20e3
	 * stuck on #404, still line=736 4591616 — falsified.
	 * #396 pix_store=0 on #410 still 4591616 with bit29 on.
	 * #397 EARLY_EOF=0 on #411 cfg0=0x802b2063 still 4591616
	 * UV 659.145 — falsified. #398 WM5 width 2304 on #412
	 * img=0x20 as0 C=0 0 bytes — falsified, reverted. #399
	 * burst_limit 0 on #414 burst5=0x0 stuck, still 4591616
	 * — falsified. #400 FRAME_INCR 2320*660-1984 on #415
	 * incr5=0x175580 still 4591616 — falsified, reverted.
	 * #401 height 659 on #416 wm5=0x2930910 img=0x20 still
	 * 4591616 — falsified, reverted. Do not invent Q21.
	 * Do not crop last again.
	 * Do not retry EARLY_EOF bit29. Do not retry WM5 2304.
	 * Do not retry burst as the chroma gap.
	 * Do not retry FRAME_INCR 1984. Do not retry height 659.
	 * #402 packer 3 on #417 UV avg 19.3 — falsified, reverted.
	 * Do not retry front packer 3. #403 MNDS_C V_SIZE 0x0293016f
	 * on #418 vsz=0x293016f still 4591616 — not the chroma gap.
	 * #404 V_STRIPE 0x02930000 on #419 vst=0x2930000 still
	 * 4591616 — not the chroma gap. Keep.
	 * Do not retry V_STRIPE as the chroma gap.
	 * #405 V_PHASE 0x0011d7a9 on #420 vph=0x1117a9 still
	 * 4591616 — not the chroma gap. Keep.
	 * Do not retry V_PHASE as the chroma gap.
	 * #406 H_STRIPE 0x090f0000 on #421 hst=0x90f0000 still
	 * 4591616 — not the chroma gap. Keep.
	 * Do not retry H_STRIPE as the chroma gap.
	 * Display Full epoch = (0x05bf + 1) / 4 = 368. #412 identity
	 * epoch is in_h / 4 = 488. Do not retry epoch 368.
	 */
	writel_relaxed((0x14 << 16) | epoch, vfe->base + CLC_CAMIF_EPOCH);
	/*
	 * CAF starts CAMIF last, after CDM IMAGE_ADDR and start_wm EN.
	 * Enabling here (wm_start Y, addr still 0, EN still 0) arms the
	 * 2ppc pipe before DISP has a buffer. First SOF then PIXEL-PIPE-
	 * OVERFLOW with as0=0. Crop/epoch stay programmed; EN waits for
	 * vfe_480_camif_go() after DISP_C IMAGE_ADDR.
	 */

	dev_info(vfe->camss->dev,
		 "dagu ife%d pix clc in %ux%u pipe_h=%u out %ux%u core=0x%x camif=0x%x crop=0x%x/0x%x pdpc=0x%x/0x%x ped=0x%x lin=0x%x gtm=0x%x wb=0x%x gamma=0x%x demux=0x%x/0x%x/0x%x/0x%x abf=0x%x gic=0x%x demosaic=0x%x/0x%x cc=0x%x/0x%x/0x%x/0x%x epoch=0x%x\n",
		 vfe->id, in_w, in_h, pipe_h, out_w, out_h,
		 readl_relaxed(vfe->base + VFE_CORE_CFG_0),
		 readl_relaxed(vfe->base + CLC_CAMIF + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CAMIF_CROP_WIDTH),
		 readl_relaxed(vfe->base + CAMIF_CROP_HEIGHT),
		 readl_relaxed(vfe->base + CLC_PDPC11 + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_PDPC30 + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_PEDESTAL + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_LIN + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_GTM + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_WB + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_GAMMA + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_DEMUX),
		 readl_relaxed(vfe->base + CLC_DEMUX + 0x04),
		 readl_relaxed(vfe->base + CLC_DEMUX + 0x14),
		 readl_relaxed(vfe->base + CLC_DEMUX + 0x18),
		 readl_relaxed(vfe->base + CLC_ABF + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_GIC + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_DEMOSAIC + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_DEMOSAIC_INTERP),
		 readl_relaxed(vfe->base + CLC_CC + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_CC + CLC_CC_SPARE),
		 readl_relaxed(vfe->base + CLC_CC + CLC_CC_MATRIX),
		 readl_relaxed(vfe->base + CLC_CC + CLC_CC_MATRIX + 16),
		 readl_relaxed(vfe->base + CLC_CAMIF_EPOCH));
	dev_info(vfe->camss->dev,
		 "dagu ife%d pix bls cfg=0x%x px=0x%x ln=0x%x dmi=0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_PREPROCESS + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_PREPROCESS + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_PREPROCESS + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_PREPROCESS + CLC_DMI_CFG));
	dev_info(vfe->camss->dev,
		 "dagu ife%d pix wb13 3868=0x%x/0x%x/0x%x/0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB),
		 readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 4),
		 readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 8),
		 readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 12));
	dev_info(vfe->camss->dev,
		 "dagu ife%d rndclamp=0x%x/0x%x/0x%x/0x%x crop=0x%x/0x%x/0x%x/0x%x/0x%x/0x%x crop_c=0x%x/0x%x/0x%x/0x%x/0x%x/0x%x cfg1=0x%x mid_y=0x%x/0x%x/0x%x mid_c=0x%x/0x%x/0x%x post_y=0x%x/0x%x/0x%x post_c=0x%x/0x%x/0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_RNDCLAMP + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP + RNDCLAMP_CH0),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_CROP + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_SPARE),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_H_STRIPE),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_V_STRIPE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_SPARE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_H_STRIPE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_V_STRIPE),
		 readl_relaxed(vfe->base + VFE_CORE_CFG_1),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_LINE));
	dev_info(vfe->camss->dev,
		 "dagu ife%d pix cst=0x%x offu=0x%x offv=0x%x postc70=0x%x/0x%x midc70=0x%x/0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_CST + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_CST + 0x68 + 24),
		 readl_relaxed(vfe->base + CLC_CST + 0x68 + 40),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + 0x70),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + 0x74),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + 0x70),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + 0x74));
	dev_info(vfe->camss->dev,
		 "dagu ife%d mnds_y cfg=0x%x spr=0x%x hsz=0x%x hph=0x%x hst=0x%x hpd=0x%x vsz=0x%x vph=0x%x vst=0x%x vpd=0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_MNDS_Y + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_SPARE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_H_SIZE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_H_PHASE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_H_STRIPE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_H_PAD),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_V_SIZE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_V_PHASE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_V_STRIPE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_V_PAD));
	dev_info(vfe->camss->dev,
		 "dagu ife%d mnds_c cfg=0x%x spr=0x%x hsz=0x%x hph=0x%x hst=0x%x hpd=0x%x vsz=0x%x vph=0x%x vst=0x%x vpd=0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_MNDS_C + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_SPARE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_SIZE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_PHASE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_STRIPE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_PAD),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_V_SIZE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_V_PHASE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_V_STRIPE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_V_PAD));
}

static void *vfe_480_ds4_cpu;
static void *vfe_480_ds16_cpu;
static void *vfe_480_meta_cpu;
static dma_addr_t vfe_480_ds4_dma;
static dma_addr_t vfe_480_ds16_dma;
static dma_addr_t vfe_480_meta_dma;

/*
 * WM4/5 always have ubwc_regs. Live HyperOS update_ubwc_meta_addr
 * binds a mapped IOVA every frame. Linear CAF skips sidecar, but
 * reset meta_addr=0 is not in the VFE SMMU; the client latches
 * IMAGE_ADDR (as3) and never consumes (as0=0). Bind a dummy page.
 * mode_cfg bit0 stays 0 — compressor is not V4L2 NV12.
 * CAF debug_status_cfg=1 makes debug_status_0 valid/ready readable.
 * Leaving it 0 kept dbg=0 through every packer cut — telemetry-blind,
 * not proof the packer had no input. Datapath is start_wm EN, not this.
 */
static void vfe_480_wm_sidecar_linear(struct vfe_device *vfe, u8 wm)
{
	u32 meta = 0;

	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_STATS_CTRL(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_CTRL_2(wm));
	/* CAF skips bw_limit when the CamX value is 0. Writing 0 here
	 * is "limit 0 beats", not unlimited.
	 */
	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_META_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_SYSTEM_CACHE_CFG(wm));
	if (vfe_480_meta_cpu) {
		meta = lower_32_bits(vfe_480_meta_dma);
		if (wm == DISP_C_WM)
			meta += DISP_META_PAGE;
	}
	writel_relaxed(meta, vfe->base + VFE_BUS_WM_UBWC_META_ADDR(wm));
}

static void vfe_480_wm_config(struct vfe_device *vfe, u8 wm,
			      u32 width, u32 height, u32 stride, u32 frame_incr,
			      bool plain)
{
	writel_relaxed(WM_CGC_OVERRIDE_ALL, vfe->base + VFE_BUS_WM_CGC_OVERRIDE);
	writel_relaxed(0x0, vfe->base + VFE_BUS_WM_TEST_BUS_CTRL);

	writel_relaxed(frame_incr, vfe->base + VFE_BUS_WM_FRAME_INCR(wm));
	/*
	 * #399 burst_limit 0 on #414 burst5=0x0 stuck, still
	 * 4591616 UV 659.145 last_partial=336 — falsified.
	 * CAF skips burst_limit when CamX value is 0 (HW default,
	 * not "0 beats" — that is UBWC bw_limit). Leave front WM5
	 * at 0; same pixels as 0xf. Do not retry burst as the chroma
	 * gap. Width stays 2320. Do not retry WM5 2304. Do not
	 * retry bit29.
	 */
	if (plain && wm == DISP_C_WM && width == 2320 && height == 660)
		writel_relaxed(0, vfe->base + VFE_BUS_WM_BURST_LIMIT(wm));
	else
		writel_relaxed(0xf, vfe->base + VFE_BUS_WM_BURST_LIMIT(wm));
	if (plain)
		writel_relaxed((height << 16) | width,
			       vfe->base + VFE_BUS_WM_IMAGE_CFG_0(wm));
	else
		writel_relaxed(WM_IMAGE_CFG_0_DEFAULT_WIDTH,
			       vfe->base + VFE_BUS_WM_IMAGE_CFG_0(wm));
	/*
	 * #409 CAF IMAGE_CFG_1 is h_init. Camera ID 1 live
	 * WM:5 h_init 0x0. Keep 0. Do not write non-zero IMAGE_CFG_1.
	 */
	writel_relaxed(0, vfe->base + VFE_BUS_WM_IMAGE_CFG_1(wm));
	writel_relaxed(stride, vfe->base + VFE_BUS_WM_IMAGE_CFG_2(wm));
	if (plain) {
		writel_relaxed(wm == DISP_C_WM ? PACKER_PLAIN_8 :
			       PACKER_PLAIN_8_LSB_MSB_10,
			       vfe->base + VFE_BUS_WM_PACKER_CFG(wm));
		/*
		 * #402 front WM5 packer 3 on #417 packer5=0x3 stuck,
		 * still 4591616, UV avg 19.3 (2-38) — same as #362
		 * green. CamX get_packer_fmt(NV12)=3 is UBWC 10-bit;
		 * linear C stays PLAIN_8. Reverted. Do not retry front packer 3.
		 * Do not retry height 659. Do not retry FRAME_INCR 1984.
		 * Do not retry WM5 2304.
		 */
		writel_relaxed(WM_DEBUG_STATUS_0_MUX |
			       (WM_DEBUG_STATUS_1_CONSTRAINT << 8),
			       vfe->base + VFE_BUS_WM_DEBUG_CFG(wm));
		writel_relaxed(UBWC_STATIC_LPDDR5,
			       vfe->base + VFE_BUS_UBWC_STATIC_CTRL);
		vfe_480_wm_sidecar_linear(vfe, wm);
	} else {
		writel_relaxed(0, vfe->base + VFE_BUS_WM_PACKER_CFG(wm));
	}

	writel_relaxed(0, vfe->base + VFE_BUS_WM_FRAMEDROP_PERIOD(wm));
	writel_relaxed(plain ? 0xffffffff : 1,
		       vfe->base + VFE_BUS_WM_FRAMEDROP_PATTERN(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PERIOD(wm));
	writel_relaxed(plain ? 0xffffffff : 1,
		       vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PATTERN(wm));

	/*
	 * CAF start_wm enables after CDM has IMAGE_ADDR. Enabling PLAIN
	 * DISP with addr 0 left the client not-ready (dbg valid, img=0).
	 * RDI still enables here: MIPI RAW latches width-default.
	 */
	if (plain)
		writel_relaxed(MODE_QCOM_PLAIN << WM_CFG_MODE,
			       vfe->base + VFE_BUS_WM_CFG(wm));
	else
		writel_relaxed(1 << WM_CFG_EN | MODE_MIPI_RAW << WM_CFG_MODE,
			       vfe->base + VFE_BUS_WM_CFG(wm));
}

static int vfe_480_ds_alloc(struct device *dev)
{
	if (vfe_480_ds4_cpu && vfe_480_ds16_cpu && vfe_480_meta_cpu)
		return 0;

	vfe_480_ds4_cpu = dma_alloc_coherent(dev, DISP_DS4_INCR,
					     &vfe_480_ds4_dma, GFP_KERNEL);
	vfe_480_ds16_cpu = dma_alloc_coherent(dev, DISP_DS16_INCR,
					      &vfe_480_ds16_dma, GFP_KERNEL);
	vfe_480_meta_cpu = dma_alloc_coherent(dev, DISP_META_PAGE * 2,
					      &vfe_480_meta_dma, GFP_KERNEL);
	if (!vfe_480_ds4_cpu || !vfe_480_ds16_cpu || !vfe_480_meta_cpu) {
		dev_err(dev, "dagu DISP DS/meta dummy alloc failed\n");
		return -ENOMEM;
	}
	return 0;
}

static void __maybe_unused vfe_480_ds_config(struct vfe_device *vfe, u8 wm,
			      u32 width, u32 height, u32 stride, u32 frame_incr)
{
	writel_relaxed(frame_incr, vfe->base + VFE_BUS_WM_FRAME_INCR(wm));
	writel_relaxed(0xf, vfe->base + VFE_BUS_WM_BURST_LIMIT(wm));
	writel_relaxed((height << 16) | width,
		       vfe->base + VFE_BUS_WM_IMAGE_CFG_0(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_IMAGE_CFG_1(wm));
	writel_relaxed(stride, vfe->base + VFE_BUS_WM_IMAGE_CFG_2(wm));
	writel_relaxed(PACKER_PLAIN_64, vfe->base + VFE_BUS_WM_PACKER_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_SYSTEM_CACHE_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_FRAMEDROP_PERIOD(wm));
	writel_relaxed(0xffffffff, vfe->base + VFE_BUS_WM_FRAMEDROP_PATTERN(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PERIOD(wm));
	writel_relaxed(0xffffffff, vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PATTERN(wm));
	writel_relaxed(MODE_QCOM_PLAIN << WM_CFG_MODE,
		       vfe->base + VFE_BUS_WM_CFG(wm));
}

static void __maybe_unused vfe_480_ds_go(struct vfe_device *vfe)
{
	if (!vfe_480_ds4_cpu || !vfe_480_ds16_cpu)
		return;

	writel_relaxed(lower_32_bits(vfe_480_ds4_dma),
		       vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS4_WM));
	writel_relaxed(lower_32_bits(vfe_480_ds16_dma),
		       vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS16_WM));
	wmb();
	writel_relaxed(1 << WM_CFG_EN | MODE_QCOM_PLAIN << WM_CFG_MODE,
		       vfe->base + VFE_BUS_WM_CFG(DISP_DS4_WM));
	writel_relaxed(1 << WM_CFG_EN | MODE_QCOM_PLAIN << WM_CFG_MODE,
		       vfe->base + VFE_BUS_WM_CFG(DISP_DS16_WM));
}

static void vfe_wm_start(struct vfe_device *vfe, u8 wm, struct vfe_line *line)
{
	struct v4l2_pix_format_mplane *pix =
		&line->video_out.active_fmt.fmt.pix_mp;
	u32 bpl = pix->plane_fmt[0].bytesperline;

	if (line->id == VFE_LINE_PIX && !vfe_is_lite(vfe)) {
		/*
		 * CLC first, then DISP WM. BUS DISP alone (no demux /
		 * demosaic / MNDS) hangs CAMNOC on this IFE.
		 */
		if (wm == DISP_Y_WM) {
			vfe_480_pix_pipeline(vfe, line);
			/*
			 * Do not start WM6/7. CamX DSX10 is the DS4 CLC;
			 * empty DS411 hung CAMNOC. COMP_GRP_1 with EN=1
			 * and no DSX waits for PD10 forever.
			 */
		}

		if (wm == DISP_C_WM) {
			/*
			 * #401 WM5 IMAGE_CFG_0 height 659 on #416:
			 * wm5=0x2930910 incr5=0x175430 stuck, img=0x20,
			 * still 4591616 UV 659.145 last_partial=336.
			 * Chroma height does not stop the 336 leftover
			 * or start frame 2. Reverted. Do not retry
			 * height 659. Do not retry FRAME_INCR 1984.
			 * Do not retry WM5 2304. Width stays 2320.
			 * Burst stays 0 (falsified). Keep errrec=0
			 * pix_store=0 EARLY_EOF=0.
			 */
			vfe_480_wm_config(vfe, wm, pix->width, pix->height / 2,
					  bpl, bpl * (pix->height / 2), true);
		} else
			vfe_480_wm_config(vfe, wm, pix->width, pix->height,
					  bpl, bpl * pix->height, true);
		if (wm == DISP_C_WM)
			dev_info(vfe->camss->dev,
				 "dagu ife%d packer4=0x%x packer5=0x%x dbg=0x%x/0x%x ubwc=0x%x mode4/5=0x%x/0x%x addr4/5=0x%x/0x%x cfg4/5=0x%x/0x%x\n",
				 vfe->id,
				 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_UBWC_STATIC_CTRL),
				 readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_C_WM)));
		return;
	}

	wm = RDI_WM(wm);

	vfe_480_wm_config(vfe, wm, 0, 0, bpl,
			  bpl * pix->height, false);
}

static void vfe_wm_stop(struct vfe_device *vfe, u8 wm)
{
	if (wm == DISP_Y_WM || wm == DISP_C_WM) {
		if (wm == DISP_Y_WM) {
			dev_info(vfe->camss->dev,
				 "dagu ife%d pix stop irq0=0x%x bus=0x%x viol=0x%x img=0x%x ccif=0x%x ovf=0x%x camif=0x%x/0x%x core=0x%x wm4=0x%x/0x%x wm5=0x%x/0x%x burst5=0x%x incr5=0x%x wm5cfg1=0x%x\n",
				 vfe->id,
				 readl_relaxed(vfe->base + VFE_IRQ_STATUS(0)),
				 readl_relaxed(vfe->base + VFE_BUS_IRQ_STATUS(0)),
				 readl_relaxed(vfe->base + VFE_VIOLATION_STATUS),
				 readl_relaxed(vfe->base + VFE_BUS_IMAGE_SIZE_VIOLATION),
				 readl_relaxed(vfe->base + VFE_BUS_CCIF_VIOLATION),
				 readl_relaxed(vfe->base + VFE_BUS_OVERFLOW_STATUS),
				 readl_relaxed(vfe->base + CAMIF_DEBUG_0),
				 readl_relaxed(vfe->base + CAMIF_DEBUG_1),
				 readl_relaxed(vfe->base + VFE_CORE_CFG_0),
				 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_BURST_LIMIT(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_FRAME_INCR(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_1(DISP_C_WM)));
			dev_info(vfe->camss->dev,
				 "dagu ife%d pix stop as0=0x%x/0x%x as1=0x%x/0x%x as2=0x%x/0x%x as3=0x%x/0x%x\n",
				 vfe->id,
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_C_WM)));
			dev_info(vfe->camss->dev,
				 "dagu ife%d pix stop crop_c=0x%x/0x%x/0x%x/0x%x/0x%x/0x%x cfg1=0x%x mid_y=0x%x/0x%x/0x%x mid_c=0x%x/0x%x/0x%x post_y=0x%x/0x%x/0x%x post_c=0x%x/0x%x/0x%x packer4=0x%x packer5=0x%x dbg=0x%x/0x%x ubwc=0x%x mode4/5=0x%x/0x%x\n",
				 vfe->id,
				 readl_relaxed(vfe->base + CLC_CROP_C + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_CROP_C + CROP_SPARE),
				 readl_relaxed(vfe->base + CLC_CROP_C + CROP_PIXEL),
				 readl_relaxed(vfe->base + CLC_CROP_C + CROP_LINE),
				 readl_relaxed(vfe->base + CLC_CROP_C + CROP_H_STRIPE),
				 readl_relaxed(vfe->base + CLC_CROP_C + CROP_V_STRIPE),
				 readl_relaxed(vfe->base + VFE_CORE_CFG_1),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_PIXEL),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_LINE),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_PIXEL),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_LINE),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_PIXEL),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_LINE),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_PIXEL),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_LINE),
				 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_UBWC_STATIC_CTRL),
				 readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_C_WM)));
		}
		writel_relaxed(0, vfe->base + VFE_BUS_WM_CFG(wm));
		if (wm == DISP_Y_WM) {
			writel_relaxed(0, vfe->base + VFE_BUS_WM_CFG(DISP_DS4_WM));
			writel_relaxed(0, vfe->base + VFE_BUS_WM_CFG(DISP_DS16_WM));
			vfe_480_clc_enable(vfe, CLC_CAMIF, 0);
		}
		return;
	}

	wm = RDI_WM(wm);
	writel_relaxed(0, vfe->base + VFE_BUS_WM_CFG(wm));
}

static void vfe_480_camif_go(struct vfe_device *vfe)
{
	u32 pat;
	u32 cfg;

	if (readl_relaxed(vfe->base + CLC_CAMIF + CLC_MODULE_CFG) & CAMIF_EN)
		return;

	/*
	 * CamX 0x52650c: MODULE = 0x101 | (bayer << 24). Pattern in
	 * CORE_CFG_0 bits 24-25 is DSP_STREAMING, not Bayer.
	 */
	pat = vfe_480_pixel_pattern(
		vfe->line[VFE_LINE_PIX].fmt[MSM_VFE_PAD_SINK].code);
	cfg = CAMIF_EN | CAMIF_IFE_OUT_EN | (pat << CAMIF_PIXEL_PATTERN);
	vfe_480_clc_enable(vfe, CLC_CAMIF, cfg);
	wmb();
	dev_info(vfe->camss->dev,
		 "dagu ife%d camif go camif=0x%x addr4/5=0x%x/0x%x cfg4/5=0x%x/0x%x as0=0x%x/0x%x as1=0x%x/0x%x as2=0x%x/0x%x as3=0x%x/0x%x wm6/7=0x%x/0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_CAMIF + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(6)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(7)));
	vfe_480_bus_dump(vfe, "go");
}

static void vfe_wm_update(struct vfe_device *vfe, u8 wm, u32 addr,
			  struct vfe_line *line)
{
	if (wm != DISP_Y_WM && wm != DISP_C_WM)
		wm = RDI_WM(wm);
	writel_relaxed(addr, vfe->base + VFE_BUS_WM_IMAGE_ADDR(wm));
	if (wm == DISP_Y_WM || wm == DISP_C_WM) {
		vfe_480_wm_sidecar_linear(vfe, wm);
		wmb();
		writel_relaxed(1 << WM_CFG_EN | MODE_QCOM_PLAIN << WM_CFG_MODE,
			       vfe->base + VFE_BUS_WM_CFG(wm));
		/* CAMIF waits for PIX RUP. CAF CDM: IMAGE_ADDR, EN, RUP, then CAMIF. */
	}
}

static void vfe_reg_update(struct vfe_device *vfe, enum vfe_line_id line_id)
{
	if (line_id == VFE_LINE_PIX) {
		vfe->reg_update |= REG_UPDATE_PIX;
		wmb();
		writel_relaxed(vfe->reg_update, vfe->base + VFE_REG_UPDATE_CMD);
		return;
	}

	vfe->reg_update |= REG_UPDATE_RDI(vfe, line_id);
	writel_relaxed(vfe->reg_update, vfe->base + VFE_REG_UPDATE_CMD);
}

static inline void vfe_reg_update_clear(struct vfe_device *vfe,
					enum vfe_line_id line_id)
{
	if (line_id == VFE_LINE_PIX)
		vfe->reg_update &= ~REG_UPDATE_PIX;
	else
		vfe->reg_update &= ~REG_UPDATE_RDI(vfe, line_id);
}

static void vfe_enable_irq(struct vfe_device *vfe)
{
	int i;
	u32 bus_irq_mask = 0;

	if (!vfe->stream_count)
		writel(IRQ_MASK_0_RESET_ACK | IRQ_MASK_0_BUS_TOP_IRQ |
		       IRQ_MASK_0_PIX_OVERFLOW,
		       vfe->base + VFE_IRQ_MASK(0));

	if (!vfe_is_lite(vfe))
		writel(IRQ_MASK_1_CAMIF, vfe->base + VFE_IRQ_MASK(1));

	for (i = 0; i < MAX_VFE_OUTPUT_LINES; i++) {
		/* Enable IRQ for newly added lines, but also keep already running lines's IRQ */
		if (vfe->line[i].output.state == VFE_OUTPUT_RESERVED ||
		    vfe->line[i].output.state == VFE_OUTPUT_ON) {
			if (i == VFE_LINE_PIX && !vfe_is_lite(vfe))
				bus_irq_mask |= BUS_IRQ_MASK_0_PIX_RUP |
						BUS_IRQ_MASK_0_COMP_DONE(vfe,
									 DISP_COMP_GROUP);
			else
				bus_irq_mask |= BUS_IRQ_MASK_0_RDI_RUP(vfe, i)
					| BUS_IRQ_MASK_0_COMP_DONE(vfe, RDI_COMP_GROUP(i));
			}
	}

	if (vfe->res->line_num > VFE_LINE_PIX && !vfe_is_lite(vfe))
		bus_irq_mask |= BUS_IRQ_MASK_0_PIX_RUP |
				BUS_IRQ_MASK_0_COMP_DONE(vfe, DISP_COMP_GROUP);

	writel(bus_irq_mask, vfe->base + VFE_BUS_IRQ_MASK(0));
}

static void vfe_isr_reg_update(struct vfe_device *vfe, enum vfe_line_id line_id);

/*
 * vfe_isr - VFE module interrupt handler
 * @irq: Interrupt line
 * @dev: VFE device
 *
 * Return IRQ_HANDLED on success
 */
static irqreturn_t vfe_isr(int irq, void *dev)
{
	struct vfe_device *vfe = dev;
	u32 status;
	int i;

	status = readl_relaxed(vfe->base + VFE_IRQ_STATUS(0));
	writel_relaxed(status, vfe->base + VFE_IRQ_CLEAR(0));

	if (!vfe_is_lite(vfe)) {
		u32 status1 = readl_relaxed(vfe->base + VFE_IRQ_STATUS(1));

		writel_relaxed(status1, vfe->base + VFE_IRQ_CLEAR(1));
		if (status1 & IRQ_MASK_1_CAMIF)
			dev_info_ratelimited(vfe->camss->dev,
					     "dagu ife%d camif irq1=0x%x\n",
					     vfe->id, status1);
	}

	writel_relaxed(IRQ_CMD_GLOBAL_CLEAR, vfe->base + VFE_IRQ_CMD);

	/*
	 * #391: PIXEL PIPE OVERFLOW latches the Titan 480 pipe.
	 * CAF error_irq_mask0 0x82000200 includes bit31 so they
	 * recover, not halt-and-dump. Clear BUS overflow and run
	 * COMP_DONE before the dump so the last 1984 UV and the
	 * next SOF can finish. #389 epoch and #390 EARLY_EOF
	 * stuck, still line=736 4591616. #391 ovf recover stuck
	 * on #405: irq0=0x80000000 bus=0x0 — PIXEL PIPE is TOP,
	 * not BUS, still 4591616. Do not crop last. Do not retry
	 * EARLY_EOF bit29. Do not treat BUS overflow clear as
	 * TOP recover.
	 */
	if (status & IRQ_MASK_0_PIX_OVERFLOW) {
		u32 bus = readl_relaxed(vfe->base + VFE_BUS_IRQ_STATUS(0));

		writel_relaxed(1, vfe->base + VFE_BUS_OVERFLOW_STATUS_CLEAR);
		wmb();
		/*
		 * #393 overflow buf_done on #407: 9183232 = 2*4591616,
		 * chunk1 Y avg 0.1 UV 0, camif irq1 still 0x1 0xc 0x2,
		 * one PIXEL PIPE OVERFLOW. buf_done retired an empty
		 * pending WM, not a second SOF. #395 CAMIF EOF buf_done
		 * on #409: eof_buf_done irq1=0x2 bus=0x0, still 9183232
		 * chunk1 Y avg 0.1 UV 0.2, irq1 0x1 0xc 0x2 0x1, one
		 * EOF. Same empty pending WM without overflow. Do not
		 * retry overflow buf_done. Do not retry CAMIF EOF
		 * buf_done. Do not retry CAMIF EN pulse. #392 pulse
		 * stuck camif=0x2000101 still 4591616. Do not crop
		 * last. Do not retry EARLY_EOF.
		 */
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d ovf recover irq0=0x%x bus=0x%x\n",
				    vfe->id, status, bus);
	}

	if (status & IRQ_MASK_0_RESET_ACK)
		vfe_isr_reset_ack(vfe);

	if (status & IRQ_MASK_0_BUS_TOP_IRQ) {
		u32 bus = readl_relaxed(vfe->base + VFE_BUS_IRQ_STATUS(0));

		writel_relaxed(bus, vfe->base + VFE_BUS_IRQ_CLEAR(0));
		writel_relaxed(1, vfe->base + VFE_BUS_IRQ_CLEAR_GLOBAL);

		for (i = 0; i < MAX_VFE_OUTPUT_LINES; i++) {
			if (i == VFE_LINE_PIX)
				continue;
			if (bus & BUS_IRQ_MASK_0_RDI_RUP(vfe, i))
				vfe_isr_reg_update(vfe, i);
		}

		if (!vfe_is_lite(vfe) && (bus & BUS_IRQ_MASK_0_PIX_RUP))
			vfe_isr_reg_update(vfe, VFE_LINE_PIX);

		if (!vfe_is_lite(vfe) &&
		    (bus & BUS_IRQ_MASK_0_COMP_DONE(vfe, DISP_COMP_GROUP))) {
			vfe_isr_reg_update(vfe, VFE_LINE_PIX);
			vfe_buf_done(vfe, DISP_Y_WM);
		}

		for (i = 0; i < MSM_VFE_IMAGE_MASTERS_NUM; i++) {
			if (bus & BUS_IRQ_MASK_0_COMP_DONE(vfe, RDI_COMP_GROUP(i)))
				vfe_buf_done(vfe, i);
		}
	}

	if (status & IRQ_MASK_0_PIX_OVERFLOW) {
		u32 viol = readl_relaxed(vfe->base + VFE_VIOLATION_STATUS);
		u32 camif0 = readl_relaxed(vfe->base + CAMIF_DEBUG_0);

		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d PIXEL PIPE OVERFLOW irq0=0x%x viol=0x%x viol_id=%u (%s) camif=0x%x pix=%u line=%u dbg=0x%x/0x%x/0x%x/0x%x mnds_c=0x%x/0x%x/0x%x/0x%x\n",
				    vfe->id, status, viol, viol & VIOL_ID_MASK,
				    vfe_480_viol_name(viol & VIOL_ID_MASK),
				    camif0, camif0 & 0xffff, camif0 >> 16,
				    readl_relaxed(vfe->base + VFE_TOP_DEBUG_0),
				    readl_relaxed(vfe->base + VFE_TOP_DEBUG_0 + 4),
				    readl_relaxed(vfe->base + VFE_TOP_DEBUG_0 + 8),
				    readl_relaxed(vfe->base + VFE_TOP_DEBUG_0 + 12),
				    readl_relaxed(vfe->base + CLC_MNDS_C + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_SIZE),
				    readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_PHASE),
				    readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_V_PAD));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow clcstat camif=0x%x bls=0x%x demux=0x%x demo=0x%x crop=0x%x mnds=0x%x post=0x%x hdr=0x%x crop64=0x%x dbg1=0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_CAMIF + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_PREPROCESS + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_DEMUX_BASE + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_DEMOSAIC + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_CROP + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_MNDS_Y + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_HDR + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_CROP + CROP_SPARE),
				    readl_relaxed(vfe->base + CLC_CAMIF + CLC_CAMIF_DEBUG_1));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow ped 2c5c=0x%x 2c60=0x%x 2c68=0x%x/0x%x/0x%x/0x%x/0x%x dmi=0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_WIN),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_AHB),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_AHB + 4),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_AHB + 8),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_AHB + 12),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_AHB + 16),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + CLC_DMI_CFG));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow pdpc30 2e60=0x%x 2e68=0x%x/0x%x/0x%x 2e7c=0x%x/0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_PDPC30 + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 4),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 8),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 20),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 24),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 28));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow demuxwin 3058=0x%x 3068=0x%x/0x%x/0x%x 307c=0x%x/0x%x 3090=0x%x 30ac=0x%x/0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + 0x3058),
				    readl_relaxed(vfe->base + 0x3068),
				    readl_relaxed(vfe->base + 0x306c),
				    readl_relaxed(vfe->base + 0x3070),
				    readl_relaxed(vfe->base + 0x307c),
				    readl_relaxed(vfe->base + 0x3080),
				    readl_relaxed(vfe->base + CLC_DEMUX),
				    readl_relaxed(vfe->base + CLC_DEMUX_TAIL_CROP +
						  CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_DEMUX_TAIL_CROP +
						  CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_DEMUX_TAIL_CROP +
						  CROP_LINE));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow lin 2a60=0x%x 2a64=0x%x 2a68=0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_LIN + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_LIN + 0x64),
				    readl_relaxed(vfe->base + CLC_LIN + 0x68),
				    readl_relaxed(vfe->base + CLC_LIN + 0x6c));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow rcwin pre=0x%x/0x%x midy=0x%x/0x%x midc=0x%x/0x%x posty=0x%x/0x%x postc=0x%x/0x%x outy=0x%x/0x%x outc=0x%x/0x%x ds411=0x%x/0x%x/0x%x/0x%x bls=0x%x/0x%x/0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_RNDCLAMP + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_OUT_Y + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_OUT_Y + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_OUT_C + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_OUT_C + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_DS411_Y_CROP),
				    readl_relaxed(vfe->base + CLC_DS411_Y_CROP + 4),
				    readl_relaxed(vfe->base + CLC_DS411_C_CROP),
				    readl_relaxed(vfe->base + CLC_DS411_C_CROP + 4),
				    readl_relaxed(vfe->base + CLC_PREPROCESS + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_PREPROCESS + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_PREPROCESS + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_PREPROCESS + CLC_DMI_CFG));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow lsc40 3660=0x%x 3668=0x%x/0x%x/0x%x/0x%x/0x%x cst=0x%x/0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_GTM + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_GTM + LSC_AHB),
				    readl_relaxed(vfe->base + CLC_GTM + LSC_AHB + 4),
				    readl_relaxed(vfe->base + CLC_GTM + LSC_AHB + 8),
				    readl_relaxed(vfe->base + CLC_GTM + LSC_AHB + 12),
				    readl_relaxed(vfe->base + CLC_GTM + LSC_AHB + 16),
				    readl_relaxed(vfe->base + CLC_CST + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_CST_MATRIX),
				    readl_relaxed(vfe->base + CLC_CST_MATRIX + 4));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow wb13 3868=0x%x/0x%x/0x%x/0x%x interp=0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB),
				    readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 4),
				    readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 8),
				    readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 12),
				    readl_relaxed(vfe->base + CLC_DEMOSAIC_INTERP));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow abf40 3260=0x%x 3268=0x%x/0x%x 3270=0x%x/0x%x 3460=0x%x 3468=0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_ABF + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_ABF + 0x68),
				    readl_relaxed(vfe->base + CLC_ABF + 0x6c),
				    readl_relaxed(vfe->base + CLC_ABF + ABF_REGION),
				    readl_relaxed(vfe->base + CLC_ABF + ABF_REGION + 4),
				    readl_relaxed(vfe->base + CLC_GIC + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_GIC + 0x68),
				    readl_relaxed(vfe->base + CLC_GIC + 0x6c));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow packer4=0x%x packer5=0x%x dbg=0x%x/0x%x ubwc=0x%x mode4/5=0x%x/0x%x addr4/5=0x%x/0x%x cfg4/5=0x%x/0x%x camif=0x%x wm6/7=0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_UBWC_STATIC_CTRL),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_C_WM)),
				    readl_relaxed(vfe->base + CLC_CAMIF + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + VFE_BUS_WM_CFG(6)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_CFG(7)));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow as0=0x%x/0x%x as1=0x%x/0x%x as2=0x%x/0x%x as3=0x%x/0x%x meta4/5=0x%x/0x%x pwr_iso=0x%x cache4=0x%x bwlim4/5=0x%x/0x%x fh4=0x%x dbg1=0x%x/0x%x cc=0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_META_ADDR(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_META_ADDR(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_PWR_ISO_CFG),
				    readl_relaxed(vfe->base + VFE_BUS_WM_SYSTEM_CACHE_CFG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_BW_LIMIT(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_BW_LIMIT(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_FRAME_HEADER_CFG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG_1(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG_1(DISP_C_WM)),
				    readl_relaxed(vfe->base + CLC_CC + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_CC + CLC_CC_MATRIX));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow ds as0=0x%x/0x%x as2=0x%x/0x%x as3=0x%x/0x%x addr6/7=0x%x/0x%x packer6/7=0x%x/0x%x dbg1=0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_DS4_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_DS16_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_DS4_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_DS16_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_DS4_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_DS16_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS4_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS16_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_DS4_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_DS16_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG_1(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG_1(DISP_C_WM)));
		vfe_480_bus_dump(vfe, "ovf");
		vfe_480_camnoc_dump(vfe, "ovf");
	}

	return IRQ_HANDLED;
}

/*
 * vfe_halt - Trigger halt on VFE module and wait to complete
 * @vfe: VFE device
 *
 * Return 0 on success or a negative error code otherwise
 */
static int vfe_halt(struct vfe_device *vfe)
{
	/* rely on vfe_disable_output() to stop the VFE */
	return 0;
}

/*
 * vfe_isr_reg_update - Process reg update interrupt
 * @vfe: VFE Device
 * @line_id: VFE line
 */
static void vfe_isr_reg_update(struct vfe_device *vfe, enum vfe_line_id line_id)
{
	struct vfe_output *output;
	unsigned long flags;

	spin_lock_irqsave(&vfe->output_lock, flags);
	vfe_reg_update_clear(vfe, line_id);

	output = &vfe->line[line_id].output;

	if (output->wait_reg_update) {
		output->wait_reg_update = 0;
		complete(&output->reg_update);
	}

	spin_unlock_irqrestore(&vfe->output_lock, flags);
}

static const struct camss_video_ops vfe_video_ops_480 = {
	.queue_buffer = vfe_queue_buffer_v2,
	.flush_buffers = vfe_flush_buffers,
};

static void vfe_subdev_init(struct device *dev, struct vfe_device *vfe)
{
	vfe->video_ops = vfe_video_ops_480;
	vfe_480_ds_alloc(dev);
	if (!vfe_480_camnoc) {
		vfe_480_camnoc = devm_ioremap(dev, CAMNOC_PHYS, CAMNOC_SIZE);
		if (!vfe_480_camnoc)
			dev_err(dev, "dagu CAMNOC 0x%lx ioremap failed\n",
				(unsigned long)CAMNOC_PHYS);
	}
}

static void vfe_isr_read(struct vfe_device *vfe, u32 *value0, u32 *value1)
{
	/* nop */
}

static void vfe_violation_read(struct vfe_device *vfe)
{
	/* nop */
}

static void vfe_buf_done_480(struct vfe_device *vfe, int port_id)
{
	/* nop */
}

const struct vfe_hw_ops vfe_ops_480 = {
	.enable_irq = vfe_enable_irq,
	.global_reset = vfe_global_reset,
	.hw_version = vfe_hw_version,
	.isr = vfe_isr,
	.isr_read = vfe_isr_read,
	.reg_update = vfe_reg_update,
	.reg_update_clear = vfe_reg_update_clear,
	.pm_domain_off = vfe_pm_domain_off,
	.pm_domain_on = vfe_pm_domain_on,
	.subdev_init = vfe_subdev_init,
	.vfe_disable = vfe_disable,
	.vfe_enable = vfe_enable_v2,
	.vfe_halt = vfe_halt,
	.violation_read = vfe_violation_read,
	.vfe_wm_start = vfe_wm_start,
	.vfe_wm_stop = vfe_wm_stop,
	.vfe_buf_done = vfe_buf_done_480,
	.vfe_wm_update = vfe_wm_update,
	.pix_go = vfe_480_camif_go,
};
