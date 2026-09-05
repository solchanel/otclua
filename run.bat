@echo off
REM Standalone LuaJIT worker client for Gunzodus (protocol 1530).
REM Usage: run.bat [flags]        (run.bat --help for the flag list)
REM Set LUACLIENT_LUAJIT to override the interpreter location.
setlocal
if "%LUACLIENT_LUAJIT%"=="" (
  set "LUAJIT=D:\Claude\otclient_mehah1530\otclient\build\win-local\vcpkg_installed\x64-windows-static-release\tools\luajit\luajit.exe"
) else (
  set "LUAJIT=%LUACLIENT_LUAJIT%"
)
if not exist "%LUAJIT%" (
  echo run.bat: LuaJIT not found at "%LUAJIT%"
  echo          set LUACLIENT_LUAJIT to the interpreter you want to use.
  exit /b 1
)
cd /d "%~dp0"
"%LUAJIT%" main.lua %*
REM endlocal resets ERRORLEVEL, so carry it out explicitly.
endlocal & exit /b %ERRORLEVEL%
