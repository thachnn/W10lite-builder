@echo off
setlocal EnableDelayedExpansion

:: args
set "cabFile=%~1"
set "cabId=%~n1"

cd /d "%~dp0"

:: necessary utility binaries
where 7z >nul 2>&1 || (
  if /i "%PROCESSOR_ARCHITECTURE%"=="amd64" (set xOS=amd64) else (set xOS=x86)

  if not exist "bin\!xOS!\7z.exe" tar -xvf bin.tar.zip "bin/!xOS!/7z.*"
  set "PATH=%PATH%;%CD%\bin\!xOS!"
)

:: is DU?
7z l -ba "uup\%cabFile%" update.mum | find /i ".mum" || exit /b

set "cabId=%cabId:*-KB=KB%"
echo Expand cab "%cabFile%" to "%cabId%"

:ExpandCab
7z x -ba -aos "uup\%cabFile%" -o"tmp\%cabId%" -x^^!WSU*.cab
if exist "tmp\%cabId%\%cabFile%" move /y "tmp\%cabId%\*.cab" uup\ && rd /s /q "tmp\%cabId%" && goto :ExpandCab

:: extract nested cab
if exist "tmp\%cabId%\*.cab" (
  if exist "tmp\%cabId%\*cablist.ini" del /f "tmp\%cabId%\*cablist.ini"
  for %%i in ("tmp\%cabId%\*.cab") do 7z x -ba "%%i" -o"tmp\%cabId%" && del /f "%%i"
)

if "%cabId:-x86=%"=="%cabId%" (set arch=x64) else (set arch=x86)
:: rename SSU dir
if /i not "%cabId:~0,2%"=="KB" (
  set _id=
  for /f "tokens=3 delims== " %%a in ('findstr /ri /c:"<package  *identifier=" "tmp\%cabId%\update.mum"') do set "_id=%%~a-%arch%"
  if not "!_id!"=="" (rd /s /q "tmp\!_id!" 2>nul & ren "tmp\%cabId%" "!_id!" && set "cabId=!_id!")
)

:: detect update type
if "!cabId:*-%arch%=!"=="" (
  set _type=

  findstr /i "Package_for_RollupFix" "tmp\%cabId%\update.mum" && set _type=LCU
  if "!_type!"=="" if exist "tmp\%cabId%\*_microsoft-windows-servicingstack_*.manifest" set _type=SSU
  if "!_type!"=="" findstr /i "Package_for_DotNetRollup" "tmp\%cabId%\update.mum" && set _type=NDP
  if "!_type!"=="" if exist "tmp\%cabId%\*_netfx4-netfx_detectionkeys_extended*.manifest" set _type=NetFX
  if "!_type!"=="" findstr /i "Package_for_SafeOSDU" "tmp\%cabId%\update.mum" && set _type=SafeOS

  if "!_type!"=="" if not exist "tmp\%cabId%\*_netfx4clientcorecomp.resources*.manifest" if not exist "tmp\%cabId%\*_microsoft-windows-n..35wpfcomp.resources*.manifest" (
    findstr /im "Microsoft-Windows-NetFx" "tmp\%cabId%\*.mum" && set _type=NDP
  )
  if "!_type!"=="" for %%i in (
    "tmp\%cabId%\*_microsoft-windows-sysreset_*.manifest"
    "tmp\%cabId%\*_microsoft-windows-winpe_tools_*.manifest"
    "tmp\%cabId%\*_microsoft-windows-winre-tools_*.manifest"
    "tmp\%cabId%\*_microsoft-windows-i..dsetup-rejuvenation_*.manifest"
  ) do if "!_type!"=="" set _type=SafeOS

  if "!_type!"=="" if exist "tmp\%cabId%\*_microsoft-windows-s..boot-firmwareupdate_*.manifest" set _type=SecureBoot
  :: if "!_type!"=="" findstr /im "WinPE" "tmp\%cabId%\update.mum" && (find /i "Edition""" "tmp\%cabId%\update.mum" || set _type=WinPE)
  if "!_type!"=="" if exist "tmp\%cabId%\microsoft-windows-*enablement-package~*.mum" set _type=Enablement

  if not "!_type!"=="" (
    set "_type=%cabId%-!_type!" & rd /s /q "tmp\!_type!" 2>nul & ren "tmp\%cabId%" "!_type!" && set "cabId=!_type!"
  )
)
echo Expanded to "%cabId%"
