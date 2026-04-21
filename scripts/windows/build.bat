@echo off
REM scripts/windows/build.bat
REM
REM Builds fractalsql-couch.exe on Windows with the MSVC toolchain
REM using static CRT (/MT) and whole-program optimization (/GL).
REM Zero runtime dependency on the Visual C++ Redistributable —
REM matches the glibc-only Linux posture on its own side of the
REM Windows/Linux ABI boundary.
REM
REM Prerequisites
REM   * Visual Studio Build Tools (cl.exe on PATH — run from a
REM     Developer Command Prompt, or invoke vcvarsall.bat first).
REM   * A static LuaJIT library. Build LuaJIT 2.1 from source:
REM         cd LuaJIT\src
REM         msvcbuild.bat static
REM     which emits lua51.lib (and the lua.h / lualib.h / lauxlib.h
REM     headers). Set LUAJIT_DIR to that src directory.
REM   * cJSON source checked out locally (we compile cJSON.c inline
REM     into the binary — no .lib to link). Set CJSON_DIR to the
REM     cJSON clone root. A /cjson/cJSON.h shim is created so
REM     <cjson/cJSON.h> in main.c resolves to the vendored source.
REM
REM Environment overrides
REM   LUAJIT_DIR        directory holding lua.h + lua51.lib
REM                     (default: C:\deps\LuaJIT\src)
REM   CJSON_DIR         directory holding cJSON.c / cJSON.h
REM                     (default: C:\deps\cJSON)
REM   OUT_DIR           output directory
REM                     (default: dist\windows_%MSI_ARCH%)
REM   MSI_ARCH          x64 (default) | arm64
REM
REM Invocation
REM   scripts\windows\build.bat
REM   -- or --
REM   set LUAJIT_DIR=C:\deps\LuaJIT\src
REM   set CJSON_DIR=C:\deps\cJSON
REM   scripts\windows\build.bat

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

if "%LUAJIT_DIR%"=="" set LUAJIT_DIR=C:\deps\LuaJIT\src
if "%CJSON_DIR%"==""  set CJSON_DIR=C:\deps\cJSON
if "%MSI_ARCH%"==""   set MSI_ARCH=x64
if "%OUT_DIR%"==""    set OUT_DIR=dist\windows_%MSI_ARCH%

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

echo ==^> LUAJIT_DIR = %LUAJIT_DIR%
echo ==^> CJSON_DIR  = %CJSON_DIR%
echo ==^> MSI_ARCH   = %MSI_ARCH%
echo ==^> OUT_DIR    = %OUT_DIR%

REM Accept either the Makefile-style libluajit-5.1.lib or the
REM msvcbuild.bat static output lua51.lib.
set LUAJIT_LIB=%LUAJIT_DIR%\libluajit-5.1.lib
if not exist "%LUAJIT_LIB%" (
    if exist "%LUAJIT_DIR%\lua51.lib" set LUAJIT_LIB=%LUAJIT_DIR%\lua51.lib
)
if not exist "%LUAJIT_LIB%" (
    echo ==^> ERROR: no LuaJIT static library in %LUAJIT_DIR%
    echo         ^(expected libluajit-5.1.lib or lua51.lib^)
    exit /b 1
)
echo ==^> LUAJIT_LIB = %LUAJIT_LIB%

if not exist "%CJSON_DIR%\cJSON.c" (
    echo ==^> ERROR: %CJSON_DIR%\cJSON.c missing
    exit /b 1
)
if not exist "%CJSON_DIR%\cJSON.h" (
    echo ==^> ERROR: %CJSON_DIR%\cJSON.h missing
    exit /b 1
)

REM Create a shim dir so main.c's #include <cjson/cJSON.h> resolves
REM against the cJSON source checkout. mklink would work but requires
REM admin on some runners; a plain copy is simpler and idempotent.
set CJSON_SHIM=%OUT_DIR%\cjson-shim\cjson
if not exist "%CJSON_SHIM%" mkdir "%CJSON_SHIM%"
copy /Y "%CJSON_DIR%\cJSON.h" "%CJSON_SHIM%\cJSON.h" >nul
if errorlevel 1 (
    echo ==^> ERROR: could not stage cJSON header shim
    exit /b 1
)

REM cl.exe flags:
REM   /MT    static CRT (no MSVC runtime DLL dependency)
REM   /GL    whole program optimization
REM   /LTCG  link-time code generation (needed when /GL is active)
REM   /O2    optimize for speed
REM   /TC    compile as C (main.c + cJSON.c are both C)
REM   /DWIN32 /D_WINDOWS
REM   /DCJSON_HIDE_SYMBOLS       (we compile cJSON into the binary
REM                               itself; disables dllexport so the
REM                               resulting .exe has no stray exports)
set SHIM_INC=%OUT_DIR%\cjson-shim

cl.exe /nologo /MT /GL /O2 /TC ^
    /DWIN32 /D_WINDOWS /D_CRT_SECURE_NO_WARNINGS /DCJSON_HIDE_SYMBOLS ^
    /I"%LUAJIT_DIR%" /I"%CJSON_DIR%" /I"%SHIM_INC%" /Iinclude /Isrc ^
    src\main.c "%CJSON_DIR%\cJSON.c" ^
    /Fo"%OUT_DIR%\\" ^
    /Fe"%OUT_DIR%\fractalsql-couch.exe" ^
    /link /LTCG ^
        "%LUAJIT_LIB%"

if errorlevel 1 (
    echo.
    echo ==^> BUILD FAILED
    exit /b 1
)

echo.
echo ==^> Built %OUT_DIR%\fractalsql-couch.exe
dir "%OUT_DIR%\fractalsql-couch.exe"

REM Posture check: the .exe should depend only on kernel32/user32
REM and similar Windows system DLLs — never msvcp*, vcruntime*, or
REM any third-party runtime.
echo.
echo ==^> dependencies:
dumpbin /nologo /dependents "%OUT_DIR%\fractalsql-couch.exe" ^
    | findstr /I "\.dll"

REM Fail if the /MT posture slipped and we picked up the dynamic CRT.
dumpbin /nologo /dependents "%OUT_DIR%\fractalsql-couch.exe" ^
    | findstr /I "vcruntime msvcp msvcr ucrtbase" >nul
if not errorlevel 1 (
    echo.
    echo ==^> ERROR: fractalsql-couch.exe links the dynamic CRT
    echo         ^(vcruntime/msvcp/msvcr/ucrtbase^) — /MT posture broken
    exit /b 1
)
echo ==^> posture OK: no dynamic CRT dependency

REM Explicit success exit. The preceding `findstr ... >nul` returns 1
REM when it finds NO matches (the success case for our posture check).
REM cmd.exe's `echo` does not reset errorlevel, so without this line
REM the script inherits findstr's 1 and GitHub Actions fails the step
REM despite the build succeeding.
endlocal
exit /b 0
