param(
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Project = Join-Path $Root "VoiceLinkNative/VoiceLinkNative.csproj"
$PublishDir = Join-Path $Root "publish/win-x64"
$DistDir = Join-Path $Root "dist"
$WixMsi = Join-Path $Root "installer/wix/VoiceLink.msi.wxs"
$WixBundle = Join-Path $Root "installer/wix/VoiceLink.bundle.wxs"

New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK is required. Install .NET 8 SDK first."
}

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    dotnet tool install --global wix
}

$env:Path = "$env:USERPROFILE\.dotnet\tools;$env:Path"

wix extension add WixToolset.UI.wixext | Out-Null
wix extension add WixToolset.Bal.wixext | Out-Null

dotnet restore $Project
dotnet publish $Project -c Release -r win-x64 --self-contained true -o $PublishDir /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true /p:PublishTrimmed=false

$MsiOut = Join-Path $DistDir "VoiceLinkNative-$Version-win-x64.msi"
$ExeOut = Join-Path $DistDir "VoiceLinkNative-$Version-setup.exe"
$PortableOut = Join-Path $DistDir "VoiceLink-$Version-windows-portable.exe"
$PortableSha = "$PortableOut.sha256"
$SetupOut = Join-Path $DistDir "VoiceLink-$Version-windows-setup.exe"
$SetupSha = "$SetupOut.sha256"
$MsiNamed = Join-Path $DistDir "VoiceLink-$Version-windows.msi"

wix build $WixMsi -arch x64 -d Version=$Version -d PublishDir=$PublishDir -o $MsiOut
wix build $WixBundle -arch x64 -ext WixToolset.Bal.wixext -d Version=$Version -d DistDir=$DistDir -o $ExeOut

Copy-Item "$PublishDir\VoiceLinkNative.exe" $PortableOut -Force
Copy-Item $ExeOut $SetupOut -Force
Copy-Item $MsiOut $MsiNamed -Force
(Get-FileHash $PortableOut -Algorithm SHA256).Hash | Out-File -FilePath $PortableSha -Encoding ascii
(Get-FileHash $SetupOut -Algorithm SHA256).Hash | Out-File -FilePath $SetupSha -Encoding ascii

if ((Get-FileHash $PortableOut -Algorithm SHA256).Hash -eq (Get-FileHash $SetupOut -Algorithm SHA256).Hash) {
    throw "Setup EXE hash matches portable EXE hash. Refusing release because installer payload is invalid."
}

Write-Host "Built artifacts:" -ForegroundColor Green
Get-Item $MsiNamed, $SetupOut, $PortableOut, $SetupSha, $PortableSha | Select-Object FullName, Length, LastWriteTime
