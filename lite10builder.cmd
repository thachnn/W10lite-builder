@echo off
setlocal EnableDelayedExpansion

:: necessary utility binaries
if not exist "%~dp0bin\%PROCESSOR_ARCHITECTURE%\" tar -xf bin.tar.zip "bin\%PROCESSOR_ARCHITECTURE%"
set "PATH=%~dp0bin\%PROCESSOR_ARCHITECTURE%;%PATH%"

cd /d "%~dp0"

