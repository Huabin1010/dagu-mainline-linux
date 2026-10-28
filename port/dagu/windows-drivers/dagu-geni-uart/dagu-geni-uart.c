/* SPDX-License-Identifier: MIT
 * dagu QUP0 SE6 GENI UART, SerCx2 PIO controller (Bluetooth transport bottom).
 *
 * The QCA6390 Bluetooth radio hangs off QUP0 serial engine 6 (serial@998000,
 * GIC_SPI 607 -> ACPI 639). On top of it the stock Qualcomm transport
 * qcbtfmuart_hst8180.sys (ACPI\QCOM0471, _SUB MTPC8180) speaks HCI and loads
 * htbtfw20.tlv/htnv20.bin. That transport opens its UART through the ACPI
 * UartSerialBusV2 + Resource Hub, which needs a SerCx2 controller underneath.
 *
 * The stock qcuart8250 cannot be that controller on dagu: it depends on the
 * Qualcomm power engine (PoFx/qcpep8250) to turn the SE on at open time, and
 * dagu has no working PEP (loading qcpep bricks the boot, 0x7B/0x1D5). So the
 * device "starts" but every CreateFile on it returns STATUS_DEVICE_NOT_READY
 * (0xC00000A3), and the transport fails Code 10.
 *
 * This driver is the replacement. It assumes the environment DaguQupDxe and
 * DaguPcieDxe leave at hand-off, and never reaches for the PEP:
 *   - SE6 already has the GENI UART protocol firmware loaded (FW_REVISION_RO
 *     proto == UART). DaguQupDxe did it before ExitBootServices.
 *   - GPIO16..19 are muxed to qup6 (TX/RX/CTS/RFR).
 *   - The QUP0 wrapper AHB/core clocks and gcc_qupv3_wrap0_s6_clk are running
 *     and nobody in Windows turns them off (no Qualcomm clock driver). We do
 *     NOT touch GCC or the QUP wrapper CSRs (those drop dagu to fastboot).
 *   - QCA6390 is powered and BT_EN (gpio21) is asserted by DaguPcieDxe.
 *
 * All we do is drive the SE-local GENI UART registers in FIFO/PIO mode, the
 * same register sequence the mainline qcom_geni_serial.c FIFO path uses, with
 * no GPI DMA, no interconnect vote, no wrapper firmware re-init.
 *
 * Source clock: gcc_qupv3_wrap0_s6_clk is left at whatever rate DaguQupDxe
 * programmed (see Se6SourceHz below). The GENI serial-clock divider in
 * GENI_SER_M/S_CLK_CFG is what we change per baud, so the source must be a
 * rate from which the wanted bauds divide acceptably. The actual achieved
 * source rate is logged by DaguQupDxe over the PStore ring; if it differs from
 * the default assumed here, set the REG_DWORD "Se6SourceHz" under the driver
 * service Parameters key and reload (no recompile) -- same idea as himax.
 */

#include <ntddk.h>
#include <wdf.h>
#include <sercx.h>
#include <ntddser.h>
#include <reshub.h>

/* ------------------------------------------------------------------ */
/* GENI SE register map (SE-local, offset from the 0x998000 block).    */
/* ------------------------------------------------------------------ */
#define GENI_FORCE_DEFAULT_REG      0x20
#define GENI_OUTPUT_CTRL            0x24
#define SE_GENI_CGC_CTRL            0x28
#define SE_GENI_STATUS              0x40
#define GENI_SER_M_CLK_CFG          0x48
#define GENI_SER_S_CLK_CFG          0x4c
#define GENI_FW_REVISION_RO         0x68
#define SE_GENI_CLK_SEL             0x7c
#define SE_GENI_CFG_SEQ_START       0x84
#define SE_GENI_BYTE_GRAN           0x254
#define SE_GENI_DMA_MODE_EN         0x258
#define SE_GENI_TX_PACKING_CFG0     0x260
#define SE_GENI_TX_PACKING_CFG1     0x264
#define SE_GENI_RX_PACKING_CFG0     0x284
#define SE_GENI_RX_PACKING_CFG1     0x288
#define SE_GENI_M_CMD0              0x600
#define SE_GENI_M_CMD_CTRL_REG      0x604
#define SE_GENI_M_IRQ_STATUS        0x610
#define SE_GENI_M_IRQ_EN            0x614
#define SE_GENI_M_IRQ_CLEAR         0x618
#define SE_GENI_S_CMD0              0x630
#define SE_GENI_S_CMD_CTRL_REG      0x634
#define SE_GENI_S_IRQ_STATUS        0x640
#define SE_GENI_S_IRQ_EN            0x644
#define SE_GENI_S_IRQ_CLEAR         0x648
#define SE_GENI_TX_FIFOn            0x700
#define SE_GENI_RX_FIFOn            0x780
#define SE_GENI_TX_FIFO_STATUS      0x800
#define SE_GENI_RX_FIFO_STATUS      0x804
#define SE_GENI_TX_WATERMARK_REG    0x80c
#define SE_GENI_RX_WATERMARK_REG    0x810
#define SE_GENI_RX_RFR_WATERMARK_REG 0x814
#define SE_GENI_IOS                 0x908
#define SE_DMA_TX_IRQ_CLR           0xc44
#define SE_DMA_TX_FSM_RST           0xc58
#define SE_DMA_RX_IRQ_CLR           0xd44
#define SE_DMA_RX_FSM_RST           0xd58
#define SE_HW_PARAM_0               0xe24
#define SE_HW_PARAM_1               0xe28
#define SE_GSI_EVENT_EN             0xe18
#define SE_IRQ_EN                   0xe1c
#define SE_DMA_GENERAL_CFG          0xe30

/* UART-specific GENI registers. */
#define SE_UART_LOOPBACK_CFG        0x22c
#define SE_UART_IO_MACRO_CTRL       0x240
#define SE_UART_TX_TRANS_CFG        0x25c
#define SE_UART_TX_WORD_LEN         0x268
#define SE_UART_TX_STOP_BIT_LEN     0x26c
#define SE_UART_TX_TRANS_LEN        0x270
#define SE_UART_RX_TRANS_CFG        0x280
#define SE_UART_RX_WORD_LEN         0x28c
#define SE_UART_RX_STALE_CNT        0x294
#define SE_UART_TX_PARITY_CFG       0x2a4
#define SE_UART_RX_PARITY_CFG       0x2a8
#define SE_UART_MANUAL_RFR          0x2ac

/* GENI wrapper HW version, read-only. Only used to pick the oversampling. */
#define QUP0_WRAP_HW_VER_PHYS       0x009C0004ULL

/* Field bits. */
#define SER_CLK_EN              0x1u
#define CLK_DIV_SHFT            4
#define CLK_DIV_MAX             0xFFFu
#define CLK_SEL_MSK             0x7u

#define M_OPCODE_SHFT           27
#define S_OPCODE_SHFT           27
#define UART_START_TX           0x1u
#define UART_START_READ         0x1u

#define M_GENI_CMD_CANCEL       (1u << 2)
#define M_GENI_CMD_ABORT        (1u << 1)
#define S_GENI_CMD_CANCEL       (1u << 2)
#define S_GENI_CMD_ABORT        (1u << 1)

#define M_GENI_CMD_ACTIVE       (1u << 0)   /* SE_GENI_STATUS */
#define S_GENI_CMD_ACTIVE       (1u << 12)  /* SE_GENI_STATUS */

