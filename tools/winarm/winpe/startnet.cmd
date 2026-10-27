@echo off
rem dagu Windows deploy, run by WinPE inside QEMU on the tablet's Linux.
rem
rem Disks seen by WinPE:
rem   - the WinPE media (GPT + one FAT32 partition, label WINPE) carrying
rem     \sources\boot.wim, \woa\install.wim, \woa\drivers, \woa\unattend.xml
rem   - the real UFS LUN0 (nbdkit, every write outside esp/win refused), GPT
rem     entries esp=35, win=36.
rem Everything on the target is done by Windows' own tools (format, DISM,
rem bcdboot): an NTFS made by mkntfs/wimlib got cross-allocated by Windows.
wpeinit

rem \woa\service present = servicing an installed image: no format/apply,
rem only drivers + registry; the existing BCD is kept.
rem --- find the media (M:) ---
set M=
for %%L in (C D E F G H I J K L N O P Q R T U V Y Z) do if exist %%L:\woa\install.wim set M=%%L:
if "%M%"=="" goto :nomedia
set LOG=%M%\woa\deploy.log
echo === deploy start %DATE% %TIME% > %LOG%

rem --- find LUN0: the disk whose partition 36 exists (media has only 1) ---
set DISK=
for %%d in (0 1 2 3) do if not defined DISK call :probe %%d
if not defined DISK (echo LUN0 not found >> %LOG% & goto :done)
echo LUN0 = disk %DISK% >> %LOG%

if exist %M%\woa\bcdonly goto :bcdonly
if exist %M%\woa\service goto :service
(
echo select disk %DISK%
echo select partition 36
echo format fs=ntfs quick label=Windows
echo remove all noerr
echo assign letter=W
echo select partition 35
echo format fs=fat32 quick label=ESP
echo remove all noerr
echo assign letter=S
echo list volume
) > X:\fmt.txt
diskpart /s X:\fmt.txt >> %LOG% 2>&1
if not exist W:\ (echo W: missing after format >> %LOG% & goto :done)
if not exist S:\ (echo S: missing after format >> %LOG% & goto :done)

echo === apply %TIME% >> %LOG%
dism /Apply-Image /ImageFile:%M%\woa\install.wim /Index:1 /ApplyDir:W:\ /LogPath:%M%\woa\dism-apply.log >> %LOG% 2>&1
echo apply rc=%ERRORLEVEL% %TIME% >> %LOG%
if not exist W:\Windows\System32\ntoskrnl.exe goto :done

:drivers
echo === add-driver %TIME% >> %LOG%
dism /Image:W:\ /LogPath:%M%\woa\dism-driver.log /Add-Driver /Driver:%M%\woa\drivers /Recurse /ForceUnsigned >> %LOG% 2>&1
echo dism rc=%ERRORLEVEL% %TIME% >> %LOG%

mkdir W:\Windows\Panther 2>nul
copy /y %M%\woa\unattend.xml W:\Windows\Panther\unattend.xml >> %LOG% 2>&1

rem Keep a bugcheck on screen (no auto-reboot) and print its parameters.
echo === registry %TIME% >> %LOG%
reg load HKLM\OFFSYS W:\Windows\System32\config\SYSTEM >> %LOG% 2>&1
reg add HKLM\OFFSYS\ControlSet001\Control\CrashControl /v AutoReboot /t REG_DWORD /d 0 /f >> %LOG% 2>&1
reg add HKLM\OFFSYS\ControlSet001\Control\CrashControl /v DisplayParameters /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg unload HKLM\OFFSYS >> %LOG% 2>&1
if exist %M%\woa\service goto :done

