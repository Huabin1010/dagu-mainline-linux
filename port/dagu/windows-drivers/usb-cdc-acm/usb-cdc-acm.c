/* SPDX-License-Identifier: MIT
 * USB CDC-ACM gadget (USB IF CDC 1.2, Abstract Control Model).
 * Same host ID as Linux CONFIG_USB_G_SERIAL: 0525:a4a7 -> ttyACM / usbser.
 *
 * This is a UsbFn *function* on the tablet (device role), not usbser.sys.
 * usbser.sys runs on the PC. Do not revive Mass Storage / LSMS.
 * DWC3 stays HS; SuperSpeed PHY stays off until trained.
 */
#include <ntddk.h>
#include <wdf.h>

#define DAGU_CDC_VID    0x0525
#define DAGU_CDC_PID    0xA4A7
#define DAGU_CDC_CLASS  0x02
#define DAGU_CDC_SUB    0x02
#define DAGU_CDC_PROT   0x01
#define DAGU_CDC_BAUD   115200

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
