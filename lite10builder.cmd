@echo off
setlocal EnableDelayedExpansion

:: check for Admin privileges
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (echo This script must be run as Administrator & exit /b 2)

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
for /f "usebackq tokens=1* delims==" %%a in ("%~n0.ini") do if not "%%a"=="" (
  set "_a=%%a"
  if not "!_a:~0,1!"==";" if not "!_a:~0,1!"=="[" set "!_a!=%%b"
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
    echo Invalid ISO file & exit /b 2
  )
  7z x -ba -aos "%SourceFile%" -odvd

  if exist dvd\efi\boot\*x64.efi set arch=x64
  call :prepareUUP

  for %%i in (dvd\sources\install.wim dvd\sources\boot.wim) do call :processWIM "%%i"
  call :processDVD
) else (
  echo Unsupported file type & exit /b 2
)

goto :eof

::--------------
:prepareUUP
for /d %%i in ("tmp\KB*-%arch%*") do if exist "%%i\update.mum" exit /b

call uupDownload.cmd %arch% "%uupVer%"
for %%i in ("uup\*-%arch%*.cab") do call extractCab.cmd "%%~nxi"

exit /b

:processWIM
:: process WinRE first
7z e -ba -aoa "%~1" Windows/System32/Recovery/Winre.wim 1/Windows/System32/Recovery/Winre.wim | findstr /b /c:"No files" || (
  call :processWIM Winre.wim
)

set "wimFile=%~1"
echo Process WIM file "%wimFile%"

:: number of images
set _count=1
for /f "tokens=2 delims== " %%a in ('7z l "%wimFile%" *.xml ^| findstr /r /c:"^Images *="') do set /a "_count=%%a"

for /l %%i in (1,1,%_count%) do (
  set _build=
  set edition=

  :: WIM info
  for /f "tokens=1* delims=: " %%a in ('Dism /English /Get-ImageInfo /ImageFile:"%wimFile%" /Index:%%i ^| find " :" ^| sort /r') do (
    if /i "%%a"=="Version" (
      if "%%~nb"=="10.0" (set "_b=%%b" & if !_b:~5! geq 17763 set "_build=!_b:~5!")
      if "!_build!"=="" (echo Unsupported version "%%b" & exit /b)
    )
    if /i "%%a"=="ProductType" if /i not "%%b"=="WinNT" (echo Unsupported product type "%%b" & exit /b)

    if /i "%%a"=="Installation" set "edition=%%b"
    if /i "%%a"=="Architecture" if /i not "%arch%"=="%%b" (set "arch=%%b" & call :prepareUUP)
  )

  if defined OSWimIndex if not "%%i"=="%OSWimIndex%" if /i not "!edition!"=="WindowsPE" set edition=
  if not "!edition!"=="" call :updateWIM %%i
)
exit /b

:updateWIM
set "_index=%~1"

:: detect WinRE
::if /i "!edition!"=="WindowsPE" 7z l -ba "%wimFile%" Windows/servicing/Packages/WinPE-Rejuv-Package~*.mum | find /i ".mum" && set edition=WinRE
echo Update "!edition!.!_build!" image "%wimFile%:%_index%"

if exist mount\* rmdir /s /q mount
if not exist mount\ mkdir mount

:: Dism /Mount-Image /ImageFile:"%wimFile%" /Index:%_index% /MountDir:mount /Optimize || exit /b 2


:: Dism /ScratchDir:tmp /Image:mount /Cleanup-Image /StartComponentCleanup /ResetBase || goto :Discard

:: Dism /Unmount-Image /MountDir:mount /Commit

exit /b

:Discard
Dism /Unmount-Image /MountDir:mount /Discard
exit /b 1

:processDVD
:: TODO update DVD files

if defined TargetISO (
  echo Make target ISO "%TargetISO%"
)
exit /b
