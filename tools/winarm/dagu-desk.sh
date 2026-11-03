#!/usr/bin/env bash
# Run a command line in the logged-in desktop session (session 1) of dagu
# Windows and print its output. SSH lands in session 0, which has no display:
# EnumDisplaySettings is empty there and DWM/present costs are invisible, so
# anything about real on-screen 3D must run on the interactive desktop.
#
#   tools/winarm/dagu-desk.sh 'C:\dagu\glstock\glbench.exe 1280 800' [wait_seconds]
#
# Uses a one-shot interactive scheduled task (schtasks /it) as the logged-on
# user; output goes through C:\dagu\desk-out.txt.
set -u
CMD="${1:?usage: dagu-desk.sh '<command line>' [wait_s]}"
WAIT="${2:-20}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Escape single quotes for the PowerShell single-quoted string.
ESC="${CMD//\'/\'\'}"
bash "$HERE/dagu-ps.sh" - <<PS 2>&1 | grep -av "CLIXML\|<Objs" | iconv -f gbk -t utf-8 -c
\$ProgressPreference='SilentlyContinue'
\$line1 = '@' + '$ESC' + ' > C:\dagu\desk-out.txt 2>&1'
Set-Content -Encoding ASCII C:\dagu\desk-run.cmd \$line1
Add-Content -Encoding ASCII C:\dagu\desk-run.cmd '@echo __DONE__>> C:\dagu\desk-out.txt'
Remove-Item C:\dagu\desk-out.txt -EA SilentlyContinue
schtasks /create /tn daguDesk /tr "C:\dagu\desk-run.cmd" /sc once /st 23:59 /it /f 2>&1 | Out-Null
schtasks /run /tn daguDesk 2>&1 | Out-Null
for (\$i = 0; \$i -lt $WAIT; \$i++) {
  Start-Sleep 1
  if ((Test-Path C:\dagu\desk-out.txt) -and ((Get-Content C:\dagu\desk-out.txt -Raw) -match '__DONE__')) { break }
}
if (Test-Path C:\dagu\desk-out.txt) { (Get-Content C:\dagu\desk-out.txt) | ? { \$_ -ne '__DONE__' } } else { 'no output' }
schtasks /delete /tn daguDesk /f 2>&1 | Out-Null
PS
