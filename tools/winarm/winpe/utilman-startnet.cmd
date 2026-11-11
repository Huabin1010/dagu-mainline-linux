@echo off
rem dagu: swap utilman.exe for cmd.exe in the offline Windows image so the
rem sign-in screen's accessibility button opens a SYSTEM command prompt.
rem Run from WinPE only. The original is kept as utilman.orig.exe.
rem
rem Media is found by the \woa\utilman marker; the log is \woa\utilman.log.
wpeinit
set M=
for %%L in (C D E F G H I J K L N O P Q R T U V Y Z) do if exist %%L:\woa\utilman set M=%%L:
if "%M%"=="" goto :nomedia
set LOG=%M%\woa\utilman.log
echo === utilman swap %DATE% %TIME% > %LOG%

set DISK=
for %%d in (0 1 2 3) do if not defined DISK call :probe %%d
if not defined DISK (echo LUN0 not found >> %LOG% & goto :done)
echo LUN0 = disk %DISK% >> %LOG%
(
echo select disk %DISK%
echo select partition 36
echo remove all noerr
echo assign letter=W
) > X:\u.txt
diskpart /s X:\u.txt >> %LOG% 2>&1
if not exist W:\Windows\System32\utilman.exe (echo no utilman.exe >> %LOG% & goto :done)

if not exist W:\Windows\System32\utilman.orig.exe (
  copy /y W:\Windows\System32\utilman.exe W:\Windows\System32\utilman.orig.exe >> %LOG% 2>&1
  echo backup rc=%ERRORLEVEL% >> %LOG%
) else (
  echo backup already present >> %LOG%
)
copy /y W:\Windows\System32\cmd.exe W:\Windows\System32\utilman.exe >> %LOG% 2>&1
echo swap rc=%ERRORLEVEL% >> %LOG%
for %%f in (W:\Windows\System32\utilman.exe W:\Windows\System32\utilman.orig.exe) do dir %%f >> %LOG% 2>&1

if exist %M%\woa\pkg (
  echo === package >> %LOG%
  xcopy /e /i /y %M%\woa\pkg W:\dagu-gpu >> %LOG% 2>&1
  echo xcopy rc=%ERRORLEVEL% >> %LOG%
  if exist W:\dagu-gpu\set-autologon.cmd (echo set-autologon.cmd present >> %LOG%) else (echo MISSING set-autologon.cmd >> %LOG%)
)

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
echo WinPE media with \woa\utilman not found
ping -n 60 127.0.0.1 >nul
wpeutil shutdown
