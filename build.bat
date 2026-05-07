@echo off
setlocal EnableDelayedExpansion

REM Pick which RAD Studio to compile against. Explicit env var wins; otherwise
REM walk the default install root (C:\Program Files (x86)\Embarcadero\Studio\<version>)
REM and select the highest version that has bin\dcc64.exe + bin\rsvars.bat.
REM No registry walking - the dir layout encodes the version directly.

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
  if not exist "!STUDIOROOT!" (
    echo BUILD FAILED: !STUDIOROOT! does not exist - is RAD Studio installed?
    exit /b 1
  )
  REM Scan version dirs and remember the largest. `dir /b /ad /o-n` lists subdirs
  REM newest-name-first which roughly orders by version, but only roughly
  REM (e.g. "9.0" > "37.0" lexicographically). Compare numerically.
  set "BESTMAJ=0"
  set "BESTMIN=-1"
  for /d %%D in ("!STUDIOROOT!\*") do (
    set "DNAME=%%~nxD"
    REM Validate it looks like X.Y and has the toolchain we need.
    if exist "%%D\bin\dcc64.exe" if exist "%%D\bin\rsvars.bat" (
      for /f "tokens=1,2 delims=." %%A in ("!DNAME!") do (
        set "MAJ=%%A"
        set "MIN=%%B"
        REM Numeric comparison: prefer higher major, tiebreak by minor.
        set /a "MAJ_N=MAJ" 2>nul
        set /a "MIN_N=MIN" 2>nul
        if !MAJ_N! gtr !BESTMAJ! (
          set "BESTMAJ=!MAJ_N!"
          set "BESTMIN=!MIN_N!"
          set "BDSVER=!DNAME!"
          set "BDSROOT=%%~D"
        ) else if !MAJ_N! equ !BESTMAJ! if !MIN_N! gtr !BESTMIN! (
          set "BESTMIN=!MIN_N!"
          set "BDSVER=!DNAME!"
          set "BDSROOT=%%~D"
        )
      )
    )
  )
  if not defined BDSVER (
    echo BUILD FAILED: no RAD Studio version with bin\dcc64.exe found under !STUDIOROOT!
    exit /b 1
  )
)

echo Using RAD Studio %BDSVER% at %BDSROOT%
call "%BDSROOT%\bin\rsvars.bat" || goto :err
if not exist "%~dp0bin" mkdir "%~dp0bin"
if not exist "%~dp0obj" mkdir "%~dp0obj"
dcc64.exe -B ^
  -E"%~dp0bin" ^
  -N0"%~dp0obj" ^
  -U"%~dp0src\units" ^
  -NSSystem;Winapi;System.Win;Data ^
  "%~dp0src\delphi-lsp-shim.dpr" || goto :err
echo BUILD OK: %~dp0bin\delphi-lsp-shim.exe
exit /b 0
:err
echo BUILD FAILED
exit /b 1
