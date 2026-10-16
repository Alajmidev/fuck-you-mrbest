@echo off
setlocal
set "SELF=%~f0"
net session >nul 2>&1
if %errorlevel% equ 0 goto :elevated
powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
exit /b
:elevated
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0defender.ps1" -Action uninstall
echo.
pause
