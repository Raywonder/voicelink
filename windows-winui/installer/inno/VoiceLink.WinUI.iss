#define MyAppName "VoiceLink"
#define MyAppPublisher "Devine Creations"
#define MyAppExeName "VoiceLink.WinUI.exe"

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0.79"
#endif

#ifndef PublishDir
  #define PublishDir "..\..\VoiceLink.WinUI\bin\x64\Release\net8.0-windows10.0.26100.0\win-x64"
#endif

#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{C5F4D4CF-4A2F-4B39-ACDF-E367B8F3D3E0}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://devinecreations.net/
AppSupportURL=https://devinecreations.net/
AppUpdatesURL=https://devinecreations.net/
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir={#OutputDir}
OutputBaseFilename=VoiceLink-{#MyAppVersion}-windows-winui-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
SetupLogging=yes
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=VoiceLink native WinUI client installer
VersionInfoProductName={#MyAppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
Type: files; Name: "{app}\VoiceLinkNative.exe"
Type: files; Name: "{app}\VoiceLinkNative.dll"
Type: files; Name: "{app}\VoiceLinkNative.deps.json"
Type: files; Name: "{app}\VoiceLinkNative.runtimeconfig.json"
Type: files; Name: "{app}\VoiceLinkNative.pdb"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCR; Subkey: "voicelink"; ValueType: string; ValueName: ""; ValueData: "URL:VoiceLink Protocol"; Flags: uninsdeletekey
Root: HKCR; Subkey: "voicelink"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCR; Subkey: "voicelink\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKCR; Subkey: "voicelink\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""
Root: HKCU; Subkey: "Software\DevineCreations\VoiceLink"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"
Root: HKCU; Subkey: "Software\DevineCreations\VoiceLink"; ValueType: string; ValueName: "Client"; ValueData: "WinUI"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: postinstall skipifsilent shellexec nowait
