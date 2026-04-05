@echo off
setlocal enabledelayedexpansion

REM claude-cost installer for Windows (Git Bash)
REM Requires: Git for Windows (provides bash), sqlite3, jq, Node.js (npx)

echo Installing claude-cost...

REM --- Locate Git Bash ---
where git >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo ERROR: git not found in PATH. Install Git for Windows first.
    exit /b 1
)
for /f "delims=" %%i in ('git --exec-path') do set "GIT_EXEC=%%i"
REM Git exec path is like C:\Program Files\Git\mingw64\libexec\git-core
REM Bash is at C:\Program Files\Git\bin\bash.exe
for %%i in ("%GIT_EXEC%\..\..\bin\bash.exe") do set "BASH_EXE=%%~fi"
if not exist "%BASH_EXE%" (
    echo ERROR: Could not find bash.exe at %BASH_EXE%
    exit /b 1
)
echo   Found Git Bash: %BASH_EXE%

REM --- Install paths ---
set "INSTALL_DIR=%LOCALAPPDATA%\claude-cost"
set "BIN_DIR=%INSTALL_DIR%\bin"
set "LIB_DIR=%INSTALL_DIR%\lib"
set "DATA_DIR=%INSTALL_DIR%\data"
set "LOG_DIR=%DATA_DIR%\logs"
set "CONF_DIR=%APPDATA%\claude-cost"

REM --- Copy files ---
mkdir "%BIN_DIR%" 2>nul
mkdir "%LIB_DIR%" 2>nul
mkdir "%DATA_DIR%" 2>nul
mkdir "%LOG_DIR%" 2>nul
mkdir "%CONF_DIR%" 2>nul

copy /y "bin\claude-cost-collect" "%BIN_DIR%\" >nul
copy /y "bin\claude-cost-report" "%BIN_DIR%\" >nul
copy /y "lib\claude-cost-common.sh" "%LIB_DIR%\" >nul
echo   Copied scripts to %INSTALL_DIR%

REM --- Config (never overwrite) ---
if not exist "%CONF_DIR%\config" (
    copy /y "claude-cost.conf.example" "%CONF_DIR%\config" >nul
    echo   Created config: %CONF_DIR%\config
) else (
    echo   Config exists: %CONF_DIR%\config (not overwritten)
)

REM --- Read schedule from config (defaults: 02:00) ---
set "SCHEDULE_HOUR=2"
set "SCHEDULE_MINUTE=0"
if exist "%CONF_DIR%\config" (
    for /f "usebackq tokens=1,* delims==" %%a in ("%CONF_DIR%\config") do (
        if "%%a"=="SCHEDULE_HOUR" set "SCHEDULE_HOUR=%%b"
        if "%%a"=="SCHEDULE_MINUTE" set "SCHEDULE_MINUTE=%%b"
    )
)

REM --- Remove quotes if present ---
set "SCHEDULE_HOUR=%SCHEDULE_HOUR:"=%"
set "SCHEDULE_MINUTE=%SCHEDULE_MINUTE:"=%"

REM --- Pad minute to 2 digits ---
if %SCHEDULE_MINUTE% lss 10 set "SCHEDULE_MINUTE=0%SCHEDULE_MINUTE%"

REM --- Schedule via Task Scheduler ---
set "TASK_NAME=claude-cost-collect"
set "COLLECT_SCRIPT=%BIN_DIR%\claude-cost-collect"

REM Delete existing task if present
schtasks /delete /tn "%TASK_NAME%" /f >nul 2>nul

schtasks /create /tn "%TASK_NAME%" /tr "\"%BASH_EXE%\" -l -c \"%COLLECT_SCRIPT:\=/%\"" /sc daily /st %SCHEDULE_HOUR%:%SCHEDULE_MINUTE% /f >nul
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to create scheduled task.
    exit /b 1
)
echo   Scheduled: daily at %SCHEDULE_HOUR%:%SCHEDULE_MINUTE%

echo.
echo Done! Run the following in Git Bash for immediate first collection:
echo   %BIN_DIR:\=/%/claude-cost-collect
