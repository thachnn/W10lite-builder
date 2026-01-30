@echo off
setlocal EnableDelayedExpansion

:: check for Admin privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo This script must be run as Administrator & exit /b 1
)

cd /d "%~dp0"

:: necessary utility binaries
set xOS=x86
if /i "%PROCESSOR_ARCHITECTURE%"=="amd64" set xOS=amd64

if not exist "bin\%xOS%\" tar -xf bin.tar.zip "bin/%xOS%"
set "PATH=%~dp0bin\%xOS%;%PATH%"

:: read INI
for /f "usebackq tokens=1* delims==" %%a in ("%~n0.ini") do if "%%a" neq "" (
  set "_a=%%a" & if "!_a:~0,1!" neq ";" if "!_a:~0,1!" neq "[" set "!_a!=%%b"
)

if "%SourceFile%"=="" (
  :: try to download source file
  if not exist *.iso (
    echo SourceFileUrl: "%SourceFileUrl%"

    if "%SourceFileUrl%"=="" set "SourceFileUrl=https://archive.org/download/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96_202112/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso"
    aria2c -R "%SourceFileUrl%"
  )
  for %%i in (*.iso) do set "SourceFile=%%i"
)

::
echo SourceFile: "%SourceFile%"
if exist dvd\ rmdir /s /q dvd

:: image arch
set arch=x86
if /i "%SourceFile:~-4%"==".wim" (
  7z l -ba "%SourceFile%" Windows/SysWOW64/expand.* 1/Windows/SysWOW64/expand.* | find /v "" && (set arch=x64)
  call :prepareUUP %arch%

  call :processWIM "%SourceFile%" %arch%
) else if /i "%SourceFile:~-4%"==".iso" (
  :: verify source ISO file
  7z l -ba "%SourceFile%" bootmgr efi/boot/*.efi sources/*.wim | find /c /v "" | find "4" || (
    echo Invalid ISO file & exit /b 1
  )
  7z x "%SourceFile%" -odvd

  if exist dvd\efi\boot\*x64.efi set arch=x64
  call :prepareUUP %arch%

  for %%i in (dvd\sources\install.wim dvd\sources\boot.wim) do call :processWIM "%%i" %arch%
  call :processDVD "%TargetISO%"
) else (
  echo Unsupported file type & exit /b 1
)

goto :eof

:: Functions
::--------------
:prepareUUP
echo Prepare "%1" UUP

goto :eof

:processWIM
:: process WinRE first
7z e -aoa "%1" Windows/System32/Recovery/Winre.wim 1/Windows/System32/Recovery/Winre.wim | findstr /b /c:"No files" || (
  call :processWIM Winre.wim "%2"
)

echo Process WIM "%1"

goto :eof

:processDVD
echo TargetISO: "%1"

goto :eof
