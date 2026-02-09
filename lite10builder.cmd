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

aria2c --file-allocation=trunc -c -R "%SourceFileUrl%"

:Downloaded
for %%i in (*.wim *.iso) do set "SourceFile=%%i"

:HasSource
echo Source file "%SourceFile%"
if exist dvd\ rmdir /s /q dvd

:: image arch
set arch=x86

if /i "%SourceFile:~-4%"==".wim" (
  wimlib-imagex info "%SourceFile%" 1 | findstr /ie "Architecture.*64" && set arch=x64
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
  for %%i in ("uup\*-!arch!-SetupDU*.cab") do call :updateDVD "%%i"

  for %%i in (dvd\sources\install.wim dvd\sources\boot.wim) do call :processWIM "%%i"
  call :createISO
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
if /i not "%~1"=="Winre.wim" (
  if defined OSWimIndex (set "_oIndex=%OSWimIndex%") else (set _oIndex=1)
  wimlib-imagex extract "%~1" "!_oIndex!" Windows/System32/Recovery/Winre.wim --no-acls 2>nul && call :processWIM Winre.wim
)

set "wimFile=%~1"
echo Process WIM file "%wimFile%"

:: number of images
set _count=1
for /f "tokens=3 delims== " %%a in ('wimlib-imagex info "%wimFile%" --header ^| find /i "Image Count"') do set /a "_count=%%a"

set _oIndex=
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

  if defined OSWimIndex if /i not "!edition!"=="WindowsPE" if "%%i"=="%OSWimIndex%" (set "_oIndex=%%i") else (set "edition=")
  if not "!edition!"=="" call :updateWIM %%i
)

call :optimizeWIM "%_oIndex%"
exit /b

:updateWIM
set "_index=%~1"
echo Update "!edition!.!_build!" image "%wimFile%:%_index%"

if exist mount\* rmdir /s /q mount
if not exist mount\ mkdir mount

::mkdir mount\Windows\WinSxS\Manifests
::wimlib-imagex extract "%wimFile%" %_index% Windows/servicing/Packages/Package_for_*.mum Windows/System32/config Windows/System32/Recovery Windows/System32/SMI/Store/Machine Windows/System32/UpdateAgent.* Windows/System32/Facilitator.* sources --dest-dir=mount --preserve-dir-structure --nullglob --no-acls
Dism /Mount-Image /ImageFile:"%wimFile%" /Index:%_index% /MountDir:mount /Optimize || exit /b 2

:: pre-update
if /i "!edition!"=="WindowsPE" (
  echo call :sbsConfig "" "" 1
) else (
  :: switch edition
  if defined TargetEdition Dism /English /Image:mount /Get-TargetEditions | find /i "%TargetEdition:*,=%" && (
    if "%TargetEdition:,=%"=="%TargetEdition%" (
      Dism /Image:mount /Set-Edition:"%TargetEdition%" || goto :Discard
    ) else (
      Dism /Image:mount /ProductKey:"%TargetEdition:,=" /Set-Edition:"%" /AcceptEula || goto :Discard
    )
  )

  :: manage features and packages
  if defined RemoveCapabilities for %%a in (%RemoveCapabilities%) do (
    set "_a=%%a"
    Dism /ScratchDir:tmp /Image:mount /Remove-Capability /CapabilityName:"!_a:,=" /CapabilityName:"!" || goto :Discard
  )
  if defined DisableFeatures for %%a in (%DisableFeatures%) do (
    set "_a=%%a"
    Dism /ScratchDir:tmp /Image:mount /Disable-Feature /FeatureName:"!_a:,=" /FeatureName:"!" /Remove || goto :Discard
  )
  if defined AddCapabilities for %%a in (%AddCapabilities%) do (
    set "_a=%%a"
    Dism /ScratchDir:tmp /Image:mount /Add-Capability /CapabilityName:"!_a:,=" /CapabilityName:"!" || goto :Discard
  )
  if defined EnableFeatures for %%a in (%EnableFeatures%) do (
    set "_a=%%a"
    Dism /ScratchDir:tmp /Image:mount /Enable-Feature /FeatureName:"!_a:,=" /FeatureName:"!" /All || goto :Discard
  )

  :: ESU AI patching
  if !_build! geq 19041 if !_build! lss 19046 call :latentESU
)

