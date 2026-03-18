param(
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"

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
& $Dotnet.Source publish $Project -c Release -r win-x64 --self-contained true -o $PublishDir /p:PublishSingleFile=true

$PortableOut = Join-Path $DistDir "VoiceLink-$Version-windows-portable.exe"
$SetupOut = Join-Path $DistDir "VoiceLink-$Version-windows-setup.exe"

Copy-Item (Join-Path $PublishDir "VoiceLinkNative.exe") $PortableOut -Force

& $Iscc.Source "/DMyAppVersion=$Version" "/DPublishDir=$PublishDir" "/DOutputDir=$DistDir" $InnoScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup build failed."
}

$PortableHash = (Get-FileHash $PortableOut -Algorithm SHA256).Hash.ToLowerInvariant()
$SetupHash = (Get-FileHash $SetupOut -Algorithm SHA256).Hash.ToLowerInvariant()

Set-Content -Path "$PortableOut.sha256" -Value "$PortableHash  $(Split-Path $PortableOut -Leaf)"
Set-Content -Path "$SetupOut.sha256" -Value "$SetupHash  $(Split-Path $SetupOut -Leaf)"

Write-Host "Built artifacts:" -ForegroundColor Green
Get-Item $PortableOut, $SetupOut, "$PortableOut.sha256", "$SetupOut.sha256" | Select-Object FullName, Length, LastWriteTime
