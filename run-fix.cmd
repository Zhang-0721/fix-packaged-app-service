@echo off
rem ---------------------------------------------------------------------------
rem  Launcher for Fix-PackagedAppService.ps1
rem
rem  This file is deliberately ASCII-only. cmd.exe seeks through a .bat/.cmd
rem  file by byte offset, so a file that mixes multi-byte characters with
rem  "chcp 65001" can make it jump into the middle of a line and swallow the
rem  command. Keep this launcher byte-plain.
rem
rem  Usage:
rem     run-fix.cmd                 -> diagnostic report (read-only)
rem     run-fix.cmd -Fix            -> phase 1, then reboot
rem     run-fix.cmd -Fix -Reboot    -> phase 1 and reboot automatically
rem     run-fix.cmd -Diagnose
rem ---------------------------------------------------------------------------

setlocal
set "SCRIPT=%~dp0Fix-PackagedAppService.ps1"

if not exist "%SCRIPT%" (
    echo [error] Fix-PackagedAppService.ps1 was not found next to this launcher.
    echo         Expected: "%SCRIPT%"
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo [exit code %RC%]
    pause
)
exit /b %RC%
