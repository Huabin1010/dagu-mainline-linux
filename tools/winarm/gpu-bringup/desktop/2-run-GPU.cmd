@echo off
rem Double-click; prompts for Administrator.
rem On failure / hang watchdog: auto reboot into fastboot.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d C:\dagu-gpu
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\dagu-gpu\gpu.ps1" -Stage run
echo.
echo If it failed or hung: tablet should already be going to fastboot.
pause