#define M_CMD_DONE_EN           (1u << 0)
#define M_CMD_CANCEL_EN         (1u << 4)
#define M_CMD_ABORT_EN          (1u << 5)
#define M_TX_FIFO_WATERMARK_EN  (1u << 30)

#define S_CMD_DONE_EN           (1u << 0)
#define S_CMD_CANCEL_EN         (1u << 4)
#define S_CMD_ABORT_EN          (1u << 5)
#define S_RX_FIFO_WATERMARK_EN  (1u << 26)
#define S_RX_FIFO_LAST_EN       (1u << 27)
#define S_GP_IRQ_0_EN           (1u << 9)   /* parity error */
#define S_GP_IRQ_1_EN           (1u << 10)
#define S_GP_IRQ_2_EN           (1u << 11)  /* break */
#define S_GP_IRQ_3_EN           (1u << 12)

/* qcom-geni-se.c geni_se_init() common masks (also used by DaguQupDxe). */
#define M_COMMON_GENI_M_IRQ_EN  0x33C0007Eu
#define S_COMMON_GENI_S_IRQ_EN  0x03001E36u

#define TX_FIFO_WC_MSK          0x0FFFFFFFu
#define RX_FIFO_WC_MSK          0x01FFFFFFu
#define RX_LAST                 (1u << 31)
#define RX_LAST_BYTE_VALID_MSK  (7u << 28)
#define RX_LAST_BYTE_VALID_SHFT 28

#define IO2_DATA_IN             (1u << 1)   /* SE_GENI_IOS: CTS input */

#define UART_TX_PAR_EN          (1u << 0)
#define UART_CTS_MASK           (1u << 1)
#define UART_RX_PAR_EN          (1u << 3)
#define PAR_CALC_EN             (1u << 0)
#define PAR_EVEN                0x00u
#define PAR_ODD                 0x01u
#define TX_STOP_BIT_LEN_1       0u
#define TX_STOP_BIT_LEN_2       2u

#define GENI_FW_PROTO_UART      0x2u
#define QUP_SE_VERSION_2_5      0x20050000u

#define UART_OVERSAMPLING       32u
#define STALE_TIMEOUT           16u
#define DEFAULT_BITS_PER_CHAR   10u
#define UART_RX_WM              2u
#define BYTES_PER_FIFO_WORD     4u

#define SE6_DEFAULT_SRC_HZ      102400000u  /* see DaguQupDxe; override via reg */
#define GENI_POLL_SPINS         20000       /* x1us poll bound (matches Linux)  */

#define DAGU_TAG                'UneG'

/* ------------------------------------------------------------------ */
/* Driver state.                                                       */
/* ------------------------------------------------------------------ */

/*
 * Per i.MX SerCx2 reference, PIO notifications ride a small state machine
 * handed between the SerCx2-called callback (arming), the ISR (hardware
 * fired) and the DPC (telling SerCx2 it is ready). Keep it per direction.
 */
typedef enum {
    STATE_STOPPED = 0,
    STATE_IDLE,
    STATE_WAITING_FOR_INTERRUPT,
    STATE_WAITING_FOR_DPC,
    STATE_COMPLETE,
    STATE_CANCELLED,
} GENI_STATE;

typedef struct _GENI_UART_CONTEXT {
    WDFDEVICE          Device;
    PUCHAR             Se;          /* mapped SE6 MMIO                       */
    PVOID              SeMap;
    SIZE_T             SeLen;
    WDFINTERRUPT       Interrupt;

    SERCX2PIORECEIVE   PioReceive;
    SERCX2PIOTRANSMIT  PioTransmit;

    /* Geometry / clocking. */
    ULONG              TxFifoDepth; /* in FIFO words                         */
    ULONG              RxFifoDepth;
    ULONG              Oversampling;
    ULONG              SourceHz;    /* assumed gcc_qupv3_wrap0_s6_clk rate   */

    /* Current line settings (what we last programmed). */
    ULONG              BaudRate;
    SERIAL_LINE_CONTROL LineControl;
    SERIAL_HANDFLOW    Handflow;

    /* Wait-mask machinery (IOCTL_SERIAL_SET/WAIT_ON_MASK via SerCx2). */
    ULONG              WaitMask;
    ULONG              WaitEvents;  /* accumulated, drained in the DPC       */

    /* PIO transmit transaction. */
    GENI_STATE         TxState;
    GENI_STATE         TxDrainState;
    ULONG              TxRemaining; /* bytes of the current M_CMD not yet in FIFO */

    /* PIO receive transaction. */
    GENI_STATE         RxState;
} GENI_UART_CONTEXT, *PGENI_UART_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(GENI_UART_CONTEXT, GeniGetContext)

/* SerCx2 PIO objects carry only a back-pointer to the device context. */
typedef struct _GENI_PIO_CONTEXT {
    PGENI_UART_CONTEXT Ctx;
} GENI_PIO_CONTEXT, *PGENI_PIO_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(GENI_PIO_CONTEXT, GeniGetPioContext)

static ULONG gDbg = 1;
#define GLOG(fmt, ...) \
    do { if (gDbg) DbgPrintEx(DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL, \
        "dagu-geni-uart: " fmt "\n", __VA_ARGS__); } while (0)
#define GLOG0(msg) \
    do { if (gDbg) DbgPrintEx(DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL, \
        "dagu-geni-uart: " msg "\n"); } while (0)

/* ------------------------------------------------------------------ */
/* Register helpers.                                                   */
/* ------------------------------------------------------------------ */
static __forceinline ULONG Rd(PGENI_UART_CONTEXT c, ULONG off)
{
    return READ_REGISTER_ULONG((PULONG)(c->Se + off));
}
static __forceinline VOID Wr(PGENI_UART_CONTEXT c, ULONG off, ULONG v)
{
    WRITE_REGISTER_ULONG((PULONG)(c->Se + off), v);
}
static __forceinline VOID SetB(PGENI_UART_CONTEXT c, ULONG off, ULONG m)
{
    Wr(c, off, Rd(c, off) | m);
}
static __forceinline VOID ClrB(PGENI_UART_CONTEXT c, ULONG off, ULONG m)
{
    Wr(c, off, Rd(c, off) & ~m);
}

static BOOLEAN
PollBit(PGENI_UART_CONTEXT c, ULONG off, ULONG field, BOOLEAN set)
{
    ULONG i;
    for (i = 0; i < GENI_POLL_SPINS; i++) {
        ULONG r = Rd(c, off);
        if (((r & field) != 0) == (set ? TRUE : FALSE))
            return TRUE;
        KeStallExecutionProcessor(1);
    }
    return FALSE;
}

static BOOLEAN MainActive(PGENI_UART_CONTEXT c)
{
    return (Rd(c, SE_GENI_STATUS) & M_GENI_CMD_ACTIVE) != 0;
}
static BOOLEAN SecActive(PGENI_UART_CONTEXT c)
{
    return (Rd(c, SE_GENI_STATUS) & S_GENI_CMD_ACTIVE) != 0;
}

