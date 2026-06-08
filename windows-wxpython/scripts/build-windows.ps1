param(
    [string]$Python = "",
    [string]$Configuration = "Release",
    [string]$Version = "0.1.0",
    [string]$Build = "6",
    [string]$OutputDir = "E:\Downloads\VoiceLinkWX"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $root
$venv = Join-Path $env:TEMP "voicelink-wxpython-venv"
$dist = Join-Path $root "dist"
$work = Join-Path $root "build"
$entry = Join-Path $root "src\voicelink_wx.py"
$icon = Join-Path $repoRoot "assets\icons\voicelink.ico"
$innoScript = Join-Path $root "installer\inno\VoiceLinkWX.iss"
$iscc = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

if (-not $Python) {
    $uvPython = Join-Path $env:APPDATA "uv\python\cpython-3.12.12-windows-x86_64-none\python.exe"
    if (Test-Path $uvPython) {
        $Python = $uvPython
    } else {
        $Python = "py -3.12"
    }
}

New-Item -ItemType Directory -Force -Path $OutputDir, $dist, $work | Out-Null

if (-not (Test-Path $venv)) {
    & $Python -m venv $venv
}

$venvPython = Join-Path $venv "Scripts\python.exe"
& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install -r (Join-Path $root "requirements.txt") pyinstaller

$pyInstallerArgs = @(
    "-m", "PyInstaller",
    "--noconfirm",
    "--clean",
    "--windowed",
    "--name", "VoiceLinkWX",
    "--distpath", $dist,
    "--workpath", $work,
    "--specpath", $work
)

if (Test-Path $icon) {
    $pyInstallerArgs += @("--icon", $icon)
}

$pyInstallerArgs += $entry
& $venvPython @pyInstallerArgs

$appDir = Join-Path $dist "VoiceLinkWX"
$exe = Join-Path $appDir "VoiceLinkWX.exe"
if (-not (Test-Path $exe)) {
    throw "VoiceLinkWX.exe was not produced."
}

$zipName = "VoiceLinkWX-$Version.$Build-win-x64-portable.zip"
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $appDir "*") -DestinationPath $zipPath -Force

$manifest = [ordered]@{
    version = "$Version.$Build"
    latest_version = "$Version.$Build"
    file_name = $zipName
    portable_url = "/downloads/voicelink/windows/$zipName"
    checksum_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
    release_notes = "VoiceLinkWX $Version.$Build fixes Enter on the room list. Pressing Enter now opens an accessible room details dialog with Join room as the default action."
}
$manifestPath = Join-Path $OutputDir "voicelink-wxpython-update.json"
[System.IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 4),
    [System.Text.UTF8Encoding]::new($false))

Copy-Item -LiteralPath $exe -Destination (Join-Path $OutputDir "VoiceLinkWX.exe") -Force

$setupPath = $null
if (Test-Path $innoScript) {
    if (-not (Test-Path $iscc)) {
        $iscc = "C:\Program Files\Inno Setup 6\ISCC.exe"
    }

    if (Test-Path $iscc) {
        $setupVersion = "$Version.$Build"
        & $iscc "/DMyAppVersion=$setupVersion" "/DPublishDir=$appDir" "/DOutputDir=$OutputDir" $innoScript
        if ($LASTEXITCODE -ne 0) {
            throw "Inno Setup build failed."
        }

        $setupPath = Join-Path $OutputDir "VoiceLinkWX-$setupVersion-windows-setup.exe"
        if (Test-Path $setupPath) {
            $setupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash.ToLowerInvariant()
            [System.IO.File]::WriteAllText(
                "$setupPath.sha256",
                "$setupHash  $(Split-Path -Leaf $setupPath)`r`n",
                [System.Text.UTF8Encoding]::new($false))
            $manifest.installer_url = "/downloads/voicelink/windows/$(Split-Path -Leaf $setupPath)"
            $manifest.installer_checksum_sha256 = $setupHash
            [System.IO.File]::WriteAllText(
                $manifestPath,
                ($manifest | ConvertTo-Json -Depth 4),
                [System.Text.UTF8Encoding]::new($false))
        }
    } else {
        Write-Warning "Inno Setup compiler not found; portable artifacts were built without a setup EXE."
    }
}

Write-Host "Executable: $exe"
Write-Host "Portable: $zipPath"
Write-Host "Manifest: $manifestPath"
if ($setupPath) {
    Write-Host "Installer: $setupPath"
}
