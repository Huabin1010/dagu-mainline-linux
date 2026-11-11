@echo off
rem dagu WinPE one-shot (runs in QEMU on the tablet, LUN0 writable only in
rem esp/win). For a Windows volume left dirty by a bugcheck: mount it with
rem Windows' own NTFS (replays $LogFile), load SYSTEM (replays the hive
rem logs), force QCDX Start=4 so the next boot does not load qcdx, and copy
rem \woa\pkg into C:\dagu-gpu. Nothing is formatted.
rem Media is found by the \woa\fixqcdx marker; the log is \woa\fix.log.
wpeinit
set M=
for %%L in (C D E F G H I J K L N O P Q R T U V Y Z) do if exist %%L:\woa\fixqcdx set M=%%L:
if "%M%"=="" goto :nomedia
set LOG=%M%\woa\fix.log
echo === fix start %DATE% %TIME% > %LOG%

set DISK=
for %%d in (0 1 2 3) do if not defined DISK call :probe %%d
if not defined DISK (echo LUN0 not found >> %LOG% & goto :done)
echo LUN0 = disk %DISK% >> %LOG%
(
echo select disk %DISK%
echo select partition 36
echo remove all noerr
echo assign letter=W
) > X:\fix.txt
diskpart /s X:\fix.txt >> %LOG% 2>&1
if not exist W:\Windows\System32\config\SYSTEM (echo no SYSTEM hive on W: >> %LOG% & goto :done)
fsutil dirty query W: >> %LOG% 2>&1

echo === hive %TIME% >> %LOG%
reg load HKLM\OFFSYS W:\Windows\System32\config\SYSTEM >> %LOG% 2>&1
echo --- before >> %LOG%
reg query HKLM\OFFSYS\ControlSet001\Services\QCDX /v Start >> %LOG% 2>&1
reg add HKLM\OFFSYS\ControlSet001\Services\QCDX /v Start /t REG_DWORD /d 4 /f >> %LOG% 2>&1
echo --- after >> %LOG%
reg query HKLM\OFFSYS\ControlSet001\Services\QCDX /v Start >> %LOG% 2>&1
reg unload HKLM\OFFSYS >> %LOG% 2>&1
echo unload rc=%ERRORLEVEL% >> %LOG%

if not exist %M%\woa\pkg goto :done
echo === package %TIME% >> %LOG%
xcopy /e /i /y %M%\woa\pkg W:\dagu-gpu >> %LOG% 2>&1
echo xcopy rc=%ERRORLEVEL% >> %LOG%
for %%f in (W:\dagu-gpu\shim\dagu-smmushim.sys W:\dagu-gpu\qcif\dagu-qcif.sys W:\dagu-gpu\gpu.ps1) do certutil -hashfile %%f SHA256 >> %LOG% 2>&1

:done
echo === DONE %DATE% %TIME% >> %LOG%
wpeutil shutdown
goto :eof

:probe
(
echo select disk %1
echo select partition 36
) > X:\probe.txt
diskpart /s X:\probe.txt > X:\probe.log 2>&1
type X:\probe.log >> %LOG%
find " 36 " X:\probe.log >nul && set DISK=%1
goto :eof

:nomedia
echo WinPE media with \woa\fixqcdx not found
ping -n 60 127.0.0.1 >nul
wpeutil shutdown
