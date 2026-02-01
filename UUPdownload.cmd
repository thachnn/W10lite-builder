@echo off
setlocal EnableDelayedExpansion

:: args
set "arch=%~1"
if "%arch%"=="" set arch=x64

cd /d "%~dp0"

:: prepared?
for /d %%i in ("tmp\KB*-%arch%*") do if exist "%%i\update.mum" goto :eof

set "iniVer=%~2"
if "%iniVer%" neq "" set "iniVer=.%iniVer%"

:: necessary utility binaries
set xOS=x86
if /i "%PROCESSOR_ARCHITECTURE%"=="amd64" set xOS=amd64

if not exist "bin\%xOS%\" tar -xf bin.tar.zip "bin/%xOS%"
set "PATH=%~dp0bin\%xOS%;%PATH%"

::
echo Prepare "%arch%" UUP
if not exist uup\ mkdir uup

:: read INI
for /f "usebackq tokens=1* delims==" %%a in ("%~n0%iniVer%.ini") do if "%%b" neq "" if "%%a" neq "" (
  set "_a=%%a"

  if "!_a:-%arch%=!" neq "!_a!" for %%i in ( "!_a:,=" "!" ) do (
    set "_fn=%%~i"
    if not exist "uup\!_fn!" call :doDownload "%%b" "!_fn!"

    call :extractCab "uup\!_fn!"
  )
)

goto :eof

:: Functions
::--------------
:doDownload
set "url=%~1"
set "outFile=%~2"

if exist "tmp\%outFile%" if not exist "tmp\%outFile%.aria2" goto :Downloaded

:: extract hash from URL
for /f "tokens=1 delims=?" %%a in ("%url%") do set "crc=%%~na"
echo "%crc%" | findstr /r /i "_[0-9a-f][0-9a-f]*""" && (set "crc=%crc:*_=%" & set "crc=--checksum=sha-1=!crc:*_=!") || (set "crc=")

echo Download %crc% file "%outFile%"
aria2c %crc% -c -R -o "tmp\%outFile%" "%url%"

:Downloaded
echo Try to extract cab from "%outFile%"
:: is MSU file?
7z x -ba "tmp\%outFile%" -ouup -x^^!WSU* *.cab | findstr /b /c:"No files" && (move "tmp\%outFile%" uup\) || (del /f "tmp\%outFile%")

goto :eof

:extractCab
set "cabFile=%~1"

7z l -ba "%cabFile%" update.mum | find /i ".mum" || goto :eof
echo Expand cab "%cabFile%"

:: dir name
set "cabId=%~n1"
set "cabId=%cabId:*-KB=KB%" & set "cabId=!cabId:*-kb=KB!"

:ExpandCab
7z x -ba "%cabFile%" -o"tmp\%cabId%" -x^^!WSU*.cab
if exist "tmp\%cabId%\%~nx1" move /y "tmp\%cabId%\*.cab" uup\ && rd /s /q "tmp\%cabId%" && goto :ExpandCab

:: extract nested cab
if exist "tmp\%cabId%\*.cab" (
  if exist "tmp\%cabId%\*cablist.ini" del /f "tmp\%cabId%\*cablist.ini"
  for %%i in ("tmp\%cabId%\*.cab") do 7z x -ba "%%i" -o"tmp\%cabId%" && del /f "%%i"
)

:: rename SSU dir
if /i not "%cabId:~0,2%"=="KB" (
  set _id=
  for /f "tokens=3 delims== " %%a in ('find /i "package identifier=" "tmp\%cabId%\update.mum"') do set "_id=%%~a-%arch%"
  if "!_id!" neq "" ren "tmp\%cabId%" "!_id!" && set "cabId=!_id!"
)

:: detect update type
if "!cabId:*-%arch%=!" neq "" goto :eof
set _type=

:: find /i "WinPE" "tmp\%cabId%\update.mum" && (find /i "Edition""" "tmp\%cabId%\update.mum" || set _type=WinPE)
if "%_type%"=="" find /i "Package_for_RollupFix" "tmp\%cabId%\update.mum" && set _type=LCU
if "%_type%"=="" if exist "tmp\%cabId%\*_microsoft-windows-servicingstack_*.manifest" set _type=SSU
if "%_type%"=="" find /i "Package_for_DotNetRollup" "tmp\%cabId%\update.mum" && set _type=NDP
if "%_type%"=="" if exist "tmp\%cabId%\*_netfx4*.manifest" set _type=NetFX
:: if "%_type%"=="" if exist "tmp\%cabId%\*_microsoft-windows-*boot-firmwareupdate_*.manifest" set _type=SecureBoot

if "%_type%" neq "" ren "tmp\%cabId%" "%cabId%-%_type%"

goto :eof
