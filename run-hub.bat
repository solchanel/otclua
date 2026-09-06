@echo off
REM luaclient web panel hub - Windows launcher.
REM Usage: run-hub.bat [flags]        (run-hub.bat --help for the flag list)
REM
REM Set LUACLIENT_LUAJIT to override the interpreter location.  The same
REM interpreter is handed to the hub as --luajit, so the workers it spawns run
REM on exactly the build that is running the hub.
REM
REM The hub binds 127.0.0.1 by default and REFUSES any other address unless you
REM pass --allow-insecure: it speaks plain HTTP and has no TLS.  Expose it with
REM nginx/Caddy or an SSH tunnel, not by opening the port.
REM
REM The POSIX twin is run-hub.sh.
setlocal
if not "%LUACLIENT_LUAJIT%"=="" (
  set "LUAJIT=%LUACLIENT_LUAJIT%"
  goto :have
)
set "LUAJIT=D:\Claude\otclient_mehah1530\otclient\build\win-local\vcpkg_installed\x64-windows-static-release\tools\luajit\luajit.exe"
if exist "%LUAJIT%" goto :have
REM Not at the vcpkg location - fall back to whatever is on PATH.
for %%I in (luajit.exe) do if not "%%~$PATH:I"=="" set "LUAJIT=%%~$PATH:I"
:have
if not exist "%LUAJIT%" (
  echo run-hub.bat: LuaJIT not found at "%LUAJIT%"
  echo              set LUACLIENT_LUAJIT to the interpreter you want to use.
  exit /b 1
)
cd /d "%~dp0"
"%LUAJIT%" hub\main.lua --luajit="%LUAJIT%" %*
REM endlocal resets ERRORLEVEL, so carry it out explicitly.
endlocal & exit /b %ERRORLEVEL%
