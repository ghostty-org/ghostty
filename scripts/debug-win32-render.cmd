@echo off
setlocal

set "CDB=C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe"
set "TARGET=%~dp0..\zig-out\bin\ghostty.exe"
set "LOG=%~dp0..\cdb-win32-render.txt"

"%CDB%" -lines -G -logo "%LOG%" -c "sxe ibp; g; .lastevent; kb; qd" "%TARGET%"
exit /b %ERRORLEVEL%