/* ------------------------------------------------------------------ */
/* GENI command primitives (mainline qcom-geni-se.c inline helpers).   */
/* ------------------------------------------------------------------ */
static VOID CancelMCmd(PGENI_UART_CONTEXT c)
{
    if (!MainActive(c))
        return;
    Wr(c, SE_GENI_M_CMD_CTRL_REG, M_GENI_CMD_CANCEL);
    if (!PollBit(c, SE_GENI_M_IRQ_STATUS, M_CMD_CANCEL_EN, TRUE)) {
        Wr(c, SE_GENI_M_CMD_CTRL_REG, M_GENI_CMD_ABORT);
        PollBit(c, SE_GENI_M_IRQ_STATUS, M_CMD_ABORT_EN, TRUE);
        Wr(c, SE_GENI_M_IRQ_CLEAR, M_CMD_ABORT_EN);
    }
    Wr(c, SE_GENI_M_IRQ_CLEAR, M_CMD_CANCEL_EN);
}

static VOID CancelSCmd(PGENI_UART_CONTEXT c)
{
    if (!SecActive(c))
        return;
    Wr(c, SE_GENI_S_CMD_CTRL_REG, S_GENI_CMD_CANCEL);
    if (!PollBit(c, SE_GENI_S_IRQ_STATUS, S_CMD_CANCEL_EN, TRUE)) {
        Wr(c, SE_GENI_S_CMD_CTRL_REG, S_GENI_CMD_ABORT);
        PollBit(c, SE_GENI_S_IRQ_STATUS, S_CMD_ABORT_EN, TRUE);
        Wr(c, SE_GENI_S_IRQ_CLEAR, S_CMD_ABORT_EN);
    }
    Wr(c, SE_GENI_S_IRQ_CLEAR, S_CMD_CANCEL_EN);
}

/* ------------------------------------------------------------------ */
/* One-time SE setup: packing + watermarks + IRQ masks, FIFO mode.     */
/* Mirrors geni_se_config_packing(8,4,false,..) + geni_se_init() +     */
/* geni_se_select_fifo_mode() for the UART protocol.                   */
/* ------------------------------------------------------------------ */
static VOID ConfigPacking(PGENI_UART_CONTEXT c)
{
    /* bpw 8, 4 words/entry, LSB first: idx walks 0,8,16,24. */
    ULONG cfg[4], cfg0, cfg1;
    LONG i, idx = 0;
    for (i = 0; i < 4; i++) {
        cfg[i] = ((ULONG)idx << 5) | (0u << 4) | (7u << 1);
        idx = (i + 1) * 8;
    }
    cfg[3] |= 1u;                 /* stop bit on the last vector */
    cfg0 = cfg[0] | (cfg[1] << 10);
    cfg1 = cfg[2] | (cfg[3] << 10);
    Wr(c, SE_GENI_TX_PACKING_CFG0, cfg0);
    Wr(c, SE_GENI_TX_PACKING_CFG1, cfg1);
    Wr(c, SE_GENI_RX_PACKING_CFG0, cfg0);
    Wr(c, SE_GENI_RX_PACKING_CFG1, cfg1);
    Wr(c, SE_GENI_BYTE_GRAN, 0);
}

static VOID SeInit(PGENI_UART_CONTEXT c)
{
    ULONG rxstale = DEFAULT_BITS_PER_CHAR * STALE_TIMEOUT;

    /* geni_se_irq_clear */
    Wr(c, SE_GSI_EVENT_EN, 0);
    Wr(c, SE_GENI_M_IRQ_CLEAR, 0xFFFFFFFFu);
    Wr(c, SE_GENI_S_IRQ_CLEAR, 0xFFFFFFFFu);
    Wr(c, SE_DMA_TX_IRQ_CLR, 0xFFFFFFFFu);
    Wr(c, SE_DMA_RX_IRQ_CLR, 0xFFFFFFFFu);
    Wr(c, SE_IRQ_EN, 0xFFFFFFFFu);

    /* geni_se_io_init: CGC on, default output ctrl, force default. */
    SetB(c, SE_GENI_CGC_CTRL, 0x7Fu);
    SetB(c, SE_DMA_GENERAL_CFG, 0xFu);
    Wr(c, GENI_OUTPUT_CTRL, 0x7Fu);
    Wr(c, GENI_FORCE_DEFAULT_REG, 0x1u);

    /* geni_se_io_set_mode: FIFO (clear DMA mode), no GSI. */
    ClrB(c, SE_GENI_DMA_MODE_EN, 0x1u);
    Wr(c, SE_GSI_EVENT_EN, 0);

    /* UART stale count + watermarks. */
    Wr(c, SE_UART_RX_STALE_CNT, rxstale);
    Wr(c, SE_GENI_RX_WATERMARK_REG, UART_RX_WM);
    Wr(c, SE_GENI_RX_RFR_WATERMARK_REG,
       c->RxFifoDepth > 2 ? c->RxFifoDepth - 2 : 0);

    SetB(c, SE_GENI_M_IRQ_EN, M_COMMON_GENI_M_IRQ_EN);
    SetB(c, SE_GENI_S_IRQ_EN, S_COMMON_GENI_S_IRQ_EN);

    /* No pin swap, no loopback. */
    Wr(c, SE_UART_LOOPBACK_CFG, 0);
}

/* ------------------------------------------------------------------ */
/* Baud + line control programming.                                    */
/* ------------------------------------------------------------------ */
static NTSTATUS ProgramBaud(PGENI_UART_CONTEXT c, ULONG baud)
{
    ULONG os = c->Oversampling;
    ULONG denom, div, serCfg;

    if (baud == 0)
        baud = 115200;
    denom = baud * os;
    div = (c->SourceHz + denom / 2) / denom;    /* round to nearest */
    if (div < 1)
        div = 1;
    if (div > CLK_DIV_MAX)
        div = CLK_DIV_MAX;

    serCfg = SER_CLK_EN | (div << CLK_DIV_SHFT);
    Wr(c, GENI_SER_M_CLK_CFG, serCfg);
    Wr(c, GENI_SER_S_CLK_CFG, serCfg);
    Wr(c, SE_GENI_CLK_SEL, 0);                  /* fixed GCC source, index 0 */

    c->BaudRate = baud;
    GLOG("baud %u: src %u os %u div %u (actual %u)",
         baud, c->SourceHz, os, div, c->SourceHz / (div * os));
    return STATUS_SUCCESS;
}

static VOID ProgramFormat(PGENI_UART_CONTEXT c)
{
    ULONG txCfg = Rd(c, SE_UART_TX_TRANS_CFG);
    ULONG rxCfg = Rd(c, SE_UART_RX_TRANS_CFG);
    ULONG txPar = Rd(c, SE_UART_TX_PARITY_CFG);
    ULONG rxPar = Rd(c, SE_UART_RX_PARITY_CFG);
    ULONG bits = c->LineControl.WordLength ? c->LineControl.WordLength : 8;
    ULONG stop;

    if (c->LineControl.Parity == ODD_PARITY || c->LineControl.Parity == EVEN_PARITY) {
        txCfg |= UART_TX_PAR_EN;  rxCfg |= UART_RX_PAR_EN;
        txPar |= PAR_CALC_EN;     rxPar |= PAR_CALC_EN;
        if (c->LineControl.Parity == ODD_PARITY) {
            txPar |= PAR_ODD;  rxPar |= PAR_ODD;
        } else {
            txPar |= PAR_EVEN; rxPar |= PAR_EVEN;
        }
    } else {
        txCfg &= ~UART_TX_PAR_EN;  rxCfg &= ~UART_RX_PAR_EN;
        txPar &= ~PAR_CALC_EN;     rxPar &= ~PAR_CALC_EN;
    }

    stop = (c->LineControl.StopBits == STOP_BITS_2) ? TX_STOP_BIT_LEN_2
                                                    : TX_STOP_BIT_LEN_1;

    /* Hardware flow control: clear CTS_MASK so TX honours CTS. */
    if (c->Handflow.ControlHandShake & SERIAL_CTS_HANDSHAKE)
        txCfg &= ~UART_CTS_MASK;
    else
        txCfg |= UART_CTS_MASK;

    Wr(c, SE_UART_TX_TRANS_CFG, txCfg);
    Wr(c, SE_UART_TX_PARITY_CFG, txPar);
    Wr(c, SE_UART_RX_TRANS_CFG, rxCfg);
    Wr(c, SE_UART_RX_PARITY_CFG, rxPar);
    Wr(c, SE_UART_TX_WORD_LEN, bits);
    Wr(c, SE_UART_RX_WORD_LEN, bits);
    Wr(c, SE_UART_TX_STOP_BIT_LEN, stop);
}