pushd tmp
:: ServicingStack first
for /d %%k in ("KB*-%arch%-SSU") do (set "_pkgPath[0]=" & call :checkInstall "%%k" "_pkgPath[0]")

set "_pkgPath[1]="
if /i "!edition!"=="WindowsPE" (
  :: SafeOS DU (WinRE only == exist \WinPE-Rejuv-Package~*.mum)
  for /d %%k in ("KB*-%arch%-SafeOS") do call :checkInstall "%%k" "_pkgPath[1]"
) else (
  :: SecureBoot
  for /d %%k in ("KB*-%arch%-SecureBoot") do call :checkInstall "%%k" "_pkgPath[1]"
)

:: ldr = Enablement NetFX NetRollup
set "_pkgPath[2]="
for /d %%k in ("KB*-%arch%-Enablement" "KB*-%arch%-NetFX") do call :checkInstall "%%k" "_pkgPath[2]"
for /f "delims=" %%k in ('dir /b /ad /on "KB*-%arch%-NDP*" "KB*-%arch%"') do call :checkInstall "%%k" "_pkgPath[2]"

:: cumulative update
set _n=2
for /d %%k in ("KB*-%arch%-LCU") do (
  set /a _n+=1 & set "_pkgPath[!_n!]=" & call :checkInstall "%%k" "_pkgPath[!_n!]"
)

for /l %%n in (0,1,%_n%) do if not "!_pkgPath[%%n]!"=="" (
  echo Offline installing "!_pkgPath[%%n]!"
  Dism /ScratchDir:. /Image:..\mount /Add-Package !_pkgPath[%%n]! || goto :Discard
)
popd

if /i "!edition!"=="WindowsPE" (
  call :meltdownSpectre & call :sbsConfig 3 "" 1
) else (
  :: allow rebase
  call :sbsConfig 3 0
)

Dism /ScratchDir:tmp /Image:mount /Cleanup-Image /StartComponentCleanup /ResetBase || goto :Discard
call :cleanManual

:: update Defender & MRT
if /i not "!edition!"=="WindowsPE" call :updateDefender

:: update ISO files
for %%k in (UpdateAgent.dll Facilitator.dll ServicingCommon.dll) do call :updateDVD "%%k" mount\Windows\System32
if exist mount\sources\setup.exe call :updateDVDboot

if /i not "%wimFile%"=="Winre.wim" if exist mount\Windows\System32\Recovery\Winre.wim if exist Winre.wim (
  xcopy /kdry Winre.wim mount\Windows\System32\Recovery\
)

:: install drivers
if /i "!edition!"=="WindowsPE" (set "_dTypes=ALL WinPE") else (set "_dTypes=ALL OS")
for %%a in (%_dTypes%) do call :tryInstallDrv "drvs\%%a" || goto :Discard

:: optimize hive files
call :optimizeHive SOFTWARE SYSTEM COMPONENTS DRIVERS mount\Windows\System32\SMI\Store\Machine\SCHEMA.DAT
pushd mount & del /f /q /a /s *.regtrans-ms *.TM.blf & popd

Dism /Unmount-Image /MountDir:mount /Commit
exit /b

:Discard
popd 2>nul
Dism /Unmount-Image /MountDir:mount /Discard

exit /b 1

:tryInstallDrv
for /r "%~1\" %%x in (*.inf) do (
  Dism /ScratchDir:tmp /Image:mount /Add-Driver /Driver:"%~1" /Recurse || exit /b !ERRORLEVEL!
  exit /b
)
exit /b

:checkInstall
if not exist "%~1\update.mum" exit /b
set "_dir=%~nx1"

