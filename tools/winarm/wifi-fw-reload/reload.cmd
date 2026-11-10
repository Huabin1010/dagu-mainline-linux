@echo off
rem Elevated wrapper. Arguments are passed through:
rem   reload.cmd -Role fw -Path D:\lab\wlanfw20.mbn
rem   reload.cmd -RestartOnly
rem   reload.cmd -Restore
cd /d %~dp0
net session >nul 2>&1 || (echo Run this from an elevated prompt. & pause & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reload.ps1" %*
exit /b %ERRORLEVEL%