/* ------------------------------------------------------------------ */
/* ACPI UartSerialBusV2 connection descriptor parsing (imx reference). */
/* ------------------------------------------------------------------ */
#include <pshpack1.h>
typedef struct _PNP_UART_SERIAL_BUS_DESCRIPTOR {
    PNP_SERIAL_BUS_DESCRIPTOR SerialBusDescriptor;
    ULONG  BaudRate;
    USHORT RxBufferSize;
    USHORT TxBufferSize;
    UCHAR  Parity;
    UCHAR  SerialLinesEnabled;
} PNP_UART_SERIAL_BUS_DESCRIPTOR, *PPNP_UART_SERIAL_BUS_DESCRIPTOR;
#include <poppack.h>

#define UART_SERIAL_BUS_TYPE        0x03
#define UART_FLAG_FLOW_CTL_MASK     0x0003
#define UART_FLAG_FLOW_CTL_HW       0x0001
#define UART_FLAG_STOP_BITS_MASK    (0x0003 << 2)
#define UART_FLAG_STOP_BITS_1       (0x0001 << 2)
#define UART_FLAG_STOP_BITS_2       (0x0003 << 2)
#define UART_FLAG_DATA_BITS_MASK    (0x0007 << 4)
#define UART_FLAG_DATA_BITS_8       (0x0003 << 4)
#define UART_PARITY_NONE            0x00
#define UART_PARITY_EVEN            0x01
#define UART_PARITY_ODD             0x02

static NTSTATUS
ApplyConnectionDescriptor(PGENI_UART_CONTEXT c, PVOID ConnectionParameters)
{
    PRH_QUERY_CONNECTION_PROPERTIES_OUTPUT_BUFFER rh =
        (PRH_QUERY_CONNECTION_PROPERTIES_OUTPUT_BUFFER)ConnectionParameters;
    PPNP_UART_SERIAL_BUS_DESCRIPTOR d;
    ULONG flags;

    if (rh == NULL || rh->PropertiesLength < sizeof(*d)) {
        GLOG0("connection descriptor too small");
        return STATUS_INVALID_PARAMETER;
    }
    d = (PPNP_UART_SERIAL_BUS_DESCRIPTOR)&rh->ConnectionProperties[0];
    if (d->SerialBusDescriptor.SerialBusType != UART_SERIAL_BUS_TYPE) {
        GLOG("not a UART descriptor (type %u)",
             d->SerialBusDescriptor.SerialBusType);
        return STATUS_INVALID_PARAMETER;
    }

    flags = d->SerialBusDescriptor.TypeSpecificFlags;

    RtlZeroMemory(&c->LineControl, sizeof(c->LineControl));
    RtlZeroMemory(&c->Handflow, sizeof(c->Handflow));

    c->LineControl.WordLength =
        ((flags & UART_FLAG_DATA_BITS_MASK) == UART_FLAG_DATA_BITS_8) ? 8 : 8;
    c->LineControl.StopBits =
        ((flags & UART_FLAG_STOP_BITS_MASK) == UART_FLAG_STOP_BITS_2)
            ? STOP_BITS_2 : STOP_BIT_1;
    switch (d->Parity) {
    case UART_PARITY_EVEN: c->LineControl.Parity = EVEN_PARITY; break;
    case UART_PARITY_ODD:  c->LineControl.Parity = ODD_PARITY;  break;
    default:               c->LineControl.Parity = NO_PARITY;   break;
    }
    if ((flags & UART_FLAG_FLOW_CTL_MASK) == UART_FLAG_FLOW_CTL_HW) {
        c->Handflow.ControlHandShake = SERIAL_CTS_HANDSHAKE;
        c->Handflow.FlowReplace = SERIAL_RTS_HANDSHAKE;
    } else {
        c->Handflow.FlowReplace = SERIAL_RTS_CONTROL;
    }

    GLOG("apply config: baud %u bits %u stop %u parity %u flow 0x%x",
         d->BaudRate, c->LineControl.WordLength, c->LineControl.StopBits,
         c->LineControl.Parity, flags & UART_FLAG_FLOW_CTL_MASK);

    ProgramBaud(c, d->BaudRate);
    ProgramFormat(c);
    return STATUS_SUCCESS;
}

/* ------------------------------------------------------------------ */
/* RX arm / disarm.                                                    */
/* ------------------------------------------------------------------ */
static VOID StartRx(PGENI_UART_CONTEXT c)
{
    ULONG s;

    if (SecActive(c))
        return;
    /* geni_se_setup_s_cmd(UART_START_READ, 0) */
    s = Rd(c, SE_GENI_S_CMD0);
    s &= ~(0x1Fu << S_OPCODE_SHFT);
    s |= (UART_START_READ << S_OPCODE_SHFT);
    Wr(c, SE_GENI_S_CMD0, s);
}

static VOID StopRx(PGENI_UART_CONTEXT c)
{
    ULONG en = Rd(c, SE_GENI_S_IRQ_EN);
    en &= ~(S_RX_FIFO_WATERMARK_EN | S_RX_FIFO_LAST_EN);
    Wr(c, SE_GENI_S_IRQ_EN, en);
    CancelSCmd(c);
}

/* ------------------------------------------------------------------ */
/* SerCx2 callbacks: control plane.                                    */
/* ------------------------------------------------------------------ */
static NTSTATUS
EvtSerCx2ApplyConfig(WDFDEVICE Device, PVOID ConnectionParameters)
{
    return ApplyConnectionDescriptor(GeniGetContext(Device), ConnectionParameters);
}

static VOID
EvtSerCx2PurgeFifos(WDFDEVICE Device, BOOLEAN PurgeRx, BOOLEAN PurgeTx)
{
    PGENI_UART_CONTEXT c = GeniGetContext(Device);

    if (PurgeTx) {
        CancelMCmd(c);
        Wr(c, SE_DMA_TX_FSM_RST, 1);
        c->TxRemaining = 0;
    }
    if (PurgeRx) {
        StopRx(c);
        Wr(c, SE_DMA_RX_FSM_RST, 1);
    }
}

static VOID
EvtSerCx2SetWaitMask(WDFDEVICE Device, WDFREQUEST Request, ULONG WaitMask)
{
    PGENI_UART_CONTEXT c = GeniGetContext(Device);
    WdfInterruptAcquireLock(c->Interrupt);
    c->WaitMask = WaitMask;
    c->WaitEvents = 0;
    WdfInterruptReleaseLock(c->Interrupt);
    WdfRequestComplete(Request, STATUS_SUCCESS);
}

