@echo off
chcp 65001 >nul
title LUMI aliyun beauty relay  ^:8092
cd /d "%~dp0.."

set "PY=%USERPROFILE%\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
if not exist "%PY%" set "PY=%USERPROFILE%\.workbuddy\binaries\python\versions\3.13.12\python.exe"
if not exist "%PY%" set "PY=python"

if not "%ALIYUN_AK%"=="" goto :hask
echo Aliyun console -^> AccessKey Management -^> create AccessKey (RAM sub-account recommended)
set /p ALIYUN_AK=ALIYUN_AK:
:hask
if "%ALIYUN_AK%"=="" goto :nokey

if not "%ALIYUN_SK%"=="" goto :hassk
set /p ALIYUN_SK=ALIYUN_SK:
:hassk
if "%ALIYUN_SK%"=="" goto :nokey

echo [i] interpreter : %PY%
"%PY%" tools/lumi_aliyun_beauty.py --serve --host 0.0.0.0 --port 8092 %*
echo.
echo [i] relay stopped.
pause
exit /b 0

:nokey
echo.
echo [x] No AK/SK given, relay not started.
pause
exit /b 1
