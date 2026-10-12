@echo off
chcp 65001 >nul
title LUMI volcengine beauty relay  ^:8091
cd /d "%~dp0.."

set "PY=%USERPROFILE%\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
if not exist "%PY%" set "PY=%USERPROFILE%\.workbuddy\binaries\python\versions\3.13.12\python.exe"
if not exist "%PY%" set "PY=python"

if not "%KICKART_API_KEY%"=="" goto :haskey
echo Volcengine console -^> Create Agent ^(Kickart^) -^> API Key -^> New
set /p KICKART_API_KEY=KICKART_API_KEY: 

:haskey
if "%KICKART_API_KEY%"=="" goto :nokey

echo [i] interpreter : %PY%
"%PY%" tools/lumi_volc_beauty.py --serve --host 0.0.0.0 --port 8091 %*
echo.
echo [i] relay stopped.
pause
exit /b 0

:nokey
echo.
echo [x] No API key given, relay not started.
pause
exit /b 1