static VOID GetProperties(SERIAL_COMMPROP *p)
{
    RtlZeroMemory(p, sizeof(*p));
    p->PacketLength = sizeof(SERIAL_COMMPROP);
    p->PacketVersion = 2;
    p->ServiceMask = SERIAL_SP_SERIALCOMM;
    p->MaxBaud = SERIAL_BAUD_USER;
    p->ProvSubType = SERIAL_SP_RS232;
    p->ProvCapabilities = SERIAL_PCF_RTSCTS | SERIAL_PCF_CD |
                          SERIAL_PCF_TOTALTIMEOUTS | SERIAL_PCF_INTTIMEOUTS;
    p->SettableParams = SERIAL_SP_PARITY | SERIAL_SP_BAUD | SERIAL_SP_DATABITS |
                        SERIAL_SP_STOPBITS | SERIAL_SP_HANDSHAKING;
    p->SettableBaud = SERIAL_BAUD_USER | SERIAL_BAUD_115200;
    p->SettableData = SERIAL_DATABITS_8;
    p->SettableStopParity = SERIAL_STOPBITS_10 | SERIAL_PARITY_NONE |
                            SERIAL_PARITY_ODD | SERIAL_PARITY_EVEN;
    p->CurrentTxQueue = 0;
    p->CurrentRxQueue = 0;
}

static NTSTATUS
EvtSerCx2Control(WDFDEVICE Device, WDFREQUEST Request,
                 size_t OutputBufferLength, size_t InputBufferLength,
                 ULONG IoControlCode)
{
    PGENI_UART_CONTEXT c = GeniGetContext(Device);
    NTSTATUS status = STATUS_SUCCESS;
    PVOID buf;
    size_t len;
    ULONG_PTR info = 0;

    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    switch (IoControlCode) {
    case IOCTL_SERIAL_SET_BAUD_RATE: {
        PSERIAL_BAUD_RATE br;
        status = WdfRequestRetrieveInputBuffer(Request, sizeof(*br), &buf, &len);
        if (NT_SUCCESS(status)) {
            br = (PSERIAL_BAUD_RATE)buf;
            ProgramBaud(c, br->BaudRate);
        }
        break;
    }
    case IOCTL_SERIAL_GET_BAUD_RATE: {
        PSERIAL_BAUD_RATE br;
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(*br), &buf, &len);
        if (NT_SUCCESS(status)) {
            br = (PSERIAL_BAUD_RATE)buf;
            br->BaudRate = c->BaudRate;
            info = sizeof(*br);
        }
        break;
    }
    case IOCTL_SERIAL_SET_LINE_CONTROL: {
        PSERIAL_LINE_CONTROL lc;
        status = WdfRequestRetrieveInputBuffer(Request, sizeof(*lc), &buf, &len);
        if (NT_SUCCESS(status)) {
            lc = (PSERIAL_LINE_CONTROL)buf;
            c->LineControl = *lc;
            ProgramFormat(c);
        }
        break;
    }
    case IOCTL_SERIAL_GET_LINE_CONTROL: {
        PSERIAL_LINE_CONTROL lc;
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(*lc), &buf, &len);
        if (NT_SUCCESS(status)) {
            lc = (PSERIAL_LINE_CONTROL)buf;
            *lc = c->LineControl;
            info = sizeof(*lc);
        }
        break;
    }
    case IOCTL_SERIAL_SET_HANDFLOW: {
        PSERIAL_HANDFLOW hf;
        status = WdfRequestRetrieveInputBuffer(Request, sizeof(*hf), &buf, &len);
        if (NT_SUCCESS(status)) {
            hf = (PSERIAL_HANDFLOW)buf;
            c->Handflow = *hf;
            ProgramFormat(c);
        }
        break;
    }
    case IOCTL_SERIAL_GET_HANDFLOW: {
        PSERIAL_HANDFLOW hf;
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(*hf), &buf, &len);
        if (NT_SUCCESS(status)) {
            hf = (PSERIAL_HANDFLOW)buf;
            *hf = c->Handflow;
            info = sizeof(*hf);
        }
        break;
    }
    case IOCTL_SERIAL_GET_PROPERTIES: {
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(SERIAL_COMMPROP),
                                                &buf, &len);
        if (NT_SUCCESS(status)) {
            GetProperties((SERIAL_COMMPROP *)buf);
            info = sizeof(SERIAL_COMMPROP);
        }
        break;
    }
    case IOCTL_SERIAL_GET_MODEMSTATUS: {
        PULONG ms;
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(ULONG), &buf, &len);
        if (NT_SUCCESS(status)) {
            ms = (PULONG)buf;
            *ms = 0;
            if (!(Rd(c, SE_GENI_IOS) & IO2_DATA_IN))
                *ms |= SERIAL_CTS_STATE;
            info = sizeof(ULONG);
        }
        break;
    }
    case IOCTL_SERIAL_GET_DTRRTS: {
        PULONG v;
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(ULONG), &buf, &len);
        if (NT_SUCCESS(status)) {
            v = (PULONG)buf;
            *v = SERIAL_RTS_STATE | SERIAL_DTR_STATE;
            info = sizeof(ULONG);
        }
        break;
    }
    case IOCTL_SERIAL_SET_RTS:
    case IOCTL_SERIAL_CLR_RTS:
    case IOCTL_SERIAL_SET_DTR:
    case IOCTL_SERIAL_CLR_DTR:
        /* Flow lines are owned by the GENI RFR logic; accept silently. */
        status = STATUS_SUCCESS;
        break;
    default:
        status = STATUS_NOT_SUPPORTED;
        break;
    }

    WdfRequestCompleteWithInformation(Request, status, info);
    return status;
}

/* ------------------------------------------------------------------ */
/* SerCx2 PIO transmit.                                                */
/* ------------------------------------------------------------------ */
static VOID
EvtTxInit(SERCX2PIOTRANSMIT PioTransmit, ULONG Length)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioTransmit)->Ctx;

    /* Start one GENI TX command for the whole transaction length. */
    if (MainActive(c))
        CancelMCmd(c);
    c->TxState = STATE_IDLE;
    c->TxDrainState = STATE_IDLE;
    c->TxRemaining = Length;

    Wr(c, SE_GENI_M_IRQ_CLEAR, M_CMD_DONE_EN);
    Wr(c, SE_UART_TX_TRANS_LEN, Length);
    Wr(c, SE_GENI_TX_WATERMARK_REG, c->TxFifoDepth / 2);
    Wr(c, SE_GENI_M_CMD0, UART_START_TX << M_OPCODE_SHFT);
}

static VOID
EvtTxCleanup(SERCX2PIOTRANSMIT PioTransmit)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioTransmit)->Ctx;
    c->TxState = STATE_STOPPED;
    c->TxRemaining = 0;
}

static ULONG
EvtTxWriteBuffer(SERCX2PIOTRANSMIT PioTransmit, PUCHAR Buffer, ULONG Length)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioTransmit)->Ctx;
    ULONG written = 0, space, status, used;

    c->TxState = STATE_IDLE;

    status = Rd(c, SE_GENI_TX_FIFO_STATUS);
    used = status & TX_FIFO_WC_MSK;
    space = (c->TxFifoDepth > used) ? (c->TxFifoDepth - used) : 0;

    while (space > 0 && written < Length) {
        ULONG word = 0, i, n = Length - written;
        if (n > BYTES_PER_FIFO_WORD)
            n = BYTES_PER_FIFO_WORD;
        for (i = 0; i < n; i++)
            word |= (ULONG)Buffer[written + i] << (8u * i);
        Wr(c, SE_GENI_TX_FIFOn, word);
        written += n;
        space--;
    }

    if (c->TxRemaining >= written)
        c->TxRemaining -= written;
    else
        c->TxRemaining = 0;

    Wr(c, SE_GENI_M_IRQ_CLEAR, M_TX_FIFO_WATERMARK_EN);
    return written;
}

