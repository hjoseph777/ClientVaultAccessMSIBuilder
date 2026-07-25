@echo off
setlocal
cd /d "%~dp0"
call "%~dp0Start.bat" fra
exit /b %ERRORLEVEL%