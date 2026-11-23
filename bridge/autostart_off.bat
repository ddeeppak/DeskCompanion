@echo off
set "LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Desk Bridge.lnk"
if exist "%LNK%" (
  del "%LNK%"
  echo Done. Desk Bridge will no longer start with Windows.
) else (
  echo Desk Bridge was not set to start with Windows.
)
pause
