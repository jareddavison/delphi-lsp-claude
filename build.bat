@echo off
setlocal
call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" || goto :err
if not exist "%~dp0bin" mkdir "%~dp0bin"
if not exist "%~dp0obj" mkdir "%~dp0obj"
dcc64.exe -B ^
  -E"%~dp0bin" ^
  -N0"%~dp0obj" ^
  -NSSystem;Winapi;System.Win;Data ^
  "%~dp0src\delphi-lsp-shim.dpr" || goto :err
echo BUILD OK: %~dp0bin\delphi-lsp-shim.exe
exit /b 0
:err
echo BUILD FAILED
exit /b 1
