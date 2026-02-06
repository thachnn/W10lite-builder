@echo off
setlocal EnableDelayedExpansion

:: args
set "arch=%~1"
if "%arch%"=="" set arch=x64
set "iniVer=%~n0"
if not "%~2"=="" set "iniVer=%iniVer%.%~2"

cd /d "%~dp0"

:: necessary utility binaries
where aria2c >nul 2>&1 || (
  if /i "%PROCESSOR_ARCHITECTURE%"=="amd64" (set xOS=amd64) else (set xOS=x86)

  if not exist "bin\!xOS!\aria2c.exe" tar -xvf bin.tar.zip "bin/!xOS!/aria2c.*" "bin/!xOS!/7z.*"
  set "PATH=%PATH%;%CD%\bin\!xOS!"
)

echo Prepare "%arch%" "%iniVer%"
if not exist uup\ mkdir uup

:: read INI
for /f "usebackq tokens=1* delims==" %%a in ("%iniVer%.ini") do if not "%%b"=="" if not "%%a"=="" (
  set "_a=%%a"
  if not "!_a:-%arch%=!"=="!_a!" for %%i in ( "!_a:,=" "!" ) do if not exist "uup\%%~i" call :doDownload "%%b" "%%~i"
)

goto :eof

::--------------
:doDownload
set "url=%~1"
set "outFile=%~2"

if exist "tmp\%outFile%" if not exist "tmp\%outFile%.aria2" goto :Downloaded
echo Download file "%outFile%"

:: extract hash from URL
for /f "tokens=1 delims=?" %%a in ("%url%") do set "crc=%%~na"
echo "%crc%" | findstr /i "_[0-9a-f][0-9a-f]*""" && (set "crc=%crc:*_=%" & set "crc=--checksum="sha-1=!crc:*_=!"") || (set "crc=")

echo aria2c %crc%
aria2c %crc% --file-allocation=none -c -R -o "tmp\%outFile%" "%url%"

:Downloaded
echo Try to extract cab from "%outFile%"
:: is SFX file?
if /i "%outFile:~-4%"==".exe" (
  move "tmp\%outFile%" uup\
) else (
  :: is MSU file?
  7z x -ba "tmp\%outFile%" -ouup -x^^!WSU* *.cab | findstr /b /c:"No files" && (move "tmp\%outFile%" uup\) || (del /f "tmp\%outFile%")
)
exit /b
