// dagu PCIe0 (QCA6390 Wi-Fi) root bridge. Installed by DaguPcieDxe only
// after it has trained the link and set up the iATU, together with an MCFG
// for segment 0 / buses 0-1 at 0x60000000:
//   bus 0 = the root port's DBI at 0x60000000,
//   bus 1 = iATU region 0 (CFG0, ECAM shift mode) at 0x60100000.
// MEM window = iATU region 1, 1:1, 0x60200000-0x63FFFFFF.
// Shape follows the SM8250 MTP PCI0, minus its _DEP on PEP0/QPPX (dagu has
// neither) and with the window sized for QCA6390's BAR.
DefinitionBlock ("", "SSDT", 2, "DAGU  ", "PCIE0   ", 1)
{
    Scope (\_SB)
    {
        Device (PCI0)
        {
            Name (_HID, EisaId ("PNP0A08"))
            Name (_CID, EisaId ("PNP0A03"))
            Name (_UID, Zero)
            Name (_SEG, Zero)
            Name (_BBN, Zero)
            Name (_CCA, One)        // sm8250.dtsi pcie0: dma-coherent
            // INTA..INTD = GIC SPI 149..152
            Name (_PRT, Package () {
                Package () { 0xFFFF, Zero, Zero, 0xB5 },
                Package () { 0xFFFF, One,  Zero, 0xB6 },
                Package () { 0xFFFF, 2,    Zero, 0xB7 },
                Package () { 0xFFFF, 3,    Zero, 0xB8 },
            })
            Method (_STA, 0) { Return (0x0F) }
            Method (_CRS, 0, Serialized)
            {
                Name (RBUF, ResourceTemplate ()
                {
                    WordBusNumber (ResourceProducer, MinFixed, MaxFixed, PosDecode,
                        0x0000, 0x0000, 0x0001, 0x0000, 0x0002)
                    DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed,
                        NonCacheable, ReadWrite,
                        0x00000000, 0x60200000, 0x63FFFFFF, 0x00000000, 0x03E00000)
                })
                Return (RBUF)
            }
            Name (SUPP, Zero)
            Name (CTRL, Zero)
            Method (_OSC, 4)
            {
                If ((Arg0 == ToUUID ("33db4d5b-1ff7-401c-9657-7441c03dd766")))
                {
                    CreateDWordField (Arg3, Zero, CDW1)
                    CreateDWordField (Arg3, 4, CDW2)
                    CreateDWordField (Arg3, 8, CDW3)
                    SUPP = CDW2
                    CTRL = CDW3
                    If (((SUPP & 0x16) != 0x16))
                    {
                        CTRL &= 0x1E
                    }
                    CTRL &= 0x15
                    If ((Arg1 != One))
                    {
                        CDW1 |= 0x08
                    }
                    If ((CDW3 != CTRL))
                    {
                        CDW1 |= 0x10
                    }
                    CDW3 = CTRL
                    Return (Arg3)
                }
                Else
                {
                    CreateDWordField (Arg3, Zero, CDW0)
                    CDW0 |= 0x04
                    Return (Arg3)
                }
            }
            Name (_S0W, 4)
            Device (RP1)
            {
                Name (_ADR, Zero)
                Name (_S0W, 4)
            }
        }
    }
}
