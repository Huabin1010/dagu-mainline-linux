@echo off
rem Admin: test the ESP-flag to-fastboot path without running GPU.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d C:\dagu-gpu
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p='C:\Windows\Temp\dagu-to-fastboot.cmd'; @('mountvol S: /S','break > S:\dagu-fastboot','mountvol S: /D','shutdown /r /t 0') | Set-Content $p -Encoding ASCII; schtasks /Create /TN dagu-to-fastboot /TR $p /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F; schtasks /Run /TN dagu-to-fastboot; Write-Host 'to-fastboot task started'"
