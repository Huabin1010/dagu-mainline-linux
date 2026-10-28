@echo off
rem dagu Wi-Fi debug capture. Right-click -> Run as administrator.
cd /d %~dp0
net session >nul 2>&1 || (echo Please right-click run.cmd and choose "Run as administrator" & pause & exit /b 1)
reg import qcwlan-debug.reg
set ID=PCI\VEN_17CB^&DEV_1101^&SUBSYS_010817CB^&REV_01\4^&354dc085^&0^&0000
pnputil /enum-devices /instanceid "%ID%" > devices-before.txt 2>&1
start "dbgview" /min dbgviewcli64a.exe --accepteula --kernel --verbose-kernel --no-banner --clock-ms --duration 120 --log "%~dp0qcwlan-dbg.log"
timeout /t 5 /nobreak >nul
echo Restarting the Wi-Fi device...
pnputil /restart-device "%ID%" > restart.txt 2>&1
timeout /t 60 /nobreak >nul
pnputil /enum-devices /instanceid "%ID%" > devices-after.txt 2>&1
dbgviewcli64a.exe --stop >nul 2>&1
timeout /t 3 /nobreak >nul
echo DONE. Log saved to %~dp0qcwlan-dbg.log
pause
