@echo off
setlocal
cd /d "%~dp0"

REM IWannaBeThatAsym - Game Starter
REM Starts a temporary local web server and opens the game.
REM The game's original HTML/JS/CSS/audio files are not modified.

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0game_server.ps1"

endlocal
