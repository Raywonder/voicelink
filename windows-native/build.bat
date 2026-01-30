@echo off
REM VoiceLink Native Windows Build Script
REM Run this from Command Prompt on Windows

echo ========================================
echo VoiceLink Native Windows Build
echo ========================================
echo.

REM Check for .NET SDK
dotnet --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: .NET SDK not found. Please install .NET 8 SDK from:
    echo https://dotnet.microsoft.com/download/dotnet/8.0
    exit /b 1
)

REM Navigate to script directory
cd /d "%~dp0"

REM Restore packages
echo Restoring NuGet packages...
dotnet restore VoiceLinkNative\VoiceLinkNative.csproj
if errorlevel 1 (
    echo ERROR: Failed to restore packages.
    exit /b 1
)

REM Build
echo Building VoiceLink Native (Release)...
dotnet build VoiceLinkNative\VoiceLinkNative.csproj -c Release --no-restore
if errorlevel 1 (
    echo ERROR: Build failed.
    exit /b 1
)

echo.
echo ========================================
echo Build Complete!
echo ========================================
echo.
echo Output: VoiceLinkNative\bin\Release\net8.0-windows
echo.
pause
