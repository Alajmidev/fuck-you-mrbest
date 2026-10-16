@echo off
setlocal
set "SELF=%~f0"

:: --- yonetici degilsek yukselt ---
net session >nul 2>&1
if %errorlevel% equ 0 goto :elevated
echo Yonetici yetkisi isteniyor... (UAC penceresinde Evet de)
powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
if errorlevel 1 (
    echo.
    echo [HATA] Yonetici yetkisi reddedildi - hicbir sey kurulmadi.
    pause
)
exit /b

:elevated
echo ============================================================
echo   DiscordAntiStealer (PowerShell) - kurulum (YONETICI)
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0defender.ps1" -Action install
echo.
echo ============================================================
echo   [TAMAM] Kuruldu ve baslatildi.
echo   - Her acilista (oturum) admin olarak otomatik calisir.
echo   - Python GEREKMEZ; tamamen PowerShell.
echo   - Durum : status.bat    Kaldir : uninstall.bat
echo ============================================================
echo.
pause
