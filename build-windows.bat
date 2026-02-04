@echo off
echo =============================================================
echo Building VoiceLink v1.0.4 for Windows
echo =============================================================

:: Copy enhanced files
echo Copying enhanced port detection files...
copy /Y "client\js\core\port-detector.js" "client\js\core\app.js.bak" 2>nul
copy /Y "client\js\core\app-enhanced.js" "client\js\core\app.js" 2>nul

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

:: Build Windows setup installer (NSIS)
echo Building Windows Setup Installer...
call npm run build:win-setup

:: Build Windows portable executable  
echo Building Windows Portable Version...
call npm run build:win-portable

:: Check if build was successful
if exist "releases\win-unpacked\VoiceLink Local.exe" (
    if exist "releases\VoiceLink Local-1.0.4-setup.exe" (
        echo SUCCESS: Enhanced build completed!
        echo.
        echo ✅ Built Files:
        echo   - VoiceLink Local-1.0.4-setup.exe ^(Setup Installer^)
        echo   - VoiceLink Local-1.0.4-portable.exe ^(Portable Version^)
        echo   - VoiceLink Local-1.0.4-win.zip ^(ZIP Archive^)
        echo   - VoiceLink Local-1.0.4-ia32-win.zip ^(32-bit ZIP^)
        echo.
        echo ✅ New Features:
        echo   - Auto-port detection
        echo   - Enhanced server discovery
        echo   - Improved connection handling
        echo   - Better error reporting
        echo   - License-based access control
        echo   - Device limit management
        echo.
        echo 📁 Files created in: releases\
        echo.
        echo Would you like to run the setup version now? (Y/N)
        set /p choice=
        if /i "%choice%"=="Y" (
            start "" "releases\VoiceLink Local-1.0.4-setup.exe"
        )
    ) else (
        echo ERROR: Build failed!
        echo Please check error messages above.
    )
) else (
    echo ERROR: Build failed!
    echo Please check error messages above.
)

pause
    exit /b 1
)

:: Install dependencies
echo Installing dependencies...
call npm install

:: Build the application
echo Building application...
call npm run build:win

:: Check if build was successful
if exist "releases\win-unpacked\VoiceLink Local.exe" (
    echo SUCCESS: Build completed!
    echo Executable location: releases\win-unpacked\VoiceLink Local.exe
    echo.
    echo Would you like to run the application now? (Y/N)
    set /p choice=
    if /i "%choice%"=="Y" (
        start "" "releases\win-unpacked\VoiceLink Local.exe"
    )
) else (
    echo ERROR: Build failed!
    echo Please check the error messages above.
)

pause