:: WinPE supported?
if /i "!edition!"=="WindowsPE" if /i not "%_dir:~-4%"=="-SSU" if /i not "%_dir:~-7%"=="-SafeOS" if /i not "%_dir:~-4%"=="-LCU" (
  rem if /i "%_dir:~-6%"=="-NetFX" exit /b
  findstr /im "WinPE" "%~1\update.mum" || (echo "%_dir%" not support WinPE & exit /b)
  rem findstr /im "WinPE-NetFx-Package" "%~1\update.mum" && exit /b 1
)
:: skip installed packages
if /i "%_dir:~0,2%"=="KB" for /f "delims=-" %%x in ("%_dir%") do (
  findstr /im "\<%%x\>" "..\mount\Windows\servicing\Packages\Package_for_*.mum" && exit /b 1
)

set "%~2=!%~2! /PackagePath:"%~1\update.mum""
exit /b

:sbsConfig
reg load HKLM\zSOFTWARE mount\Windows\System32\config\SOFTWARE

:: reg query HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\SideBySide\Configuration
for %%x in (SupersededActions DisableResetbase DisableComponentBackups) do (call :sbsConfigImpl %%x "%%~1" & shift)

reg unload HKLM\zSOFTWARE
exit /b

:sbsConfigImpl
if not "%~2"=="" reg add HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\SideBySide\Configuration /v "%~1" /t REG_DWORD /d "%~2" /f
exit /b

:latentESU
if exist mount\Windows\WinSxS\Manifests\amd64_microsoft-windows-s..edsecurityupdatesai_*.manifest exit /b

gsudo -s copy tmp\amd64_microsoft-windows-s..edsecurityupdatesai_*.manifest mount\Windows\WinSxS\Manifests\

reg load HKLM\zCOMPONENTS mount\Windows\System32\config\COMPONENTS
reg load HKLM\zSOFTWARE mount\Windows\System32\config\SOFTWARE

reg import tmp\ExtendedSecurityUpdatesAI.reg
for /f "delims=" %%x in ('reg query HKLM\zCOMPONENTS\DerivedData\VersionedIndex ^| find /i "VersionedIndex"') do reg delete "%%x" /f

reg unload HKLM\zSOFTWARE
reg unload HKLM\zCOMPONENTS
exit /b

:meltdownSpectre
reg load HKLM\zSYSTEM mount\Windows\System32\config\SYSTEM

:: reg query "HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management"
reg import tmp\SpectreMeltdownVulnerability.reg

reg unload HKLM\zSYSTEM
exit /b

:cleanManual
if exist mount\Windows\WinSxS\ManifestCache\*.bin gsudo -s del /f /q mount\Windows\WinSxS\ManifestCache\*.bin
if exist mount\Windows\WinSxS\Temp\PendingDeletes\* gsudo -s del /f /q mount\Windows\WinSxS\Temp\PendingDeletes\*
if exist mount\Windows\WinSxS\Temp\TransformerRollbackData\* gsudo -s del /f /q /s mount\Windows\WinSxS\Temp\TransformerRollbackData\*

if exist mount\Windows\INF\*.log del /f /q mount\Windows\INF\*.log
for /d %%x in (mount\Windows\CbsTemp\* mount\Windows\Temp\*) do rmdir /s /q "%%x"
del /f /q mount\Windows\CbsTemp\* mount\Windows\Temp\* 2>nul

if exist mount\Windows\WinSxS\pending.xml exit /b
for /d %%x in (mount\Windows\WinSxS\Temp\InFlight\*) do gsudo -s rmdir /s /q "%%x"
if exist mount\Windows\WinSxS\Temp\PendingRenames\* gsudo -s del /f /q mount\Windows\WinSxS\Temp\PendingRenames\*

exit /b

:updateDefender
:: for MRT
set "_mpam=" & for %%x in ("uup\*kb890830-%arch%*.exe") do set "_mpam=%%x"
if not "%_mpam%"=="" 7z x -ba -aoa "%_mpam%" -omount\Windows\System32 && dir /a /q mount\Windows\System32\mrt*

set "_mpam=" & for %%x in ("uup\*defender-dism*%arch%*.cab") do set "_mpam=%%x"
if "%_mpam%"=="" exit /b
if exist "mount\ProgramData\Microsoft\Windows Defender\Definition Updates\Updates\*.vdm" (echo Defender seems updated & exit /b)

