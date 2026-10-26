@echo off
rem Build the vdrx daemon with plain fpc (or open src\vdrx.lpi in Lazarus).
rem   build.bat          -> bin\vdrx.exe
rem   build.bat tests    -> also the test programs
rem Edit FPC if your compiler lives elsewhere.
setlocal
set FPC=C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe
cd /d "%~dp0"
if not exist bin mkdir bin
if not exist build\units mkdir build\units
set OPTS=-Mobjfpc -Sh -O1 -Fusrc -FUbuild\units -FEbin
"%FPC%" %OPTS% src\vdrx.lpr || exit /b 1
if /i "%1"=="tests" (
  "%FPC%" %OPTS% tests\unit\test_jsonconf.lpr || exit /b 1
  for %%t in (test_stall test_socket_stall) do "%FPC%" %OPTS% tests\manual\%%t.lpr || exit /b 1
  "%FPC%" %OPTS% tests\stress\vdrx_stress.lpr || exit /b 1
)
echo done: bin\
