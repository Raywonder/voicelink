param(
    [string]$Version = "1.0.0",
    [string]$Build = "79",
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

function Resolve-Iscc {
    $resolved = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($resolved) {
        return $resolved.Source
    }

    $fallback = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    if (Test-Path $fallback) {
        return $fallback
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        winget install --id JRSoftware.InnoSetup --source winget --silent --accept-package-agreements --accept-source-agreements
        if (Test-Path $fallback) {
            return $fallback
        }
    }

    throw "Inno Setup Compiler (ISCC.exe) is required. Install Inno Setup 6 and rerun this script."
}

function Resolve-SignTool {
    $paths = @(
        "C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe",
        "C:\Program Files\Windows Kits\10\bin\x64\signtool.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            return $path
        }
    }

    $resolved = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($resolved) {
        return $resolved.Source
    }

    return $null
}

function Sign-Artifact {
    param([string]$FilePath)

    $signTool = Resolve-SignTool
    if (-not $signTool) {
        Write-Warning "signtool.exe not found; skipping Windows code signing."
        return
    }

    $timestampUrl = if ($env:WINDOWS_CODESIGN_TIMESTAMP_URL) { $env:WINDOWS_CODESIGN_TIMESTAMP_URL } else { "http://timestamp.digicert.com" }

    if ($env:WINDOWS_CODESIGN_PFX -and $env:WINDOWS_CODESIGN_PASSWORD) {
        & $signTool sign /fd SHA256 /tr $timestampUrl /td SHA256 /f $env:WINDOWS_CODESIGN_PFX /p $env:WINDOWS_CODESIGN_PASSWORD $FilePath
    } elseif ($env:WINDOWS_CODESIGN_THUMBPRINT) {
        & $signTool sign /fd SHA256 /tr $timestampUrl /td SHA256 /sha1 $env:WINDOWS_CODESIGN_THUMBPRINT $FilePath
    } else {
        Write-Host "No Windows code-signing identity configured; skipping signing for $FilePath"
        return
    }

    if ($LASTEXITCODE -ne 0) {
        throw "signtool.exe failed while signing $FilePath"
    }
}

$root = $PSScriptRoot
$project = Join-Path $root "VoiceLink.WinUI\VoiceLink.WinUI.csproj"
$script = Join-Path $root "installer\inno\VoiceLink.WinUI.iss"
$dist = Join-Path $root "dist"
$fullVersion = "$Version.$Build"
$arch = $env:PROCESSOR_ARCHITECTURE
$platform = if ($arch -eq "AMD64") { "x64" } else { $arch }
$publishDir = Join-Path $root "VoiceLink.WinUI\bin\$platform\$Configuration\net8.0-windows10.0.26100.0\win-$platform"

New-Item -ItemType Directory -Path $dist -Force | Out-Null

& (Join-Path $root "build.ps1") -Configuration $Configuration

$iscc = Resolve-Iscc
& $iscc "/DMyAppVersion=$fullVersion" "/DPublishDir=$publishDir" "/DOutputDir=$dist" $script
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup build failed."
}

$setup = Join-Path $dist "VoiceLink-$fullVersion-windows-winui-setup.exe"
Sign-Artifact -FilePath $setup

$hash = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -Path "$setup.sha256" -Value "$hash  $(Split-Path $setup -Leaf)"

Write-Host "Built VoiceLink WinUI installer:" -ForegroundColor Green
Get-Item $setup, "$setup.sha256" | Select-Object FullName, Length, LastWriteTime