static VOID
EvtTxEnableReady(SERCX2PIOTRANSMIT PioTransmit)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioTransmit)->Ctx;

    WdfInterruptAcquireLock(c->Interrupt);
    if (c->TxState == STATE_CANCELLED) {
        WdfInterruptReleaseLock(c->Interrupt);
        return;
    }
    c->TxState = STATE_WAITING_FOR_INTERRUPT;
    SetB(c, SE_GENI_M_IRQ_EN, M_TX_FIFO_WATERMARK_EN | M_CMD_DONE_EN);
    WdfInterruptReleaseLock(c->Interrupt);
}

static BOOLEAN
EvtTxCancelReady(SERCX2PIOTRANSMIT PioTransmit)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioTransmit)->Ctx;
    BOOLEAN cancelled;

    WdfInterruptAcquireLock(c->Interrupt);
    switch (c->TxState) {
    case STATE_IDLE:
    case STATE_WAITING_FOR_INTERRUPT:
        c->TxState = STATE_CANCELLED;
        ClrB(c, SE_GENI_M_IRQ_EN, M_TX_FIFO_WATERMARK_EN);
        cancelled = TRUE;
        break;
    default:
        cancelled = FALSE;
        break;
    }
    WdfInterruptReleaseLock(c->Interrupt);
    return cancelled;
}

static VOID
EvtTxDrainFifo(SERCX2PIOTRANSMIT PioTransmit)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioTransmit)->Ctx;

    WdfInterruptAcquireLock(c->Interrupt);
    if (c->TxDrainState == STATE_CANCELLED) {
        WdfInterruptReleaseLock(c->Interrupt);
        return;
    }
    c->TxDrainState = STATE_WAITING_FOR_INTERRUPT;
    SetB(c, SE_GENI_M_IRQ_EN, M_CMD_DONE_EN);
    WdfInterruptReleaseLock(c->Interrupt);
}

static BOOLEAN
EvtTxCancelDrainFifo(SERCX2PIOTRANSMIT PioTransmit)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioTransmit)->Ctx;
    BOOLEAN cancelled;

    WdfInterruptAcquireLock(c->Interrupt);
    switch (c->TxDrainState) {
    case STATE_IDLE:
    case STATE_WAITING_FOR_INTERRUPT:
        c->TxDrainState = STATE_CANCELLED;
        cancelled = TRUE;
        break;
    default:
        cancelled = FALSE;
        break;
    }
    WdfInterruptReleaseLock(c->Interrupt);
    return cancelled;
}

static VOID
EvtTxPurgeFifo(SERCX2PIOTRANSMIT PioTransmit, ULONG BytesAlreadyTransmitted)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioTransmit)->Ctx;
    UNREFERENCED_PARAMETER(BytesAlreadyTransmitted);
    CancelMCmd(c);
    Wr(c, SE_DMA_TX_FSM_RST, 1);
    c->TxRemaining = 0;
    SerCx2PioTransmitPurgeFifoComplete(PioTransmit, 0);
}

/* ------------------------------------------------------------------ */
/* SerCx2 PIO receive.                                                 */
/* ------------------------------------------------------------------ */
static VOID
EvtRxInit(SERCX2PIORECEIVE PioReceive, ULONG Length)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioReceive)->Ctx;
    UNREFERENCED_PARAMETER(Length);
    c->RxState = STATE_IDLE;
    StartRx(c);
}

static VOID
EvtRxCleanup(SERCX2PIORECEIVE PioReceive)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioReceive)->Ctx;
    c->RxState = STATE_STOPPED;
    StopRx(c);
}

static ULONG
EvtRxReadBuffer(SERCX2PIORECEIVE PioReceive, PUCHAR Buffer, ULONG Length)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioReceive)->Ctx;
    ULONG read = 0, status, words, lastBytes, totalBytes;

    c->RxState = STATE_IDLE;

    status = Rd(c, SE_GENI_RX_FIFO_STATUS);
    words = status & RX_FIFO_WC_MSK;
    if (words == 0)
        return 0;

    lastBytes = (status & RX_LAST_BYTE_VALID_MSK) >> RX_LAST_BYTE_VALID_SHFT;
    totalBytes = BYTES_PER_FIFO_WORD * (words - 1);
    if ((status & RX_LAST) && lastBytes)
        totalBytes += lastBytes;
    else
        totalBytes += BYTES_PER_FIFO_WORD;

    while (read < totalBytes) {
        ULONG word = Rd(c, SE_GENI_RX_FIFOn);
        ULONG n = totalBytes - read;
        ULONG i;
        if (n > BYTES_PER_FIFO_WORD)
            n = BYTES_PER_FIFO_WORD;
        for (i = 0; i < n; i++) {
            if (read < Length)
                Buffer[read] = (UCHAR)(word & 0xFF);
            read++;
            word >>= 8;
        }
    }
    if (read > Length)
        read = Length;
    return read;
}

static VOID
EvtRxEnableReady(SERCX2PIORECEIVE PioReceive)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioReceive)->Ctx;

    WdfInterruptAcquireLock(c->Interrupt);
    if (c->RxState == STATE_CANCELLED) {
        WdfInterruptReleaseLock(c->Interrupt);
        return;
    }
    /* If data is already waiting, complete inline (the IRQ may not re-fire). */
    if ((Rd(c, SE_GENI_RX_FIFO_STATUS) & RX_FIFO_WC_MSK) != 0) {
        c->RxState = STATE_COMPLETE;
        WdfInterruptReleaseLock(c->Interrupt);
        SerCx2PioReceiveReady(PioReceive);
        return;
    }
    c->RxState = STATE_WAITING_FOR_INTERRUPT;
    SetB(c, SE_GENI_S_IRQ_EN, S_RX_FIFO_WATERMARK_EN | S_RX_FIFO_LAST_EN);
    WdfInterruptReleaseLock(c->Interrupt);
}

static BOOLEAN
EvtRxCancelReady(SERCX2PIORECEIVE PioReceive)
{
    PGENI_UART_CONTEXT c = GeniGetPioContext(PioReceive)->Ctx;
    BOOLEAN cancelled;

    WdfInterruptAcquireLock(c->Interrupt);
    switch (c->RxState) {
    case STATE_IDLE:
    case STATE_WAITING_FOR_INTERRUPT:
        c->RxState = STATE_CANCELLED;
        ClrB(c, SE_GENI_S_IRQ_EN, S_RX_FIFO_WATERMARK_EN | S_RX_FIFO_LAST_EN);
        cancelled = TRUE;
        break;
    default:
        cancelled = FALSE;
        break;
    }
    WdfInterruptReleaseLock(c->Interrupt);
    return cancelled;
}