:bcdboot
echo === bcdboot %TIME% >> %LOG%
bcdboot W:\Windows /s S: /f UEFI /l zh-cn >> %LOG% 2>&1
echo bcdboot rc=%ERRORLEVEL% >> %LOG%
set BCD=/store S:\EFI\Microsoft\Boot\BCD
bcdedit %BCD% /set {default} testsigning on >> %LOG% 2>&1
bcdedit %BCD% /set {default} nointegritychecks on >> %LOG% 2>&1
bcdedit %BCD% /set {default} recoveryenabled no >> %LOG% 2>&1
bcdedit %BCD% /set {default} bootstatuspolicy IgnoreAllFailures >> %LOG% 2>&1
rem ntbtlog.txt in W:\Windows lists every boot driver load.
bcdedit %BCD% /set {default} bootlog yes >> %LOG% 2>&1
rem Show driver names on screen while the kernel loads (sos) and keep the
rem boot animation off (quietboot no), so a hang shows where it stopped.
bcdedit %BCD% /set {default} sos on >> %LOG% 2>&1
bcdedit %BCD% /set {default} quietboot no >> %LOG% 2>&1
rem sos alone is ignored while the boot animation is on; bootux disabled
rem turns the spinner off so sos prints each driver as it loads.
bcdedit %BCD% /set {default} bootux disabled >> %LOG% 2>&1
bcdedit %BCD% /timeout 0 >> %LOG% 2>&1
bcdedit %BCD% /enum all >> %LOG% 2>&1

:done
echo === DONE %DATE% %TIME% >> %LOG%
copy /y X:\Windows\Logs\DISM\dism.log %M%\woa\dism-pe.log >nul 2>&1
wpeutil shutdown
goto :eof

:bcdonly
rem \woa\bcdonly present = rebuild only the BCD. Windows and the drivers are
rem not touched. The old store is kept as BCD.old so bcdboot writes a new one
rem instead of merging into the broken one.
(
echo select disk %DISK%
echo select partition 36
echo remove all noerr
echo assign letter=W
echo select partition 35
echo remove all noerr
echo assign letter=S
) > X:\bcd.txt
diskpart /s X:\bcd.txt >> %LOG% 2>&1
if not exist W:\Windows\System32\winload.efi (echo no Windows on W: >> %LOG% & goto :done)
if not exist S:\EFI (echo no ESP on S: >> %LOG% & goto :done)
echo === bcd rebuild %TIME% >> %LOG%
if exist S:\EFI\Microsoft\Boot\BCD.old del /f /q S:\EFI\Microsoft\Boot\BCD.old
ren S:\EFI\Microsoft\Boot\BCD BCD.old >> %LOG% 2>&1
goto :bcdboot

:service
(
echo select disk %DISK%
echo select partition 36
echo remove all noerr
echo assign letter=W
) > X:\svc.txt
diskpart /s X:\svc.txt >> %LOG% 2>&1
if not exist W:\Windows\System32\ntoskrnl.exe (echo no Windows on W: >> %LOG% & goto :done)
echo === service mode >> %LOG%
rem \woa\remove-drivers.txt: "oemNN.inf catalog.cat" per line. The catalog
rem name guards against oemNN renumbering: a mismatch is skipped, not removed.
if exist %M%\woa\remove-drivers.txt for /f "usebackq eol=# tokens=1,2" %%i in ("%M%\woa\remove-drivers.txt") do call :rmdrv %%i %%j
goto :drivers

:rmdrv
rem find, not findstr: installed INFs are UTF-16LE and findstr misses them.
find /i "%2" W:\Windows\INF\%1 >nul 2>&1 || (echo skip %1: not %2 >> %LOG% & goto :eof)
echo === remove-driver %1 %2 %TIME% >> %LOG%
dism /Image:W:\ /LogPath:%M%\woa\dism-remove.log /Remove-Driver /Driver:%1 >> %LOG% 2>&1
echo remove rc=%ERRORLEVEL% >> %LOG%
goto :eof

:probe
(
echo select disk %1
echo select partition 36
) > X:\probe.txt
diskpart /s X:\probe.txt > X:\probe.log 2>&1
type X:\probe.log >> %LOG%
rem Success prints "Partition 36 is now the selected partition" (localized,
rem the number stays); a failed select has no " 36 " in its output.
find " 36 " X:\probe.log >nul && set DISK=%1
goto :eof

:nomedia
echo WinPE media with \woa\install.wim not found
ping -n 300 127.0.0.1 >nul
wpeutil shutdown
