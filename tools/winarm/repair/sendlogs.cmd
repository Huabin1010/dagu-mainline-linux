@echo off
rem Send the repair/DISM/CBS logs back to the host PC (no PowerShell needed).
rem   curl -o C:\dagu-repair\sendlogs.cmd http://192.168.1.172:8765/sendlogs.cmd
rem   C:\dagu-repair\sendlogs.cmd
set HOST=http://192.168.1.172:8765/up
set D=C:\dagu-repair
copy /y %windir%\Logs\CBS\CBS.log %D%\CBS.log >nul 2>&1
copy /y %windir%\Logs\DISM\dism.log %D%\dism-windows.log >nul 2>&1
findstr /c:"[SR]" %D%\CBS.log > %D%\sr.txt 2>nul
for %%F in (repair.log dism.log dism-windows.log CBS.log sr.txt hash.txt sfc-cannot-repair.txt) do (
  if exist %D%\%%F (curl -sS -T %D%\%%F %HOST%/%%F && echo sent %%F) else (echo missing %%F)
)
pause