7z x -ba "%_mpam%" -o"mount\ProgramData\Microsoft\Windows Defender" -x^^!*defender*.xml -xr^^!MpSigStub.exe
:: for old updates
for /d %%a in ("mount\ProgramData\Microsoft\Windows Defender\Platform\*.*.*") do (
  for %%x in (ConfigSecurityPolicy.exe MpAsDesc.dll MpEvMsg.dll ProtectionManagement.dll MpUxAgent.dll) do (
    if not exist "%%a\%%x" copy /b "mount\Program Files\Windows Defender\%%x" "%%a\"
  )
  for /d %%k in ("mount\Program Files\Windows Defender\*-*") do for %%x in (MpAsDesc.dll MpEvMsg.dll ProtectionManagement.dll MpUxAgent.dll) do (
    if not exist "%%a\%%~nxk\%%x.mui" xcopy /ki "%%k\%%x.mui" "%%a\%%~nxk\"
  )

  if /i not "%arch%"=="x86" (
    if not exist "%%a\x86\MpAsDesc.dll" copy /b "mount\Program Files (x86)\Windows Defender\MpAsDesc.dll" "%%a\x86\"
    for /d %%k in ("mount\Program Files (x86)\Windows Defender\*-*") do (
      if not exist "%%a\x86\%%~nxk\MpAsDesc.dll.mui" xcopy /ki "%%k\MpAsDesc.dll.mui" "%%a\x86\%%~nxk\"
    )
  )
)
exit /b

:optimizeHive
set "_a=%~1" & if "!_a!"=="" exit /b
if "%~nx1"=="!_a!" set "_a=mount\Windows\System32\config\!_a!"

dir /a /q "!_a!*"
reg load HKLM\TEMP "!_a!" && (reg save HKLM\TEMP "!_a!2" /c /f & reg unload HKLM\TEMP)
move /y "!_a!2" "!_a!" && for %%a in ("!_a!.LOG1" "!_a!.LOG2") do if "%%~za" gtr "0" del /f /a "%%~a"

shift & goto :optimizeHive

:optimizeWIM
if "%~1"=="" (
  wimlib-imagex optimize "%wimFile%"
) else (
  wimlib-imagex export "%wimFile%" "%~1" temp.wim && move /y temp.wim "%wimFile%"
)
exit /b

:updateDVD
if not defined TargetISO exit /b 2
if not exist dvd\sources\ exit /b 1

echo Update DVD files: "%~1" "%~2"
if not "%~2"=="" (
  :: from a sources file
  if exist "%~2\%~1" call :copyIfNewer "%~2\%~1" "dvd\sources\%~1"
) else if /i "%~x1"==".cab" (
  :: update DVD from Setup DU
  set "_a=" & for /f "delims=" %%a in ('dir /b /a dvd\sources\*.') do set "_a=!_a! "%%a""
  7z x -ba -aoa "%~1" -odvd\sources *.* !_a!
) else if exist "%~1\" (
  :: or from a sources dir
  for /r "%~1" %%a in (*) do (set "_a=%%a" & call :copyIfNewer "!_a!" "dvd\sources\!_a:%~f1\=!")
)

exit /b

:copyIfNewer
if not exist "%~2" exit /b 1

:: compare file versions
powershell -nop -c "exit (gi '%~1').VersionInfo.FileVersionRaw.CompareTo((gi '%~2').VersionInfo.FileVersionRaw)"
if errorlevel 1 (
  echo "%~1" & copy /b /y "%~1" "%~2"
) else if errorlevel 0 (
  fc /b "%~1" "%~2" >nul || xcopy /kdry "%~1" "%~2"
)

exit /b

:updateDVDboot
call :updateDVD mount\sources || exit /b !ERRORLEVEL!

:: TODO update efi\boot
exit /b

:createISO
if not defined TargetISO exit /b 2
echo Make target ISO "%TargetISO%"

exit /b
