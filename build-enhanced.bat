@echo off
echo Building VoiceLink v1.0.4 with Enhanced Port Detection...
echo =============================================================

:: Copy enhanced files
echo Copying enhanced port detection files...
copy /Y "client\js\core\port-detector.js" "client\js\core\app.js.bak" 2>nul
copy /Y "client\js\core\app-enhanced.js" "client\js\core\app.js" 2>nul
copy /Y "..\server\routes\local-server-updated.js" "..\server\routes\local-server.js" 2>nul

:: Check if Node.js is installed
node --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Node.js is not installed!
    echo Please install Node.js from https://nodejs.org/
    pause
    exit /b 1
)

:: Install dependencies
echo Installing dependencies...
call npm install

:: Build application
echo Building enhanced application...
call npm run build:prod

:: Build Windows executable
echo Building Windows executable...
call npm run build:win

:: Check if build was successful
if exist "releases\win-unpacked\VoiceLink Local.exe" (
    echo SUCCESS: Enhanced build completed!
    echo.
    echo ✅ New Features:
    echo   - Auto-port detection
    echo   - Enhanced server discovery
    echo   - Improved connection handling
    echo   - Better error reporting
    echo.
    echo Executable location: releases\win-unpacked\VoiceLink Local.exe
    echo.
    echo Would you like to run the enhanced application now? (Y/N)
    set /p choice=
    if /i "%choice%"=="Y" (
        start "" "releases\win-unpacked\VoiceLink Local.exe"
    )
) else (
    echo ERROR: Build failed!
    echo Please check error messages above.
)

pause