@echo off
setlocal

set "ROOT=%~dp0.."
set "CDB=C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe"
set "CDB_SCRIPT=%TEMP%\ghostty-createprocess.cdb"
set "CDB_LOG=%ROOT%\cdb-createprocess.txt"
set "GHOSTTY_EXE=%ROOT%\zig-out\bin\ghostty.exe"

if not exist "%CDB%" (
  echo Missing cdb.exe at "%CDB%"
  exit /b 1
)

if not exist "%GHOSTTY_EXE%" (
  echo Missing ghostty.exe at "%GHOSTTY_EXE%"
  exit /b 1
)

> "%CDB_SCRIPT%" (
  echo bp kernel32!CreateProcessW ".echo CREATEPROCESS; .echo APP; .if (@rcx != 0) { du @rcx }; .echo CMD; .if (@rdx != 0) { du @rdx }; .echo CWD; .if (poi(@rsp+0x40) != 0) { du poi(@rsp+0x40) } .else { .echo NULL }; q"
  echo g
)

call "%~dp0dev-windows.cmd" "%CDB%" -g -G -logo "%CDB_LOG%" -cf "%CDB_SCRIPT%" "%GHOSTTY_EXE%"
