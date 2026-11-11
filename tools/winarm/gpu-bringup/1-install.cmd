@echo off
rem Right-click -> Run as administrator. Installs the shim and qcdx, GPU stays off at boot.
net session >nul 2>&1 || (echo Please right-click and choose "Run as administrator" & pause & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu.ps1" -Stage install
pause
