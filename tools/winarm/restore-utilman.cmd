@echo off
rem Right-click -> Run as administrator (or run from the SYSTEM prompt that the
rem swapped utilman.exe opened).
rem dagu: put the real utilman.exe back after the password has been reset.
set S=%SystemRoot%\System32
if not exist "%S%\utilman.orig.exe" (echo no %S%\utilman.orig.exe, nothing to restore & pause & exit /b 1)
copy /y "%S%\utilman.orig.exe" "%S%\utilman.exe"
echo restore rc=%ERRORLEVEL%
pause
