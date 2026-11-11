@echo off
rem Right-click -> Run as administrator. Starts qcdx once; a crash reboots into the safe state.
net session >nul 2>&1 || (echo Please right-click and choose "Run as administrator" & pause & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu.ps1" -Stage run
pause