/* ------------------------------------------------------------------ */
/* ISR + DPC.                                                          */
/* ------------------------------------------------------------------ */
static BOOLEAN
EvtInterruptIsr(WDFINTERRUPT Interrupt, ULONG MessageID)
{
    PGENI_UART_CONTEXT c = GeniGetContext(WdfInterruptGetDevice(Interrupt));
    ULONG m, s, mEn;
    BOOLEAN queueDpc = FALSE;

    UNREFERENCED_PARAMETER(MessageID);

    m = Rd(c, SE_GENI_M_IRQ_STATUS);
    s = Rd(c, SE_GENI_S_IRQ_STATUS);
    mEn = Rd(c, SE_GENI_M_IRQ_EN);
    Wr(c, SE_GENI_M_IRQ_CLEAR, m);
    Wr(c, SE_GENI_S_IRQ_CLEAR, s);

    if (m == 0 && s == 0)
        return FALSE;

    /* TX: watermark wants more bytes, or command fully done. */
    if (m & mEn & (M_TX_FIFO_WATERMARK_EN | M_CMD_DONE_EN)) {
        if (c->TxState == STATE_WAITING_FOR_INTERRUPT) {
            c->TxState = STATE_WAITING_FOR_DPC;
            ClrB(c, SE_GENI_M_IRQ_EN, M_TX_FIFO_WATERMARK_EN);
            queueDpc = TRUE;
        }
        if ((m & M_CMD_DONE_EN) &&
            c->TxDrainState == STATE_WAITING_FOR_INTERRUPT) {
            c->TxDrainState = STATE_WAITING_FOR_DPC;
            queueDpc = TRUE;
        }
        if (m & M_CMD_DONE_EN)
            c->WaitEvents |= SERIAL_EV_TXEMPTY;
    }

    /* RX: data at or above watermark, or a stale/last word. */
    if (s & (S_RX_FIFO_WATERMARK_EN | S_RX_FIFO_LAST_EN)) {
        c->WaitEvents |= SERIAL_EV_RXCHAR;
        if (c->RxState == STATE_WAITING_FOR_INTERRUPT) {
            c->RxState = STATE_WAITING_FOR_DPC;
            ClrB(c, SE_GENI_S_IRQ_EN,
                 S_RX_FIFO_WATERMARK_EN | S_RX_FIFO_LAST_EN);
            queueDpc = TRUE;
        }
    }

    if (c->WaitMask & c->WaitEvents)
        queueDpc = TRUE;

    if (queueDpc)
        WdfInterruptQueueDpcForIsr(Interrupt);
    return TRUE;
}

static VOID
EvtInterruptDpc(WDFINTERRUPT Interrupt, WDFOBJECT AssociatedObject)
{
    PGENI_UART_CONTEXT c = GeniGetContext(WdfInterruptGetDevice(Interrupt));
    BOOLEAN txReady = FALSE, txDrain = FALSE, rxReady = FALSE;
    ULONG events;

    UNREFERENCED_PARAMETER(AssociatedObject);

    WdfInterruptAcquireLock(c->Interrupt);
    if (c->TxState == STATE_WAITING_FOR_DPC) {
        c->TxState = STATE_COMPLETE;
        txReady = TRUE;
    }
    if (c->TxDrainState == STATE_WAITING_FOR_DPC) {
        c->TxDrainState = STATE_COMPLETE;
        txDrain = TRUE;
    }
    if (c->RxState == STATE_WAITING_FOR_DPC) {
        c->RxState = STATE_COMPLETE;
        rxReady = TRUE;
    }
    events = c->WaitEvents & c->WaitMask;
    c->WaitEvents &= ~events;
    WdfInterruptReleaseLock(c->Interrupt);

    if (rxReady)
        SerCx2PioReceiveReady(c->PioReceive);
    if (txReady)
        SerCx2PioTransmitReady(c->PioTransmit);
    if (txDrain)
        SerCx2PioTransmitDrainFifoComplete(c->PioTransmit);
    if (events)
        SerCx2CompleteWait(c->Device, events);
}

/* ------------------------------------------------------------------ */
/* PnP / power.                                                        */
/* ------------------------------------------------------------------ */
static NTSTATUS
EvtPrepareHardware(WDFDEVICE Device, WDFCMRESLIST Raw, WDFCMRESLIST Translated)
{
    PGENI_UART_CONTEXT c = GeniGetContext(Device);
    ULONG i, count;
    PHYSICAL_ADDRESS memStart = { 0 };
    ULONG memLen = 0;

    UNREFERENCED_PARAMETER(Raw);

    count = WdfCmResourceListGetCount(Translated);
    for (i = 0; i < count; i++) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR d =
            WdfCmResourceListGetDescriptor(Translated, i);
        if (d == NULL)
            continue;
        if (d->Type == CmResourceTypeMemory && memLen == 0) {
            memStart = d->u.Memory.Start;
            memLen = d->u.Memory.Length;
        }
    }

    if (memLen == 0) {
        GLOG0("no memory resource");
        return STATUS_DEVICE_CONFIGURATION_ERROR;
    }

    c->SeLen = memLen;
    c->SeMap = MmMapIoSpaceEx(memStart, memLen, PAGE_READWRITE | PAGE_NOCACHE);
    if (c->SeMap == NULL) {
        GLOG0("MmMapIoSpaceEx failed");
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    c->Se = (PUCHAR)c->SeMap;

    {
        ULONG ver = 0, major, minor, proto;
        PHYSICAL_ADDRESS vpa;
        PVOID vmap;

        vpa.QuadPart = QUP0_WRAP_HW_VER_PHYS;
        vmap = MmMapIoSpaceEx(vpa, 4, PAGE_READWRITE | PAGE_NOCACHE);
        if (vmap) {
            ver = READ_REGISTER_ULONG((PULONG)vmap);
            MmUnmapIoSpace(vmap, 4);
        }
        major = (ver >> 28) & 0xF;
        minor = (ver >> 16) & 0xFFF;
        c->Oversampling = (ver >= QUP_SE_VERSION_2_5) ? (UART_OVERSAMPLING / 2)
                                                      : UART_OVERSAMPLING;

        proto = (Rd(c, GENI_FW_REVISION_RO) >> 8) & 0xFF;
        GLOG("SE6 mapped: hwver %u.%u proto %u (want %u) tx/rx depth tbd",
             major, minor, proto, GENI_FW_PROTO_UART);
        if (proto != GENI_FW_PROTO_UART)
            GLOG0("WARNING: SE6 firmware is not UART; DaguQupDxe must load it");
    }

    /* FIFO depth from HW_PARAM (SM8250 QUPv3: 256-byte mask). */
    c->TxFifoDepth = (Rd(c, SE_HW_PARAM_0) >> 16) & 0xFF;
    c->RxFifoDepth = (Rd(c, SE_HW_PARAM_1) >> 16) & 0xFF;
    if (c->TxFifoDepth < 4 || c->TxFifoDepth > 64)
        c->TxFifoDepth = 16;
    if (c->RxFifoDepth < 4 || c->RxFifoDepth > 64)
        c->RxFifoDepth = 16;

    GLOG("tx depth %u rx depth %u os %u src %u",
         c->TxFifoDepth, c->RxFifoDepth, c->Oversampling, c->SourceHz);
    return STATUS_SUCCESS;
}

static NTSTATUS
EvtReleaseHardware(WDFDEVICE Device, WDFCMRESLIST Translated)
{
    PGENI_UART_CONTEXT c = GeniGetContext(Device);
    UNREFERENCED_PARAMETER(Translated);
    if (c->SeMap) {
        MmUnmapIoSpace(c->SeMap, c->SeLen);
        c->SeMap = NULL;
        c->Se = NULL;
    }
    return STATUS_SUCCESS;
}

