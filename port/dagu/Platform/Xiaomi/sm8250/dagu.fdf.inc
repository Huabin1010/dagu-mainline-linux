// ButtonsDxe — elish tablet map + dagu HOME-skip patch (ButtonsDxe.dagu.efi).
// Stock elish aborts ButtonsInit when HOME GPIO EnableInput fails (no HOME key
// on Pad 5 Pro 12.4) → Vol+/Vol-/Power never appear. apply-dagu-port.sh builds
// ButtonsDxe.dagu.efi and rewrites Apriori to the same PE32 path.
FILE DRIVER = 5bd181db-0487-4f1a-ae73-820e165611b3 {
  SECTION DXE_DEPEX = Platform/EFI_Binaries/Drivers/sm8250/ButtonsDxe/ButtonsDxe.depex
  SECTION PE32 = Platform/EFI_Binaries/Drivers/Devices/elish/ButtonsDxe/ButtonsDxe.dagu.efi
  SECTION UI = "ButtonsDxe"
}

// ACPI Tables
FILE FREEFORM = 7E374E25-8E01-4FEE-87F2-390C23C606CD {
  SECTION RAW = Platform/Xiaomi/sm8250/AcpiTables/dagu/DSDT.aml
  SECTION RAW = Silicon/Qualcomm/sm8250/AcpiTables/Madt.aml
  SECTION RAW = Silicon/Qualcomm/sm8250/AcpiTables/Facp.aml
  SECTION RAW = Silicon/Qualcomm/sm8250/AcpiTables/Gtdt.aml
  SECTION RAW = Silicon/Qualcomm/sm8250/AcpiTables/bgrt.aml
  SECTION UI = "AcpiTables"
}

// Live HyperOS FDT from dumps/dagu-20260826-210700-root/dt/fdt.dtb
// (install: tools/install-dagu-fdt.sh). Not the Linux 7.0 product DTS.
FILE FREEFORM = 25462CDA-221F-47DF-AC1D-259CFAA4E326 {
  SECTION RAW = Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb
}

# Popup boot menu (Vol+/- select, Power confirm) — must match PcdBootManagerMenuFile
INF MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenuApp.inf

# USB CDC-ACM debug console on UsbfnDwc3 (not Mass Storage / LSMS).
INF Silicon/Qualcomm/QcomPkg/Drivers/DaguUsbCdcAcmDxe/DaguUsbCdcAcmDxe.inf

# TestLabBridge OFF (ramdisk alloc was OOR). MSC/LSMS path removed.
# INF Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabBridgeDxe.inf
