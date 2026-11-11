@echo off
rem dagu repair, round 2. Round 1: CBS found 5 corrupt payloads in the
rem component store (.NET 4 assemblies, 4.0.15912.0) but "wim:" source
rem failed with 0x800706d9 when CBS initialised its WIM file fetcher.
rem Here the WIM is mounted read-only and used as a folder source instead.
rem Run from an Administrator Command Prompt:
rem   curl -o C:\dagu-repair\repair2.cmd http://192.168.1.172:8765/repair2.cmd
rem   C:\dagu-repair\repair2.cmd
setlocal
net session >nul 2>&1 || (echo Run this from an Administrator Command Prompt. & pause & exit /b 1)
set UP=http://192.168.1.172:8765/up
set D=C:\dagu-repair
set WIM=%D%\install.wim
set MNT=%D%\mnt
set LOG=%D%\repair2.log
echo === dagu repair2 %DATE% %TIME% > %LOG%

echo [1/5] mounting install.wim read-only ...
dism /Cleanup-Wim >nul 2>&1
if exist %MNT%\Windows dism /Unmount-Image /MountDir:%MNT% /Discard >nul 2>&1
if not exist %MNT% mkdir %MNT%
dism /Mount-Image /ImageFile:%WIM% /Index:1 /MountDir:%MNT% /ReadOnly /LogPath:%D%\dism-mount.log
echo mount rc=%ERRORLEVEL% >> %LOG%
if not exist %MNT%\Windows\WinSxS (echo mount failed >> %LOG% & goto :end)

echo [2/5] DISM RestoreHealth from the mounted folder ...
DISM /Online /Cleanup-Image /RestoreHealth /Source:%MNT%\Windows /LimitAccess /LogPath:%D%\dism2.log
echo dism rc=%ERRORLEVEL% >> %LOG%

echo [3/5] sfc /scannow (do not press Ctrl+C) ...
sfc /scannow
echo sfc rc=%ERRORLEVEL% >> %LOG%

echo [4/5] unmounting ...
dism /Unmount-Image /MountDir:%MNT% /Discard >nul 2>&1
echo unmount rc=%ERRORLEVEL% >> %LOG%

echo [5/5] PowerShell check ...
powershell -NoProfile -Command "Get-Date; $PSVersionTable.PSVersion" >> %LOG% 2>&1
echo powershell rc=%ERRORLEVEL% >> %LOG%

:end
echo === end %DATE% %TIME% >> %LOG%
copy /y %windir%\Logs\CBS\CBS.log %D%\CBS2.log >nul 2>&1
for %%F in (repair2.log dism-mount.log dism2.log CBS2.log) do if exist %D%\%%F curl -sS -T %D%\%%F %UP%/%%F >nul && echo sent %%F
echo.
type %LOG%
pause
