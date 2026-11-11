@echo off
rem Right-click -> Run as administrator. Stage 24 SMMU context-bank write test.
rem Writes C:\dagu-gpu\smmuwt-run.txt, then reboots into fastboot.
net session >nul 2>&1 || (echo Please right-click and choose "Run as administrator" & pause & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0smmuwt.ps1"
pause
