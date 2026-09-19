// NPU firmware carveout only. Linux reserved-memory pil_npu_region@86900000.
// No live iomem window in the HyperOS dump. Do not invent MMIO.

Device (NPU0)
{
    Name (_HID, "QCOM24CA")
    Name (_UID, 0)
    Name (_DDN, "SM8250 NPU PIL")
    Name (PILB, 0x86900000)
    Name (PILS, 0x00500000)
    Method (_STA, 0) { Return (0xF) }
}
