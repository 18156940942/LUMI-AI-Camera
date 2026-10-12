@echo off
chcp 65001 >nul
title LUMI retouch relay  ^:8091
cd /d "%~dp0.."

set "PY=%USERPROFILE%\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
if not exist "%PY%" set "PY=%USERPROFILE%\.workbuddy\binaries\python\versions\3.13.12\python.exe"
if not exist "%PY%" set "PY=python"

echo [i] interpreter : %PY%
"%PY%" -c "import numpy, cv2" >nul 2>&1
if errorlevel 1 goto :nodeps

"%PY%" tools\lumi_retouch_server.py --host 0.0.0.0 --port 8091 %*
echo.
echo [i] relay stopped.
pause
exit /b 0

:nodeps
echo.
echo [x] This interpreter has no numpy / opencv-python:
echo     %PY%
echo.
echo     Install them with:
echo         "%PY%" -m pip install opencv-python numpy
echo.
echo     The App cannot connect until the relay starts.
pause
exit /b 1
