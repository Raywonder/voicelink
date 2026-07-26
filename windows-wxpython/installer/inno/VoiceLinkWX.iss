#define MyAppName "VoiceLink"
#define MyAppPublisher "Devine Creations"
#define MyAppExeName "VoiceLinkWX.exe"

#ifndef MyAppVersion
  #define MyAppVersion "0.1.0.1"
#endif

#ifndef PublishDir
  #define PublishDir "..\..\dist\VoiceLinkWX"
#endif

#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{C5F4D4CF-4A2F-4B39-ACDF-E367B8F3D3E0}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://voicelinkapp.app/
AppSupportURL=https://voicelinkapp.app/support
AppUpdatesURL=https://voicelinkapp.app/downloads/voicelink/windows/voicelink-wxpython-update.json
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir={#OutputDir}
OutputBaseFilename=VoiceLinkWX-{#MyAppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
SetupLogging=yes
CloseApplications=yes
CloseApplicationsFilter={#MyAppExeName}
RestartApplications=no
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=VoiceLink wxPython Windows client installer
VersionInfoProductName={#MyAppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
Type: files; Name: "{userdesktop}\VoiceLink.lnk"
Type: files; Name: "{commondesktop}\VoiceLink.lnk"
Type: files; Name: "{app}\VoiceLink.WinUI.exe"
Type: files; Name: "{app}\VoiceLink.WinUI.dll"
Type: files; Name: "{app}\VoiceLinkNative.exe"
Type: files; Name: "{app}\VoiceLinkNative.dll"
Type: files; Name: "{localappdata}\Programs\VoiceLink\VoiceLink.exe"
Type: files; Name: "{localappdata}\Programs\VoiceLink\VoiceLink.WinUI.exe"
Type: files; Name: "{localappdata}\Programs\VoiceLink\VoiceLinkNative.exe"
Type: files; Name: "{localappdata}\Programs\VoiceLink\VoiceLinkWX.exe"
Type: filesandordirs; Name: "{localappdata}\Programs\VoiceLink"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
Root: HKLM; Subkey: "Software\DevineCreations\VoiceLink"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\DevineCreations\VoiceLink"; ValueType: string; ValueName: "Client"; ValueData: "wxPython"
Root: HKLM; Subkey: "Software\DevineCreations\VoiceLink"; ValueType: string; ValueName: "Executable"; ValueData: "{app}\{#MyAppExeName}"
Root: HKCU; Subkey: "Software\DevineCreations\VoiceLink"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"
Root: HKCU; Subkey: "Software\DevineCreations\VoiceLink"; ValueType: string; ValueName: "Client"; ValueData: "wxPython"
Root: HKCU; Subkey: "Software\DevineCreations\VoiceLink"; ValueType: string; ValueName: "Executable"; ValueData: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: postinstall skipifsilent shellexec nowait
Filename: "{app}\{#MyAppExeName}"; Flags: skipifnotsilent shellexec nowait
