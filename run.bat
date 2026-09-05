@echo off
REM Standalone LuaJIT worker client for Gunzodus (protocol 1530) — Windows launcher.
REM Usage: run.bat [flags]        (run.bat --help for the flag list)
REM Set LUACLIENT_LUAJIT to override the interpreter location.
REM The POSIX twin is run.sh; both cd to the project root before running main.lua.
setlocal
if not "%LUACLIENT_LUAJIT%"=="" (
  set "LUAJIT=%LUACLIENT_LUAJIT%"
  goto :have
)
set "LUAJIT=D:\Claude\otclient_mehah1530\otclient\build\win-local\vcpkg_installed\x64-windows-static-release\tools\luajit\luajit.exe"
if exist "%LUAJIT%" goto :have
REM Not at the vcpkg location — fall back to whatever is on PATH.
for %%I in (luajit.exe) do if not "%%~$PATH:I"=="" set "LUAJIT=%%~$PATH:I"
:have
if not exist "%LUAJIT%" (
  echo run.bat: LuaJIT not found at "%LUAJIT%"
  echo          set LUACLIENT_LUAJIT to the interpreter you want to use.
  exit /b 1
)
cd /d "%~dp0"
"%LUAJIT%" main.lua %*
REM endlocal resets ERRORLEVEL, so carry it out explicitly.
endlocal & exit /b %ERRORLEVEL%
