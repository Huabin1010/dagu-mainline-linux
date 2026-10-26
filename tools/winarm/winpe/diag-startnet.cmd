@echo off
rem dagu on-device WinPE (RAM disk, needs no UFS): show why the UFS boot disk
rem does not appear. Booted from the ESP by bootmgr's ramdisk entry; the output
rem stays on screen for a photo and in X:\diag.txt.
rem Counts match ASCII tokens (HKEY_, ACPI), so they work on any WinPE language.
wpeinit
reg add HKCU\Console /v FontSize /t REG_DWORD /d 0x00280000 /f >nul
reg add HKCU\Console /v ScreenBufferSize /t REG_DWORD /d 0x0bb80078 /f >nul
reg add HKCU\Console /v WindowSize /t REG_DWORD /d 0x00260078 /f >nul
set D=X:\diag.txt
echo === UFS0 (ACPI\QCOM24A5) > %D%
pnputil /enum-devices /deviceid "ACPI\QCOM24A5" /services /stack >> %D% 2>&1
echo === disks >> %D%
echo list disk > X:\ld.txt
diskpart /s X:\ld.txt >> %D% 2>&1
echo === DSDT OEM (HKLM\HARDWARE\ACPI\DSDT) >> %D%
reg query HKLM\HARDWARE\ACPI\DSDT >> %D% 2>&1
echo === ACPI device IDs enumerated (dagu DSDT has 85 devices) >> %D%
reg query HKLM\SYSTEM\CurrentControlSet\Enum\ACPI | find /c "HKEY_" >> %D% 2>&1
echo === problem devices (ACPI) >> %D%
pnputil /enum-devices /problem | find /c "ACPI" >> %D% 2>&1
pnputil /enum-devices /problem > X:\problem.txt 2>&1
start "dagu diag" cmd /k type %D%
