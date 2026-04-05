@echo off

REM claude-cost uninstaller for Windows
REM Removes scripts and schedule. Preserves data and config.

echo Uninstalling claude-cost...

set "INSTALL_DIR=%LOCALAPPDATA%\claude-cost"
set "CONF_DIR=%APPDATA%\claude-cost"
set "DATA_DIR=%INSTALL_DIR%\data"

REM --- Remove scheduled task ---
schtasks /delete /tn "claude-cost-collect" /f >nul 2>nul
echo   Removed scheduled task

REM --- Remove scripts (preserve data) ---
if exist "%INSTALL_DIR%\bin" rmdir /s /q "%INSTALL_DIR%\bin"
if exist "%INSTALL_DIR%\lib" rmdir /s /q "%INSTALL_DIR%\lib"
echo   Removed scripts

echo.
echo Done. Config and data preserved at:
echo   Config: %CONF_DIR%\config
echo   Data:   %DATA_DIR%\usage.db
