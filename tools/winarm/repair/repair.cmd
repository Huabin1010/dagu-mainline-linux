@echo off
rem dagu: repair the Windows component store and system files from the
rem install.wim served by the host PC. Uses only cmd, curl, certutil, DISM
rem and sfc, because PowerShell itself fails to load (0x80070570).
rem Run from an elevated Command Prompt:
rem   curl -o C:\dagu-repair\repair.cmd http://192.168.1.172:8765/repair.cmd
rem   C:\dagu-repair\repair.cmd
setlocal
net session >nul 2>&1 || (echo Run this from an Administrator Command Prompt. & pause & exit /b 1)
set HOST=http://192.168.1.172:8765
set D=C:\dagu-repair
set WIM=%D%\install.wim
set LOG=%D%\repair.log
set WANT=cce4253bb4a20cf1bca3c90187316e4027cf977fa73daf1174c2464e59516ad0
if not exist %D% mkdir %D%
echo === dagu repair %DATE% %TIME% > %LOG%

echo [1/4] downloading install.wim (3.6 GB) ...
curl -f -C - -o %WIM% %HOST%/install.wim
if errorlevel 1 (echo download failed >> %LOG% & echo download failed & goto :end)

echo [2/4] checking SHA-256 ...
certutil -hashfile %WIM% SHA256 > %D%\hash.txt
type %D%\hash.txt >> %LOG%
findstr /i /c:"%WANT%" %D%\hash.txt >nul
if errorlevel 1 (echo hash mismatch: install.wim is damaged, run this again >> %LOG% & echo HASH MISMATCH & goto :end)
echo hash ok >> %LOG%

echo [3/4] DISM RestoreHealth from install.wim index 1 ...
DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:%WIM%:1 /LimitAccess /LogPath:%D%\dism.log
echo dism rc=%ERRORLEVEL% >> %LOG%

echo [4/4] sfc /scannow ...
sfc /scannow
echo sfc rc=%ERRORLEVEL% >> %LOG%
findstr /c:"[SR] Cannot repair" %windir%\Logs\CBS\CBS.log > %D%\sfc-cannot-repair.txt 2>nul
for %%A in (%D%\sfc-cannot-repair.txt) do echo cannot-repair lines bytes=%%~zA >> %LOG%

echo checking PowerShell ...
powershell -NoProfile -Command "Get-Date" >> %LOG% 2>&1
echo powershell rc=%ERRORLEVEL% >> %LOG%

:end
echo === end %DATE% %TIME% >> %LOG%
echo.
type %LOG%
echo.
echo Report: %LOG%
pause
