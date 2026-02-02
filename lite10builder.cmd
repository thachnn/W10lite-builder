@echo off
setlocal EnableDelayedExpansion

:: check for Admin privileges
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (echo This script must be run as Administrator & exit /b 1)

:: args
set "uupVer=%~1"

cd /d "%~dp0"

:: necessary utility binaries
where wimlib-imagex >nul 2>&1 || (
  if /i "%PROCESSOR_ARCHITECTURE%"=="amd64" (set xOS=amd64) else (set xOS=x86)

  if not exist "bin\!xOS!\wimlib-imagex.exe" tar -xvf bin.tar.zip "bin/!xOS!"
  set "PATH=%PATH%;%CD%\bin\!xOS!"
)

:: read INI
for /f "usebackq tokens=1* delims==" %%a in ("%~n0.ini") do if "%%a" neq "" (
  set "_a=%%a"
  if "!_a:~0,1!" neq ";" if "!_a:~0,1!" neq "[" set "!_a!=%%b"
)

if defined SourceFile goto :HasSource
:: try to download source file
if exist *.iso (if not exist *.aria2 goto :Downloaded) else if exist *.wim (goto :Downloaded)

if not defined SourceFileUrl set "SourceFileUrl=https://archive.org/download/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96_202112/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso"
echo Download ISO from URL "%SourceFileUrl%"

aria2c --file-allocation=prealloc -c -R "%SourceFileUrl%"

:Downloaded
for %%i in (*.wim *.iso) do set "SourceFile=%%i"

:HasSource
echo Source file "%SourceFile%"
if exist dvd\ rmdir /s /q dvd

:: image arch
set arch=x86

if /i "%SourceFile:~-4%"==".wim" (
  7z l -ba "%SourceFile%" Windows/SysWOW64/expand.* 1/Windows/SysWOW64/expand.* | find /i "expand." && set arch=x64
  call :prepareUUP

  call :processWIM "%SourceFile%"
) else if /i "%SourceFile:~-4%"==".iso" (
  :: verify source ISO file
  7z l -ba "%SourceFile%" bootmgr efi/boot/*.efi sources/*.wim | find /c /v "" | find "4" || (
    echo Invalid ISO file & exit /b 1
  )
  7z x -ba "%SourceFile%" -odvd

  if exist dvd\efi\boot\*x64.efi set arch=x64
  call :prepareUUP

  for %%i in (dvd\sources\install.wim dvd\sources\boot.wim) do call :processWIM "%%i"
  call :processDVD
) else (
  echo Unsupported file type & exit /b 1
)

goto :eof

::--------------
:prepareUUP
for /d %%i in ("tmp\KB*-%arch%*") do if exist "%%i\update.mum" exit /b

call uupDownload.cmd %arch% "%uupVer%"
for %%i in ("uup\*-%arch%*.cab") do call extractCab.cmd "%%i"

exit /b

:processWIM
set "wimFile=%~1"

:: process WinRE first
7z e -ba -aoa "%wimFile%" Windows/System32/Recovery/Winre.wim 1/Windows/System32/Recovery/Winre.wim | findstr /b /c:"No files" || (
  call :processWIM Winre.wim
)

echo Process WIM file "%wimFile%"
:: TODO number of images

:: WIM info
::Dism /Get-ImageInfo /ImageFile:"%wimFile%" /Index:%idx%


exit /b

:processDVD
:: TODO update DVD files

if defined TargetISO (
  echo Make target ISO "%TargetISO%"
)
exit /b
