@echo off
rem Double-click; prompts for Administrator.
rem On failure the script reboots into fastboot automatically.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d C:\dagu-gpu
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\dagu-gpu\gpu.ps1" -Stage install
echo.
echo If install succeeded: reboot once, then run 2-run-GPU.
echo If it failed: tablet should reboot into fastboot by itself.
pause
