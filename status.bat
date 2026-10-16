@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0defender.ps1" -Action status
echo.
pause
