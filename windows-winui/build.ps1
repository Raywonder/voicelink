param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug"
)

$ErrorActionPreference = "Stop"
$arch = $env:PROCESSOR_ARCHITECTURE
$platform = if ($arch -eq "AMD64") { "x64" } else { $arch }
$project = Join-Path $PSScriptRoot "VoiceLink.WinUI\VoiceLink.WinUI.csproj"

dotnet build $project `
    -c $Configuration `
    -p:Platform=$platform `
    -p:GenerateAppxPackageOnBuild=false `
    -p:AppxPackage=false `
    -p:EnableMsixTooling=false
