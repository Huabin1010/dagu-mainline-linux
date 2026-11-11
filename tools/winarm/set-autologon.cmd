@echo off
rem Right-click -> Run as administrator.
rem dagu: give the local account a password and log in without a prompt.
rem No arguments: password hhb1010 for the default local account, auto-logon on.
rem   set-autologon.cmd status   show what is configured now
rem   set-autologon.cmd off      stop logging in automatically
net session >nul 2>&1 || (echo Please right-click and choose "Run as administrator" & pause & exit /b 1)
set ARG=status
if /i "%~1"=="status" set ARG=-Status
if /i "%~1"=="off" set ARG=-DisableAutologon
if "%~1"=="" set ARG=
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0set-autologon.ps1" %ARG%
pause
