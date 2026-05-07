@echo off
setlocal EnableDelayedExpansion

REM Build and run the DUnitX test suite. Mirrors build.bat's RAD Studio
REM detection (BDS_VERSION env var override; otherwise the highest installed
REM version under C:\Program Files (x86)\Embarcadero\Studio\<X.Y>\).

set "BDSVER=%BDS_VERSION%"
set "BDSROOT="

if defined BDSVER (
  set "BDSROOT=C:\Program Files (x86)\Embarcadero\Studio\!BDSVER!"
  if not exist "!BDSROOT!\bin\dcc64.exe" (
    echo BUILD FAILED: BDS_VERSION=!BDSVER! but !BDSROOT!\bin\dcc64.exe is missing
    exit /b 1
  )
) else (
  set "STUDIOROOT=C:\Program Files (x86)\Embarcadero\Studio"
  set "BESTMAJ=0"
  set "BESTMIN=-1"
  for /d %%D in ("!STUDIOROOT!\*") do (
    if exist "%%D\bin\dcc64.exe" if exist "%%D\bin\rsvars.bat" (
      for /f "tokens=1,2 delims=." %%A in ("%%~nxD") do (
        set /a "MAJ_N=%%A" 2>nul
        set /a "MIN_N=%%B" 2>nul
        if !MAJ_N! gtr !BESTMAJ! (
          set "BESTMAJ=!MAJ_N!"
          set "BESTMIN=!MIN_N!"
          set "BDSVER=%%~nxD"
          set "BDSROOT=%%~D"
        ) else if !MAJ_N! equ !BESTMAJ! if !MIN_N! gtr !BESTMIN! (
          set "BESTMIN=!MIN_N!"
          set "BDSVER=%%~nxD"
          set "BDSROOT=%%~D"
        )
      )
    )
  )
  if not defined BDSVER (
    echo BUILD FAILED: no RAD Studio with bin\dcc64.exe found
    exit /b 1
  )
)

echo Using RAD Studio %BDSVER% at %BDSROOT%
call "%BDSROOT%\bin\rsvars.bat" || goto :err

if not exist "%~dp0bin" mkdir "%~dp0bin"
if not exist "%~dp0obj" mkdir "%~dp0obj"

REM DUnitX source ships under <BdsRoot>\source\DUnitX. Add to unit search path
REM so dcc64 finds DUnitX.TestFramework etc.
set "DUNITX_SRC=%BDSROOT%\source\DUnitX"
if not exist "%DUNITX_SRC%\DUnitX.TestFramework.pas" goto :missing_dunitx

dcc64.exe -B ^
  -E"%~dp0bin" ^
  -N0"%~dp0obj" ^
  -U"%~dp0..\src\units" ^
  -U"%DUNITX_SRC%" ^
  -NSSystem;Winapi;System.Win;Data ^
  "%~dp0DelphiLspTests.dpr" || goto :err

echo BUILD OK: %~dp0bin\DelphiLspTests.exe
echo.
echo === Running tests ===
"%~dp0bin\DelphiLspTests.exe"
exit /b %errorlevel%

:err
echo BUILD FAILED
exit /b 1

:missing_dunitx
echo BUILD FAILED: DUnitX source not found at %DUNITX_SRC%
exit /b 1
