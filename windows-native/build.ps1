# VoiceLink Native Windows Build Script
# Run this script from PowerShell on Windows

param(
    [string]$Configuration = "Release",
    [switch]$Clean,
    [switch]$Publish
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "VoiceLink Native Windows Build" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$ProjectDir = Split-Path -Parent $PSScriptRoot
$SolutionFile = Join-Path $ProjectDir "VoiceLinkNative.sln"
$ProjectFile = Join-Path $ProjectDir "VoiceLinkNative\VoiceLinkNative.csproj"
$OutputDir = Join-Path $ProjectDir "bin\$Configuration"

# Check for .NET SDK
Write-Host "Checking for .NET SDK..." -ForegroundColor Yellow
$dotnetVersion = dotnet --version
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: .NET SDK not found. Please install .NET 8 SDK." -ForegroundColor Red
    exit 1
}
Write-Host "Found .NET SDK: $dotnetVersion" -ForegroundColor Green

# Clean if requested
if ($Clean) {
    Write-Host "Cleaning build output..." -ForegroundColor Yellow
    dotnet clean $ProjectFile -c $Configuration
    if (Test-Path $OutputDir) {
        Remove-Item -Recurse -Force $OutputDir
    }
}

# Restore NuGet packages
Write-Host "Restoring NuGet packages..." -ForegroundColor Yellow
dotnet restore $ProjectFile
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to restore packages." -ForegroundColor Red
    exit 1
}

# Build the project
Write-Host "Building VoiceLink Native ($Configuration)..." -ForegroundColor Yellow
dotnet build $ProjectFile -c $Configuration --no-restore
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Build failed." -ForegroundColor Red
    exit 1
}

Write-Host "Build completed successfully!" -ForegroundColor Green

# Publish if requested (creates self-contained executable)
if ($Publish) {
    Write-Host "Publishing self-contained application..." -ForegroundColor Yellow

    $PublishDir = Join-Path $ProjectDir "publish"

    # Publish for Windows x64
    dotnet publish $ProjectFile -c $Configuration -r win-x64 --self-contained true -o "$PublishDir\win-x64" /p:PublishSingleFile=true
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Publish failed for win-x64." -ForegroundColor Red
        exit 1
    }

    # Publish for Windows x86
    dotnet publish $ProjectFile -c $Configuration -r win-x86 --self-contained true -o "$PublishDir\win-x86" /p:PublishSingleFile=true
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Publish failed for win-x86." -ForegroundColor Red
        exit 1
    }

    # Publish for Windows ARM64
    dotnet publish $ProjectFile -c $Configuration -r win-arm64 --self-contained true -o "$PublishDir\win-arm64" /p:PublishSingleFile=true
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Publish failed for win-arm64." -ForegroundColor Red
        exit 1
    }

    Write-Host "Published to: $PublishDir" -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Output: $OutputDir" -ForegroundColor White

if ($Publish) {
    Write-Host "Published builds available in: $ProjectDir\publish" -ForegroundColor White
}
