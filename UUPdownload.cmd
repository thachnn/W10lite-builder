@echo off
setlocal EnableDelayedExpansion

:: args
set "arch=%~1"
if "%arch%"=="" set arch=x64

cd /d "%~dp0"

:: prepared?
if exist "tmp\KB*-%arch%-*\update.mum" goto :eof
if exist "tmp\KB*-%arch%\update.mum" goto :eof

:: necessary utility binaries
set xOS=x86
if /i "%PROCESSOR_ARCHITECTURE%"=="amd64" set xOS=amd64

if not exist "bin\%xOS%\" tar -xf bin.tar.zip "bin/%xOS%"
set "PATH=%~dp0bin\%xOS%;%PATH%"

::
echo Prepare "%arch%" UUP
if not exist uup\ mkdir uup

:: read INI
for /f "usebackq tokens=1* delims==" %%a in ("%~n0.ini") do if "%%b" neq "" if "%%a" neq "" (
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
set "crc=%~n1"
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

7z x -ba "%cabFile%" -o"tmp\%cabId%"

:: extract nested cab
if exist "tmp\%cabId%\*.cab" (
  if exist "tmp\%cabId%\*.ini" del /f "tmp\%cabId%\*.ini"
  for %%i in ("tmp\%cabId%\*.cab") do 7z x -ba "%%i" -o"tmp\%cabId%" && del /f "%%i"
)

:: rename SSU dir
if /i not "%cabId:~0,2%"=="KB" (
  set _id=
  for /f "tokens=3 delims== " %%a in ('find /i "package identifier=" "tmp\%cabId%\update.mum"') do set "_id=%%~a-%arch%"
  if "!_id!" neq "" ren "tmp\%cabId%" "!_id!" && set "cabId=!_id!"
)

:: TODO detect update type
echo "tmp\%cabId%\update.mum"

goto :eof
