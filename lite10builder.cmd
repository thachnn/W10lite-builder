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
if exist *.iso (if not exist *.aria2 goto :Downloaded) else if exist *.wim goto :Downloaded

if not defined SourceFileUrl set "SourceFileUrl=https://archive.org/download/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96_202112/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso"
echo Download ISO from URL "%SourceFileUrl%"

aria2c --file-allocation=trunc -c -R "%SourceFileUrl%"

:Downloaded
for %%i in (*.wim *.iso) do set "SourceFile=%%i"

:HasSource
echo Source file "%SourceFile%"
if exist dvd\ rmdir /s /q dvd

set arch=
:: process a specified WIM file
if /i "%SourceFile:~-4%"==".wim" (
  call :processWIM "%SourceFile%"
) else if /i "%SourceFile:~-4%"==".iso" (
  :: verify source ISO file
  7z l -ba "%SourceFile%" bootmgr efi/boot/*.efi sources/*.wim | find /c /v "" | find "4" || (
    echo Invalid ISO file & exit /b 2
  )
  7z x -ba -aos "%SourceFile%" -odvd

  if exist dvd\efi\boot\*x64.efi (set arch=x64) else if exist dvd\efi\boot\*64.efi (set arch=arm64) else (set arch=x86)
  call :prepareUUP

  :: adding setup DU
  set "_duCab=" & for %%i in ("uup\*-!arch!-SetupDU*.cab") do set "_duCab=%%i"
  if not "!_duCab!"=="" call :updateDVD "!_duCab!"

  for %%f in (dvd\sources\install.wim dvd\sources\boot.wim) do call :processWIM "%%f"
  call :createISO
) else (
  echo Unsupported file type & exit /b 2
)

goto :eof

::--------------
:prepareUUP
for /d %%i in ("tmp\KB*-%arch%*") do if exist "%%i\update.mum" exit /b

call uupDownload.cmd "%arch%" "%uupVer%"
for %%i in ("uup\*-%arch%*.cab") do call extractCab.cmd "%%~nxi"

exit /b

:processWIM
:: process WinRE first
if /i not "%~1"=="Winre.wim" (
  if defined OSWimIndex (set "_oIndex=%OSWimIndex%") else (set _oIndex=1)
  wimlib-imagex extract %1 "!_oIndex!" Windows/System32/Recovery/Winre.wim 2>nul && call :processWIM Winre.wim
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
  set "_pa=%arch%"

  :: WIM info
  for /f "tokens=1* delims=:" %%a in ('wimlib-imagex info "%wimFile%" %%i ^| findstr /i "Arch Build Version Type"') do (
    set "_b=%%b" & set "_b=!_b: =!"

    if /i "%%a"=="Major Version" if !_b! neq 10 (echo Unsupported version "!_b!" & set "edition=-")
    if /i "%%a"=="Build" if !_b! geq 17763 (set "_build=!_b!") else (echo Unsupported build "!_b!" & set "edition=-")
    if /i "%%a"=="Product Type" if /i not "!_b!"=="WinNT" (echo Unsupported product type "!_b!" & set "edition=-")

    if /i "%%a"=="Installation Type" if "!edition!"=="" set "edition=!_b!"
    if /i "%%a"=="Architecture" (set "arch=!_b:86_=!" & set "arch=!arch:ARM=arm!")
  )

  if "!edition!"=="-" (set "edition=") else if /i "!edition!"=="WindowsPE" (
    if defined PEWimIndex if "%%i"=="%PEWimIndex%" (set "_oIndex=%%i") else (set "edition=")
  ) else (
    if defined OSWimIndex if "%%i"=="%OSWimIndex%" (set "_oIndex=%%i") else (set "edition=")
  )

  :: arch changed?
  if "!edition!"=="" (set "arch=!_pa!") else (
    if /i not "!arch!"=="!_pa!" call :prepareUUP
    call :updateWIM %%i
  )
)

call :optimizeWIM "%_oIndex%"
exit /b

:optimizeWIM
if "%~1"=="" (
  wimlib-imagex optimize "%wimFile%"
) else (
  wimlib-imagex export "%wimFile%" %1 temp.wim && move /y temp.wim "%wimFile%"
)
exit /b

:updateWIM
set "_index=%~1"
echo Update "!edition!.!_build!" image "%wimFile%:%_index%"

if exist mount\* rmdir /s /q mount
if not exist mount\ mkdir mount

::wimlib-imagex extract "%wimFile%" %_index% Windows/servicing/Packages/Package_for_*.mum Windows/WinSxS/Manifests/*_microsoft-windows-foundation_* Windows/System32/config Windows/System32/Recovery Windows/System32/SMI/Store/Machine Windows/System32/UpdateAgent.* Windows/System32/Facilitator.* sources setup.exe Windows/Boot --dest-dir=mount --preserve-dir-structure --nullglob --no-acls
Dism /Mount-Image /ImageFile:"%wimFile%" /Index:%_index% /MountDir:mount || exit /b 2

:: pre-update
if /i "!edition!"=="WindowsPE" (
  echo call :sbsConfig "" "" 1
) else (
  call :switchEdition || goto :Discard

  :: manage features and packages
  call :manageFeatures || goto :Discard

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
  Dism /ScratchDir:. /Image:..\mount /Add-Package !_pkgPath[%%n]! || (popd & goto :Discard)
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
:: if exist mount\Windows\servicing\Packages\WinPE-Setup-Package~*.mum
if exist mount\sources\setup.exe call :updateDVDboot

if /i not "%wimFile%"=="Winre.wim" if exist mount\Windows\System32\Recovery\Winre.wim if exist Winre.wim (
  xcopy /kdry Winre.wim mount\Windows\System32\Recovery\
)

:: install drivers
if /i "!edition!"=="WindowsPE" (set "_dTypes=ALL WinPE") else (set "_dTypes=ALL OS")
for %%k in (%_dTypes%) do call :tryInstallDrv "drvs\%%k" || goto :Discard

:: optimize hive files
call :optimizeHive SOFTWARE SYSTEM COMPONENTS DRIVERS mount\Users\Default\NTUSER.DAT
pushd mount & del /f /q /a /s *.regtrans-ms *.TM.blf & popd

Dism /Unmount-Image /MountDir:mount /Commit
exit /b

:Discard
Dism /Unmount-Image /MountDir:mount /Discard
exit /b 1

:switchEdition
if not defined TargetEdition exit /b
Dism /ScratchDir:tmp /Image:mount /Get-TargetEditions | find /i "%TargetEdition:*,=%" || exit /b 0

if "%TargetEdition:,=%"=="%TargetEdition%" (
  Dism /ScratchDir:tmp /Image:mount /Set-Edition:"%TargetEdition%" || exit /b !ERRORLEVEL!
) else (
  Dism /ScratchDir:tmp /Image:mount /ProductKey:"%TargetEdition:,=" /Set-Edition:"%" /AcceptEula || exit /b !ERRORLEVEL!
)
exit /b

:manageFeatures
if defined RemoveCapabilities for %%a in (%RemoveCapabilities%) do (
  set "_a=%%a"
  Dism /ScratchDir:tmp /Image:mount /Remove-Capability /CapabilityName:"!_a:,=" /CapabilityName:"!" || exit /b !ERRORLEVEL!
)
if defined AddCapabilities for %%a in (%AddCapabilities%) do (
  set "_a=%%a"
  Dism /ScratchDir:tmp /Image:mount /Add-Capability /CapabilityName:"!_a:,=" /CapabilityName:"!" || exit /b !ERRORLEVEL!
)

if defined DisableFeatures for %%a in (%DisableFeatures%) do (
  set "_a=%%a"
  Dism /ScratchDir:tmp /Image:mount /Disable-Feature /FeatureName:"!_a:,=" /FeatureName:"!" /Remove || exit /b !ERRORLEVEL!
)
if defined EnableFeatures for %%a in (%EnableFeatures%) do (
  set "_a=%%a"
  Dism /ScratchDir:tmp /Image:mount /Enable-Feature /FeatureName:"!_a:,=" /FeatureName:"!" /All || exit /b !ERRORLEVEL!
)
exit /b

:tryInstallDrv
for /r "%~1\" %%x in (*.inf) do (
  Dism /ScratchDir:tmp /Image:mount /Add-Driver /Driver:%1 /Recurse || exit /b !ERRORLEVEL!
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
for %%x in (SupersededActions DisableResetbase DisableComponentBackups) do (call :sbsConfigImpl %%x %%1 & shift)

reg unload HKLM\zSOFTWARE
exit /b

:sbsConfigImpl
if not "%~2"=="" reg add HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\SideBySide\Configuration /v %1 /t REG_DWORD /d %2 /f
exit /b

:latentESU
set "xBT=%arch:x64=amd64%"
if exist "mount\Windows\WinSxS\Manifests\%xBT%_microsoft-windows-s*edsecurityupdatesai_*.manifest" exit /b

gsudo --ti copy "tmp\%xBT%_microsoft-windows-s*edsecurityupdatesai_*.manifest" mount\Windows\WinSxS\Manifests\

reg load HKLM\zCOMPONENTS mount\Windows\System32\config\COMPONENTS
reg load HKLM\zSOFTWARE mount\Windows\System32\config\SOFTWARE

reg import "tmp\%xBT%_ExtendedSecurityUpdatesAI.reg"

for /f "tokens=4,6 delims=_" %%a in ('dir /b /a "mount\Windows\WinSxS\Manifests\%xBT%_microsoft-windows-foundation_*.manifest"') do ^
for /f "delims=[]" %%x in ('findstr /i "DerivedData" "tmp\%xBT%_ExtendedSecurityUpdatesAI.reg"') do (
  reg add "%%x" /v "c^!microsoft-w..-foundation_31bf3856ad364e35_%%a_%%~nb" /t REG_BINARY /d "" /f
)
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
if exist mount\Windows\WinSxS\ManifestCache\*.bin gsudo --ti del /f /q mount\Windows\WinSxS\ManifestCache\*.bin
if exist mount\Windows\WinSxS\Temp\PendingDeletes\* gsudo --ti del /f /q mount\Windows\WinSxS\Temp\PendingDeletes\*
if exist mount\Windows\WinSxS\Temp\TransformerRollbackData\* gsudo --ti del /f /q /s mount\Windows\WinSxS\Temp\TransformerRollbackData\*

if exist mount\Windows\INF\*.log del /f /q mount\Windows\INF\*.log
del /f /q mount\Windows\CbsTemp\* mount\Windows\Temp\* 2>nul
call :removeSubdirs mount\Windows\CbsTemp & call :removeSubdirs mount\Windows\Temp

if exist mount\Windows\WinSxS\pending.xml exit /b
call :removeSubdirs mount\Windows\WinSxS\Temp\InFlight "gsudo --ti"
if exist mount\Windows\WinSxS\Temp\PendingRenames\* gsudo --ti del /f /q mount\Windows\WinSxS\Temp\PendingRenames\*

exit /b

:removeSubdirs
for /f "delims=" %%x in ('dir /b /ad "%~1\" 2^>nul') do %~2 rmdir /s /q "%~1\%%x"
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
set "_mpam=" & for /d %%x in ("mount\ProgramData\Microsoft\Windows Defender\Platform\*.*.*") do set "_mpam=%%x"
if "%_mpam%"=="" exit /b 1

for %%x in (ConfigSecurityPolicy.exe MpAsDesc.dll MpEvMsg.dll ProtectionManagement.dll MpUxAgent.dll) do (
  if not exist "%_mpam%\%%x" copy /b "mount\Program Files\Windows Defender\%%x" "%_mpam%\"
)
for /d %%a in ("mount\Program Files\Windows Defender\*-*.") do for %%x in (MpAsDesc.dll MpEvMsg.dll ProtectionManagement.dll MpUxAgent.dll) do (
  if not exist "%_mpam%\%%~na\%%x.mui" xcopy /ki "%%a\%%x.mui" "%_mpam%\%%~na\"
)

if /i not "%arch%"=="x86" (
  if not exist "%_mpam%\x86\MpAsDesc.dll" xcopy /ki "mount\Program Files (x86)\Windows Defender\MpAsDesc.dll" "%_mpam%\x86\"
  for /d %%a in ("mount\Program Files (x86)\Windows Defender\*-*.") do (
    if not exist "%_mpam%\x86\%%~na\MpAsDesc.dll.mui" xcopy /ki "%%a\MpAsDesc.dll.mui" "%_mpam%\x86\%%~na\"
  )
)
exit /b

:optimizeHive
set "_a=%~1" & if "!_a!"=="" exit /b
if "%~nx1"=="%_a%" set "_a=mount\Windows\System32\config\%_a%"

set "_b=%~n1" & dir /a /q "%_a%*"
reg load "HKLM\z%_b%" "%_a%" && (
  :: apply tweaks
  for %%a in ("%_b%~" "%_b%~%arch%") do if exist "tmp\tweaks-%%~a.reg" gsudo --ti reg import "tmp\tweaks-%%~a.reg"
  for %%a in ("%_b%" "%_b%-%arch%") do if exist "tmp\tweaks-%%~a.reg" reg import "tmp\tweaks-%%~a.reg"

  :: export to hive file
  reg save "HKLM\z%_b%" "%_a%2" /c /f & reg unload "HKLM\z%_b%"
  move /y "%_a%2" "%_a%" && for %%a in ("%_a%.LOG1" "%_a%.LOG2") do if "%%~za" gtr "0" powershell -nop -c "clc '%%~a'"
)

shift & goto :optimizeHive

:updateDVD
if not defined TargetISO exit /b 2
if not exist dvd\sources\ exit /b 1

echo Update DVD files: %1 %2
if not "%~2"=="" (
  :: from a sources file
  if exist "%~2\%~1" call :copyIfNewer "%~2\%~1" "dvd\sources\%~1"
) else if /i "%~x1"==".cab" (
  :: update DVD from Setup DU
  set "_a=" & for /f "delims=" %%a in ('dir /b /a dvd\sources\*.') do set "_a=!_a! "%%a""
  7z x -ba -aoa %1 -odvd\sources -x^^!setup.exe *.* !_a!
) else if exist "%~1\" (
  :: sync with a sources dir
  for /r %1 %%a in (*) do (set "_a=%%a" & call :copyIfNewer "!_a!" "dvd\sources\!_a:%~f1\=!" 1)
)

exit /b 0

:copyIfNewer
if not exist %2 exit /b 1

:: skip identical files
comp /m %1 %2 >nul && exit /b

:: compare file versions
:: powershell -nop -c "exit (gi '%~1').VersionInfo.FileVersionRaw.CompareTo((gi '%~2').VersionInfo.FileVersionRaw)"
set "_ver1=-1" & call :getFileRevision %1 _ver1
set "_ver2=-1" & call :getFileRevision %2 _ver2

if %_ver1% equ %_ver2% (
  xcopy /kdry %1 %2
) else if %_ver1% gtr %_ver2% (
  echo %1 & copy /b /y %1 %2
) else if "%~3"=="1" (
  :: sync mode
  echo Sync %2 & copy /b /y %2 %1
)

exit /b

:getFileRevision
set "_fp=%~f1"
for /f "tokens=4 delims=. " %%x in ('wmic datafile where "name='!_fp:\=\\!'" get Version ^| find "."') do (
  if not "%%x"=="" set /a "%~2=%%x"
)
exit /b

:updateDVDboot
:: xcopy /kudry mount\sources dvd\sources
call :updateDVD mount\sources || exit /b !ERRORLEVEL!

:: update boot files
if /i not "%arch%"=="arm64" (
  xcopy /kdry mount\Windows\Boot\PCAT\bootmgr dvd\
  xcopy /kidry mount\Windows\Boot\PCAT\memtest.exe dvd\boot\
  xcopy /kidry mount\Windows\Boot\EFI\memtest.efi dvd\efi\microsoft\boot\
)

set "_pa=%arch:x86=ia32%" & set "_pa=!_pa:arm64=aa64!"
:: new boot?
if exist mount\Windows\Boot\EFI_EX\*_EX.efi (
  xcopy /kidry mount\Windows\Boot\DVD_EX\EFI\en-US\efisys_EX.bin dvd\efi\microsoft\boot\efisys.bin
  xcopy /kdry mount\Windows\Boot\DVD_EX\EFI\en-US\efisys_noprompt_EX.bin dvd\efi\microsoft\boot\efisys_noprompt.bin

  xcopy /kidry mount\Windows\Boot\EFI_EX\bootmgfw_EX.efi "dvd\efi\boot\boot%_pa%.efi"
  xcopy /kdry mount\Windows\Boot\EFI_EX\bootmgr_EX.efi dvd\bootmgr.efi

  for %%a in (mount\Windows\Boot\FONTS_EX\*) do (
    set "_a=%%~nxa" & set "_a=!_a:_EX.=.!"
    xcopy /kidry "%%a" "dvd\efi\microsoft\boot\fonts\!_a!" & xcopy /kidry "%%a" "dvd\boot\fonts\!_a!"
  )
) else (
  xcopy /kidry mount\Windows\Boot\DVD\EFI\en-US\efisys.bin dvd\efi\microsoft\boot\
  xcopy /kdry mount\Windows\Boot\DVD\EFI\en-US\efisys_noprompt.bin dvd\efi\microsoft\boot\

  xcopy /kudry mount\Windows\Boot\EFI\bootmgfw.efi dvd\efi\boot\
  xcopy /kidry mount\Windows\Boot\EFI\bootmgfw.efi "dvd\efi\boot\boot%_pa%.efi"
  xcopy /kdry mount\Windows\Boot\EFI\bootmgr.efi dvd\
)
if exist mount\setup.exe xcopy /kdry mount\setup.exe dvd\

exit /b

:createISO
if not defined TargetISO exit /b 2
if not exist dvd\sources\ exit /b 1

rem 7z x -ba -aoa "uup\*-%arch%-SetupDU*.cab" -otmp\du -x^^!setup.exe
:: xcopy /kudry tmp\du dvd\sources\
:: call :updateDVD tmp\du\*.*
:: copy /y tmp\du\*.ini dvd\sources\ 2>nul
:: copy /b /y tmp\du\*-*\*.mui dvd\sources\*-*\
:: xcopy /ekiry tmp\du\ReplacementManifests dvd\sources\ReplacementManifests\
rem rmdir /s /q tmp\du

echo Make target ISO "%TargetISO%"

set "_b=#pEF,e,b"dvd\efi\microsoft\boot\efisys.bin""
if /i "%arch%"=="arm64" (set "_b=1%_b%") else (set "_b=2#p0,e,b"dvd\boot\etfsboot.com"%_b%")

set "_a=%TargetISO:*\=%" & set "_a=!_a:.iso=!"
call :toUpperCase _a

oscdimg -m -o -u2 -udfver102 -bootdata:%_b% -l"%_a: =_%" dvd "%TargetISO%"
exit /b

:toUpperCase
for %%x in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do set "%~1=!%~1:%%x=%%x!"
exit /b
