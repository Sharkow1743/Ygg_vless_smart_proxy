@echo off
:: Set the working directory to the folder where this script is located
cd /d "%~dp0"

:: Run the batch file and wait for it to finish
call "install_ygg.bat"

:: Launch Netch.exe in a separate window/process
start "" "Netch.exe"

exit