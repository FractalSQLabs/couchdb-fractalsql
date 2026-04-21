@echo off
REM scripts/windows/build-msi.bat
REM
REM Packages fractalsql-couch.exe (pre-built by build.bat) into a
REM Windows MSI using the WiX Toolset.
REM
REM Prerequisites
REM   * WiX Toolset v3.x installed (candle.exe / light.exe on PATH).
REM     Download from https://github.com/wixtoolset/wix3/releases
REM   * dist\windows_%MSI_ARCH%\fractalsql-couch.exe already built.
REM     scripts\windows\build.bat produces it there.

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

set REPO_ROOT=%~dp0..\..
pushd %REPO_ROOT%

if "%MSI_ARCH%"=="" set MSI_ARCH=x64

set SRC_EXE=dist\windows_%MSI_ARCH%\fractalsql-couch.exe
if not exist "%SRC_EXE%" (
    echo ==^> ERROR: %SRC_EXE% missing — run scripts\windows\build.bat first
    popd & exit /b 1
)

REM WiX references dist\windows\fractalsql-couch.exe as its Source
REM (one .wxs for all archs). Stage the current-arch binary there so
REM light.exe finds it, then restore later if needed.
if not exist "dist\windows" mkdir "dist\windows"
copy /Y "%SRC_EXE%" "dist\windows\fractalsql-couch.exe" >nul
if errorlevel 1 (
    echo ==^> ERROR: could not stage .exe for WiX
    popd & exit /b 1
)

if not exist "obj" mkdir "obj"

set WXS=scripts\windows\fractalsql-couch.wxs
set MSI=dist\windows\FractalSQL-CouchDB-1.0.0-%MSI_ARCH%.msi

echo ==^> MSI_ARCH = %MSI_ARCH%
echo ==^> MSI      = %MSI%

candle -nologo -arch %MSI_ARCH% -out obj\fractalsql-couch.wixobj %WXS%
if errorlevel 1 (
    echo ==^> candle failed
    popd & exit /b 1
)

light -nologo ^
      -ext WixUIExtension ^
      -ext WixUtilExtension ^
      -out %MSI% ^
      obj\fractalsql-couch.wixobj
if errorlevel 1 (
    echo ==^> light failed
    popd & exit /b 1
)

echo.
echo ==^> Built %MSI%
dir %MSI%

popd
endlocal
exit /b 0
