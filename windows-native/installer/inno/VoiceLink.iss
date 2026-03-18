#define MyAppName "VoiceLink"
#define MyAppPublisher "Devine Creations"
#define MyAppExeName "VoiceLinkNative.exe"

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#ifndef PublishDir
  #define PublishDir "..\..\publish\win-x64"
#endif

#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{C5F4D4CF-4A2F-4B39-ACDF-E367B8F3D3E0}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir={#OutputDir}
OutputBaseFilename=VoiceLink-{#MyAppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
