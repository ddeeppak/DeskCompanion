@echo off
rem Starts Desk Bridge (minimised) every time you sign in to Windows.
set "LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Desk Bridge.lnk"
set "TARGET=%~dp0start_bridge.bat"
set "FOLDER=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:LNK); $s.TargetPath = $env:TARGET; $s.WorkingDirectory = $env:FOLDER; $s.WindowStyle = 7; $s.Save()"
if exist "%LNK%" (
  echo Done. Desk Bridge will start minimised when you sign in to Windows.
  echo To turn this off, run autostart_off.bat.
) else (
  echo Sorry, the shortcut could not be created.
)
pause
