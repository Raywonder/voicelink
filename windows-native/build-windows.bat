echo Building VoiceLink Native Windows App...

REM Set PATH to include .NET SDK
set PATH=C:\Users\40493\.dotnet;%PATH%

REM Change to correct directory
cd VoiceLinkNative

REM Build the app
dotnet build ./VoiceLinkNative.csproj -c Release -r win-x64 --self-contained true -o ./publish/win-x64

echo Build completed! Check publish/win-x64 directory for executable.
echo.