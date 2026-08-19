@echo off
setlocal enabledelayedexpansion

set SDK_ROOT=%1
set CMD=%2
set ARCH=%3
set TYPE=%4

if "%SDK_ROOT%"=="" goto :usage
goto :run

:usage
echo Usage: build-ohos.bat ^<sdk-root^> ^[command^] ^[arch^] ^[buildtype^]
echo   sdk-root  : path to command-line-tools (e.g. C:\D\command-line-tools)
echo   command   : full ^| deps ^| hap ^| clean          [default: full]
echo   arch      : arm64-v8a ^| armeabi-v7a ^| x86_64     [default: arm64-v8a]
echo   buildtype : debug ^| release                        [default: debug]
exit /b 1

:run
if "%CMD%"=="" set CMD=full
if "%ARCH%"=="" set ARCH=arm64-v8a
if "%TYPE%"=="" set TYPE=debug

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0\..\ohos\build-ohos.ps1" -SdkRoot "%SDK_ROOT%" -Target "%CMD%" -Arch "%ARCH%" -BuildType "%TYPE%"
