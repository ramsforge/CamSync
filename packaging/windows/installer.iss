; CamSync Inno Setup Installer Script
; Produces a unified installer for Windows with automatic COM Virtual Camera Driver registration

#define MyAppName "CamSync"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "CamSync Project"
#define MyAppURL "https://github.com/camsync/camsync"
#define MyAppExeName "desktop.exe"

[Setup]
AppId={{D37F21F2-9844-4A8E-8167-DF9846E9BC01}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\..\LICENSE
OutputDir=..\..\Output
OutputBaseFilename=CamSync-Setup-v{#MyAppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Flutter Desktop Companion Executable and Assets
Source: "..\..\apps\desktop\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; Native DirectShow Virtual Camera Filter (registered with regserver)
Source: "..\..\build\native\driver\Release\CamSyncVirtualCam.dll"; DestDir: "{app}"; Flags: ignoreversion regserver

; Native Hardware Decoder and Shared Memory Bridge
Source: "..\..\build\native\Release\camsync_native.dll"; DestDir: "{app}"; Flags: ignoreversion

; Diagnostic and Testing Tools
Source: "..\..\build\native\Release\camsync_feeder.exe"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "..\..\build\native\Release\camsync_list_devices.exe"; DestDir: "{app}\tools"; Flags: ignoreversion

; Manual Registration Scripts
Source: "scripts\register_filter.bat"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "scripts\unregister_filter.bat"; DestDir: "{app}\scripts"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
