param(
    [string]$Version = "1.0.0",
    [string]$Build = "48"
)

$ErrorActionPreference = "Stop"

function Resolve-SignTool {
    $preferredPaths = @(
        "C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe",
        "C:\Program Files\Windows Kits\10\bin\x64\signtool.exe"
    )
    foreach ($path in $preferredPaths) {
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
    param(
        [string]$FilePath
    )

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

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Project = Join-Path $Root "VoiceLinkNative/VoiceLinkNative.csproj"
$PublishDir = Join-Path $Root "publish/win-x64"
$DistDir = Join-Path $Root "dist"
$InnoScript = Join-Path $Root "installer/inno/VoiceLink.iss"

New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

$PreferredDotnet = "C:\Program Files\dotnet\dotnet.exe"
$Dotnet = $null
if (Test-Path $PreferredDotnet) {
    $Dotnet = @{ Source = $PreferredDotnet }
} else {
    $ResolvedDotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($ResolvedDotnet) {
        $Dotnet = @{ Source = $ResolvedDotnet.Source }
    } else {
        throw "dotnet SDK is required. Install .NET 8 SDK first."
    }
}

$SdkList = & $Dotnet.Source --list-sdks
if (-not $SdkList) {
    throw "The resolved dotnet binary does not have any SDKs available."
}

if (-not (Test-Path $InnoScript)) {
    throw "Inno Setup script not found at $InnoScript"
}

$Iscc = Get-Command iscc -ErrorAction SilentlyContinue
if (-not $Iscc) {
    $FallbackIscc = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    if (Test-Path $FallbackIscc) {
        $Iscc = @{ Source = $FallbackIscc }
    } else {
        throw "Inno Setup Compiler (ISCC.exe) is required. Install Inno Setup 6 first."
    }
}

& $Dotnet.Source restore $Project
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed."
}
& $Dotnet.Source publish $Project -c Release -r win-x64 --self-contained true -o $PublishDir /p:PublishSingleFile=true /p:FileVersion="$Version.$Build" /p:InformationalVersion="$Version+$Build"
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed."
}

$PortableOut = Join-Path $DistDir "VoiceLink-$Version-windows-portable.exe"
$SetupOut = Join-Path $DistDir "VoiceLink-$Version-windows-setup.exe"

Copy-Item (Join-Path $PublishDir "VoiceLinkNative.exe") $PortableOut -Force

& $Iscc.Source "/DMyAppVersion=$Version" "/DPublishDir=$PublishDir" "/DOutputDir=$DistDir" $InnoScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup build failed."
}

Sign-Artifact -FilePath $PortableOut
Sign-Artifact -FilePath $SetupOut

$PortableHash = (Get-FileHash $PortableOut -Algorithm SHA256).Hash.ToLowerInvariant()
$SetupHash = (Get-FileHash $SetupOut -Algorithm SHA256).Hash.ToLowerInvariant()

Set-Content -Path "$PortableOut.sha256" -Value "$PortableHash  $(Split-Path $PortableOut -Leaf)"
Set-Content -Path "$SetupOut.sha256" -Value "$SetupHash  $(Split-Path $SetupOut -Leaf)"

Write-Host "Built artifacts:" -ForegroundColor Green
Get-Item $PortableOut, $SetupOut, "$PortableOut.sha256", "$SetupOut.sha256" | Select-Object FullName, Length, LastWriteTime