static NTSTATUS
EvtD0Entry(WDFDEVICE Device, WDF_POWER_DEVICE_STATE PreviousState)
{
    PGENI_UART_CONTEXT c = GeniGetContext(Device);
    UNREFERENCED_PARAMETER(PreviousState);

    ConfigPacking(c);
    SeInit(c);
    ProgramBaud(c, c->BaudRate ? c->BaudRate : 115200);
    ProgramFormat(c);
    GLOG0("D0 entry: SE initialised");
    return STATUS_SUCCESS;
}

static NTSTATUS
EvtD0Exit(WDFDEVICE Device, WDF_POWER_DEVICE_STATE TargetState)
{
    PGENI_UART_CONTEXT c = GeniGetContext(Device);
    UNREFERENCED_PARAMETER(TargetState);
    StopRx(c);
    CancelMCmd(c);
    return STATUS_SUCCESS;
}

/* ------------------------------------------------------------------ */
/* Registry: optional source-clock override.                          */
/* ------------------------------------------------------------------ */
static VOID
ReadParameters(WDFDRIVER Driver, PGENI_UART_CONTEXT c)
{
    WDFKEY key = NULL;
    NTSTATUS st;
    ULONG v;
    DECLARE_CONST_UNICODE_STRING(valSrc, L"Se6SourceHz");
    DECLARE_CONST_UNICODE_STRING(valDbg, L"DebugPrint");

    c->SourceHz = SE6_DEFAULT_SRC_HZ;

    st = WdfDriverOpenParametersRegistryKey(Driver, KEY_READ,
                                            WDF_NO_OBJECT_ATTRIBUTES, &key);
    if (!NT_SUCCESS(st))
        return;
    if (NT_SUCCESS(WdfRegistryQueryULong(key, &valSrc, &v)) && v >= 1000000)
        c->SourceHz = v;
    if (NT_SUCCESS(WdfRegistryQueryULong(key, &valDbg, &v)))
        gDbg = v;
    WdfRegistryClose(key);
}

/* ------------------------------------------------------------------ */
/* Device add.                                                         */
/* ------------------------------------------------------------------ */
static NTSTATUS
EvtDeviceAdd(WDFDRIVER Driver, PWDFDEVICE_INIT DeviceInit)
{
    NTSTATUS status;
    WDF_PNPPOWER_EVENT_CALLBACKS pnp;
    WDF_OBJECT_ATTRIBUTES attr;
    WDFDEVICE device;
    PGENI_UART_CONTEXT c;
    WDF_INTERRUPT_CONFIG intCfg;
    SERCX2_CONFIG serCfg;
    SERCX2_PIO_RECEIVE_CONFIG rxCfg;
    SERCX2_PIO_TRANSMIT_CONFIG txCfg;
    WDF_OBJECT_ATTRIBUTES pioAttr;

    DECLARE_CONST_UNICODE_STRING(sddl,
        L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;UD)(A;;GRGW;;;BU)");

    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
    pnp.EvtDevicePrepareHardware = EvtPrepareHardware;
    pnp.EvtDeviceReleaseHardware = EvtReleaseHardware;
    pnp.EvtDeviceD0Entry = EvtD0Entry;
    pnp.EvtDeviceD0Exit = EvtD0Exit;
    WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnp);

    status = SerCx2InitializeDeviceInit(DeviceInit);
    if (!NT_SUCCESS(status)) {
        GLOG("SerCx2InitializeDeviceInit %!STATUS!", status);
        return status;
    }

    WdfDeviceInitAssignSDDLString(DeviceInit, &sddl);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, GENI_UART_CONTEXT);
    status = WdfDeviceCreate(&DeviceInit, &attr, &device);
    if (!NT_SUCCESS(status)) {
        GLOG("WdfDeviceCreate %!STATUS!", status);
        return status;
    }

    c = GeniGetContext(device);
    RtlZeroMemory(c, sizeof(*c));
    c->Device = device;
    ReadParameters(Driver, c);

    /* Interrupt (GIC SPI 639). The GPIO-wake line is not in this _CRS. */
    WDF_INTERRUPT_CONFIG_INIT(&intCfg, EvtInterruptIsr, EvtInterruptDpc);
    status = WdfInterruptCreate(device, &intCfg, WDF_NO_OBJECT_ATTRIBUTES,
                                &c->Interrupt);
    if (!NT_SUCCESS(status)) {
        GLOG("WdfInterruptCreate %!STATUS!", status);
        return status;
    }

    /* SerCx2 control plane. */
    SERCX2_CONFIG_INIT(&serCfg, EvtSerCx2ApplyConfig, EvtSerCx2Control,
                       EvtSerCx2PurgeFifos);
    serCfg.EvtSerCx2SetWaitMask = EvtSerCx2SetWaitMask;
    status = SerCx2InitializeDevice(device, &serCfg);
    if (!NT_SUCCESS(status)) {
        GLOG("SerCx2InitializeDevice %!STATUS!", status);
        return status;
    }

    /* PIO receive. */
    SERCX2_PIO_RECEIVE_CONFIG_INIT(&rxCfg, EvtRxReadBuffer, EvtRxEnableReady,
                                   EvtRxCancelReady);
    rxCfg.EvtSerCx2PioReceiveInitializeTransaction = EvtRxInit;
    rxCfg.EvtSerCx2PioReceiveCleanupTransaction = EvtRxCleanup;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&pioAttr, GENI_PIO_CONTEXT);
    status = SerCx2PioReceiveCreate(device, &rxCfg, &pioAttr, &c->PioReceive);
    if (!NT_SUCCESS(status)) {
        GLOG("SerCx2PioReceiveCreate %!STATUS!", status);
        return status;
    }
    GeniGetPioContext(c->PioReceive)->Ctx = c;

    /* PIO transmit. */
    SERCX2_PIO_TRANSMIT_CONFIG_INIT(&txCfg, EvtTxWriteBuffer, EvtTxEnableReady,
                                    EvtTxCancelReady);
    txCfg.EvtSerCx2PioTransmitInitializeTransaction = EvtTxInit;
    txCfg.EvtSerCx2PioTransmitCleanupTransaction = EvtTxCleanup;
    txCfg.EvtSerCx2PioTransmitDrainFifo = EvtTxDrainFifo;
    txCfg.EvtSerCx2PioTransmitCancelDrainFifo = EvtTxCancelDrainFifo;
    txCfg.EvtSerCx2PioTransmitPurgeFifo = EvtTxPurgeFifo;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&pioAttr, GENI_PIO_CONTEXT);
    status = SerCx2PioTransmitCreate(device, &txCfg, &pioAttr, &c->PioTransmit);
    if (!NT_SUCCESS(status)) {
        GLOG("SerCx2PioTransmitCreate %!STATUS!", status);
        return status;
    }
    GeniGetPioContext(c->PioTransmit)->Ctx = c;

    GLOG0("device added");
    return STATUS_SUCCESS;
}

NTSTATUS
DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG config;
    WDFDRIVER driver;
    NTSTATUS status;

    WDF_DRIVER_CONFIG_INIT(&config, EvtDeviceAdd);
    status = WdfDriverCreate(DriverObject, RegistryPath, WDF_NO_OBJECT_ATTRIBUTES,
                             &config, &driver);
    if (!NT_SUCCESS(status))
        GLOG("WdfDriverCreate %!STATUS!", status);
    return status;
}
