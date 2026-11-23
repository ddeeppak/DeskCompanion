@echo off
title Desk Bridge
cd /d "%~dp0"
:run
python desk_bridge.py
echo.
echo Desk Bridge stopped. Starting again in 5 seconds (close this window to stop it for good).
timeout /t 5 /nobreak >nul
goto run
